/// Ghostel target module export dispatch.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const emacs = @import("emacs");
const GhostelTerm = @import("GhostelTerm.zig");
const gt = @import("ghostty-vt");
const input = @import("input.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const sys = @import("sys.zig");
const pty = @import("pty.zig");
const loader = @import("dyn_loader_abi");

const c = emacs.c;

/// In debug builds, all allocations go through DebugAllocator for corruption
/// detection (double-free, use-after-free, overflow canaries).  A debug-only
/// kill-emacs-hook explicitly deinits all live terminals before process exit so
/// atexit can call deinit() on a clean slate.
var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
var alloc: Allocator = std.heap.c_allocator;

/// Module version — see src/version.zig.  Keep in sync with ghostel.el
/// and build.zig.zon.
const version = @import("version.zig").version;
const id: [:0]const u8 = "ghostel";

extern fn atexit(func: *const fn () callconv(.c) void) c_int;

// ---------------------------------------------------------------------------
// Module entry point
// ---------------------------------------------------------------------------
export fn loader_module_init_generic(out: *loader.GenericManifest) callconv(.c) void {
    // The dyn-loader path does not call `emacs_module_init`, so install
    // libghostty's process-global callbacks when the loader reads our manifest.
    sys.init();
    out.* = .{
        .loader_abi = loader.LoaderAbiVersion,
        .module_id = id.ptr,
        .module_version = version.ptr,
        .exports_len = ghostel_export_descriptors.len,
        .exports = ghostel_export_descriptors[0..].ptr,
        .invoke = &invokeExport,
        .get_variable = &getVariable,
        .set_variable = &setVariable,
    };
}

export const plugin_is_GPL_compatible: c_int = 1;

export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) return 1;

    if (builtin.mode == .Debug) {
        alloc = debug_alloc.allocator();
        _ = atexit(&debugAtExit);
    }

    const raw_env = runtime.get_environment.?(runtime);
    emacs.initModule(alloc, raw_env);

    const env = emacs.Env.init(raw_env);
    for (&ghostel_export_descriptors) |*descriptor| {
        bindExportDescriptor(env, descriptor);
    }

    // Install system callbacks (PNG decoder for kitty graphics, logging).
    sys.init();

    env.provide("ghostel-module");
    return 0;
}

fn debugAtExit() callconv(.c) void {
    if (debug_alloc.deinit() == .leak) {
        std.debug.print("ghostel: memory leak detected at exit\n", .{});
    }
}

fn terminalFinalize(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const term: *GhostelTerm = @ptrCast(@alignCast(p));
        term.deinit();
    }
}

fn bindExportDescriptor(env: emacs.Env, descriptor: *const loader.ExportDescriptor) void {
    switch (descriptor.kind) {
        @intFromEnum(loader.ExportKind.function) => {
            const function = env.makeFunction(
                descriptor.min_arity,
                descriptor.max_arity,
                &invokeExportDescriptor,
                descriptor.docstring,
                @ptrCast(@constCast(descriptor)),
            );
            _ = env.call2(env.intern("fset"), env.intern(descriptor.lisp_name), function);
        },
        @intFromEnum(loader.ExportKind.variable) => {
            const value = getVariable(
                descriptor.export_id,
                env.raw,
                @ptrCast(@constCast(descriptor)),
            );
            _ = env.call2(env.intern("set"), env.intern(descriptor.lisp_name), value);
        },
        else => unreachable,
    }
}

fn invokeExportDescriptor(
    raw_env: ?*c.emacs_env,
    nargs: isize,
    args: [*c]c.emacs_value,
    data: ?*anyopaque,
) callconv(.c) c.emacs_value {
    emacs.initModule(alloc, raw_env.?);
    const env = emacs.Env.init(raw_env.?);
    const raw_descriptor = data orelse {
        env.signalError("missing export descriptor");
        return env.nil();
    };
    const descriptor: *const loader.ExportDescriptor = @ptrCast(@alignCast(raw_descriptor));
    return invokeExport(descriptor.export_id, raw_env, nargs, args, null);
}

/// (ghostel--new ROWS COLS &optional MAX-SCROLLBACK KITTY-STORAGE-LIMIT)
fn fnNew(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    // Reject out-of-range row/col counts rather than wrapping/panicking.
    const rows = std.math.cast(u16, env.extractInteger(args[0])) orelse {
        env.signalError("rows out of range");
        return env.nil();
    };
    const cols = std.math.cast(u16, env.extractInteger(args[1])) orelse {
        env.signalError("cols out of range");
        return env.nil();
    };
    const max_scrollback: usize = if (nargs > 2 and env.isNotNil(args[2]))
        (std.math.cast(usize, env.extractInteger(args[2])) orelse {
            env.signalError("max-scrollback out of range");
            return env.nil();
        })
    else
        5 * 1024 * 1024; // ~5 MB, roughly 5k rows on an 80-column terminal

    // Default 320 MiB; explicit 0 disables kitty graphics entirely
    // (skips the storage allocation in libghostty's screen state).
    const kitty_storage_limit: usize = if (nargs > 3 and env.isNotNil(args[3]))
        (std.math.cast(usize, env.extractInteger(args[3])) orelse {
            env.signalError("kitty-storage-limit out of range");
            return env.nil();
        })
    else
        320 * 1024 * 1024;

    // Bit 0 = file medium, bit 1 = temp_file, bit 2 = shared_mem.
    // Default 0 — only the direct medium (base64 inline) is enabled.
    // The other mediums let a remote program instruct ghostel to read
    // arbitrary local files / SHM regions, so opt-in only.
    const kitty_mediums: u32 = if (nargs > 4 and env.isNotNil(args[4]))
        (std.math.cast(u32, env.extractInteger(args[4])) orelse 0)
    else
        0;

    var effects: gt.TerminalStream.Handler.Effects = .readonly;
    effects.write_pty = &writePtyCallback;
    effects.bell = &bellCallback;
    effects.device_attributes = &deviceAttributesCallback;
    effects.title_changed = &titleChangedCallback;
    effects.size = &sizeCallback;

    const term = GhostelTerm.init(alloc, cols, rows, max_scrollback, effects) catch {
        env.signalError("failed to create terminal");
        return env.nil();
    };

    // Set default colors (light gray on black)
    term.setColorForeground(.{ .r = 204, .g = 204, .b = 204 });
    term.setColorBackground(.{ .r = 0, .g = 0, .b = 0 });

    // Enable kitty graphics protocol if storage limit > 0.
    if (kitty_storage_limit > 0) {
        term.enableKittyGraphics(
            kitty_storage_limit,
            (kitty_mediums & 0x1) != 0,
            (kitty_mediums & 0x2) != 0,
            (kitty_mediums & 0x4) != 0,
        ) catch |err|
            env.logErrorf("enableKittyGraphics failed: {s}", .{@errorName(err)});
    }

    return env.makeUserPtr(terminalFinalize, term);
}

