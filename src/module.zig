/// Ghostel target module export dispatch.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const emacs = @import("emacs");
const ComintFilter = @import("comint_filter.zig");
const GhostelTerm = @import("GhostelTerm.zig");
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
// Module entry points
// ---------------------------------------------------------------------------

export fn loader_module_init_generic(out: *loader.GenericManifest) callconv(.c) void {
    // The dyn-loader path does not call `emacs_module_init`, so install
    // libghostty's process-global callbacks when the loader reads our manifest.
    GhostelTerm.setModuleAllocator(alloc);
    ComintFilter.setModuleAllocator(alloc);
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
    GhostelTerm.setModuleAllocator(alloc);
    ComintFilter.setModuleAllocator(alloc);
    const env = emacs.Env.init(raw_env);

    // Runtime functions are loaded through dyn-loader.  Do not bind the target
    // module's export table directly here; direct binding pins this DLL/shared
    // object and bypasses dyn-loader reload/recovery semantics.
    sys.init();
    env.provide("ghostel-module");
    return 0;
}

fn debugAtExit() callconv(.c) void {
    if (debug_alloc.deinit() == .leak) {
        std.debug.print("ghostel: memory leak detected at exit\n", .{});
    }
}

// ---------------------------------------------------------------------------
// Module-owned Elisp functions
// ---------------------------------------------------------------------------

const module_functions = [_]emacs.FunctionEntry{
    .{
        .name = "ghostel--module-version",
        .arity = .{ 0, 0 },
        .doc =
        \\Return the native module version string.
        \\
        \\(ghostel--module-version)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                return env.makeString(version);
            }
        },
    },
    .{
        .name = "ghostel--enable-vt-log",
        .arity = .{ 0, 0 },
        .doc =
        \\Enable libghostty internal log routing to *ghostel-debug*.
        \\
        \\(ghostel--enable-vt-log)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                vt_log_active = true;
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--disable-vt-log",
        .arity = .{ 0, 0 },
        .doc =
        \\Disable libghostty internal log routing.
        \\
        \\(ghostel--disable-vt-log)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, _: [*c]emacs.Value) !emacs.Value {
                vt_log_active = false;
                return env.t();
            }
        },
    },
    .{
        .name = "ghostel--pty-password-input-p",
        .arity = .{ 1, 1 },
        .doc =
        \\Return t if the tty at PATH is in canonical mode with echo off.
        \\
        \\This mirrors libghostty's password-input heuristic.  Returns nil when the
        \\path can't be opened, `tcgetattr' fails, or the tty is in some other state.
        \\
        \\(ghostel--pty-password-input-p PATH)
        ,
        .impl = struct {
            pub fn call(env: emacs.Env, _: isize, args: [*c]emacs.Value) !emacs.Value {
                var stack_buf: [1024]u8 = undefined;
                const path = env.extractString(args[0], &stack_buf) catch return env.nil();
                return if (pty.isPasswordMode(path)) env.t() else env.nil();
            }
        },
    },
};

// ---------------------------------------------------------------------------
// Dyn-loader ABI manifest and dispatch
// ---------------------------------------------------------------------------

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
    comint_make_state = 34,
    comint_filter = 35,
    comint_set_palette = 36,
    comint_set_default_colors = 37,
};

