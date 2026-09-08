const std = @import("std");
const emacs = @import("emacs");
const abi = @import("abi.zig");
const loader_io = @import("io.zig");
const state = @import("state.zig");

const c = emacs.c;
export const plugin_is_GPL_compatible: c_int = 1;
const emacs_variadic_function: i32 = c.emacs_variadic_function;
var object_generations: ?c.emacs_value = null;

const LoaderManifestJson = struct {
    loader_abi: u32,
    module_path: []const u8,
};

fn signalValidationError(env: emacs.Env, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "dyn-loader: loader validation failed";
    env.signalError(msg);
}

pub fn validateGenericManifest(
    manifest: *const abi.GenericManifest,
    expected_loader_abi: u32,
) !void {
    if (manifest.loader_abi != expected_loader_abi) return error.LoaderAbiMismatch;

    const module_id = std.mem.span(manifest.module_id);
    if (module_id.len == 0) return error.MissingModuleId;

    const module_version = std.mem.span(manifest.module_version);
    if (module_version.len == 0) return error.MissingModuleVersion;

    const exports = manifest.exports[0..manifest.exports_len];
    for (exports, 0..) |descriptor, index| {
        switch (descriptor.kind) {
            @intFromEnum(abi.ExportKind.function), @intFromEnum(abi.ExportKind.variable) => {},
            else => return error.InvalidExportKind,
        }

        const lisp_name = std.mem.span(descriptor.lisp_name);
        if (lisp_name.len == 0) return error.MissingExportName;

        for (exports[index + 1 ..]) |other| {
            if (std.mem.eql(u8, lisp_name, std.mem.span(other.lisp_name))) {
                return error.DuplicateExportName;
            }
        }
    }
}

fn arityMatches(handle: *const state.FunctionHandle, descriptor: *const state.ExportState) bool {
    if (descriptor.min_arity > handle.min_arity) return false;

    if (handle.max_arity == emacs_variadic_function) {
        return descriptor.max_arity == emacs_variadic_function;
    }

    if (descriptor.max_arity == emacs_variadic_function) return true;
    return descriptor.max_arity >= handle.max_arity;
}

fn generationFunctionExport(
    generation: *const state.LiveModuleState,
    handle: *const state.FunctionHandle,
) ?*const state.ExportState {
    const descriptor = generation.exports_by_name.getPtr(handle.lisp_name) orelse return null;
    if (descriptor.kind != @intFromEnum(abi.ExportKind.function)) return null;
    if (!arityMatches(handle, descriptor)) return null;
    return descriptor;
}

fn signalDynamicExportError(env: emacs.Env, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "dyn-loader: stale or invalid function binding";
    env.signalError(msg);
}

fn forwardGenericExport(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const raw_binding = data orelse {
        env.signalError("dyn-loader: missing function handle");
        return env.nil();
    };
    const binding: *const state.FunctionHandle = @ptrCast(@alignCast(raw_binding));
    const args_slice: []const c.emacs_value = if (nargs == 0)
        &.{}
    else
        args[0..@intCast(nargs)];
    const choice = state.generationChoiceForArguments(
        env,
        binding.slot,
        object_generations orelse return env.nil(),
        args_slice,
    );
    const generation, const object_owned = switch (choice) {
        .current => .{ binding.slot.live_state orelse return env.nil(), false },
        .generation_id => |id| .{
            binding.slot.generationById(id) orelse return env.nil(),
            true,
        },
        .conflict => return env.nil(),
    };
    if (generation.status == .disabled) return env.nil();

    const descriptor = generationFunctionExport(generation, binding) orelse {
        if (object_owned) return env.nil();
        if (generation.exports_by_name.get(binding.lisp_name)) |current| {
            if (current.kind != @intFromEnum(abi.ExportKind.function)) {
                signalDynamicExportError(env, "dyn-loader: export '{s}' is no longer available", .{binding.lisp_name});
            } else {
                signalDynamicExportError(env, "dyn-loader: export '{s}' changed signature", .{binding.lisp_name});
            }
        } else {
            signalDynamicExportError(env, "dyn-loader: export '{s}' is no longer available", .{binding.lisp_name});
        }
        return env.nil();
    };
    const result = generation.generic_manifest.invoke(descriptor.export_id, raw_env, nargs, args, null);
    if (env.raw.non_local_exit_check.?(env.raw) == c.emacs_funcall_exit_return) {
        state.trackReturnedUserPointer(
            env,
            object_generations orelse return env.nil(),
            result,
            generation,
        );
    }
    return result;
}