/// (ghostel--write-input TERM DATA)
fn fnWriteInput(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle");
        return env.nil();
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Extract string data — try stack buffer first, fall back to alloc
    var stack_buf: [65536]u8 = undefined;
    const data = env.extractString(args[1], &stack_buf) orelse blk: {
        break :blk env.extractStringAlloc(args[1], allocator);
    };

    if (data == null) {
        return env.nil();
    }

    // Stash env for callbacks (and for the VT log callback)
    term.env = env;
    defer term.env = null;
    if (vt_log_active) {
        vt_log_env = env;
        defer vt_log_env = null;
    }

    const raw = data.?;
    // Normalize CRLF by streaming directly into libghostty's parser.
    // Emacs PTYs lack ONLCR, so bare \n arrives without \r — insert
    // one before each bare \n by feeding the preceding segment verbatim
    // and then "\r\n".  libghostty's VT state machine handles arbitrary
    // chunking (that's how the process filter already works), so no
    // scratch buffer, no allocation, no truncation fallback.
    //
    // Skip normalization on the alternate screen.  Apps that use the
    // alt screen (tmux, vim, less) send VT-correct sequences where bare
    // \n is LF (cursor down, column preserved); normalizing to \r\n
    // breaks their layout.
    //
    // `prev_was_cr` is seeded from `term.last_input_was_cr` so a CRLF
    // pair split across two writes — chunk A ending with \r, chunk B
    // starting with \n — is not mis-normalized into \r\r\n.  The final
    // value is persisted back for the next call. An empty input
    // round-trips the flag unchanged.
    //
    // All standard OSC sequences (4, 7, 9, 10, 11, 52, 133, 777) are
    // intercepted by `GhostelHandler` inside the stream itself — no
    // post-write byte scan is needed for them.
    if (term.terminal.screens.active_key == .alternate) {
        term.vtWrite(raw);
        if (raw.len > 0) term.last_input_was_cr = raw[raw.len - 1] == '\r';
    } else {
        var seg_start: usize = 0;
        var prev_was_cr: bool = term.last_input_was_cr;
        for (raw, 0..) |ch, i| {
            if (ch == '\n' and !prev_was_cr) {
                if (i > seg_start) term.vtWrite(raw[seg_start..i]);
                term.vtWrite("\r\n");
                seg_start = i + 1;
                prev_was_cr = false;
            } else {
                prev_was_cr = (ch == '\r');
            }
        }
        if (seg_start < raw.len) {
            term.vtWrite(raw[seg_start..]);
        }
        term.last_input_was_cr = prev_was_cr;
    }

    // OSC 51;E (ghostel's elisp-eval extension) is not a standard OSC,
    // so ghostty's parser drops it without firing an action.  Scan the
    // raw input for it ourselves.
    dispatchOsc51(env, raw);

    return env.nil();
}

// ---------------------------------------------------------------------------
// OSC 51 (ghostel extension) — elisp eval
// ---------------------------------------------------------------------------

// TODO: Ghostty's parser is a whitelist state machine and if a 5 is
//   followed by 1, the parser transitions to .invalid.
//   Replace this with either an upstream fix or change to OSC52;E
//   OSC 52 is the clipboard parser where only the "c, p, s, q, 0-7"
//   kinds are used.

/// Only OSC 51 (ghostel's elisp-eval extension) still needs a byte scan
/// because it is not a standard OSC that ghostty's parser knows about.
///
/// Dispatch each `ESC ] 51 ; E <payload> (BEL|ST)` in `data` to
/// `ghostel--osc51-eval`.  Other OSC 51 sub-codes (used by other
/// terminals for things unrelated to elisp eval) are ignored.
///
/// Single-pass scan: the `intermediate` introducer carries the literal
/// "E" so we can match the full prefix in one `indexOfPos`.  Limitation:
/// an OSC 51 split across two `ghostel--write-input` calls is dropped
/// entirely — we keep no carry-over state between calls.  Unlike
/// ghostty's `Parser`, which buffers an OSC body across chunks, this
/// scanner only sees one `data` slice at a time.  Adding carry-over
/// would require per-`GhostelTerm` state; not worth it until an
/// OSC 51 chunk-spanning case actually shows up.
fn dispatchOsc51(env: emacs.Env, data: []const u8) void {
    const intro = "\x1b]51;E";
    var pos: usize = 0;
    while (pos + intro.len <= data.len) {
        const start = std.mem.indexOfPos(u8, data, pos, intro) orelse return;
        const payload_start = start + intro.len;
        // Find BEL or ST terminator. Stops at the next OSC introducer
        // too: a missing terminator on the current OSC should not
        // cannibalize the following one.
        var end = payload_start;
        var term_len: usize = 0;
        while (end < data.len) : (end += 1) {
            const ch = data[end];
            if (ch == 0x07) {
                term_len = 1;
                break;
            }
            if (ch == 0x1b and end + 1 < data.len) {
                const next_ch = data[end + 1];
                if (next_ch == '\\') {
                    term_len = 2;
                    break;
                }
                if (next_ch == ']') break; // next OSC - current is partial
            }
        }

        if (term_len == 0) {
            // Partial - skip past the introducer and resume. If
            // nothing matched, the next `indexOfPos` terminates.
            pos = if (end > start) end else payload_start;
            continue;
        }

        if (end > payload_start) {
            _ = env.f("ghostel--osc51-eval", .{data[payload_start..end]});
        }
        pos = end + term_len;
    }
}

