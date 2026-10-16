/// Terminal state management wrapping libghostty-vt.
///
/// Holds the resources for one Ghostel terminal, including rendering state
/// and, for native PTY sessions, the process reader.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const emacs = @import("emacs");
const gt = @import("ghostty-vt");
const GhostelHandler = @import("handler.zig").GhostelHandler;
const Renderer = @import("Renderer.zig");
const RecursiveMutex = @import("RecursiveMutex.zig");
const input = @import("input.zig");
const utils = @import("utils.zig");
const parseHexColor = utils.parseHexColor;
const platform = @import("platform.zig");
const pty_utils = @import("pty_utils.zig");

const NativeProcess = @import("NativeProcess.zig");
const ChildProcess = NativeProcess.ChildProcess;
const RefCount = @import("RefCount.zig").RefCount;
const WinSize = @import("backend_types.zig").WinSize;
const ChannelFd = NativeProcess.ChannelFd;
const ProcessParams = NativeProcess.ProcessParams;
const ProcessPid = i64;
const HandoffProtocolVersion = 1;

const Self = @This();

alloc: Allocator,
io: std.Io,
// Emacs owns one reference; each native reader retains one until its last
// terminal access, including callbacks that temporarily unlock for pipe I/O.
refcount: RefCount(Self) = .init(1),
mutex: RecursiveMutex = .{},
terminal: gt.Terminal,
/// Creation options; their limits also govern restored snapshots.
options: gt.Terminal.Options,
stream: gt.Stream(GhostelHandler(*Self)),
string_buffer: ?[]u8 = null,
renderer: Renderer,
process: ?*NativeProcess = null,
/// Desired native output-refresh gate; owned by the Emacs thread.
refresh_enabled: bool = true,
/// Last window size sent to the PTY.
pty_size: WinSize = .{ .cols = 0, .rows = 0 },
/// Light/dark as classified by Emacs for `ghostel-default`; reported via CSI 996/997.
color_scheme: gt.device_status.ColorScheme = .dark,
/// Name and version answered to XTVERSION; null answers libghostty's default.
xtversion: ?[]u8 = null,
emacs_process_pid: ?i64 = null,

/// Create a new terminal with the given dimensions and scrollback.
pub fn init(
    alloc: Allocator,
    io: std.Io,
    env: emacs.Env,
    opts_arg: gt.Terminal.Options,
) !*Self {
    if (opts_arg.cols == 0 or opts_arg.rows == 0) return error.InvalidSize;

    var opts = opts_arg;
    opts.default_modes = .{ .grapheme_cluster = true };

    const term = try alloc.create(Self);
    errdefer alloc.destroy(term);

    term.* = Self{
        .alloc = alloc,
        .io = io,
        .terminal = try .init(io, alloc, opts),
        .options = opts,
        .renderer = undefined,
        .stream = undefined,
    };
    errdefer term.terminal.deinit(alloc);

    term.stream = .init(.{ .allocator = alloc, .handler = .init(alloc, term, term) });
    errdefer term.stream.deinit();

    term.renderer = try .init(alloc, env, &term.terminal);

    return term;
}

/// Release Emacs ownership without waiting for native event delivery.
pub fn deinit(self: *Self) void {
    self.killNativeProcess();
    self.refcount.release();
}

pub fn destroy(self: *Self) void {
    std.debug.assert(self.process == null);

    self.renderer.deinit();
    self.stream.deinit();
    self.terminal.deinit(self.alloc);
    if (self.string_buffer) |buf| self.alloc.free(buf);
    if (self.xtversion) |v| self.alloc.free(v);
    self.alloc.destroy(self);
}

pub fn redraw(self: *Self, force_full: bool, force_sync: bool) !bool {
    if (!self.mutex.tryLock()) return false;
    defer self.unlock();

    const env = emacs.current_env orelse return false;
    const pre_size = .{ self.terminal.cols, self.terminal.rows };
    if (!try self.renderer.redraw(env, force_full, force_sync)) return false;

    if (self.process) |proc| {
        const size = self.winSize();
        if (!std.meta.eql(size, self.pty_size)) {
            try proc.resizePty(size);
            self.pty_size = size;
        }
    } else if (try nativeTransportTerm(env)) |transport_term| {
        const size = self.winSize();
        if (!std.meta.eql(size, self.pty_size)) {
            try env.checkNonLocalExit();
            const result = env.f("ghostel--handoff-resize", .{
                transport_term,
                size.rows,
                size.cols,
                size.xpixel,
                size.ypixel,
            });
            try env.checkNonLocalExit();
            if (env.eq(result, env.t())) self.pty_size = size;
        }
    } else if (!std.meta.eql(pre_size, .{ self.terminal.cols, self.terminal.rows })) {
        // Emacs-owned PTYs carry no pixel geometry.
        const process = env.symbolValue("ghostel--process");
        if (env.isNotNil(process)) {
            _ = env.f("set-process-window-size", .{ process, self.terminal.rows, self.terminal.cols });
        }
    }
    return true;
}

/// Window size for the PTY.  The terminal must be locked.
fn winSize(self: *Self) WinSize {
    return .{
        .cols = self.terminal.cols,
        .rows = self.terminal.rows,
        .xpixel = std.math.lossyCast(u16, self.terminal.width_px),
        .ypixel = std.math.lossyCast(u16, self.terminal.height_px),
    };
}

fn queueTransportResizeIfChanged(cached: *WinSize, requested: WinSize, queue: anytype) !bool {
    if (std.meta.eql(cached.*, requested)) return false;
    try queue.enqueue(requested);
    cached.* = requested;
    return true;
}

/// Set the color palette (256 entries). The terminal must be locked.
fn setColorPaletteLocked(self: *Self, palette: gt.color.Palette) !void {
    try self.terminal.colors.palette.changeDefault(self.alloc, palette);
    self.terminal.flags.dirty.palette = true;
}

pub fn vtWrite(self: *Self, data: []const u8) !void {
    try self.lock();
    defer self.unlock();
    self.stream.nextSlice(data);
    self.stream.handler.flushControlMode();
}

pub fn ptyWrite(self: *Self, data: []const u8) !void {
    const env = emacs.current_env orelse return error.MissingEmacsEnv;
    if (self.process) |proc| {
        try proc.ptyWrite(env, data);
    } else {
        const bytes = env.makeUnibyteString(data);
        _ = env.f("ghostel--pty-out", .{bytes});
        preserveTerminalReplyExit(env);
    }
}

