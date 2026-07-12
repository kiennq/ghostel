/// Ghostel target module export dispatch.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gt = @import("ghostty-vt");

const emacs = @import("emacs");
const ComintFilter = @import("comint_filter.zig");
const GhostelTerm = @import("GhostelTerm.zig");
const png = @import("png.zig");
const loader = @import("dyn_loader_abi");

const c = emacs.c;

/// In debug builds, all allocations go through DebugAllocator for corruption
/// detection (double-free, use-after-free, overflow canaries).  A debug-only
/// kill-emacs-hook explicitly deinits all live terminals before process exit so
/// atexit can call deinit() on a clean slate.
var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
var alloc: Allocator = std.heap.c_allocator;
var debug_alloc_initialized = false;

var io: std.Io.Threaded = .init_single_threaded;

/// Module version — see src/version.zig.  Keep in sync with ghostel.el
/// and build.zig.zon.
const version = @import("version.zig").version;
const id: [:0]const u8 = "ghostel";

extern fn atexit(func: *const fn () callconv(.c) void) c_int;

// ---------------------------------------------------------------------------
// Module entry points
// ---------------------------------------------------------------------------

export fn loader_module_init_generic(out: *loader.GenericManifest) callconv(.c) void {
    initAllocator();
    // The dyn-loader path does not call `emacs_module_init`, so install
    // libghostty's process-global callbacks when the loader reads our manifest.
    GhostelTerm.setModuleRuntime(alloc, io.io());
    ComintFilter.setModuleAllocator(alloc);
    gt.sys.decode_png = &png.decode;
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

    initAllocator();

    const raw_env = runtime.get_environment.?(runtime);
    emacs.initModule(alloc, raw_env);
    GhostelTerm.setModuleRuntime(alloc, io.io());
    ComintFilter.setModuleAllocator(alloc);
    const env = emacs.Env.init(raw_env);

    // Runtime functions are loaded through dyn-loader.  Do not bind the target
    // module's export table directly here; direct binding pins this DLL/shared
    // object and bypasses dyn-loader reload/recovery semantics.
    GhostelTerm.setModuleEnvironment(env) catch return 1;
    gt.sys.decode_png = &png.decode;
    env.provide("ghostel-module");
    return 0;
}

fn initAllocator() void {
    if (builtin.mode == .Debug and !debug_alloc_initialized) {
        alloc = debug_alloc.allocator();
        _ = atexit(&debugAtExit);
        debug_alloc_initialized = true;
    }
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
};

// ---------------------------------------------------------------------------
// Dyn-loader ABI manifest and dispatch
// ---------------------------------------------------------------------------

const exported_functions =
    GhostelTerm.emacs_functions ++ module_functions ++ ComintFilter.emacs_functions;

comptime {
    @setEvalBranchQuota(200_000);
    for (exported_functions, 0..) |entry, index| {
        for (exported_functions[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.name, other.name)) {
                @compileError("duplicate Emacs export name: " ++ entry.name);
            }
        }
    }
}

pub const ghostel_export_descriptors = blk: {
    var descriptors: [exported_functions.len]loader.ExportDescriptor = undefined;
    for (exported_functions, 0..) |entry, index| {
        descriptors[index] = descriptor(index, entry);
    }
    break :blk descriptors;
};

fn descriptor(comptime index: usize, comptime entry: emacs.FunctionEntry) loader.ExportDescriptor {
    return .{
        .export_id = @intCast(index + 1),
        .kind = @intFromEnum(loader.ExportKind.function),
        .lisp_name = entry.name,
        .min_arity = entry.arity[0],
        .max_arity = entry.arity[1],
        .docstring = entry.doc,
        .flags = 0,
    };
}

fn exportIdByName(comptime name: []const u8) u32 {
    inline for (exported_functions, 0..) |entry, index| {
        if (comptime std.mem.eql(u8, entry.name, name)) {
            return @intCast(index + 1);
        }
    }
    @compileError("missing Emacs function entry: " ++ name);
}

fn callEntry(
    comptime entry: emacs.FunctionEntry,
    env: emacs.Env,
    nargs: isize,
    args: [*c]c.emacs_value,
) c.emacs_value {
    const result = entry.impl.call(env, nargs, args);
    return if (comptime @typeInfo(@TypeOf(result)) == .error_union)
        result catch |e| {
            const err: anyerror = e;
            switch (err) {
                error.EmacsQuit => env.nonLocalExitSignal(emacs.sym.quit, env.nil()),
                else => {
                    env.logStackTrace(@errorReturnTrace());
                    env.signalErrorf("error in %s: %s", .{ entry.name, @errorName(err) });
                },
            }
            return env.nil();
        }
    else
        result;
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

    if (export_id == exportIdByName("ghostel--new")) {
        GhostelTerm.setModuleEnvironment(env) catch |err| {
            env.signalErrorf("unable to initialize module environment: %s", .{@errorName(err)});
            return env.nil();
        };
    }

    inline for (exported_functions, 0..) |entry, index| {
        if (export_id == @as(u32, @intCast(index + 1))) {
            return callEntry(entry, env, nargs, args);
        }
    }
    env.signalErrorf("unknown export id: %d", .{export_id});
    return env.nil();
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
    // Debug only: in `emacs -nw' the module's stderr is the user's tty.
    if (builtin.mode == .Debug) {
        std.log.defaultLog(message_level, scope, format, args);
    }

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

test "loader manifest exports every registered Emacs function" {
    var generic_manifest = std.mem.zeroes(loader.GenericManifest);
    loader_module_init_generic(&generic_manifest);

    try std.testing.expectEqual(exported_functions.len, generic_manifest.exports_len);
    inline for (exported_functions, 0..) |entry, index| {
        const exported = generic_manifest.exports[index];
        try std.testing.expectEqual(@as(u32, @intCast(index + 1)), exported.export_id);
        try std.testing.expectEqualStrings(entry.name, std.mem.span(exported.lisp_name));
        try std.testing.expectEqual(entry.arity[0], exported.min_arity);
        try std.testing.expectEqual(entry.arity[1], exported.max_arity);
        try std.testing.expectEqualStrings(entry.doc, std.mem.span(exported.docstring));
    }
}