pub const ghostel_export_descriptors = [_]loader.ExportDescriptor{
    descriptor(.new_term, entryByName(GhostelTerm.emacs_functions, "ghostel--new")),
    descriptor(.write_input, entryByName(GhostelTerm.emacs_functions, "ghostel--write-input")),
    descriptor(.set_size, entryByName(GhostelTerm.emacs_functions, "ghostel--set-size")),
    descriptor(.redraw, entryByName(GhostelTerm.emacs_functions, "ghostel--redraw")),
    descriptor(.scroll, entryByName(GhostelTerm.emacs_functions, "ghostel--scroll")),
    descriptor(.scroll_top, entryByName(GhostelTerm.emacs_functions, "ghostel--scroll-top")),
    descriptor(.scroll_bottom, entryByName(GhostelTerm.emacs_functions, "ghostel--scroll-bottom")),
    descriptor(.encode_key, entryByName(GhostelTerm.emacs_functions, "ghostel--encode-key")),
    descriptor(.mouse_event, entryByName(GhostelTerm.emacs_functions, "ghostel--mouse-event")),
    descriptor(.focus_event, entryByName(GhostelTerm.emacs_functions, "ghostel--focus-event")),
    descriptor(.set_palette, entryByName(GhostelTerm.emacs_functions, "ghostel--set-palette")),
    descriptor(.set_default_colors, entryByName(GhostelTerm.emacs_functions, "ghostel--set-default-colors")),
    descriptor(.mode_enabled, entryByName(GhostelTerm.emacs_functions, "ghostel--mode-enabled")),
    descriptor(.debug_state, entryByName(GhostelTerm.emacs_functions, "ghostel--debug-state")),
    descriptor(.debug_feed, entryByName(GhostelTerm.emacs_functions, "ghostel--debug-feed")),
    descriptor(.module_version, entryByName(module_functions, "ghostel--module-version")),
    descriptor(.cursor_position, entryByName(GhostelTerm.emacs_functions, "ghostel--cursor-position")),
    descriptor(.redraw_full_scrollback, entryByName(GhostelTerm.emacs_functions, "ghostel--redraw-full-scrollback")),
    descriptor(.copy_all_text, entryByName(GhostelTerm.emacs_functions, "ghostel--copy-all-text")),
    descriptor(.enable_vt_log, entryByName(module_functions, "ghostel--enable-vt-log")),
    descriptor(.disable_vt_log, entryByName(module_functions, "ghostel--disable-vt-log")),
    descriptor(.get_title, entryByName(GhostelTerm.emacs_functions, "ghostel--get-title")),
    descriptor(.get_pwd, entryByName(GhostelTerm.emacs_functions, "ghostel--get-pwd")),
    descriptor(.cursor_pending_wrap, entryByName(GhostelTerm.emacs_functions, "ghostel--cursor-pending-wrap-p")),
    descriptor(.alt_screen, entryByName(GhostelTerm.emacs_functions, "ghostel--alt-screen-p")),
    descriptor(.cursor_on_empty_row, entryByName(GhostelTerm.emacs_functions, "ghostel--cursor-on-empty-row-p")),
    descriptor(.uri_at, entryByName(GhostelTerm.emacs_functions, "ghostel--native-uri-at")),
    descriptor(.cursor_row_char_offset, entryByName(GhostelTerm.emacs_functions, "ghostel--cursor-row-char-offset")),
    descriptor(.pty_password_input_p, entryByName(module_functions, "ghostel--pty-password-input-p")),
    descriptor(.set_bold_config, entryByName(GhostelTerm.emacs_functions, "ghostel--set-bold-config")),
    descriptor(.comint_make_state, entryByName(ComintFilter.emacs_functions, "ghostel--comint-make-state")),
    descriptor(.comint_filter, entryByName(ComintFilter.emacs_functions, "ghostel--comint-filter")),
    descriptor(.comint_set_palette, entryByName(ComintFilter.emacs_functions, "ghostel--comint-set-palette")),
    descriptor(.comint_set_default_colors, entryByName(ComintFilter.emacs_functions, "ghostel--comint-set-default-colors")),
};

fn descriptor(comptime export_id: ExportId, comptime entry: emacs.FunctionEntry) loader.ExportDescriptor {
    return .{
        .export_id = @intFromEnum(export_id),
        .kind = @intFromEnum(loader.ExportKind.function),
        .lisp_name = entry.name,
        .min_arity = entry.arity[0],
        .max_arity = entry.arity[1],
        .docstring = entry.doc,
        .flags = 0,
    };
}

fn entryByName(comptime entries: anytype, comptime name: []const u8) emacs.FunctionEntry {
    inline for (entries) |entry| {
        if (comptime entryNameEql(entry.name, name)) return entry;
    }
    @compileError("missing Emacs function entry: " ++ name);
}

