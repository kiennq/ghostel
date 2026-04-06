const builtin = @import("builtin");
const std = @import("std");
const abi = @import("abi.zig");
const dynlib = @import("dynlib.zig");

pub const ExportBinding = struct {
    module: *ModuleRecord,
    export_id: u32,
};

pub const CandidateModule = struct {
    allocator: std.mem.Allocator,
    library: ?dynlib.Library,
    generic_manifest: abi.GenericManifest,
    manifest_path: []u8,
    target_path: []u8,
    load_path: []u8,
    loader_abi: u32,

    pub fn deinit(self: *CandidateModule) void {
        if (self.library) |*library| library.close();
        cleanupLoadPath(self.load_path, self.target_path);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.target_path);
        self.allocator.free(self.load_path);
        self.library = null;
        self.manifest_path = &[_]u8{};
        self.target_path = &[_]u8{};
        self.load_path = &[_]u8{};
    }
};

pub const ModuleRecord = struct {
    allocator: std.mem.Allocator,
    module_id: []u8,
    manifest_path: []u8,
    target_path: []u8,
    load_path: []u8,
    loader_abi: u32,
    library: ?dynlib.Library,
    generic_manifest: abi.GenericManifest,
    bindings: std.ArrayListUnmanaged(*ExportBinding) = .{},

    fn replace(self: *ModuleRecord, candidate: *CandidateModule) void {
        if (self.library) |*library| library.close();
        cleanupLoadPath(self.load_path, self.target_path);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.target_path);
        self.allocator.free(self.load_path);

        self.manifest_path = candidate.manifest_path;
        self.target_path = candidate.target_path;
        self.load_path = candidate.load_path;
        self.loader_abi = candidate.loader_abi;
        self.library = candidate.library;
        self.generic_manifest = candidate.generic_manifest;

        candidate.manifest_path = &[_]u8{};
        candidate.target_path = &[_]u8{};
        candidate.load_path = &[_]u8{};
        candidate.library = null;
    }

    fn deinit(self: *ModuleRecord) void {
        if (self.library) |*library| library.close();
        cleanupLoadPath(self.load_path, self.target_path);
        self.allocator.free(self.module_id);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.target_path);
        self.allocator.free(self.load_path);
        for (self.bindings.items) |binding| self.allocator.destroy(binding);
        self.bindings.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

var loaded_modules: std.StringHashMapUnmanaged(*ModuleRecord) = .{};
var loaded_module_order: std.ArrayListUnmanaged(*ModuleRecord) = .{};
var registry_allocator: ?std.mem.Allocator = null;

fn cleanupLoadPath(load_path: []const u8, target_path: []const u8) void {
    if (load_path.len == 0 or std.mem.eql(u8, load_path, target_path)) return;
    if (std.fs.path.isAbsolute(load_path))
        std.fs.deleteFileAbsolute(load_path) catch {}
    else
        std.fs.cwd().deleteFile(load_path) catch {};
}

fn copyShadowSource(target_path: []const u8, shadow_path: []const u8) !void {
    if (std.fs.path.isAbsolute(target_path) and std.fs.path.isAbsolute(shadow_path)) {
        try std.fs.copyFileAbsolute(target_path, shadow_path, .{});
        return;
    }
    if (!std.fs.path.isAbsolute(target_path) and !std.fs.path.isAbsolute(shadow_path)) {
        try std.fs.cwd().copyFile(target_path, std.fs.cwd(), shadow_path, .{});
        return;
    }
    return error.MixedPathKind;
}

fn createShadowCopyPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(target_path) orelse ".";
    const base = std.fs.path.basename(target_path);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];

    while (true) {
        const name = try std.fmt.allocPrint(
            allocator,
            ".{s}.load.{x}{s}",
            .{ stem, std.crypto.random.int(u64), ext },
        );
        defer allocator.free(name);

        const shadow_path = try std.fs.path.join(allocator, &.{ dir, name });
        errdefer allocator.free(shadow_path);

        copyShadowSource(target_path, shadow_path) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return shadow_path;
    }
}

pub fn openCandidate(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    target_path: []const u8,
    loader_abi: u32,
) !CandidateModule {
    const load_path = try createShadowCopyPath(allocator, target_path);
    errdefer allocator.free(load_path);
    errdefer cleanupLoadPath(load_path, target_path);

    var library = try dynlib.Library.open(allocator, load_path);
    errdefer library.close();

    const generic_init_fn = try library.lookup(abi.GenericLoaderModuleInitFn, "loader_module_init_generic");
    var generic_manifest = std.mem.zeroes(abi.GenericManifest);
    generic_init_fn(&generic_manifest);

    return .{
        .allocator = allocator,
        .library = library,
        .generic_manifest = generic_manifest,
        .manifest_path = try allocator.dupe(u8, manifest_path),
        .target_path = try allocator.dupe(u8, target_path),
        .load_path = load_path,
        .loader_abi = loader_abi,
    };
}