pub fn ptyWriteFromTerminal(self: *Self, data: []const u8) void {
    if (emacs.current_env) |env| {
        const transport_term = nativeTransportTerm(env) catch |err| {
            std.log.err("ghostel: Failed to inspect native transport handle: {any}", .{err});
            return;
        };
        if (transport_term) |transport| {
            const bytes = env.makeUnibyteString(data);
            if (env.nonLocalExitCheck() == .normal) {
                _ = env.f("ghostel--handoff-reply", .{ transport, bytes });
            }
            preserveTerminalReplyExit(env);
            return;
        }
    }

    self.ptyWrite(data) catch |err| {
        std.log.err("ghostel: Failed to write to PTY from terminal: {any}", .{err});
    };
}

fn preserveTerminalReplyExit(env: emacs.Env) void {
    const exit = env.nonLocalExitGet();
    if (exit.status == .signal) {
        env.nonLocalExitClear();
        if (env.eq(exit.symbol, emacs.sym.quit)) {
            env.nonLocalExitSignal(exit.symbol, exit.data);
        }
    }
}

fn nativeTransportTerm(env: emacs.Env) !?emacs.Value {
    const var_symbol = emacs.sym.@"ghostel--native-transport-term";
    const is_bound = env.f("boundp", .{var_symbol});
    try env.checkNonLocalExit();
    if (env.isNil(is_bound)) return null;

    const value = env.symbolValue("ghostel--native-transport-term");
    try env.checkNonLocalExit();
    return if (env.isNotNil(value)) value else null;
}

/// Replace the terminal with the snapshot DATA.  The terminal must have no
/// native process, and its VT parser must be in the ground state, which a
/// terminal that has seen no output satisfies.
pub fn restoreSnapshot(self: *Self, env: emacs.Env, data: []const u8) !void {
    try self.lock();
    defer self.unlock();
    try self.restoreSnapshotLocked(env, data, null, false);
}

pub fn restoreHandoffSnapshot(
    self: *Self,
    env: emacs.Env,
    data: []const u8,
    cell_w: u32,
    cell_h: u32,
    pixel_scale: u32,
    color_scheme: gt.device_status.ColorScheme,
) !void {
    if (!self.mutex.tryLock()) return error.TerminalBusy;
    defer self.unlock();
    try self.restoreSnapshotLocked(env, data, .{
        .cell_w = cell_w,
        .cell_h = cell_h,
        .pixel_scale = pixel_scale,
    }, true);
    self.color_scheme = color_scheme;
}

const RestoreGeometry = struct {
    cell_w: u32,
    cell_h: u32,
    pixel_scale: u32,
};

fn restoreSnapshotLocked(
    self: *Self,
    env: emacs.Env,
    data: []const u8,
    geometry: ?RestoreGeometry,
    require_ground: bool,
) !void {
    if (self.process != null) return error.TerminalHasProcess;

    var reader: std.Io.Reader = .fixed(data);
    var decoded = try gt.snapshot.decodeExact(self.alloc, self.io, &reader, .{
        .max_continuation_bytes = 1024 * 1024,
        .kitty_image_storage_limit = self.options.kitty_image_storage_limit,
    });
    defer decoded.deinit(self.alloc);

    if (require_ground) {
        switch (decoded.continuation) {
            .ground => {},
            .bytes => return error.UnsupportedSnapshotContinuation,
        }
    }

    // The old terminal and renderer stay intact until the new renderer
    // exists, so a failure leaves the terminal as it was.
    var old_terminal = self.terminal;
    self.terminal = decoded.toOwned();

    // Limits and default modes are host policy, not snapshot state.
    self.terminal.setScrollbackMaxBytes(self.options.max_scrollback_bytes);
    self.terminal.setScrollbackMaxLines(self.options.max_scrollback_lines);
    var screens = self.terminal.screens.all.iterator();
    while (screens.next()) |entry| {
        entry.value.*.kitty_images.image_limits = self.options.kitty_image_loading_limits;
    }
    self.terminal.modes.default = self.options.default_modes;
    if (require_ground and builtin.os.tag == .windows) {
        // ConPTY has no scrollback to pull into the viewport on reattach.
        self.terminal.flags.resize_pull_scrollback = false;
    }

    const renderer = if (geometry) |size|
        Renderer.initWithGeometry(
            self.alloc,
            env,
            &self.terminal,
            size.cell_w,
            size.cell_h,
            size.pixel_scale,
        )
    else
        Renderer.init(self.alloc, env, &self.terminal);
    const new_renderer = renderer catch |err| {
        self.terminal.deinit(self.alloc);
        self.terminal = old_terminal;
        return err;
    };
    // The old renderer's pin lives in the old terminal's page list.
    self.renderer.term = &old_terminal;
    self.renderer.deinit();
    self.renderer = new_renderer;
    old_terminal.deinit(self.alloc);

    if (!require_ground) {
        switch (decoded.continuation) {
            .ground => {},
            .bytes => |bytes| self.stream.nextSlice(bytes),
        }
    }
}

pub fn effect(_: *Self, comptime func: []const u8, args: anytype) void {
    if (emacs.current_env) |env| {
        _ = env.f(
            "ghostel--defer",
            &(env.makeValues(.{@field(emacs.sym, func)}) ++ env.makeValues(args)),
        );
    }
}

pub fn encode(
    self: *Self,
    buf: []u8,
    event: gt.input.KeyEvent,
) !?[]const u8 {
    const options = blk: {
        try self.lock();
        defer self.unlock();
        var options = gt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
        // Emacs resolves option-vs-meta before the event reaches us, so a
        // meta modifier always means alt.
        options.macos_option_as_alt = .true;
        break :blk options;
    };

    // Encode
    var writer = std.Io.Writer.fixed(buf);
    try gt.input.encodeKey(&writer, event, options);
    const encoded = writer.buffered();

    if (encoded.len == 0) return null;
    try self.ptyWrite(encoded);
    return encoded;
}

