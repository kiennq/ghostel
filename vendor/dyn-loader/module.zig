const std = @import("std");
const emacs = @import("emacs");
const abi = @import("abi.zig");
const state = @import("state.zig");

const c = emacs.c;
export const plugin_is_GPL_compatible: c_int = 1;

const LoaderManifestJson = struct {
    loader_abi: u32,
    module_path: []const u8,
};

fn signalValidationError(env: emacs.Env, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "ghostel: loader validation failed";
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
    for (exports) |descriptor| {
        switch (descriptor.kind) {
            @intFromEnum(abi.ExportKind.function), @intFromEnum(abi.ExportKind.variable) => {},
            else => return error.InvalidExportKind,
        }

        const lisp_name = std.mem.span(descriptor.lisp_name);
        if (lisp_name.len == 0) return error.MissingExportName;
    }
}

fn forwardGenericExport(raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const raw_binding = data orelse {
        env.signalError("ghostel: missing export binding");
        return env.nil();
    };
    const binding: *const state.ExportBinding = @ptrCast(@alignCast(raw_binding));
    return binding.module.generic_manifest.invoke(binding.export_id, raw_env, nargs, args, null);
}

fn clearInstalledTrampoline(env: emacs.Env, function_symbol: c.emacs_value) void {
    const cache_symbol = env.intern("comp-installed-trampolines-h");
    if (!env.isNotNil(env.call1(env.intern("boundp"), cache_symbol))) return;

    const cache = env.call1(emacs.sym.@"symbol-value", cache_symbol);
    if (!env.isNotNil(cache)) return;

    _ = env.call2(env.intern("remhash"), function_symbol, cache);
}

fn registerGenericFunction(env: emacs.Env, module: *state.ModuleRecord, descriptor: *const abi.ExportDescriptor) !void {
    const binding = try state.exportBinding(module, descriptor.export_id);
    const name_symbol = env.intern(descriptor.lisp_name);
    clearInstalledTrampoline(env, name_symbol);
    const function = env.makeFunction(
        descriptor.min_arity,
        descriptor.max_arity,
        &forwardGenericExport,
        descriptor.docstring,
        @ptrCast(binding),
    );
    _ = env.call2(env.intern("fset"), name_symbol, function);
}

fn registerGenericVariable(env: emacs.Env, module: *state.ModuleRecord, descriptor: *const abi.ExportDescriptor) void {
    const value = module.generic_manifest.get_variable(descriptor.export_id, env.raw, null);
    _ = env.call2(env.intern("set"), env.intern(descriptor.lisp_name), value);
}

fn registerGenericExports(env: emacs.Env, module: *state.ModuleRecord) !void {
    for (module.generic_manifest.exports[0..module.generic_manifest.exports_len]) |*descriptor| {
        switch (descriptor.kind) {
            @intFromEnum(abi.ExportKind.function) => try registerGenericFunction(env, module, descriptor),
            @intFromEnum(abi.ExportKind.variable) => registerGenericVariable(env, module, descriptor),
            else => unreachable,
        }
    }
}

fn makeLoadedModulesValue(env: emacs.Env) c.emacs_value {
    var list = env.nil();
    const modules = state.loadedModules();
    var index = modules.len;
    while (index > 0) {
        index -= 1;
        list = env.call2(env.intern("cons"), env.makeString(modules[index].module_id), list);
    }
    return list;
}

fn updateLoadedModulesVariable(env: emacs.Env) void {
    _ = env.call2(
        env.intern("set"),
        env.intern("dyn-loader-loaded-modules"),
        makeLoadedModulesValue(env),
    );
}

fn readFileAllocPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
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

fn loadManifest(env: emacs.Env, manifest_path: []const u8) ?*state.ModuleRecord {
    const parsed = parseLoaderManifest(std.heap.c_allocator, manifest_path) catch |err| {
        signalValidationError(env, "ghostel: failed to read loader manifest: {s}", .{@errorName(err)});
        return null;
    };
    defer std.heap.c_allocator.free(parsed.target_path);

    var candidate = state.openCandidate(
        std.heap.c_allocator,
        manifest_path,
        parsed.target_path,
        parsed.loader_abi,
    ) catch |err| {
        signalValidationError(env, "ghostel: failed to open target module: {s}", .{@errorName(err)});
        return null;
    };
    defer candidate.deinit();

    validateGenericManifest(&candidate.generic_manifest, parsed.loader_abi) catch |err| {
        switch (err) {
            error.LoaderAbiMismatch => signalValidationError(env, "ghostel: loader ABI mismatch (expected {d}, got {d})", .{ parsed.loader_abi, candidate.generic_manifest.loader_abi }),
            error.InvalidExportKind => signalValidationError(env, "ghostel: target module published an unsupported export kind", .{}),
            error.MissingExportName => signalValidationError(env, "ghostel: target module published an export without a Lisp name", .{}),
            error.MissingModuleId => signalValidationError(env, "ghostel: target module did not publish a module id", .{}),
            error.MissingModuleVersion => signalValidationError(env, "ghostel: target module did not publish a version", .{}),
        }
        return null;
    };

    const module = state.installCandidate(&candidate) catch |err| {
        signalValidationError(env, "ghostel: failed to install target module: {s}", .{@errorName(err)});
        return null;
    };
    registerGenericExports(env, module) catch |err| {
        signalValidationError(env, "ghostel: failed to register target exports: {s}", .{@errorName(err)});
        return null;
    };
    updateLoadedModulesVariable(env);
    return module;
}

fn fnLoaderLoadManifest(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const manifest_path = env.extractString(args[0], &path_buf) orelse {
        env.signalError("ghostel: invalid loader manifest path");
        return env.nil();
    };
    const module = loadManifest(env, manifest_path) orelse return env.nil();
    return env.makeString(module.module_id);
}

fn fnLoaderReload(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);

    var module_id_buf: [256]u8 = undefined;
    const module_id = env.extractString(args[0], &module_id_buf) orelse {
        env.signalError("ghostel: invalid module id");
        return env.nil();
    };
    const module = state.moduleForId(module_id) orelse {
        signalValidationError(env, "ghostel: module id is not loaded: {s}", .{module_id});
        return env.nil();
    };
    _ = loadManifest(env, module.manifest_path) orelse return env.nil();
    return env.t();
}

export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) return 1;

    const raw_env = runtime.get_environment.?(runtime);
    const env = emacs.Env.init(raw_env);

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

test "loader manifest json uses module_path" {
    const parsed = try std.json.parseFromSlice(
        LoaderManifestJson,
        std.testing.allocator,
        "{\"loader_abi\":1,\"module_path\":\"ghostel-module.dll\"}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.loader_abi);
    try std.testing.expectEqualStrings("ghostel-module.dll", parsed.value.module_path);
}