fn clearInstalledTrampoline(env: emacs.Env, function_symbol: c.emacs_value) void {
    const cache_symbol = env.intern("comp-installed-trampolines-h");
    if (!env.isNotNil(env.f("boundp", .{cache_symbol}))) return;

    const cache = env.f("symbol-value", .{cache_symbol});
    if (!env.isNotNil(cache)) return;

    _ = env.f("remhash", .{ function_symbol, cache });
}

fn registerGenericFunction(env: emacs.Env, module: *state.ModuleSlot, descriptor: *const abi.ExportDescriptor) !void {
    const binding = try state.functionHandle(module, std.mem.span(descriptor.lisp_name), descriptor.min_arity, descriptor.max_arity);
    const name_symbol = env.intern(descriptor.lisp_name);
    clearInstalledTrampoline(env, name_symbol);
    const function = env.makeFunction(
        binding.min_arity,
        binding.max_arity,
        &forwardGenericExport,
        descriptor.docstring,
        @ptrCast(binding),
    );
    _ = env.f("fset", .{ name_symbol, function });
}

fn registerGenericVariable(env: emacs.Env, module: *state.ModuleSlot, descriptor: *const abi.ExportDescriptor) void {
    const live_state = module.live_state orelse unreachable;
    const value = live_state.generic_manifest.get_variable(descriptor.export_id, env.raw, null);
    _ = env.f("set", .{ env.intern(descriptor.lisp_name), value });
}

fn registerGenericExports(env: emacs.Env, module: *state.ModuleSlot) !void {
    const live_state = module.live_state orelse unreachable;
    for (live_state.generic_manifest.exports[0..live_state.generic_manifest.exports_len]) |*descriptor| {
        switch (descriptor.kind) {
            @intFromEnum(abi.ExportKind.function) => try registerGenericFunction(env, module, descriptor),
            @intFromEnum(abi.ExportKind.variable) => registerGenericVariable(env, module, descriptor),
            else => unreachable,
        }
    }
}

fn makeLoadedModulesValue(env: emacs.Env) c.emacs_value {
    var list = env.nil();
    const modules = state.moduleSlots();
    var index = modules.len;
    while (index > 0) {
        index -= 1;
        if (!modules[index].isLoaded()) continue;
        list = env.cons(env.makeString(modules[index].module_id), list);
    }
    return list;
}

fn updateLoadedModulesVariable(env: emacs.Env) void {
    _ = env.f(
        "set",
        .{ env.intern("dyn-loader-loaded-modules"), makeLoadedModulesValue(env) },
    );
}

fn readFileAllocPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = loader_io.get();
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn resolveTargetPathAlloc(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    module_path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(module_path)) {
        return try allocator.dupe(u8, module_path);
    }

    const manifest_dir = std.fs.path.dirname(manifest_path) orelse ".";
    return try std.fs.path.join(allocator, &.{ manifest_dir, module_path });
}

const ParsedLoaderManifest = struct {
    loader_abi: u32,
    target_path: []u8,
};

fn parseLoaderManifest(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
) !ParsedLoaderManifest {
    const text = try readFileAllocPath(allocator, manifest_path);
    defer allocator.free(text);

    const parsed = try std.json.parseFromSlice(LoaderManifestJson, allocator, text, .{});
    defer parsed.deinit();

    return .{
        .loader_abi = parsed.value.loader_abi,
        .target_path = try resolveTargetPathAlloc(allocator, manifest_path, parsed.value.module_path),
    };
}

fn loadManifest(env: emacs.Env, manifest_path: []const u8) ?*state.ModuleSlot {
    const alloc = state.moduleAllocator();
    const parsed = parseLoaderManifest(alloc, manifest_path) catch |err| {
        signalValidationError(env, "dyn-loader: failed to read loader manifest: {s}", .{@errorName(err)});
        return null;
    };
    defer alloc.free(parsed.target_path);

    var candidate = state.openCandidate(
        alloc,
        manifest_path,
        parsed.target_path,
        parsed.loader_abi,
    ) catch |err| {
        signalValidationError(env, "dyn-loader: failed to open target module: {s}", .{@errorName(err)});
        return null;
    };
    defer candidate.deinit(env.raw);

    validateGenericManifest(&candidate.generic_manifest, parsed.loader_abi) catch |err| {
        switch (err) {
            error.LoaderAbiMismatch => signalValidationError(env, "dyn-loader: loader ABI mismatch (expected {d}, got {d})", .{ parsed.loader_abi, candidate.generic_manifest.loader_abi }),
            error.DuplicateExportName => signalValidationError(env, "dyn-loader: target module published duplicate Lisp export names", .{}),
            error.InvalidExportKind => signalValidationError(env, "dyn-loader: target module published an unsupported export kind", .{}),
            error.MissingExportName => signalValidationError(env, "dyn-loader: target module published an export without a Lisp name", .{}),
            error.MissingModuleId => signalValidationError(env, "dyn-loader: target module did not publish a module id", .{}),
            error.MissingModuleVersion => signalValidationError(env, "dyn-loader: target module did not publish a version", .{}),
        }
        return null;
    };

    const module = state.installCandidate(&candidate, env.raw) catch |err| {
        signalValidationError(env, "dyn-loader: failed to install target module: {s}", .{@errorName(err)});
        return null;
    };
    registerGenericExports(env, module) catch |err| {
        signalValidationError(env, "dyn-loader: failed to register target exports: {s}", .{@errorName(err)});
        return null;
    };
    updateLoadedModulesVariable(env);
    return module;
}