pub fn encodeMouse(
    self: *Self,
    action: i64,
    button: i64,
    row: i64,
    col: i64,
    mods_val: i64,
) !bool {
    const options, const pos = blk: {
        try self.lock();
        defer self.unlock();
        const t = &self.terminal;
        // An in-band column switch leaves the pixel size stale.
        const cell_w = @max(1, t.width_px / t.cols);
        const cell_h = @max(1, t.height_px / t.rows);
        // The centre of the cell, clamped to the grid.
        const x = std.math.clamp(col, 0, t.cols - 1) * cell_w + cell_w / 2;
        const y = std.math.clamp(row, 0, t.rows - 1) * cell_h + cell_h / 2;
        break :blk .{
            gt.input.MouseEncodeOptions.fromTerminal(t, .{
                .screen = .{ .width = t.cols * cell_w, .height = t.rows * cell_h },
                .cell = .{ .width = cell_w, .height = cell_h },
                .padding = .{ .top = 0, .bottom = 0, .right = 0, .left = 0 },
            }),
            gt.input.MouseEncodeEvent.Pos{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
        };
    };

    const event = gt.input.MouseEncodeEvent{
        .action = @fromBackingInt(@intCast(action)),
        .button = @fromBackingInt(@intCast(button)),
        .mods = @bitCast(@as(i16, @truncate(mods_val))),
        .pos = pos,
    };

    // Encode
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try gt.input.encodeMouse(&writer, event, options);
    const encoded = writer.buffered();

    if (encoded.len == 0) return false;
    try self.ptyWrite(encoded);
    return true;
}

pub fn encodeFocus(self: *Self, gained: bool) !bool {
    const enabled = blk: {
        try self.lock();
        defer self.unlock();
        break :blk self.terminal.modes.get(.focus_event);
    };
    if (!enabled) return false;

    const event = if (gained) gt.input.FocusEvent.gained else gt.input.FocusEvent.lost;
    var buf: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    gt.input.encodeFocus(&writer, event) catch return false;
    const encoded = writer.buffered();
    if (encoded.len == 0) return false;
    try self.ptyWrite(encoded);
    return true;
}

pub fn encodePaste(self: *Self, data: []u8) !bool {
    const options = blk: {
        try self.lock();
        defer self.unlock();
        break :blk gt.input.PasteOptions.fromTerminal(&self.terminal);
    };
    const slices = gt.input.encodePaste(data, options);

    // zsh ends a paste at any gap longer than KEYTIMEOUT, and a remote
    // terminal adds a round trip between writes, so send a single buffer.
    const bytes = try std.mem.concat(self.alloc, u8, &slices);
    defer self.alloc.free(bytes);
    if (bytes.len == 0) return false;
    try self.ptyWrite(bytes);
    return true;
}

/// Resize the terminal. The col/row size gets committed on next redraw in order
/// to ensure that the we fully render the very latest state in case any rows
/// get promoted to scrollback due to vertical shrinking of the viewport.
pub fn resize(self: *Self, cols: u16, rows: u16, cell_w: u32, cell_h: u32, pixel_scale: u32) !void {
    try self.lock();
    defer self.unlock();
    try self.renderer.resize(cols, rows, cell_w, cell_h, pixel_scale);
}

pub fn lock(self: *Self) !void {
    try self.mutex.lock(self.io);
}

pub fn unlock(self: *Self) void {
    self.mutex.unlock(self.io);
}

/// Return the child with a reference owned by the caller.
pub fn spawnNativeProcess(
    self: *Self,
    command: [][:0]const u8,
    env: *const std.process.Environ.Map,
    cwd: [:0]const u8,
    event_fd: ChannelFd,
) !*ChildProcess {
    if (command.len == 0) return error.InvalidCommand;

    const initial_size = blk: {
        try self.lock();
        defer self.unlock();
        // ConPTY keeps its own screen buffer without scrollback, so a resize
        // that pulled rows back would disagree with it about what is on screen.
        if (builtin.os.tag == .windows) self.terminal.flags.resize_pull_scrollback = false;
        break :blk self.winSize();
    };

    const process = try self.alloc.create(NativeProcess);
    errdefer self.alloc.destroy(process);
    const child = try process.init(
        self.alloc,
        self.io,
        initial_size,
        ProcessParams{ .file = command[0], .args = command, .env = env, .cwd = cwd },
        self,
        event_fd,
    );
    self.process = process;
    self.pty_size = initial_size;
    return child;
}

pub fn setRefreshEnabled(self: *Self, enabled: bool) void {
    self.refresh_enabled = enabled;
    if (self.process) |process| process.setRefreshEnabled(enabled);
}

pub fn killNativeProcess(self: *Self) void {
    if (self.process) |process| {
        process.deinit();
        self.process = null;
    }
}

pub fn isProcessLive(self: *Self) bool {
    if (self.process) |process| {
        return process.isRunning();
    } else if (emacs.current_env) |env| {
        return self.emacsProcessMaybeLive() and
            env.isNotNil(env.symbolValue("ghostel--process"));
    }

    return false;
}

fn emacsProcessMaybeLive(self: *Self) bool {
    const pid = self.emacs_process_pid orelse return true;
    if (builtin.os.tag == .windows) return true;

    const posix_pid = std.math.cast(std.posix.pid_t, pid) orelse return false;
    std.posix.kill(posix_pid, 0) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

pub fn isPasswordMode(self: *Self) !bool {
    if (builtin.os.tag == .windows) return false;

    if (self.process) |process| {
        return pty_utils.isPasswordMode(process.replicaName());
    } else if (emacs.current_env) |env| {
        const process = env.symbolValue("ghostel--process");
        if (env.isNil(process)) return false;
        const tty_name_val = env.f("process-tty-name", .{process});
        if (env.isNil(tty_name_val)) return false;

        const tty_name = env.extractStringAlloc(
            self.alloc,
            tty_name_val,
            &self.string_buffer,
        ) catch |err| switch (err) {
            error.ExtractStringFailed => return false,
            else => return err,
        };
        return pty_utils.isPasswordMode(tty_name);
    }

    return false;
}

pub fn foregroundPgid(self: *Self) !?i32 {
    if (self.process) |process| return process.foregroundPgid();
    return null;
}

var module_alloc: Allocator = undefined;
var module_io: std.Io = undefined;
var temp_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var temp_dir: []const u8 = undefined;

pub fn setModuleRuntime(allocator: Allocator, io: std.Io) void {
    module_alloc = allocator;
    module_io = io;
}

pub fn setModuleEnvironment(env: emacs.Env) !void {
    temp_dir = try env.extractString(env.f("temporary-file-directory", .{}), &temp_dir_buf);
}

fn terminalFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const term: *Self = @ptrCast(@alignCast(p));
        term.deinit();
    }
}

fn getHandoffTerm(env: emacs.Env, value: emacs.Value) !*Self {
    const term = try env.getUserPtrWithFinalizer(Self, value, terminalFinalize);
    if (term) |ptr| return ptr;
    return error.InvalidTerminalHandle;
}

fn childFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const child: *ChildProcess = @ptrCast(@alignCast(p));
        child.refcount.release();
    }
}