pub fn installCandidate(candidate: *CandidateModule) !*ModuleRecord {
    if (registry_allocator == null) registry_allocator = candidate.allocator;

    const module_id = std.mem.span(candidate.generic_manifest.module_id);
    if (loaded_modules.get(module_id)) |module| {
        module.replace(candidate);
        return module;
    }

    const module = try candidate.allocator.create(ModuleRecord);
    errdefer candidate.allocator.destroy(module);

    module.* = .{
        .allocator = candidate.allocator,
        .module_id = try candidate.allocator.dupe(u8, module_id),
        .manifest_path = candidate.manifest_path,
        .target_path = candidate.target_path,
        .load_path = candidate.load_path,
        .loader_abi = candidate.loader_abi,
        .library = candidate.library,
        .generic_manifest = candidate.generic_manifest,
    };
    candidate.manifest_path = &[_]u8{};
    candidate.target_path = &[_]u8{};
    candidate.load_path = &[_]u8{};
    candidate.library = null;

    try loaded_modules.put(candidate.allocator, module.module_id, module);
    try loaded_module_order.append(candidate.allocator, module);
    return module;
}

pub fn moduleForId(module_id: []const u8) ?*ModuleRecord {
    return loaded_modules.get(module_id);
}

pub fn loadedModules() []const *ModuleRecord {
    return loaded_module_order.items;
}

pub fn exportBinding(module: *ModuleRecord, export_id: u32) !*ExportBinding {
    for (module.bindings.items) |binding| {
        if (binding.export_id == export_id) return binding;
    }

    const binding = try module.allocator.create(ExportBinding);
    binding.* = .{
        .module = module,
        .export_id = export_id,
    };
    try module.bindings.append(module.allocator, binding);
    return binding;
}

pub fn reset() void {
    for (loaded_module_order.items) |module| module.deinit();
    const allocator = registry_allocator orelse std.heap.c_allocator;
    loaded_modules.deinit(allocator);
    loaded_module_order.deinit(allocator);
    loaded_modules = .{};
    loaded_module_order = .{};
    registry_allocator = null;
}

fn testDynlibExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}

fn testBuildReloadFixture(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    version: []const u8,
) !void {
    const source_path = try std.fmt.allocPrint(allocator, "{s}.zig", .{output_path});
    defer allocator.free(source_path);
    const source = try std.fmt.allocPrint(
        allocator,
        \\const GenericManifest = extern struct {{
        \\    loader_abi: u32,
        \\    module_id: [*:0]const u8,
        \\    module_version: [*:0]const u8,
        \\    exports_len: u32,
        \\    exports: ?*const anyopaque,
        \\    invoke: ?*const anyopaque,
        \\    get_variable: ?*const anyopaque,
        \\    set_variable: ?*const anyopaque,
        \\}};
        \\
        \\export fn loader_module_init_generic(manifest: *GenericManifest) callconv(.c) void {{
        \\    manifest.* = .{{
        \\        .loader_abi = 1,
        \\        .module_id = "sample-module",
        \\        .module_version = "{s}",
        \\        .exports_len = 0,
        \\        .exports = null,
        \\        .invoke = null,
        \\        .get_variable = null,
        \\        .set_variable = null,
        \\    }};
        \\}}
        \\
    , .{version});
    defer allocator.free(source);

    const source_file = try std.fs.createFileAbsolute(source_path, .{ .truncate = true });
    defer source_file.close();
    try source_file.writeAll(source);

    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{output_path});
    defer allocator.free(emit_arg);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build-lib", "-dynamic", "-O", "ReleaseSafe", source_path, emit_arg },
        .max_output_bytes = 32 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("zig build-lib failed for {s}: {s}\n", .{ output_path, result.stderr });
        return error.ZigBuildFailed;
    }
}

test "installCandidate stores module by module id" {
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
    var candidate = CandidateModule{
        .allocator = std.testing.allocator,
        .library = null,
        .generic_manifest = .{
            .loader_abi = abi.LoaderAbiVersion,
            .module_id = "sample-module",
            .module_version = "1.0",
            .exports_len = exports.len,
            .exports = exports[0..].ptr,
            .invoke = undefined,
            .get_variable = undefined,
            .set_variable = undefined,
        },
        .manifest_path = try std.testing.allocator.dupe(u8, "C:/ghostel/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module.dll"),
        .load_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module.dll.load"),
        .loader_abi = 1,
    };
    defer reset();

    const module = try installCandidate(&candidate);

    try std.testing.expectEqualStrings("sample-module", module.module_id);
    try std.testing.expectEqualStrings("C:/ghostel/ghostel-module.json", module.manifest_path);
    try std.testing.expectEqualStrings("C:/ghostel/sample-module.dll", module.target_path);
    try std.testing.expectEqual(module, moduleForId("sample-module").?);
}

