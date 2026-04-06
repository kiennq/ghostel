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
    loader_abi: u32,

    pub fn deinit(self: *CandidateModule) void {
        if (self.library) |*library| library.close();
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.target_path);
        self.library = null;
        self.manifest_path = &[_]u8{};
        self.target_path = &[_]u8{};
    }
};

pub const ModuleRecord = struct {
    allocator: std.mem.Allocator,
    module_id: []u8,
    manifest_path: []u8,
    target_path: []u8,
    loader_abi: u32,
    library: ?dynlib.Library,
    generic_manifest: abi.GenericManifest,
    bindings: std.ArrayListUnmanaged(*ExportBinding) = .{},

    fn replace(self: *ModuleRecord, candidate: *CandidateModule) void {
        if (self.library) |*library| library.close();
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.target_path);

        self.manifest_path = candidate.manifest_path;
        self.target_path = candidate.target_path;
        self.loader_abi = candidate.loader_abi;
        self.library = candidate.library;
        self.generic_manifest = candidate.generic_manifest;

        candidate.manifest_path = &[_]u8{};
        candidate.target_path = &[_]u8{};
        candidate.library = null;
    }

    fn deinit(self: *ModuleRecord) void {
        if (self.library) |*library| library.close();
        self.allocator.free(self.module_id);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.target_path);
        for (self.bindings.items) |binding| self.allocator.destroy(binding);
        self.bindings.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

var loaded_modules: std.StringHashMapUnmanaged(*ModuleRecord) = .{};
var loaded_module_order: std.ArrayListUnmanaged(*ModuleRecord) = .{};
var registry_allocator: ?std.mem.Allocator = null;

pub fn openCandidate(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    target_path: []const u8,
    loader_abi: u32,
) !CandidateModule {
    var library = try dynlib.Library.open(allocator, target_path);
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
        .loader_abi = candidate.loader_abi,
        .library = candidate.library,
        .generic_manifest = candidate.generic_manifest,
    };
    candidate.manifest_path = &[_]u8{};
    candidate.target_path = &[_]u8{};
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