/// (ghostel--set-size TERM ROWS COLS &optional CELL-W CELL-H)
fn fnSetSize(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle");
        return env.nil();
    };

    const rows = std.math.cast(u16, env.extractInteger(args[1])) orelse {
        env.signalError("rows out of range");
        return env.nil();
    };
    const cols = std.math.cast(u16, env.extractInteger(args[2])) orelse {
        env.signalError("cols out of range");
        return env.nil();
    };

    // Clamp cell dimensions to at least 1.  A zero (or negative,
    // pre-cast) value would propagate into the OPT_SIZE answer, and
    // some apps treat zero cell sizes as "kitty graphics not
    // supported" and fall back to half-block rendering.
    const cell_w: u32 = if (nargs > 3 and env.isNotNil(args[3])) blk: {
        const raw = env.extractInteger(args[3]);
        if (raw < 1) break :blk 1;
        break :blk std.math.cast(u32, raw) orelse 1;
    } else 1;

    const cell_h: u32 = if (nargs > 4 and env.isNotNil(args[4])) blk: {
        const raw = env.extractInteger(args[4]);
        if (raw < 1) break :blk 1;
        break :blk std.math.cast(u32, raw) orelse 1;
    } else 1;

    term.resize(cols, rows, cell_w, cell_h);
    return env.nil();
}

/// (ghostel--get-title TERM)
fn fnGetTitle(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const title = term.terminal.getTitle();
    return if (title) |t| env.makeString(t) else env.nil();
}

/// (ghostel--pty-password-input-p PATH)
fn fnPtyPasswordInputP(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    var stack_buf: [1024]u8 = undefined;
    const path = env.extractString(args[0], &stack_buf) orelse return env.nil();
    return if (pty.isPasswordMode(path)) env.t() else env.nil();
}

/// (ghostel--get-pwd TERM)
fn fnGetPwd(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const pwd = term.terminal.getPwd();
    return if (pwd) |p| env.makeString(p) else env.nil();
}

/// (ghostel--redraw TERM &optional FULL)
/// Reads the render state and updates the current Emacs buffer with styled text.
/// When FULL is non-nil, always perform a full redraw instead of incremental.
fn fnRedraw(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const force_full = nargs > 1 and env.isNotNil(args[1]);
    if (vt_log_active) {
        vt_log_env = env;
        defer vt_log_env = null;
    }

    term.renderer.redraw(term.alloc, env, force_full) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.signalErrorf("Redraw failed: {s}", .{@errorName(err)});
        return env.nil();
    };

    // `redraw' parks the libghostty viewport one row above the active
    // area for the next-redraw incremental change detection.  Kitty
    // placement queries report `viewport_row' relative to the current
    // viewport, so reading them with the parked offset shifts every
    // placement up by 1, anchoring the resulting overlay one row too
    // low and covering the prompt that sits just below the image.
    // Restore to the active area (SCROLL_BOTTOM) for the kitty calls,
    // then re-park afterwards.
    term.terminal.scrollViewport(.bottom);
    defer term.terminal.scrollViewport(.{ .delta = -1 });

    // Clear viewport-region kitty overlays after redraw so the cleared
    // region is computed against the post-promotion `scrollback_in_buffer`.
    // Running kitty-clear before redraw would use the pre-promotion viewport
    // boundary, wiping the overlay on the row that's about to be promoted
    // into scrollback — exactly the row we want to keep tagged.
    _ = env.call0(emacs.sym.@"ghostel--kitty-clear");
    kitty_graphics.emitPlacements(env, term) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.logErrorf("emitPlacements failed: {s}", .{@errorName(err)});
    };

    return env.nil();
}

/// (ghostel--scroll TERM DELTA)
fn fnScroll(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const delta = env.extractInteger(args[1]);
    term.terminal.scrollViewport(.{ .delta = @intCast(delta) });
    return env.nil();
}

/// (ghostel--scroll-top TERM)
fn fnScrollTop(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    term.terminal.scrollViewport(.top);
    return env.nil();
}

/// (ghostel--scroll-bottom TERM)
fn fnScrollBottom(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    term.terminal.scrollViewport(.bottom);
    return env.nil();
}
/// (ghostel--encode-key TERM KEY MODS &optional UTF8)
/// Encode a key event and send it to the PTY.
/// KEY is a key name string (e.g. "a", "return", "up", "f1").
/// MODS is a modifier string (e.g. "ctrl", "shift,ctrl", "").
/// UTF8 is optional text generated by the key (e.g. "a" for the 'a' key).
fn fnEncodeKey(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    // Extract key name
    var key_buf: [64]u8 = undefined;
    const key_name = env.extractString(args[1], &key_buf) orelse return env.nil();

    // Extract modifiers
    var mod_buf: [64]u8 = undefined;
    const mod_str = env.extractString(args[2], &mod_buf) orelse "";

    // Extract optional UTF-8 text
    var utf8_buf: [32]u8 = undefined;
    const utf8: ?[]const u8 = if (nargs > 3 and env.isNotNil(args[3]))
        env.extractString(args[3], &utf8_buf)
    else
        null;

    const key = input.mapKey(key_name);
    const mods = input.parseMods(mod_str);

    const sent = input.encodeAndSend(env, term, key, mods, utf8) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.signalErrorf("encodeAndSend failed: {s}", .{@errorName(err)});
        return env.nil();
    };
    return if (sent) env.t() else env.nil();
}