fn fnLoaderLoadManifest(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = env.extractString(args[0], &path_buf) catch {
        env.signalError("dyn-loader: invalid loader manifest path");
        return env.nil();
    };
    const module = loadManifest(env, manifest_path) orelse return env.nil();
    return env.makeString(module.module_id);
}

fn fnLoaderReload(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);

    var module_id_buf: [256]u8 = undefined;
    const module_id = env.extractString(args[0], &module_id_buf) catch {
        env.signalError("dyn-loader: invalid module id");
        return env.nil();
    };
    const module = state.moduleForId(module_id) orelse {
        signalValidationError(env, "dyn-loader: unknown module id: {s}", .{module_id});
        return env.nil();
    };
    _ = loadManifest(env, module.manifest_path) orelse return env.nil();
    return env.t();
}

fn fnLoaderUnload(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);

    var module_id_buf: [256]u8 = undefined;
    const module_id = env.extractString(args[0], &module_id_buf) catch {
        env.signalError("dyn-loader: invalid module id");
        return env.nil();
    };
    const module = state.moduleForId(module_id) orelse {
        signalValidationError(env, "dyn-loader: module id is not loaded: {s}", .{module_id});
        return env.nil();
    };

    module.unload(env.raw) catch |err| {
        signalValidationError(env, "dyn-loader: failed to unload module: {s}", .{@errorName(err)});
        return env.nil();
    };
    updateLoadedModulesVariable(env);
    return env.t();
}

fn fnLoaderCleanupRetiredFiles(raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    return env.makeInteger(@intCast(state.cleanupRetiredLoadPaths()));
}

export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) return 1;

    const raw_env = runtime.get_environment.?(runtime);
    const env = emacs.Env.init(raw_env);
    if (object_generations == null) {
        object_generations = env.makeGlobalRef(env.f(
            "make-hash-table",
            .{
                env.intern(":test"),
                env.intern("eq"),
                env.intern(":weakness"),
                env.intern("key"),
            },
        ));
    }

    env.bindFunction(
        "dyn-loader-load-manifest",
        1,
        1,
        &fnLoaderLoadManifest,
        "Load or reload a target module from MANIFEST-PATH.\n\n(dyn-loader-load-manifest MANIFEST-PATH)",
    );
    env.bindFunction(
        "dyn-loader-reload",
        1,
        1,
        &fnLoaderReload,
        "Reload a previously loaded module by MODULE-ID.\n\n(dyn-loader-reload MODULE-ID)",
    );
    env.bindFunction(
        "dyn-loader-unload",
        1,
        1,
        &fnLoaderUnload,
        "Unload a previously loaded module by MODULE-ID.\n\n(dyn-loader-unload MODULE-ID)",
    );
    env.bindFunction(
        "dyn-loader-cleanup-retired-files",
        0,
        0,
        &fnLoaderCleanupRetiredFiles,
        "Retry cleanup of retired dyn-loader shadow files.\n\n(dyn-loader-cleanup-retired-files)",
    );
    _ = env.f(
        "add-hook",
        .{ env.intern("kill-emacs-hook"), env.intern("dyn-loader-cleanup-retired-files") },
    );
    emacs.initSymbols(env);
    env.provide("dyn-loader-module");
    return 0;
}

test "validateGenericManifest accepts function exports" {
    const exports = [_]abi.ExportDescriptor{
        .{
            .export_id = 1,
            .kind = @intFromEnum(abi.ExportKind.function),
            .lisp_name = "sample--ping",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Ping sample module.",
            .flags = 0,
        },
    };
    const manifest = abi.GenericManifest{
        .loader_abi = abi.LoaderAbiVersion,
        .module_id = "sample-module",
        .module_version = "1.0",
        .exports_len = exports.len,
        .exports = exports[0..].ptr,
        .invoke = undefined,
        .get_variable = undefined,
        .set_variable = undefined,
    };
    try validateGenericManifest(&manifest, abi.LoaderAbiVersion);
}