fn getProcessEnvironment(alloc: Allocator, env: emacs.Env) !std.process.Environ.Map {
    var env_map: std.process.Environ.Map = .init(alloc);
    errdefer env_map.deinit();

    var display_explicit = false;
    var penv = env.f("reverse", .{env.symbolValue("process-environment")});
    while (!env.isNil(penv)) : (penv = env.f("cdr", .{penv})) {
        const item = env.f("car", .{penv});
        const str = try platform.extractProcessStringAlloc(alloc, env, item);
        defer alloc.free(str);
        const key, const value = if (std.mem.indexOfScalar(u8, str, '=')) |pos|
            .{ str[0..pos], str[(pos + 1)..str.len] }
        else
            .{ str, null };
        if (std.mem.eql(u8, key, "DISPLAY")) display_explicit = true;
        if (value) |v| {
            try env_map.put(key, v);
        } else {
            _ = env_map.swapRemove(key);
        }
    }

    if (!display_explicit and env.isNotNil(env.f("display-graphic-p", .{}))) {
        const display = env.f("getenv", .{env.makeString("DISPLAY")});
        if (env.isNotNil(display)) {
            const value = try platform.extractProcessStringAlloc(alloc, env, display);
            defer alloc.free(value);
            try env_map.put("DISPLAY", value);
        }
    }

    return env_map;
}

fn validateHandoffStream(stream: anytype) !void {
    if (!stream.ground()) return error.VtParserNotGround;
    if (stream.handler.control_mode or
        stream.handler.control_buf.items.len != 0 or
        stream.handler.title_stack_len != 0)
    {
        return error.UnsupportedHandlerState;
    }
}

// ---------------------------------------------------------------------------
// Exported Elisp functions — GhostelTerm operations
// ---------------------------------------------------------------------------