/// (ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)
/// ACTION: 0=press, 1=release, 2=motion
/// BUTTON: 0=none, 1=left, 2=right, 3=middle
/// ROW, COL: 0-based cell coordinates
/// MODS: modifier bitmask
fn fnMouseEvent(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const action = env.extractInteger(args[1]);
    const button = env.extractInteger(args[2]);
    const row = env.extractInteger(args[3]);
    const col = env.extractInteger(args[4]);
    const mods = env.extractInteger(args[5]);

    const sent = input.encodeAndSendMouse(env, term, action, button, row, col, mods) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.signalErrorf("encodeAndSendMouse failed: {s}", .{@errorName(err)});
        return env.nil();
    };
    return if (sent) env.t() else env.nil();
}

/// (ghostel--focus-event TERM GAINED)
/// Encode a focus gained/lost event and send to the PTY.
/// Only sends if the terminal has enabled focus reporting (DEC mode 1004).
fn fnFocusEvent(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    // Only send focus events if the terminal has enabled mode 1004
    if (!term.terminal.modes.get(gt.modes.Mode.focus_event)) {
        return env.nil();
    }

    const gained = env.isNotNil(args[1]);
    const event = if (gained) gt.input.FocusEvent.gained else gt.input.FocusEvent.lost;

    var buf: [8]u8 = undefined;
    var writer = std.io.Writer.fixed(&buf);
    gt.input.encodeFocus(&writer, event) catch return env.nil();
    const encoded = writer.buffered();
    if (encoded.len == 0) return env.nil();

    // Stash env for the flush callback
    term.env = env;
    defer term.env = null;

    _ = env.f("ghostel--flush-output", .{encoded});
    return env.t();
}

/// (ghostel--mode-enabled TERM MODE)
/// Return t if terminal DEC private MODE is enabled, nil otherwise.
fn fnModeEnabled(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const raw_int = env.extractInteger(args[1]);
    const mode_int = std.math.cast(u16, raw_int) orelse {
        env.signalErrorf("invalid mode value: {d}", .{raw_int});
        return env.nil();
    };
    const mode = std.meta.intToEnum(gt.modes.Mode, mode_int) catch {
        env.signalErrorf("invalid mode value: {d}", .{raw_int});
        return env.nil();
    };
    return if (term.terminal.modes.get(mode)) env.t() else env.nil();
}

/// (ghostel--alt-screen-p TERM)
/// Return t if the terminal is on the alternate screen buffer.
fn fnAltScreen(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    return if (term.terminal.screens.active_key == .alternate) env.t() else env.nil();
}