test "validateGenericManifest rejects missing module id" {
    const exports = [_]abi.ExportDescriptor{
        .{
            .export_id = 1,
            .kind = @intFromEnum(abi.ExportKind.function),
            .lisp_name = "sample--ping",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Ping sample module.",
            .flags = 0,
        },
    };
    const manifest = abi.GenericManifest{
        .loader_abi = abi.LoaderAbiVersion,
        .module_id = "",
        .module_version = "1.0",
        .exports_len = exports.len,
        .exports = exports[0..].ptr,
        .invoke = undefined,
        .get_variable = undefined,
        .set_variable = undefined,
    };
    try std.testing.expectError(error.MissingModuleId, validateGenericManifest(&manifest, abi.LoaderAbiVersion));
}

test "validateGenericManifest rejects unknown export kinds" {
    const exports = [_]abi.ExportDescriptor{
        .{
            .export_id = 1,
            .kind = 99,
            .lisp_name = "sample--broken",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Broken export.",
            .flags = 0,
        },
    };
    const manifest = abi.GenericManifest{
        .loader_abi = abi.LoaderAbiVersion,
        .module_id = "sample-module",
        .module_version = "1.0",
        .exports_len = exports.len,
        .exports = exports[0..].ptr,
        .invoke = undefined,
        .get_variable = undefined,
        .set_variable = undefined,
    };
    try std.testing.expectError(error.InvalidExportKind, validateGenericManifest(&manifest, abi.LoaderAbiVersion));
}

test "validateGenericManifest rejects duplicate export names" {
    const exports = [_]abi.ExportDescriptor{
        .{
            .export_id = 1,
            .kind = @intFromEnum(abi.ExportKind.function),
            .lisp_name = "sample--ping",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Ping sample module.",
            .flags = 0,
        },
        .{
            .export_id = 2,
            .kind = @intFromEnum(abi.ExportKind.variable),
            .lisp_name = "sample--ping",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Conflicting export.",
            .flags = 0,
        },
    };
    const manifest = abi.GenericManifest{
        .loader_abi = abi.LoaderAbiVersion,
        .module_id = "sample-module",
        .module_version = "1.0",
        .exports_len = exports.len,
        .exports = exports[0..].ptr,
        .invoke = undefined,
        .get_variable = undefined,
        .set_variable = undefined,
    };

    try std.testing.expectError(error.DuplicateExportName, validateGenericManifest(&manifest, abi.LoaderAbiVersion));
}

test "arityMatches requires the current export to cover the captured contract" {
    var slot = state.ModuleSlot{
        .allocator = std.testing.allocator,
        .module_id = &[_]u8{},
        .manifest_path = &[_]u8{},
    };

    const fixed_handle = state.FunctionHandle{
        .slot = &slot,
        .lisp_name = &[_]u8{},
        .min_arity = 1,
        .max_arity = 3,
    };
    const variadic_handle = state.FunctionHandle{
        .slot = &slot,
        .lisp_name = &[_]u8{},
        .min_arity = 2,
        .max_arity = emacs_variadic_function,
    };

    try std.testing.expect(arityMatches(&fixed_handle, &.{ .export_id = 1, .kind = @intFromEnum(abi.ExportKind.function), .min_arity = 0, .max_arity = 3 }));
    try std.testing.expect(arityMatches(&fixed_handle, &.{ .export_id = 2, .kind = @intFromEnum(abi.ExportKind.function), .min_arity = 1, .max_arity = emacs_variadic_function }));
    try std.testing.expect(!arityMatches(&fixed_handle, &.{ .export_id = 3, .kind = @intFromEnum(abi.ExportKind.function), .min_arity = 2, .max_arity = 3 }));
    try std.testing.expect(!arityMatches(&fixed_handle, &.{ .export_id = 4, .kind = @intFromEnum(abi.ExportKind.function), .min_arity = 0, .max_arity = 2 }));
    try std.testing.expect(arityMatches(&variadic_handle, &.{ .export_id = 5, .kind = @intFromEnum(abi.ExportKind.function), .min_arity = 1, .max_arity = emacs_variadic_function }));
    try std.testing.expect(!arityMatches(&variadic_handle, &.{ .export_id = 6, .kind = @intFromEnum(abi.ExportKind.function), .min_arity = 1, .max_arity = 4 }));
}

test "loader manifest json uses module_path" {
    const parsed = try std.json.parseFromSlice(
        LoaderManifestJson,
        std.testing.allocator,
        "{\"loader_abi\":1,\"module_path\":\"fixtures/sample-module\"}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.loader_abi);
    try std.testing.expectEqualStrings("fixtures/sample-module", parsed.value.module_path);
}

test "loader registers retired shadow cleanup hook" {
    const source = @embedFile("module.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "dyn-loader-cleanup-retired-files") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "state.cleanupRetiredLoadPaths()") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "kill-emacs-hook") != null);
}