pub const emacs_functions = [_]emacs.FunctionEntry{
    .{
        .name = "ghostel--new",
        .arity = .{ 2, 6 },
        .doc =
        \\Create a new ghostel terminal.
        \\
        \\(ghostel--new ROWS COLS &optional MAX-SCROLLBACK KITTY-STORAGE-LIMIT KITTY-MEDIUMS XTVERSION)
        \\
        \\KITTY-STORAGE-LIMIT is the kitty graphics image storage cap in bytes (default 320 MiB);
        \\0 disables kitty graphics entirely.
        \\KITTY-MEDIUMS is a bitfield: bit 0 = file medium, bit 1 = temp-file medium,
        \\bit 2 = shared-memory medium (default 0 = direct only).
        \\XTVERSION is the name and version string answered to XTVERSION queries
        \\(default "libghostty").
        \\
        \\The returned handle is buffer-affine: `ghostel--new' initializes
        \\renderer-owned buffer-local state in the current buffer, and later
        \\GhostelTerm operations must be called with that same buffer current.
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                // Bit 0 = file medium, bit 1 = temp_file, bit 2 = shared_mem.
                const kitty_mediums: u32 = if (nargs > 4 and env.isNotNil(args[4]))
                    (std.math.cast(u32, env.cast(i64, args[4])) orelse 0)
                else
                    0;

                const opts: gt.Terminal.Options = .{
                    .rows = std.math.cast(u16, env.cast(i64, args[0])) orelse {
                        return error.OutOfRange;
                    },

                    .cols = std.math.cast(u16, env.cast(i64, args[1])) orelse {
                        return error.OutOfRange;
                    },

                    .max_scrollback_bytes = if (nargs > 2 and env.isNotNil(args[2]))
                        (std.math.cast(usize, env.cast(i64, args[2])) orelse {
                            return error.OutOfRange;
                        })
                    else
                        5 * 1024 * 1024,

                    .kitty_image_storage_limit = if (nargs > 3 and env.isNotNil(args[3]))
                        (std.math.cast(usize, env.cast(i64, args[3])) orelse {
                            return error.OutOfRange;
                        })
                    else
                        320 * 1024 * 1024,

                    .kitty_image_loading_limits = .{
                        .file = (kitty_mediums & 0x1) != 0,
                        .temporary_file = if ((kitty_mediums & 0x2) != 0)
                            .{ .enabled = .{ .directory = temp_dir } }
                        else
                            .disabled,

                        .shared_memory = (kitty_mediums & 0x4) != 0,
                    },
                };

                const term = try init(module_alloc, module_io, env, opts);
                errdefer term.deinit();
                // Seed protocol defaults for OSC 10/11.  The renderer does
                // not paint these as cell faces; default text inherits the
                // buffer's `ghostel-default' remap instead.
                term.terminal.colors.foreground.default = .{ .r = 204, .g = 204, .b = 204 };
                term.terminal.colors.background.default = .{ .r = 0, .g = 0, .b = 0 };

                if (nargs > 5 and env.isNotNil(args[5])) {
                    term.xtversion = try module_alloc.dupe(u8, try env.extractStringAlloc(module_alloc, args[5], &term.string_buffer));
                }

                return try env.makeUserPtr(terminalFinalize, term);
            }
        },
    },
    .{
        .name = "ghostel--get-title",
        .arity = .{ 1, 1 },
        .doc =
        \\Get the terminal title.
        \\
        \\(ghostel--get-title TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                try term.lock();
                defer term.unlock();
                const title = term.terminal.getTitle();
                return if (title) |t| env.makeString(t) else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--get-pwd",
        .arity = .{ 1, 1 },
        .doc =
        \\Get the terminal's working directory from OSC 7.
        \\
        \\(ghostel--get-pwd TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                try term.lock();
                defer term.unlock();
                const pwd = term.terminal.getPwd();
                return if (pwd) |p| env.makeString(p) else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--write-vt",
        .arity = .{ 2, 2 },
        .doc =
        \\Write raw bytes to the terminal.
        \\
        \\(ghostel--write-vt TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const raw = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                try term.vtWrite(raw);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--restore-snapshot",
        .arity = .{ 2, 2 },
        .doc =
        \\Replace TERM's state with the snapshot DATA.
        \\
        \\See `ghostel-restore-snapshot'.
        \\
        \\(ghostel--restore-snapshot TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const raw = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                try term.restoreSnapshot(env, raw);
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--handoff-version",
        .arity = .{ 1, 1 },
        .doc =
        \\Return the renderer-handoff protocol version for this generation.
        \\
        \\Version 1 guarantees the fixed snapshot, commit, cancel, restore,
        \\resize, and reply exports.  Pass nil to probe the active generation,
        \\or a terminal handle to probe the generation that owns it.
        \\
        \\(ghostel--handoff-version TERM-OR-NIL)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                try env.checkNonLocalExit();
                if (env.raw.get_user_finalizer == null) return env.nil();
                if (env.isNil(args[0])) return env.makeInteger(HandoffProtocolVersion);

                const term = try env.getUserPtrWithFinalizer(
                    Self,
                    args[0],
                    terminalFinalize,
                );
                if (term == null) return env.nil();
                return env.makeInteger(HandoffProtocolVersion);
            }
        },
    },
    .{
        .name = "ghostel--handoff-snapshot",
        .arity = .{ 2, 2 },
        .doc =
        \\Create a ground-state snapshot and optionally stage a live native PTY.
        \\
        \\Return (BYTES ROWS COLS CELL-W CELL-H PIXEL-SCALE), or nil if TERM is busy.
        \\CAPTURE non-nil arms bounded output staging only after the snapshot value
        \\has been created successfully.
        \\
        \\(ghostel--handoff-snapshot TERM CAPTURE)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = try getHandoffTerm(env, args[0]);
                if (!term.mutex.tryLock()) return env.nil();
                defer term.unlock();

                const capture = env.isNotNil(args[1]);
                const process = term.process;
                if (capture) {
                    const proc = process orelse return error.NativeProcessRequired;
                    if (proc.owner != term or !proc.attached.load(.acquire) or !proc.isRunning()) {
                        return error.ProcessExited;
                    }
                    try validateHandoffStream(&proc.stream);
                } else {
                    if (process != null) return error.TerminalHasProcess;
                    try validateHandoffStream(&term.stream);
                }
                if (term.renderer.pending_resize != null) return error.ResizePending;

                var writer = std.Io.Writer.Allocating.init(module_alloc);
                defer writer.deinit();
                try gt.snapshot.encode(
                    module_alloc,
                    &writer.writer,
                    &term.terminal,
                    .{ .continuation = .ground },
                );

                const size = term.renderer.size;
                const color_scheme = switch (term.color_scheme) {
                    .light => emacs.sym.light,
                    .dark => emacs.sym.dark,
                };
                const bytes = env.makeUnibyteString(writer.written());
                try env.checkNonLocalExit();
                const result = env.list(.{
                    bytes,
                    size.rows,
                    size.cols,
                    size.cell_w,
                    size.cell_h,
                    size.pixel_scale,
                    color_scheme,
                });
                try env.checkNonLocalExit();

                if (capture) try process.?.beginHandoff();
                return result;
            }
        },
    },
    .{
        .name = "ghostel--handoff-commit",
        .arity = .{ 1, 1 },
        .doc =
        \\Commit a staged native PTY cutover, returning nil when busy or unavailable.
        \\
        \\(ghostel--handoff-commit TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = try getHandoffTerm(env, args[0]);
                const process = term.process orelse return env.nil();
                return env.makeValue(process.commitHandoff() == .committed);
            }
        },
    },
    .{
        .name = "ghostel--handoff-cancel",
        .arity = .{ 1, 1 },
        .doc =
        \\Asynchronously roll an unfinished native PTY handoff back to its old parser.
        \\
        \\A committed raw transport is never reverted.
        \\
        \\(ghostel--handoff-cancel TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = try getHandoffTerm(env, args[0]);
                const process = term.process orelse return env.nil();
                return env.makeValue(process.cancelHandoff());
            }
        },
    },
    .{
        .name = "ghostel--handoff-restore",
        .arity = .{ 6, 6 },
        .doc =
        \\Restore a ground-state snapshot into a processless candidate renderer.
        \\
        \\SCHEME is the host-assigned `light' or `dark' color scheme.
        \\
        \\(ghostel--handoff-restore FRESH-TERM BYTES CELL-W CELL-H PIXEL-SCALE SCHEME)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = try getHandoffTerm(env, args[0]);
                const cell_w = std.math.cast(u32, env.cast(i64, args[2])) orelse return error.OutOfRange;
                const cell_h = std.math.cast(u32, env.cast(i64, args[3])) orelse return error.OutOfRange;
                const pixel_scale = std.math.cast(u32, env.cast(i64, args[4])) orelse return error.OutOfRange;
                if (cell_w == 0 or cell_h == 0 or pixel_scale == 0) return error.InvalidSize;
                const color_scheme: gt.device_status.ColorScheme =
                    if (env.eq(args[5], emacs.sym.light))
                        .light
                    else if (env.eq(args[5], emacs.sym.dark))
                        .dark
                    else
                        return error.InvalidColorScheme;
                try env.checkNonLocalExit();

                const raw = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                try env.checkNonLocalExit();
                try term.restoreHandoffSnapshot(
                    env,
                    raw,
                    cell_w,
                    cell_h,
                    pixel_scale,
                    color_scheme,
                );
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--handoff-resize",
        .arity = .{ 5, 5 },
        .doc =
        \\Queue a committed renderer resize on its native transport PTY.
        \\
        \\(ghostel--handoff-resize TRANSPORT-TERM ROWS COLS XPIXEL YPIXEL)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = try getHandoffTerm(env, args[0]);
                const rows = std.math.cast(u16, env.cast(i64, args[1])) orelse return error.OutOfRange;
                const cols = std.math.cast(u16, env.cast(i64, args[2])) orelse return error.OutOfRange;
                const xpixel = std.math.cast(u16, env.cast(i64, args[3])) orelse return error.OutOfRange;
                const ypixel = std.math.cast(u16, env.cast(i64, args[4])) orelse return error.OutOfRange;
                if (rows == 0 or cols == 0) return error.InvalidSize;
                try env.checkNonLocalExit();

                const process = term.process orelse return env.nil();
                var queue = struct {
                    process: *NativeProcess,

                    fn enqueue(self: *@This(), size: WinSize) !void {
                        try self.process.resizePty(size);
                    }
                }{ .process = process };
                _ = try queueTransportResizeIfChanged(&term.pty_size, .{
                    .rows = rows,
                    .cols = cols,
                    .xpixel = xpixel,
                    .ypixel = ypixel,
                }, &queue);
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--handoff-reply",
        .arity = .{ 2, 2 },
        .doc =
        \\Queue a terminal-generated reply on its native transport using reply backpressure.
        \\
        \\(ghostel--handoff-reply TRANSPORT-TERM BYTES)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = try getHandoffTerm(env, args[0]);
                const bytes = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                try env.checkNonLocalExit();
                const process = term.process orelse return env.nil();
                process.ptyWriteFromTerminal(bytes);
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--set-refresh-enabled",
        .arity = .{ 2, 2 },
        .doc =
        \\Set whether TERM sends output-only native refresh notifications.
        \\
        \\Semantic terminal callbacks are not gated.
        \\
        \\(ghostel--set-refresh-enabled TERM ENABLED)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                term.setRefreshEnabled(env.isNotNil(args[1]));
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--write-pty",
        .arity = .{ 2, 2 },
        .doc =
        \\Write raw bytes to TERM's PTY.
        \\
        \\DATA is sent to the native PTY process when TERM owns one, and
        \\through `ghostel--pty-out' otherwise.
        \\
        \\(ghostel--write-pty TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const raw = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                try term.ptyWrite(raw);
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--set-process-pid",
        .arity = .{ 2, 2 },
        .doc =
        \\Cache the local Emacs PTY child process id for TERM.
        \\
        \\(ghostel--set-process-pid TERM PID)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                term.emacs_process_pid = env.cast(i64, args[1]);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--set-size",
        .arity = .{ 3, 6 },
        .doc =
        \\Set the grid, logical cell dimensions and integer PIXEL-SCALE.
        \\CELL-W, CELL-H and PIXEL-SCALE default to 1. Native code derives the
        \\reported pixel dimensions and raster density from the same scale.
        \\
        \\(ghostel--set-size TERM ROWS COLS &optional CELL-W CELL-H PIXEL-SCALE)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const rows = std.math.cast(u16, env.cast(i64, args[1])) orelse {
                    return error.OutOfRange;
                };
                const cols = std.math.cast(u16, env.cast(i64, args[2])) orelse {
                    return error.OutOfRange;
                };
                // Clamp cell dimensions to at least 1.  A zero (or negative,
                // pre-cast) value would propagate into the OPT_SIZE answer, and
                // some apps treat zero cell sizes as "kitty graphics not
                // supported" and fall back to half-block rendering.
                const cell_w: u32 = if (nargs > 3 and env.isNotNil(args[3])) blk: {
                    const raw = env.cast(i64, args[3]);
                    if (raw < 1) break :blk 1;
                    break :blk std.math.cast(u32, raw) orelse return error.OutOfRange;
                } else 1;
                const cell_h: u32 = if (nargs > 4 and env.isNotNil(args[4])) blk: {
                    const raw = env.cast(i64, args[4]);
                    if (raw < 1) break :blk 1;
                    break :blk std.math.cast(u32, raw) orelse return error.OutOfRange;
                } else 1;
                const pixel_scale: u32 = if (nargs > 5 and env.isNotNil(args[5]))
                    std.math.cast(u32, env.cast(i64, args[5])) orelse return error.OutOfRange
                else
                    1;
                try env.checkNonLocalExit();
                try term.resize(cols, rows, cell_w, cell_h, pixel_scale);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--redraw",
        .arity = .{ 1, 3 },
        .doc =
        \\Redraw the terminal into the current buffer.
        \\
        \\(ghostel--redraw TERM &optional FULL FORCE-SYNC)
        \\
        \\Return non-nil when rendering completed.  Unless FORCE-SYNC is
        \\non-nil, return nil without rendering during synchronized output.
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const force_full = nargs > 1 and env.isNotNil(args[1]);
                const force_sync = nargs > 2 and env.isNotNil(args[2]);
                return env.makeValue(try term.redraw(force_full, force_sync));
            }
        },
    },
    .{
        .name = "ghostel--encode-key",
        .arity = .{ 3, 4 },
        .doc =
        \\Encode a key event using the terminal's key encoder.
        \\
        \\(ghostel--encode-key TERM KEY MODS &optional UTF8)
        \\
        \\For a single-character KEY, UTF8 defaults to KEY itself.
        \\Writes the encoded bytes to the PTY and returns them as a unibyte
        \\string, or nil when the encoder produced no output.
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, nargs: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var key_buf: [64]u8 = undefined;
                const key_name = env.extractString(args[1], &key_buf) catch return env.nil();
                var mod_buf: [64]u8 = undefined;
                const mod_str = env.extractString(args[2], &mod_buf) catch "";
                var utf8_buf: [32]u8 = undefined;
                const utf8: ?[]const u8 = if (nargs > 3 and env.isNotNil(args[3]))
                    env.extractString(args[3], &utf8_buf) catch null
                else
                    null;
                const event = input.keyEvent(key_name, mod_str, utf8);
                var encode_buf: [128]u8 = undefined;
                const sent = try term.encode(&encode_buf, event);
                return if (sent) |bytes|
                    env.makeUnibyteString(bytes)
                else
                    env.nil();
            }
        },
    },
    .{
        .name = "ghostel--mouse-event",
        .arity = .{ 6, 6 },
        .doc =
        \\Send a mouse event to the terminal.
        \\
        \\(ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const action = env.cast(i64, args[1]);
                const button = env.cast(i64, args[2]);
                const row = env.cast(i64, args[3]);
                const col = env.cast(i64, args[4]);
                const mods = env.cast(i64, args[5]);
                const sent = try term.encodeMouse(action, button, row, col, mods);
                return if (sent) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--focus-event",
        .arity = .{ 2, 2 },
        .doc =
        \\Send a focus event to the terminal.
        \\
        \\(ghostel--focus-event TERM GAINED)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const gained = env.isNotNil(args[1]);
                return if (try term.encodeFocus(gained)) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--encode-paste",
        .arity = .{ 2, 2 },
        .doc =
        \\Encode paste text using the terminal's paste encoder and write it to the PTY.
        \\
        \\(ghostel--encode-paste TERM DATA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const data = try env.extractStringAlloc(module_alloc, args[1], &term.string_buffer);
                return if (try term.encodePaste(data)) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--set-palette",
        .arity = .{ 2, 2 },
        .doc =
        \\Set the ANSI color palette.
        \\
        \\(ghostel--set-palette TERM COLORS-STRING)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var str_buf: [2048]u8 = undefined;
                const colors_str = try env.extractString(args[1], &str_buf);
                if (colors_str.len < 16 * 7) return error.InvalidPaletteLength;
                try term.lock();
                defer term.unlock();
                var palette = term.terminal.colors.palette.current;
                var idx: usize = 0;
                while (idx < 16) : (idx += 1) {
                    const pos = idx * 7;
                    palette[idx] = try gt.color.RGB.parse(colors_str[pos .. pos + 7]);
                }
                try term.setColorPaletteLocked(palette);
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--set-default-colors",
        .arity = .{ 4, 4 },
        .doc =
        \\Set protocol default foreground and background colors.
        \\
        \\These defaults are used for OSC 10/11 replies and terminal dynamic
        \\color state.  The renderer intentionally does not emit them as
        \\default-cell face properties.
        \\
        \\(ghostel--set-default-colors TERM FG-HEX BG-HEX SCHEME)
        \\
        \\SCHEME is `light' or `dark'.  When it changes and the child enabled
        \\Mode 2031, a CSI ? 997 n report is written to the PTY.
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var fg_buf: [16]u8 = undefined;
                var bg_buf: [16]u8 = undefined;
                const fg_str = try env.extractString(args[1], &fg_buf);
                const bg_str = try env.extractString(args[2], &bg_buf);
                const scheme: gt.device_status.ColorScheme =
                    if (env.eq(args[3], emacs.sym.light)) .light else .dark;
                const report = blk: {
                    try term.lock();
                    defer term.unlock();
                    term.terminal.colors.foreground.default = try gt.color.RGB.parse(fg_str);
                    term.terminal.colors.background.default = try gt.color.RGB.parse(bg_str);
                    const changed = term.color_scheme != scheme;
                    term.color_scheme = scheme;
                    break :blk changed and term.terminal.modes.get(.report_color_scheme);
                };
                // Written outside the lock: a full PTY must not stall the reader thread.
                // Best effort: a client can re-query with CSI ? 996 n.
                if (report) {
                    var buf: [gt.device_status.max_color_scheme_report_encode_size]u8 = undefined;
                    var writer = std.Io.Writer.fixed(&buf);
                    try gt.device_status.encodeColorSchemeReport(&writer, scheme);
                    term.ptyWrite(writer.buffered()) catch {};
                }
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--set-bold-config",
        .arity = .{ 2, 2 },
        .doc =
        \\Configure bold text coloring.
        \\
        \\CONFIG can be nil (none), 'bright, or a hex color string.
        \\
        \\(ghostel--set-bold-config TERM CONFIG)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const val = args[1];
                if (env.isNil(val)) {
                    term.renderer.bold_config = null;
                } else if (env.eq(val, emacs.sym.bright)) {
                    term.renderer.bold_config = .bright;
                } else {
                    var hex_buf: [16]u8 = undefined;
                    const hex = try env.extractString(val, &hex_buf);
                    term.renderer.bold_config = .{ .color = try gt.color.RGB.parse(hex) };
                }
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--mode-enabled",
        .arity = .{ 2, 2 },
        .doc =
        \\Return t if terminal DEC private MODE is enabled.
        \\
        \\(ghostel--mode-enabled TERM MODE)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const raw_int = env.cast(i64, args[1]);
                const mode_int = std.math.cast(u16, raw_int) orelse {
                    return error.InvalidModeValue;
                };
                const mode: gt.modes.Mode = gt.modes.modeFromInt(mode_int, false) orelse {
                    return error.InvalidModeValue;
                };
                if (!term.mutex.tryLock()) return env.nil();
                defer term.unlock();
                return if (term.terminal.modes.get(mode)) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--alt-screen-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t if terminal is on the alternate screen buffer.
        \\
        \\(ghostel--alt-screen-p TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                try term.lock();
                defer term.unlock();
                return if (term.terminal.screens.active_key == .alternate) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--mouse-tracking-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t if the terminal reports wheel presses (DEC 1000/1002/1003).
        \\
        \\(ghostel--mouse-tracking-p TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                try term.lock();
                defer term.unlock();
                return switch (term.terminal.flags.mouse_event) {
                    .none, .x10 => env.nil(),
                    else => env.t(),
                };
            }
        },
    },
    .{
        .name = "ghostel--copy-all-text",
        .arity = .{ 1, 1 },
        .doc =
        \\Return entire scrollback as plain text string.
        \\
        \\(ghostel--copy-all-text TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                const options = gt.formatter.Options{
                    .emit = .plain,
                    .unwrap = true,
                    .trim = true,
                };
                try term.lock();
                defer term.unlock();
                var formatter = gt.formatter.TerminalFormatter.init(&term.terminal, options);
                var writer = std.Io.Writer.Allocating.init(module_alloc);
                defer writer.deinit();
                try formatter.format(&writer.writer);
                const written = writer.written();
                if (written.len == 0) return env.nil();
                return env.makeString(written);
            }
        },
    },
    .{
        .name = "ghostel--spawn-native-process",
        .arity = .{ 3, 3 },
        .doc =
        \\Spawn COMMAND on a PTY for TERM and return a retained child handle.
        \\
        \\COMMAND is a list of argv strings.  PIPE receives Lisp event forms
        \\followed by a PID-tagged exit marker, then closes.
        \\Use `ghostel--native-child-pid' to retrieve its PID.
        \\
        \\(ghostel--spawn-native-process TERM COMMAND PIPE)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                var cmd_list = args[1];
                const pipe_val = args[2];
                var cmd: std.ArrayList([:0]const u8) = .empty;
                defer {
                    for (cmd.items) |item| module_alloc.free(item);
                    cmd.deinit(module_alloc);
                }
                while (env.isNotNil(cmd_list)) : (cmd_list = env.f("cdr", .{cmd_list})) {
                    const arg = env.f("car", .{cmd_list});
                    const arg_string = try platform.extractProcessStringAlloc(
                        module_alloc,
                        env,
                        arg,
                    );
                    errdefer module_alloc.free(arg_string);
                    try cmd.append(module_alloc, arg_string);
                }
                var process_env = try getProcessEnvironment(module_alloc, env);
                defer process_env.deinit();
                const cwd = try platform.extractProcessStringAlloc(
                    module_alloc,
                    env,
                    env.f("expand-file-name", .{env.symbolValue("default-directory")}),
                );
                defer module_alloc.free(cwd);
                const child = try term.spawnNativeProcess(
                    cmd.items,
                    &process_env,
                    cwd,
                    @intCast(env.openChannel(pipe_val)),
                );
                errdefer {
                    child.terminate() catch |err| {
                        std.log.err("Failed to terminate unreturned native child: {any}", .{err});
                    };
                    term.killNativeProcess();
                    child.refcount.release();
                }
                return try env.makeUserPtr(childFinalize, child);
            }
        },
    },
    .{
        .name = "ghostel--native-child-pid",
        .arity = .{ 1, 1 },
        .doc =
        \\Return the original PID of CHILD, including after it has exited.
        \\
        \\(ghostel--native-child-pid CHILD)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const child = env.getUserPtr(ChildProcess, args[0]) orelse return error.InvalidChildHandle;
                return env.makeInteger(child.pidValue());
            }
        },
    },
    .{
        .name = "ghostel--terminate-native-child",
        .arity = .{ 1, 1 },
        .doc =
        \\Force termination of CHILD without waiting for exit.
        \\
        \\CHILD is a handle returned by `ghostel--spawn-native-process'.
        \\Safe after child exit; never signals a reused PID.
        \\
        \\(ghostel--terminate-native-child CHILD)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const child = env.getUserPtr(ChildProcess, args[0]) orelse return error.InvalidChildHandle;
                try child.terminate();
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--kill-native-process",
        .arity = .{ 1, 1 },
        .doc =
        \\Request TERM's native PTY reader to stop without waiting for it.
        \\
        \\The detached reader finishes event delivery, closes the PTY, and
        \\waits for the child before reporting its exit through the event pipe.
        \\This does not send SIGKILL.  No-op when TERM is not
        \\using the native PTY path.
        \\
        \\(ghostel--kill-native-process TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                term.killNativeProcess();
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--pty-password-input-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t when TERM's foreground PTY appears to be reading a password.
        \\
        \\This checks the terminal attributes of the PTY of TERM's process, also
        \\after the process exited, when another PTY may have taken its name.
        \\Nil when there is no process or the PTY is not in canonical no-echo mode.
        \\
        \\(ghostel--pty-password-input-p TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                return if (try term.isPasswordMode()) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--tty-password-input-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t when the PTY device PATH appears to be reading a password.
        \\
        \\Nil when PATH is not a readable tty or not in canonical no-echo mode.
        \\
        \\(ghostel--tty-password-input-p PATH)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                var buf: ?[]u8 = null;
                defer if (buf) |b| module_alloc.free(b);
                const path = try env.extractStringAlloc(module_alloc, args[0], &buf);
                return if (pty_utils.isPasswordMode(path)) env.t() else env.nil();
            }
        },
    },
    .{
        .name = "ghostel--pty-foreground-pgid",
        .arity = .{ 1, 1 },
        .doc =
        \\Return the foreground process-group id of TERM's PTY, or nil.
        \\
        \\From `tcgetpgrp' on the native PTY primary.  Nil when TERM is nil,
        \\is not on the native PTY path, or the query fails (e.g. Windows).
        \\
        \\(ghostel--pty-foreground-pgid TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                if (env.isNil(args[0])) return env.nil();
                const term = env.getUserPtr(Self, args[0]) orelse return error.InvalidTerminalHandle;
                return env.makeValue(try term.foregroundPgid());
            }
        },
    },
    .{
        .name = "ghostel--native-uri-at",
        .arity = .{ 3, 3 },
        .doc =
        \\Get URI at ROW-from-bottom and COL.
        \\
        \\(ghostel--native-uri-at TERM ROW COL)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                if (!term.mutex.tryLock()) return env.nil();
                defer term.unlock();
                const row_from_bottom = env.extractInteger(args[1]);
                const col = env.extractInteger(args[2]);
                const total_rows = term.terminal.screens.active.pages.total_rows;
                if (col < 0 or col >= term.terminal.cols) return env.nil();
                // The Emacs buffer always carries a trailing newline, so the line
                // immediately after the last content row produces row_from_bottom == 0.
                if (row_from_bottom <= 0 or row_from_bottom > total_rows) return env.nil();
                const row = total_rows - @as(usize, @intCast(row_from_bottom));
                const point = gt.Point{ .screen = .{
                    .x = @intCast(col),
                    .y = @intCast(row),
                } };
                const pin = term.terminal.screens.active.pages.pin(point) orelse return env.nil();
                const cell = pin.rowAndCell().cell;
                if (!cell.hyperlink) {
                    return env.nil();
                }
                const page = pin.node.page();
                const link_id = page.lookupHyperlink(cell) orelse return env.nil();
                const entry = page.hyperlink_set.get(page.memory, link_id);
                const uri = entry.uri.slice(page.memory);
                return env.makeString(uri);
            }
        },
    },
    .{
        .name = "ghostel--scroll",
        .arity = .{ 2, 2 },
        .doc =
        \\Scroll the terminal viewport by DELTA lines.
        \\
        \\(ghostel--scroll TERM DELTA)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                if (!term.mutex.tryLock()) return env.nil();
                defer term.unlock();
                const delta = env.extractInteger(args[1]);
                term.terminal.scrollViewport(.{ .delta = @intCast(delta) });
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--scroll-top",
        .arity = .{ 1, 1 },
        .doc =
        \\Scroll the terminal viewport to the top of scrollback.
        \\
        \\(ghostel--scroll-top TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                if (!term.mutex.tryLock()) return env.nil();
                defer term.unlock();
                term.terminal.scrollViewport(.top);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--scroll-bottom",
        .arity = .{ 1, 1 },
        .doc =
        \\Scroll the terminal viewport to the bottom.
        \\
        \\(ghostel--scroll-bottom TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                if (!term.mutex.tryLock()) return env.nil();
                defer term.unlock();
                term.terminal.scrollViewport(.bottom);
                return env.nil();
            }
        },
    },
    .{
        .name = "ghostel--cursor-pending-wrap-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t if the cursor is in pending-wrap state.
        \\
        \\(ghostel--cursor-pending-wrap-p TERM)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) emacs.Value {
                const term = env.getUserPtr(Self, args[0]) orelse return env.nil();
                if (!term.mutex.tryLock()) return env.nil();
                defer term.unlock();
                return if (term.terminal.screens.active.cursor.pending_wrap) env.t() else env.nil();
            }
        },
    },
};

test "refresh gate defaults enabled and updates the native process" {
    var term = Self{
        .alloc = std.testing.allocator,
        .io = undefined,
        .terminal = undefined,
        .options = .{
            .rows = 24,
            .cols = 80,
            .max_scrollback_bytes = 5 * 1024 * 1024,
            .kitty_image_storage_limit = 320 * 1024 * 1024,
            .kitty_image_loading_limits = .{
                .file = false,
                .temporary_file = .disabled,
                .shared_memory = false,
            },
            .default_modes = .{ .grapheme_cluster = true },
        },
        .stream = undefined,
        .renderer = undefined,
    };
    try std.testing.expect(term.refresh_enabled);

    var process = NativeProcess{
        .alloc = std.testing.allocator,
        .io = undefined,
        .backend = undefined,
        .event_writer = .{ .fd = -1 },
        .replica_name = undefined,
        .child_pid = 4242,
        .owner = &term,
        .stream = undefined,
        .thread = undefined,
    };
    defer process.event_buf.deinit(process.alloc);
    term.process = &process;

    term.setRefreshEnabled(false);
    try std.testing.expect(!term.refresh_enabled);
    try std.testing.expect(!process.refresh_enabled.load(.acquire));

    term.setRefreshEnabled(true);
    try std.testing.expect(term.refresh_enabled);
    try std.testing.expect(process.refresh_enabled.load(.acquire));
}

test "transport resize deduplicates and commits its cache only after enqueue" {
    const Recorder = struct {
        calls: usize = 0,
        fail: bool = false,

        fn enqueue(self: *@This(), _: WinSize) !void {
            self.calls += 1;
            if (self.fail) return error.ResizeQueueFailed;
        }
    };

    var cached = WinSize{ .cols = 80, .rows = 24, .xpixel = 800, .ypixel = 480 };
    var recorder = Recorder{};

    try std.testing.expect(!try queueTransportResizeIfChanged(&cached, cached, &recorder));
    try std.testing.expectEqual(@as(usize, 0), recorder.calls);

    const committed = WinSize{ .cols = 100, .rows = 30, .xpixel = 1000, .ypixel = 600 };
    try std.testing.expect(try queueTransportResizeIfChanged(&cached, committed, &recorder));
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualDeep(committed, cached);

    recorder.fail = true;
    const failed = WinSize{ .cols = 120, .rows = 40, .xpixel = 1200, .ypixel = 800 };
    try std.testing.expectError(
        error.ResizeQueueFailed,
        queueTransportResizeIfChanged(&cached, failed, &recorder),
    );
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try std.testing.expectEqualDeep(committed, cached);
}