/// (ghostel--set-palette TERM COLORS-STRING)
/// Set the 16 ANSI colors from a concatenated hex string like "#000000#aa0000...".
/// Applies colors via OSC 4 so Ghostty updates its effective palette safely.
fn fnSetPalette(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle");
        return env.nil();
    };

    var str_buf: [2048]u8 = undefined;
    const colors_str = env.extractString(args[1], &str_buf) orelse {
        env.signalError("invalid palette string");
        return env.nil();
    };

    // Get current palette as base (keeps entries 16-255)
    var palette = term.terminal.colors.palette.current;

    // Parse "#RRGGBB" entries — 7 chars each
    var idx: usize = 0;
    var pos: usize = 0;
    while (idx < 16 and pos + 7 <= colors_str.len) {
        if (colors_str[pos] != '#') {
            pos += 1;
            continue;
        }
        const r = parseHexByte(colors_str[pos + 1], colors_str[pos + 2]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        const g = parseHexByte(colors_str[pos + 3], colors_str[pos + 4]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        const b = parseHexByte(colors_str[pos + 5], colors_str[pos + 6]) orelse {
            pos += 7;
            idx += 1;
            continue;
        };
        palette[idx] = .{ .r = r, .g = g, .b = b };
        idx += 1;
        pos += 7;
    }

    term.setColorPalette(palette);
    return env.t();
}

fn parseHexByte(hi: u8, lo: u8) ?u8 {
    const h = hexDigit(hi) orelse return null;
    const l = hexDigit(lo) orelse return null;
    return (h << 4) | l;
}

fn hexDigit(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

/// Parse a "#RRGGBB" hex color string into a ColorRgb.
fn parseHexColor(s: []const u8) ?gt.color.RGB {
    if (s.len < 7 or s[0] != '#') return null;
    const r = parseHexByte(s[1], s[2]) orelse return null;
    const g = parseHexByte(s[3], s[4]) orelse return null;
    const b = parseHexByte(s[5], s[6]) orelse return null;
    return .{ .r = r, .g = g, .b = b };
}

/// (ghostel--set-default-colors TERM FG-HEX BG-HEX)
/// Set the terminal's default foreground and background colors from "#RRGGBB" strings.
fn fnSetDefaultColors(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse {
        env.signalError("invalid terminal handle");
        return env.nil();
    };

    var fg_buf: [16]u8 = undefined;
    var bg_buf: [16]u8 = undefined;
    const fg_str = env.extractString(args[1], &fg_buf) orelse {
        env.signalError("invalid foreground color");
        return env.nil();
    };
    const bg_str = env.extractString(args[2], &bg_buf) orelse {
        env.signalError("invalid background color");
        return env.nil();
    };

    const fg = parseHexColor(fg_str) orelse {
        env.signalError("cannot parse foreground color");
        return env.nil();
    };
    const bg = parseHexColor(bg_str) orelse {
        env.signalError("cannot parse background color");
        return env.nil();
    };

    term.setColorForeground(fg);
    term.setColorBackground(bg);
    return env.t();
}

/// (ghostel--set-bold-config TERM CONFIG)
///
/// CONFIG can be nil (none), 'bright, or a hex color string.
fn fnSetBoldConfig(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const val = args[1];

    if (env.isNil(val)) {
        term.renderer.bold_config = null;
    } else if (env.eq(val, emacs.sym.bright)) {
        term.renderer.bold_config = .bright;
    } else {
        var hex_buf: [16]u8 = undefined;
        const hex = env.extractString(val, &hex_buf) orelse {
            env.signalError("invalid bold config value");
            return env.nil();
        };

        if (parseHexColor(hex)) |color| {
            term.renderer.bold_config = .{ .color = color };
        } else {
            env.signalErrorf("invalid bold color: {s}", .{hex});
            return env.nil();
        }
    }

    return env.t();
}

/// (ghostel--debug-state TERM)
/// Returns a string with render state debug info.
///
/// TODO: This function is inherently broken since it clobbers the render state.
///       It's currently only used in tests but should still be removed as soon
///       as possible.
fn fnDebugState(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    var buf: [4096]u8 = undefined;
    return env.makeString(term.renderer.debugState(term.alloc, &buf));
}

/// (ghostel--debug-feed TERM STR)
/// Feed STR to the terminal, update render state, return first row.
///
/// TODO: This function is inherently broken since it clobbers the render state.
///       It's currently only used in tests but should still be removed as soon
///       as possible.
fn fnDebugFeed(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    var stack_buf: [4096]u8 = undefined;
    const data = env.extractString(args[1], &stack_buf) orelse return env.nil();

    var buf: [2048]u8 = undefined;
    return env.makeString(term.renderer.debugFeed(term, data, &buf));
}

/// (ghostel--cursor-position TERM)
/// Return the terminal cursor position as (COL . ROW), 0-indexed.
/// Returns nil when the cursor has no value (e.g. scrolled away).
fn fnCursorPosition(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const pos = term.renderer.cursorPosition(term.alloc) catch |err| {
        env.signalErrorf("cursor position failed: {s}", .{@errorName(err)});
        return env.nil();
    } orelse return env.nil();

    return env.call2(emacs.sym.cons, env.makeInteger(@as(i64, pos.x)), env.makeInteger(@as(i64, pos.y)));
}

/// (ghostel--cursor-row-char-offset TERM)
/// Return the Emacs character offset of the cursor within its row,
/// counted from the row's beginning.  Used by line-mode to find the
/// input boundary without relying on `move-to-column', which uses
/// `char-width' that disagrees with the terminal column model on
/// pgtk for box-drawing glyphs (and for any wide cell whose Emacs
/// width differs from libghostty's grid width).  Returns nil when
/// the cursor has no value.
fn fnCursorRowCharOffset(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const offset = term.renderer.cursorRowCharOffset(term.alloc) catch |err| {
        env.signalErrorf("cursor row char offset failed: {s}", .{@errorName(err)});
        return env.nil();
    } orelse return env.nil();

    return env.makeInteger(offset);
}

/// (ghostel--cursor-pending-wrap-p TERM)
/// Return t when the terminal cursor is waiting to soft-wrap.
fn fnCursorPendingWrap(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    return if (term.terminal.screens.active.cursor.pending_wrap) env.t() else env.nil();
}

/// (ghostel--cursor-on-empty-row-p TERM)
/// Return t when the viewport row containing the cursor renders as empty.
fn fnCursorOnEmptyRow(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const empty = term.renderer.cursorOnEmptyRow(term.alloc) catch |err| {
        env.signalErrorf("row emptiness check failed: {s}", .{@errorName(err)});
        return env.nil();
    } orelse return env.nil();
    return if (empty) env.t() else env.nil();
}

/// (ghostel--redraw-full-scrollback TERM)
/// Render the entire scrollback into the current buffer.
/// Returns the 1-based line number of the original viewport position.
fn fnRedrawFullScrollback(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const line = term.renderer.redrawFullScrollback(term.alloc, env) catch |err| {
        env.logStackTrace(@errorReturnTrace());
        env.signalErrorf("redrawFullScrollback failed: {s}", .{@errorName(err)});
        return env.nil();
    };
    return env.makeInteger(line);
}
/// (ghostel--copy-all-text TERM)
/// Return the entire scrollback as a plain text string using the formatter API.
fn fnCopyAllText(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();

    const options = gt.formatter.Options{
        .emit = .plain,
        .unwrap = true,
        .trim = true,
    };

    var formatter = gt.formatter.TerminalFormatter.init(&term.terminal, options);
    var writer = std.io.Writer.Allocating.init(alloc);
    defer writer.deinit();
    formatter.format(&writer.writer) catch {
        env.signalError("formatter failed");
        return env.nil();
    };
    const written = writer.written();

    if (written.len == 0) return env.nil();
    return env.makeString(written);
}

/// (ghostel--module-version)
fn fnModuleVersion(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    return env.makeString(version);
}

const ExportId = enum(u32) {
    new_term = 1,
    write_input = 2,
    set_size = 3,
    redraw = 6,
    scroll = 8,
    scroll_top = 9,
    scroll_bottom = 10,
    encode_key = 11,
    mouse_event = 12,
    focus_event = 13,
    set_palette = 14,
    set_default_colors = 15,
    mode_enabled = 16,
    debug_state = 17,
    debug_feed = 18,
    module_version = 19,
    cursor_position = 20,
    redraw_full_scrollback = 21,
    copy_all_text = 22,
    enable_vt_log = 23,
    disable_vt_log = 24,
    get_title = 25,
    get_pwd = 26,
    cursor_pending_wrap = 27,
    alt_screen = 28,
    cursor_on_empty_row = 29,
    uri_at = 30,
    cursor_row_char_offset = 31,
    pty_password_input_p = 32,
    set_bold_config = 33,
};

pub const ghostel_export_descriptors = [_]loader.ExportDescriptor{
    .{ .export_id = @intFromEnum(ExportId.new_term), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--new", .min_arity = 2, .max_arity = 5, .docstring = "Create a new ghostel terminal.\n\n(ghostel--new ROWS COLS &optional MAX-SCROLLBACK KITTY-STORAGE-LIMIT KITTY-MEDIUMS)\n\nKITTY-STORAGE-LIMIT is the kitty graphics image storage cap in bytes (default 320 MiB); 0 disables kitty graphics entirely.\nKITTY-MEDIUMS is a bitfield: bit 0 = file medium, bit 1 = temp-file medium, bit 2 = shared-memory medium (default 0 = direct only).", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.write_input), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--write-input", .min_arity = 2, .max_arity = 2, .docstring = "Write raw bytes to the terminal.\n\n(ghostel--write-input TERM DATA)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.set_size), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--set-size", .min_arity = 3, .max_arity = 5, .docstring = "Resize the terminal.\n\n(ghostel--set-size TERM ROWS COLS &optional CELL-W CELL-H)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.redraw), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--redraw", .min_arity = 1, .max_arity = 2, .docstring = "Redraw the terminal into the current buffer.\n\n(ghostel--redraw TERM &optional FULL)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.scroll), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--scroll", .min_arity = 2, .max_arity = 2, .docstring = "Scroll the terminal viewport by DELTA lines.\n\n(ghostel--scroll TERM DELTA)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.scroll_top), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--scroll-top", .min_arity = 1, .max_arity = 1, .docstring = "Scroll the terminal viewport to the top of scrollback.\n\n(ghostel--scroll-top TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.scroll_bottom), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--scroll-bottom", .min_arity = 1, .max_arity = 1, .docstring = "Scroll the terminal viewport to the bottom.\n\n(ghostel--scroll-bottom TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.encode_key), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--encode-key", .min_arity = 3, .max_arity = 4, .docstring = "Encode a key event using the terminal's key encoder.\n\n(ghostel--encode-key TERM KEY MODS &optional UTF8)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.mouse_event), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--mouse-event", .min_arity = 6, .max_arity = 6, .docstring = "Send a mouse event to the terminal.\n\n(ghostel--mouse-event TERM ACTION BUTTON ROW COL MODS)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.focus_event), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--focus-event", .min_arity = 2, .max_arity = 2, .docstring = "Send a focus event to the terminal.\n\n(ghostel--focus-event TERM GAINED)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.set_palette), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--set-palette", .min_arity = 2, .max_arity = 2, .docstring = "Set the ANSI color palette.\n\n(ghostel--set-palette TERM COLORS-STRING)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.set_default_colors), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--set-default-colors", .min_arity = 3, .max_arity = 3, .docstring = "Set default foreground and background colors.\n\n(ghostel--set-default-colors TERM FG-HEX BG-HEX)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.set_bold_config), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--set-bold-config", .min_arity = 2, .max_arity = 2, .docstring = "Configure bold text coloring.\n\nCONFIG can be nil (none), 'bright, or a hex color string.\n\n(ghostel--set-bold-config TERM CONFIG)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.mode_enabled), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--mode-enabled", .min_arity = 2, .max_arity = 2, .docstring = "Return t if terminal DEC private MODE is enabled.\n\n(ghostel--mode-enabled TERM MODE)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.debug_state), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--debug-state", .min_arity = 1, .max_arity = 1, .docstring = "Return debug info about terminal/render state.\n\n(ghostel--debug-state TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.debug_feed), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--debug-feed", .min_arity = 2, .max_arity = 2, .docstring = "Feed STR to terminal and return first row + cursor.\n\n(ghostel--debug-feed TERM STR)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.module_version), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--module-version", .min_arity = 0, .max_arity = 0, .docstring = "Return the native module version string.\n\n(ghostel--module-version)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.cursor_position), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--cursor-position", .min_arity = 1, .max_arity = 1, .docstring = "Return terminal cursor position as (COL . ROW), 0-indexed.\n\n(ghostel--cursor-position TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.cursor_row_char_offset), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--cursor-row-char-offset", .min_arity = 1, .max_arity = 1, .docstring = "Return cursor Emacs char offset from its row start.\n\n(ghostel--cursor-row-char-offset TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.cursor_pending_wrap), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--cursor-pending-wrap-p", .min_arity = 1, .max_arity = 1, .docstring = "Return t if the cursor is in pending-wrap state.\n\n(ghostel--cursor-pending-wrap-p TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.alt_screen), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--alt-screen-p", .min_arity = 1, .max_arity = 1, .docstring = "Return t if terminal is on the alternate screen buffer.\n\n(ghostel--alt-screen-p TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.cursor_on_empty_row), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--cursor-on-empty-row-p", .min_arity = 1, .max_arity = 1, .docstring = "Return t if the cursor row has no written cells or styled cells.\n\n(ghostel--cursor-on-empty-row-p TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.redraw_full_scrollback), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--redraw-full-scrollback", .min_arity = 1, .max_arity = 1, .docstring = "Render entire scrollback into buffer, return original viewport line.\n\n(ghostel--redraw-full-scrollback TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.copy_all_text), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--copy-all-text", .min_arity = 1, .max_arity = 1, .docstring = "Return entire scrollback as plain text string.\n\n(ghostel--copy-all-text TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.enable_vt_log), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--enable-vt-log", .min_arity = 0, .max_arity = 0, .docstring = "Enable libghostty internal log routing to *ghostel-debug*.\n\n(ghostel--enable-vt-log)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.disable_vt_log), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--disable-vt-log", .min_arity = 0, .max_arity = 0, .docstring = "Disable libghostty internal log routing.\n\n(ghostel--disable-vt-log)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.get_title), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--get-title", .min_arity = 1, .max_arity = 1, .docstring = "Get the terminal title.\n\n(ghostel--get-title TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.get_pwd), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--get-pwd", .min_arity = 1, .max_arity = 1, .docstring = "Get the terminal working directory.\n\n(ghostel--get-pwd TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.uri_at), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--native-uri-at", .min_arity = 3, .max_arity = 3, .docstring = "Get URI at ROW-from-bottom and COL.\n\n(ghostel--native-uri-at TERM ROW COL)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.pty_password_input_p), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "ghostel--pty-password-input-p", .min_arity = 1, .max_arity = 1, .docstring = "Return t if the tty at PATH is in canonical mode with echo off.\n\n(ghostel--pty-password-input-p PATH)", .flags = 0 },
};

pub fn invokeExport(export_id: u32, raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    emacs.initModule(alloc, raw_env.?);
    return switch (@as(ExportId, @enumFromInt(export_id))) {
        .new_term => fnNew(raw_env, nargs, args, data),
        .write_input => fnWriteInput(raw_env, nargs, args, data),
        .set_size => fnSetSize(raw_env, nargs, args, data),
        .redraw => fnRedraw(raw_env, nargs, args, data),
        .scroll => fnScroll(raw_env, nargs, args, data),
        .scroll_top => fnScrollTop(raw_env, nargs, args, data),
        .scroll_bottom => fnScrollBottom(raw_env, nargs, args, data),
        .encode_key => fnEncodeKey(raw_env, nargs, args, data),
        .mouse_event => fnMouseEvent(raw_env, nargs, args, data),
        .focus_event => fnFocusEvent(raw_env, nargs, args, data),
        .set_palette => fnSetPalette(raw_env, nargs, args, data),
        .set_default_colors => fnSetDefaultColors(raw_env, nargs, args, data),
        .set_bold_config => fnSetBoldConfig(raw_env, nargs, args, data),
        .mode_enabled => fnModeEnabled(raw_env, nargs, args, data),
        .debug_state => fnDebugState(raw_env, nargs, args, data),
        .debug_feed => fnDebugFeed(raw_env, nargs, args, data),
        .module_version => fnModuleVersion(raw_env, nargs, args, data),
        .cursor_position => fnCursorPosition(raw_env, nargs, args, data),
        .cursor_row_char_offset => fnCursorRowCharOffset(raw_env, nargs, args, data),
        .cursor_pending_wrap => fnCursorPendingWrap(raw_env, nargs, args, data),
        .alt_screen => fnAltScreen(raw_env, nargs, args, data),
        .cursor_on_empty_row => fnCursorOnEmptyRow(raw_env, nargs, args, data),
        .redraw_full_scrollback => fnRedrawFullScrollback(raw_env, nargs, args, data),
        .copy_all_text => fnCopyAllText(raw_env, nargs, args, data),
        .enable_vt_log => fnEnableVtLog(raw_env, nargs, args, data),
        .disable_vt_log => fnDisableVtLog(raw_env, nargs, args, data),
        .get_title => fnGetTitle(raw_env, nargs, args, data),
        .get_pwd => fnGetPwd(raw_env, nargs, args, data),
        .uri_at => fnUriAt(raw_env, nargs, args, data),
        .pty_password_input_p => fnPtyPasswordInputP(raw_env, nargs, args, data),
    };
}

pub fn getVariable(export_id: u32, raw_env: ?*c.emacs_env, _: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = export_id;
    const env = emacs.Env.init(raw_env.?);
    env.signalError("variable export not supported");
    return env.nil();
}

pub fn setVariable(export_id: u32, raw_env: ?*c.emacs_env, _: c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = export_id;
    const env = emacs.Env.init(raw_env.?);
    env.signalError("variable export not supported");
    return env.nil();
}

// ---------------------------------------------------------------------------
// Ghostty callbacks — invoked synchronously during vtWrite
// ---------------------------------------------------------------------------

/// Called when the terminal needs to write response data back to the PTY.
fn writePtyCallback(handler: *gt.TerminalStream.Handler, data: [:0]const u8) void {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    const env = term.env orelse return;

    if (data.len == 0) return;
    _ = env.f("ghostel--flush-output", .{data});
}

/// Called when the terminal receives BEL.
fn bellCallback(handler: *gt.TerminalStream.Handler) void {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    const env = term.env orelse return;

    _ = env.call0(emacs.sym.ding);
}

// TODO: DeviceAttributes is not exported from ghostty-vt for some reason.
//       We should file an issue.
const DeviceAttributesFn = @typeInfo(
    @typeInfo(
        @FieldType(gt.TerminalStream.Handler.Effects, "device_attributes"),
    ).optional.child,
).pointer.child;
const DeviceAttributes = @typeInfo(DeviceAttributesFn).@"fn".return_type.?;

/// Called when the terminal receives a device attributes query (DA1/DA2/DA3).
/// Reports as a VT220-compatible terminal with ANSI color support.
fn deviceAttributesCallback(_: *gt.TerminalStream.Handler) DeviceAttributes {
    return .{
        .primary = .{
            .conformance_level = .vt220,
            .features = &.{.ansi_color},
        },
        .secondary = .{
            .device_type = .vt220,
            .firmware_version = 1,
            .rom_cartridge = 0,
        },
        .tertiary = .{
            .unit_id = 0,
        },
    };
}

/// Called for XTWINOPS size queries (CSI 14/16/18 t).  libghostty
/// invokes this to learn the terminal's row/column count and cell
/// pixel dimensions, then encodes the appropriate response itself
/// and writes it via the write_pty callback.  Image-rendering tools
/// like timg use these queries to detect kitty graphics support and
/// size images correctly — without a response they fall back to
/// half-block rendering.
fn sizeCallback(handler: *gt.TerminalStream.Handler) ?gt.size_report.Size {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    return .{
        .rows = term.terminal.rows,
        .columns = term.terminal.cols,
        .cell_width = term.terminal.width_px / term.terminal.cols,
        .cell_height = term.terminal.height_px / term.terminal.rows,
    };
}

/// Called when the terminal title changes.
fn titleChangedCallback(handler: *gt.TerminalStream.Handler) void {
    const term: *GhostelTerm = @fieldParentPtr("terminal", handler.terminal);
    const env = term.env orelse return;

    const title = term.terminal.getTitle();
    if (title) |t| {
        _ = env.call1(emacs.sym.@"ghostel--set-title", env.makeString(t));
    }
}

fn normalizeBareLfAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var extra_cr: usize = 0;
    for (0..raw.len) |i| {
        if (raw[i] == '\n' and (i == 0 or raw[i - 1] != '\r')) {
            extra_cr += 1;
        }
    }
    if (extra_cr == 0) return raw;

    const normalized = try allocator.alloc(u8, raw.len + extra_cr);
    var pos: usize = 0;
    for (0..raw.len) |i| {
        if (raw[i] == '\n' and (i == 0 or raw[i - 1] != '\r')) {
            normalized[pos] = '\r';
            pos += 1;
        }
        normalized[pos] = raw[i];
        pos += 1;
    }
    return normalized[0..pos];
}

test "normalizeBareLfAlloc inserts carriage returns before bare line feeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const normalized = try normalizeBareLfAlloc(arena.allocator(), "alpha\nbeta\r\ngamma\n");
    try std.testing.expectEqualStrings("alpha\r\nbeta\r\ngamma\r\n", normalized);
}

test "normalizeBareLfAlloc reuses the original slice when no normalization is needed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = "alpha\r\nbeta";
    const normalized = try normalizeBareLfAlloc(arena.allocator(), raw);
    try std.testing.expectEqualStrings(raw, normalized);
    try std.testing.expectEqual(@intFromPtr(raw.ptr), @intFromPtr(normalized.ptr));
}