test "installCandidate replaces existing module state for reload" {
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
    var first = CandidateModule{
        .allocator = std.testing.allocator,
        .library = null,
        .generic_manifest = .{
            .loader_abi = abi.LoaderAbiVersion,
            .module_id = "sample-module",
            .module_version = "1.0",
            .exports_len = exports.len,
            .exports = exports[0..].ptr,
            .invoke = undefined,
            .get_variable = undefined,
            .set_variable = undefined,
        },
        .manifest_path = try std.testing.allocator.dupe(u8, "C:/ghostel/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module.dll"),
        .load_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module.dll.load"),
        .loader_abi = 1,
    };
    defer reset();
    const module = try installCandidate(&first);

    var second = CandidateModule{
        .allocator = std.testing.allocator,
        .library = null,
        .generic_manifest = .{
            .loader_abi = abi.LoaderAbiVersion,
            .module_id = "sample-module",
            .module_version = "1.1",
            .exports_len = exports.len,
            .exports = exports[0..].ptr,
            .invoke = undefined,
            .get_variable = undefined,
            .set_variable = undefined,
        },
        .manifest_path = try std.testing.allocator.dupe(u8, "C:/ghostel/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module-next.dll"),
        .load_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module-next.dll.load"),
        .loader_abi = 1,
    };
    const reloaded = try installCandidate(&second);

    try std.testing.expectEqual(module, reloaded);
    try std.testing.expectEqualStrings("C:/ghostel/sample-module-next.dll", reloaded.target_path);
    try std.testing.expectEqualStrings("1.1", std.mem.span(reloaded.generic_manifest.module_version));
}

test "exportBinding reuses stable callback data for the same export id" {
    const exports = [_]abi.ExportDescriptor{
        .{
            .export_id = 7,
            .kind = @intFromEnum(abi.ExportKind.function),
            .lisp_name = "sample--ping",
            .min_arity = 0,
            .max_arity = 0,
            .docstring = "Ping sample module.",
            .flags = 0,
        },
    };
    var candidate = CandidateModule{
        .allocator = std.testing.allocator,
        .library = null,
        .generic_manifest = .{
            .loader_abi = abi.LoaderAbiVersion,
            .module_id = "sample-module",
            .module_version = "1.0",
            .exports_len = exports.len,
            .exports = exports[0..].ptr,
            .invoke = undefined,
            .get_variable = undefined,
            .set_variable = undefined,
        },
        .manifest_path = try std.testing.allocator.dupe(u8, "C:/ghostel/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module.dll"),
        .load_path = try std.testing.allocator.dupe(u8, "C:/ghostel/sample-module.dll.load"),
        .loader_abi = 1,
    };
    defer reset();

    const module = try installCandidate(&candidate);
    const first = try exportBinding(module, 7);
    const second = try exportBinding(module, 7);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, 7), first.export_id);
    try std.testing.expectEqual(module, first.module);
}

test "openCandidate sees updated module contents when target path is replaced" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    defer reset();

    const first_output = try std.fmt.allocPrint(allocator, "{s}/sample-v1{s}", .{ dir_path, testDynlibExtension() });
    defer allocator.free(first_output);
    const second_output = try std.fmt.allocPrint(allocator, "{s}/sample-v2{s}", .{ dir_path, testDynlibExtension() });
    defer allocator.free(second_output);
    const live_output = try std.fmt.allocPrint(allocator, "{s}/sample-live{s}", .{ dir_path, testDynlibExtension() });
    defer allocator.free(live_output);

    try testBuildReloadFixture(allocator, first_output, "1.0");
    try testBuildReloadFixture(allocator, second_output, "2.0");
    try std.fs.copyFileAbsolute(first_output, live_output, .{});

    var first = try openCandidate(allocator, "sample-module.json", live_output, abi.LoaderAbiVersion);
    const installed = try installCandidate(&first);
    try std.testing.expectEqualStrings("1.0", std.mem.span(installed.generic_manifest.module_version));

    tmp_dir.dir.deleteFile("sample-live.old") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    tmp_dir.dir.rename(std.fs.path.basename(live_output), "sample-live.old") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.copyFileAbsolute(second_output, live_output, .{});

    var reloaded = try openCandidate(allocator, "sample-module.json", live_output, abi.LoaderAbiVersion);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("2.0", std.mem.span(reloaded.generic_manifest.module_version));
}