fn entryNameEql(comptime actual: [*:0]const u8, comptime expected: []const u8) bool {
    @setEvalBranchQuota(10_000);
    for (expected, 0..) |ch, i| {
        if (actual[i] != ch) return false;
    }
    return actual[expected.len] == 0;
}

fn callEntry(
    comptime entries: anytype,
    comptime name: []const u8,
    env: emacs.Env,
    nargs: isize,
    args: [*c]c.emacs_value,
) c.emacs_value {
    inline for (entries) |entry| {
        if (comptime entryNameEql(entry.name, name)) {
            const result = entry.impl.call(env, nargs, args);
            return if (comptime @typeInfo(@TypeOf(result)) == .error_union)
                result catch |err| {
                    env.logStackTrace(@errorReturnTrace());
                    env.signalErrorf("error in %s: %s", .{ entry.name, @errorName(err) });
                    return env.nil();
                }
            else
                result;
        }
    }
    @compileError("missing Emacs function entry: " ++ name);
}

pub fn invokeExport(
    export_id: u32,
    raw_env: ?*c.emacs_env,
    nargs: isize,
    args: [*c]c.emacs_value,
    _: ?*anyopaque,
) callconv(.c) c.emacs_value {
    emacs.initModule(alloc, raw_env.?);
    const env = emacs.Env.init(raw_env.?);
    const prev_env = emacs.current_env;
    emacs.current_env = env;
    defer emacs.current_env = prev_env;

    const id_enum = std.meta.intToEnum(ExportId, export_id) catch {
        env.signalErrorf("unknown export id: %d", .{export_id});
        return env.nil();
    };

    return switch (id_enum) {
        .new_term => callEntry(GhostelTerm.emacs_functions, "ghostel--new", env, nargs, args),
        .write_input => callEntry(GhostelTerm.emacs_functions, "ghostel--write-input", env, nargs, args),
        .set_size => callEntry(GhostelTerm.emacs_functions, "ghostel--set-size", env, nargs, args),
        .redraw => callEntry(GhostelTerm.emacs_functions, "ghostel--redraw", env, nargs, args),
        .scroll => callEntry(GhostelTerm.emacs_functions, "ghostel--scroll", env, nargs, args),
        .scroll_top => callEntry(GhostelTerm.emacs_functions, "ghostel--scroll-top", env, nargs, args),
        .scroll_bottom => callEntry(GhostelTerm.emacs_functions, "ghostel--scroll-bottom", env, nargs, args),
        .encode_key => callEntry(GhostelTerm.emacs_functions, "ghostel--encode-key", env, nargs, args),
        .mouse_event => callEntry(GhostelTerm.emacs_functions, "ghostel--mouse-event", env, nargs, args),
        .focus_event => callEntry(GhostelTerm.emacs_functions, "ghostel--focus-event", env, nargs, args),
        .set_palette => callEntry(GhostelTerm.emacs_functions, "ghostel--set-palette", env, nargs, args),
        .set_default_colors => callEntry(GhostelTerm.emacs_functions, "ghostel--set-default-colors", env, nargs, args),
        .mode_enabled => callEntry(GhostelTerm.emacs_functions, "ghostel--mode-enabled", env, nargs, args),
        .debug_state => callEntry(GhostelTerm.emacs_functions, "ghostel--debug-state", env, nargs, args),
        .debug_feed => callEntry(GhostelTerm.emacs_functions, "ghostel--debug-feed", env, nargs, args),
        .module_version => callEntry(module_functions, "ghostel--module-version", env, nargs, args),
        .cursor_position => callEntry(GhostelTerm.emacs_functions, "ghostel--cursor-position", env, nargs, args),
        .redraw_full_scrollback => callEntry(GhostelTerm.emacs_functions, "ghostel--redraw-full-scrollback", env, nargs, args),
        .copy_all_text => callEntry(GhostelTerm.emacs_functions, "ghostel--copy-all-text", env, nargs, args),
        .enable_vt_log => callEntry(module_functions, "ghostel--enable-vt-log", env, nargs, args),
        .disable_vt_log => callEntry(module_functions, "ghostel--disable-vt-log", env, nargs, args),
        .get_title => callEntry(GhostelTerm.emacs_functions, "ghostel--get-title", env, nargs, args),
        .get_pwd => callEntry(GhostelTerm.emacs_functions, "ghostel--get-pwd", env, nargs, args),
        .cursor_pending_wrap => callEntry(GhostelTerm.emacs_functions, "ghostel--cursor-pending-wrap-p", env, nargs, args),
        .alt_screen => callEntry(GhostelTerm.emacs_functions, "ghostel--alt-screen-p", env, nargs, args),
        .cursor_on_empty_row => callEntry(GhostelTerm.emacs_functions, "ghostel--cursor-on-empty-row-p", env, nargs, args),
        .uri_at => callEntry(GhostelTerm.emacs_functions, "ghostel--native-uri-at", env, nargs, args),
        .cursor_row_char_offset => callEntry(GhostelTerm.emacs_functions, "ghostel--cursor-row-char-offset", env, nargs, args),
        .pty_password_input_p => callEntry(module_functions, "ghostel--pty-password-input-p", env, nargs, args),
        .set_bold_config => callEntry(GhostelTerm.emacs_functions, "ghostel--set-bold-config", env, nargs, args),
        .comint_make_state => callEntry(ComintFilter.emacs_functions, "ghostel--comint-make-state", env, nargs, args),
        .comint_filter => callEntry(ComintFilter.emacs_functions, "ghostel--comint-filter", env, nargs, args),
        .comint_set_palette => callEntry(ComintFilter.emacs_functions, "ghostel--comint-set-palette", env, nargs, args),
        .comint_set_default_colors => callEntry(ComintFilter.emacs_functions, "ghostel--comint-set-default-colors", env, nargs, args),
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
// zig log callback
// ---------------------------------------------------------------------------

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .Debug) .debug else .warn,
};