test "loader module publishes generic export manifest" {
    var manifest = std.mem.zeroes(loader.GenericManifest);
    loader_module_init_generic(&manifest);

    try std.testing.expectEqual(loader.LoaderAbiVersion, manifest.loader_abi);
    try std.testing.expectEqualStrings("ghostel", std.mem.span(manifest.module_id));
    try std.testing.expect(manifest.exports_len > 0);
    try std.testing.expectEqual(@intFromEnum(loader.ExportKind.function), manifest.exports[0].kind);
    try std.testing.expectEqualStrings("ghostel--new", std.mem.span(manifest.exports[0].lisp_name));
}

test "Env.init initializes symbols for loader-managed entrypoints" {
    const source = @embedFile("emacs.zig");
    const init_pos = std.mem.indexOf(u8, source, "pub fn init(raw: *c.emacs_env) Env") orelse return error.MissingEnvInit;
    const end_pos = std.mem.indexOfPos(u8, source, init_pos, "    // --- Symbol interning ---") orelse return error.MissingEnvInitEnd;
    const body = source[init_pos..end_pos];
    const ensure_pos = std.mem.indexOf(u8, body, "ensureSymbols(env);") orelse return error.MissingEnsureSymbols;
    const return_pos = std.mem.indexOf(u8, body, "return env;") orelse return error.MissingEnvReturn;

    try std.testing.expect(ensure_pos < return_pos);
}

// ---------------------------------------------------------------------------
// zig log callback
// ---------------------------------------------------------------------------

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .warn,
};

/// Global Emacs env stashed during any Elisp→Zig call where logging is
/// active.  Only valid on the main thread while a Zig function is
/// executing; set to null at all other times.
///
/// Thread safety: the GhosttySysLogFn contract requires thread safety,
/// but ghostel only drives libghostty from Emacs's main thread, so the
/// callback always fires on the same thread that stashed the env.  If
/// libghostty ever uses background threads, this would need a mutex or
/// a lock-free message queue.
var vt_log_env: ?emacs.Env = null;

/// Log callback matching GhosttySysLogFn.  Formats the message and
/// forwards it to `ghostel--debug-log-vt' in Elisp.
fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(message_level, scope, format, args);

    if (!vt_log_active) return;
    const env = vt_log_env orelse return;
    const level_str: []const u8 = switch (message_level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const scope_slice = @tagName(scope);
    var buf: [4096]u8 = undefined;
    const msg_slice = std.fmt.bufPrint(&buf, format, args) catch return;

    _ = env.call3(
        emacs.sym.@"ghostel--debug-log-vt",
        env.makeString(level_str),
        env.makeString(scope_slice),
        env.makeString(msg_slice),
    );

    // If the Elisp call signaled an error (e.g. ghostel--debug-log-vt is
    // void-function because ghostel-debug.el isn't loaded), clear it so it
    // doesn't leak into the calling context and disable logging to prevent
    // repeated errors.
    if (env.nonLocalExitCheck() != c.emacs_funcall_exit_return) {
        env.nonLocalExitClear();
        vt_log_active = false;
    }
}

/// Whether the VT log callback is installed.
var vt_log_active: bool = false;

/// (ghostel--enable-vt-log)
fn fnEnableVtLog(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    vt_log_active = true;
    return env.t();
}

/// (ghostel--disable-vt-log)
fn fnDisableVtLog(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    vt_log_active = false;
    return env.t();
}

fn fnUriAt(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const term = env.getUserPtr(GhostelTerm, args[0]) orelse return env.nil();
    const row_from_bottom = env.extractInteger(args[1]);
    const col = env.extractInteger(args[2]);
    const total_rows = term.terminal.screens.active.pages.total_rows;

    if (col < 0 or col >= term.renderer.size.cols) return env.nil();
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

    const link_id = pin.node.data.lookupHyperlink(cell) orelse return env.nil();
    const entry = pin.node.data.hyperlink_set.get(pin.node.data.memory, link_id);
    const uri = entry.uri.slice(pin.node.data.memory);

    return env.makeString(uri);
}