/// Whether VT logging is active.
pub var vt_log_active: bool = false;

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
    const env = emacs.current_env orelse return;
    const level_str: []const u8 = switch (message_level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const scope_slice = @tagName(scope);
    var buf: [4096]u8 = undefined;
    const msg_slice = std.fmt.bufPrint(&buf, format, args) catch return;

    _ = env.f("ghostel--debug-log-vt", .{ level_str, scope_slice, msg_slice });

    // If the Elisp call signaled an error (e.g. ghostel--debug-log-vt is
    // void-function because ghostel-debug.el isn't loaded), clear it so it
    // doesn't leak into the calling context and disable logging to prevent
    // repeated errors.
    if (env.nonLocalExitCheck() != .normal) {
        env.nonLocalExitClear();
        vt_log_active = false;
    }
}

test "loader module publishes generic export manifest" {
    var generic_manifest = std.mem.zeroes(loader.GenericManifest);
    loader_module_init_generic(&generic_manifest);

    try std.testing.expectEqual(loader.LoaderAbiVersion, generic_manifest.loader_abi);
    try std.testing.expectEqualStrings("ghostel", std.mem.span(generic_manifest.module_id));
    try std.testing.expect(generic_manifest.exports_len > 0);
    try std.testing.expectEqual(@intFromEnum(loader.ExportKind.function), generic_manifest.exports[0].kind);
    try std.testing.expectEqualStrings("ghostel--new", std.mem.span(generic_manifest.exports[0].lisp_name));
}

test "comint export ids are appended after terminal ABI ids" {
    try std.testing.expectEqual(@as(u32, 33), @intFromEnum(ExportId.set_bold_config));
    try std.testing.expectEqual(@as(u32, 34), @intFromEnum(ExportId.comint_make_state));
    try std.testing.expectEqual(@as(u32, 37), @intFromEnum(ExportId.comint_set_default_colors));
}
