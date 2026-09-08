const builtin = @import("builtin");
const std = @import("std");
const abi = @import("abi.zig");
const dynlib = @import("dynlib.zig");
const emacs = @import("emacs");
const loader_io = @import("io.zig");

pub const ExportState = struct {
    export_id: u32,
    kind: u32,
    min_arity: i32,
    max_arity: i32,
};

pub const FunctionHandle = struct {
    slot: *ModuleSlot,
    lisp_name: []u8,
    min_arity: i32,
    max_arity: i32,

    fn deinit(self: *FunctionHandle) void {
        self.slot.allocator.free(self.lisp_name);
        self.slot.allocator.destroy(self);
    }
};

pub const GenerationStatus = enum {
    active,
    retired,
    disabled,
};

fn cleanupStaleShadowCopies(allocator: std.mem.Allocator, target_path: []const u8) void {
    const io = loader_io.get();
    const dir_path = std.fs.path.dirname(target_path) orelse ".";
    const base = std.fs.path.basename(target_path);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    const prefix = std.fmt.allocPrint(allocator, ".{s}.load.", .{stem}) catch return;
    defer allocator.free(prefix);

    var dir = if (std.fs.path.isAbsolute(dir_path))
        std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        dir.deleteFile(io, entry.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return,
        };
    }
}

fn deleteLoadPath(load_path: []const u8) bool {
    const io = loader_io.get();
    if (std.fs.path.isAbsolute(load_path)) {
        std.Io.Dir.deleteFileAbsolute(io, load_path) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return false,
        };
    } else {
        std.Io.Dir.cwd().deleteFile(io, load_path) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return false,
        };
    }
    return true;
}

pub const CandidateModule = struct {
    allocator: std.mem.Allocator,
    library: ?dynlib.Library,
    generic_manifest: abi.GenericManifest,
    cleanup: ?abi.CleanupFn,
    manifest_path: []u8,
    target_path: []u8,
    load_path: []u8,
    loader_abi: u32,

    pub fn deinit(self: *CandidateModule, raw_env: ?*emacs.c.emacs_env) void {
        if (self.cleanup) |cleanup| cleanup(raw_env);
        if (self.library) |*library| library.close();
        _ = cleanupLoadPath(self.load_path, self.target_path);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.target_path);
        self.allocator.free(self.load_path);
        self.library = null;
        self.cleanup = null;
        self.manifest_path = &[_]u8{};
        self.target_path = &[_]u8{};
        self.load_path = &[_]u8{};
    }
};

pub const LiveModuleState = struct {
    id: u64,
    status: GenerationStatus,
    target_path: []u8,
    load_path: []u8,
    loader_abi: u32,
    library: ?dynlib.Library,
    generic_manifest: abi.GenericManifest,
    cleanup: ?abi.CleanupFn,
    exports_by_name: std.StringHashMapUnmanaged(ExportState) = .{},

    fn create(
        allocator: std.mem.Allocator,
        candidate: *CandidateModule,
        id: u64,
    ) !*LiveModuleState {
        const live_state = try allocator.create(LiveModuleState);
        errdefer allocator.destroy(live_state);

        live_state.* = .{
            .id = id,
            .status = .active,
            .target_path = candidate.target_path,
            .load_path = candidate.load_path,
            .loader_abi = candidate.loader_abi,
            .library = candidate.library,
            .generic_manifest = candidate.generic_manifest,
            .cleanup = candidate.cleanup,
        };
        candidate.target_path = &[_]u8{};
        candidate.load_path = &[_]u8{};
        candidate.library = null;
        candidate.cleanup = null;

        errdefer live_state.deinit(allocator, null);
        try live_state.rebuildExportsByName(allocator);
        return live_state;
    }

    fn rebuildExportsByName(self: *LiveModuleState, allocator: std.mem.Allocator) !void {
        for (self.generic_manifest.exports[0..self.generic_manifest.exports_len]) |descriptor| {
            const lisp_name = std.mem.span(descriptor.lisp_name);
            const owned_name = try allocator.dupe(u8, lisp_name);
            errdefer allocator.free(owned_name);

            const entry = try self.exports_by_name.getOrPut(allocator, owned_name);
            if (entry.found_existing) allocator.free(owned_name);
            entry.value_ptr.* = .{
                .export_id = descriptor.export_id,
                .kind = descriptor.kind,
                .min_arity = descriptor.min_arity,
                .max_arity = descriptor.max_arity,
            };
        }
    }

    fn deinit(self: *LiveModuleState, allocator: std.mem.Allocator, raw_env: ?*emacs.c.emacs_env) void {
        if (self.cleanup) |cleanup| cleanup(raw_env);
        if (self.library) |*library| library.close();
        _ = cleanupLoadPath(self.load_path, self.target_path);
        self.deinitExportsByName(allocator);
        allocator.free(self.target_path);
        if (self.load_path.len != 0) allocator.free(self.load_path);
        allocator.destroy(self);
    }

    fn deinitExportsByName(self: *LiveModuleState, allocator: std.mem.Allocator) void {
        var iterator = self.exports_by_name.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        self.exports_by_name.deinit(allocator);
        self.exports_by_name = .{};
    }

    fn cleanupLoadFile(self: *LiveModuleState, allocator: std.mem.Allocator) bool {
        if (self.load_path.len == 0) return false;
        if (!cleanupLoadPath(self.load_path, self.target_path)) return false;
        allocator.free(self.load_path);
        self.load_path = &[_]u8{};
        return true;
    }
};

pub const ModuleSlot = struct {
    allocator: std.mem.Allocator,
    module_id: []u8,
    manifest_path: []u8,
    live_state: ?*LiveModuleState = null,
    retired_states: std.ArrayListUnmanaged(*LiveModuleState) = .empty,
    bindings: std.ArrayListUnmanaged(*FunctionHandle) = .empty,

    pub fn isLoaded(self: *const ModuleSlot) bool {
        return self.live_state != null;
    }

    pub fn unload(self: *ModuleSlot, _: ?*emacs.c.emacs_env) !void {
        for (self.retired_states.items) |generation| {
            generation.status = .disabled;
        }

        if (self.live_state) |live_state| {
            try self.retired_states.append(self.allocator, live_state);
            live_state.status = .disabled;
            self.live_state = null;
        }
    }

    fn replace(self: *ModuleSlot, candidate: *CandidateModule, raw_env: ?*emacs.c.emacs_env) !void {
        _ = raw_env;
        const next_live_state = try LiveModuleState.create(
            self.allocator,
            candidate,
            nextGenerationId(),
        );
        errdefer next_live_state.deinit(self.allocator, null);

        if (self.live_state) |live_state| {
            try self.retired_states.append(self.allocator, live_state);
            live_state.status = .retired;
        }
        self.live_state = next_live_state;

        self.allocator.free(self.manifest_path);
        self.manifest_path = candidate.manifest_path;
        candidate.manifest_path = &[_]u8{};
    }

    pub fn generationById(self: *ModuleSlot, id: u64) ?*LiveModuleState {
        if (self.live_state) |live_state| {
            if (live_state.id == id) return live_state;
        }
        for (self.retired_states.items) |generation| {
            if (generation.id == id) return generation;
        }
        return null;
    }

    fn deinit(self: *ModuleSlot) void {
        if (self.live_state) |live_state| {
            live_state.deinit(self.allocator, null);
        }
        for (self.retired_states.items) |generation| {
            generation.deinit(self.allocator, null);
        }
        self.retired_states.deinit(self.allocator);
        self.allocator.free(self.module_id);
        self.allocator.free(self.manifest_path);
        for (self.bindings.items) |binding| binding.deinit();
        self.bindings.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

var loaded_modules: std.StringHashMapUnmanaged(*ModuleSlot) = .{};
var loaded_module_order: std.ArrayListUnmanaged(*ModuleSlot) = .empty;
var module_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
// Tracks the allocator used to populate the registry collections so they
// can be properly deinited (necessary when tests use std.testing.allocator).
var registry_allocator: ?std.mem.Allocator = null;
var next_generation_id: u64 = 1;

fn nextGenerationId() u64 {
    const id = next_generation_id;
    next_generation_id += 1;
    return id;
}

fn isUserPointer(env: emacs.Env, value: emacs.c.emacs_value) bool {
    const predicate = env.raw.intern.?(env.raw, "user-ptrp");
    var args = [_]emacs.c.emacs_value{value};
    const result = env.raw.funcall.?(env.raw, predicate, args.len, &args);
    return env.raw.is_not_nil.?(env.raw, result);
}

pub fn cleanupRetiredLoadPaths() usize {
    var removed: usize = 0;
    for (loaded_module_order.items) |module| {
        for (module.retired_states.items) |generation| {
            if (generation.cleanupLoadFile(module.allocator)) removed += 1;
        }
    }
    return removed;
}

pub fn trackReturnedUserPointer(
    env: emacs.Env,
    object_generations: emacs.c.emacs_value,
    value: emacs.c.emacs_value,
    generation: *LiveModuleState,
) void {
    if (!isUserPointer(env, value)) return;
    if (env.isNotNil(env.f("gethash", .{ value, object_generations }))) return;
    _ = env.f(
        "puthash",
        .{ value, env.makeInteger(@intCast(generation.id)), object_generations },
    );
}

pub const GenerationChoice = union(enum) {
    current,
    generation_id: u64,
    conflict,
};

pub fn generationChoiceForArguments(
    env: emacs.Env,
    module: *ModuleSlot,
    object_generations: emacs.c.emacs_value,
    args: []const emacs.c.emacs_value,
) GenerationChoice {
    var selected_id: ?u64 = null;
    for (args) |arg| {
        if (!isUserPointer(env, arg)) continue;
        const generation_value = env.f("gethash", .{ arg, object_generations });
        if (!env.isNotNil(generation_value)) continue;
        const generation_id: u64 = @intCast(env.extractInteger(generation_value));
        if (module.generationById(generation_id) == null) continue;
        if (selected_id) |id| {
            if (id != generation_id) return .conflict;
        } else {
            selected_id = generation_id;
        }
    }

    return if (selected_id) |id|
        .{ .generation_id = id }
    else
        .current;
}

pub fn moduleAllocator() std.mem.Allocator {
    return module_arena.allocator();
}

fn cleanupLoadPath(load_path: []const u8, target_path: []const u8) bool {
    if (load_path.len == 0 or std.mem.eql(u8, load_path, target_path)) return true;
    return deleteLoadPath(load_path);
}

fn copyShadowSource(target_path: []const u8, shadow_path: []const u8) !void {
    const io = loader_io.get();
    if (std.fs.path.isAbsolute(target_path) and std.fs.path.isAbsolute(shadow_path)) {
        try std.Io.Dir.copyFileAbsolute(target_path, shadow_path, io, .{});
        return;
    }
    if (!std.fs.path.isAbsolute(target_path) and !std.fs.path.isAbsolute(shadow_path)) {
        const cwd = std.Io.Dir.cwd();
        try cwd.copyFile(target_path, cwd, shadow_path, io, .{});
        return;
    }
    return error.MixedPathKind;
}

fn createShadowCopyPath(allocator: std.mem.Allocator, target_path: []const u8) ![]u8 {
    cleanupStaleShadowCopies(allocator, target_path);

    const dir = std.fs.path.dirname(target_path) orelse ".";
    const base = std.fs.path.basename(target_path);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];

    while (true) {
        const rng_source: std.Random.IoSource = .{ .io = loader_io.get() };
        const rng = rng_source.interface();
        const name = try std.fmt.allocPrint(
            allocator,
            ".{s}.load.{x}{s}",
            .{ stem, rng.int(u64), ext },
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
    errdefer _ = cleanupLoadPath(load_path, target_path);

    var library = try dynlib.Library.open(allocator, load_path);
    errdefer library.close();

    const generic_init_fn = try library.lookup(abi.GenericLoaderModuleInitFn, "loader_module_init_generic");
    var generic_manifest = std.mem.zeroes(abi.GenericManifest);
    generic_init_fn(&generic_manifest);
    const cleanup = library.lookup(abi.CleanupFn, abi.CleanupSymbolName) catch null;
    errdefer if (cleanup) |cleanup_fn| cleanup_fn(null);

    return .{
        .allocator = allocator,
        .library = library,
        .generic_manifest = generic_manifest,
        .cleanup = cleanup,
        .manifest_path = try allocator.dupe(u8, manifest_path),
        .target_path = try allocator.dupe(u8, target_path),
        .load_path = load_path,
        .loader_abi = loader_abi,
    };
}

pub fn installCandidate(candidate: *CandidateModule, raw_env: ?*emacs.c.emacs_env) !*ModuleSlot {
    if (registry_allocator == null) registry_allocator = candidate.allocator;

    const module_id = std.mem.span(candidate.generic_manifest.module_id);
    if (loaded_modules.get(module_id)) |module| {
        try module.replace(candidate, raw_env);
        return module;
    }

    const module = try candidate.allocator.create(ModuleSlot);
    errdefer candidate.allocator.destroy(module);

    module.* = .{
        .allocator = candidate.allocator,
        .module_id = try candidate.allocator.dupe(u8, module_id),
        .manifest_path = candidate.manifest_path,
    };
    errdefer module.deinit();
    candidate.manifest_path = &[_]u8{};

    module.live_state = try LiveModuleState.create(
        candidate.allocator,
        candidate,
        nextGenerationId(),
    );

    try loaded_modules.put(candidate.allocator, module.module_id, module);
    try loaded_module_order.append(candidate.allocator, module);
    return module;
}

pub fn moduleForId(module_id: []const u8) ?*ModuleSlot {
    return loaded_modules.get(module_id);
}

pub fn moduleSlots() []const *ModuleSlot {
    return loaded_module_order.items;
}

pub fn functionHandle(
    module: *ModuleSlot,
    lisp_name: []const u8,
    min_arity: i32,
    max_arity: i32,
) !*FunctionHandle {
    for (module.bindings.items) |binding| {
        if (binding.min_arity != min_arity) continue;
        if (binding.max_arity != max_arity) continue;
        if (std.mem.eql(u8, binding.lisp_name, lisp_name)) return binding;
    }

    const binding = try module.allocator.create(FunctionHandle);
    errdefer module.allocator.destroy(binding);

    binding.* = .{
        .slot = module,
        .lisp_name = try module.allocator.dupe(u8, lisp_name),
        .min_arity = min_arity,
        .max_arity = max_arity,
    };
    try module.bindings.append(module.allocator, binding);
    return binding;
}

pub fn reset() void {
    for (loaded_module_order.items) |module| module.deinit();
    if (registry_allocator) |alloc| {
        loaded_modules.deinit(alloc);
        loaded_module_order.deinit(alloc);
    }
    module_arena.deinit();
    module_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    loaded_modules = .{};
    loaded_module_order = .empty;
    registry_allocator = null;
    next_generation_id = 1;
}

fn testDynlibExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}

fn realPathAlloc(dir: std.Io.Dir, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(loader_io.get(), &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn testBuildReloadFixture(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    version: []const u8,
) !void {
    const source_path = try std.fmt.allocPrint(allocator, "{s}.zig", .{output_path});
    defer allocator.free(source_path);
    const source = try std.fmt.allocPrint(allocator,
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

    const io = std.testing.io;
    const source_file = try std.Io.Dir.createFileAbsolute(io, source_path, .{ .truncate = true });
    defer source_file.close(io);
    var source_writer = source_file.writer(io, &.{});
    try source_writer.interface.writeAll(source);

    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{output_path});
    defer allocator.free(emit_arg);
    const cache_dir = std.fs.path.dirname(output_path) orelse ".";

    const process_allocator = std.heap.page_allocator;
    const result = try std.process.run(process_allocator, io, .{
        .argv = &.{
            "zig",
            "build-lib",
            "-dynamic",
            "-O",
            "ReleaseSafe",
            source_path,
            emit_arg,
            "--cache-dir",
            cache_dir,
            "--global-cache-dir",
            cache_dir,
        },
        .stdout_limit = .limited(32 * 1024),
        .stderr_limit = .limited(32 * 1024),
    });
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);

    const exit_code = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    if (exit_code != 0) {
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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    defer reset();

    const module = try installCandidate(&candidate, null);

    try std.testing.expectEqualStrings("sample-module", module.module_id);
    try std.testing.expectEqualStrings("fixtures/ghostel-module.json", module.manifest_path);
    try std.testing.expectEqualStrings("fixtures/sample-module", module.live_state.?.target_path);
    try std.testing.expectEqual(module, moduleForId("sample-module").?);
}

test "installCandidate replaces existing module live state for reload" {
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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    defer reset();
    const module = try installCandidate(&first, null);
    const first_generation = module.live_state.?;

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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module-next.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-next"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-next.load"),
        .loader_abi = 1,
    };
    const reloaded = try installCandidate(&second, null);

    try std.testing.expectEqual(module, reloaded);
    try std.testing.expectEqualStrings("fixtures/ghostel-module-next.json", reloaded.manifest_path);
    try std.testing.expectEqualStrings("fixtures/sample-module-next", reloaded.live_state.?.target_path);
    try std.testing.expectEqualStrings("1.1", std.mem.span(reloaded.live_state.?.generic_manifest.module_version));
    try std.testing.expect(first_generation != reloaded.live_state.?);
    try std.testing.expectEqual(GenerationStatus.retired, first_generation.status);
    try std.testing.expectEqual(first_generation, module.generationById(first_generation.id).?);
}

var cleanup_test_events: std.ArrayListUnmanaged(u8) = .empty;

fn recordCleanup(_: ?*emacs.c.emacs_env) callconv(.c) void {
    cleanup_test_events.append(std.testing.allocator, 'c') catch unreachable;
}

test "candidate cleanup hook runs when discarded before install" {
    cleanup_test_events = .empty;
    defer cleanup_test_events.deinit(std.testing.allocator);

    var candidate = CandidateModule{
        .allocator = std.testing.allocator,
        .library = null,
        .generic_manifest = std.mem.zeroes(abi.GenericManifest),
        .cleanup = &recordCleanup,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    candidate.deinit(null);

    try std.testing.expectEqualStrings("c", cleanup_test_events.items);
}

test "module cleanup hook is deferred while generations remain callable" {
    cleanup_test_events = .empty;
    defer cleanup_test_events.deinit(std.testing.allocator);

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
        .cleanup = &recordCleanup,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    const module = try installCandidate(&first, null);

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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module-next.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-next"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-next.load"),
        .loader_abi = 1,
    };
    _ = try installCandidate(&second, null);
    try std.testing.expectEqualStrings("", cleanup_test_events.items);

    try module.unload(null);
    try std.testing.expectEqualStrings("", cleanup_test_events.items);

    var third = CandidateModule{
        .allocator = std.testing.allocator,
        .library = null,
        .generic_manifest = .{
            .loader_abi = abi.LoaderAbiVersion,
            .module_id = "sample-module",
            .module_version = "1.2",
            .exports_len = exports.len,
            .exports = exports[0..].ptr,
            .invoke = undefined,
            .get_variable = undefined,
            .set_variable = undefined,
        },
        .cleanup = &recordCleanup,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module-third.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-third"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-third.load"),
        .loader_abi = 1,
    };
    _ = try installCandidate(&third, null);

    try module.unload(null);
    try std.testing.expectEqualStrings("", cleanup_test_events.items);

    reset();
    try std.testing.expectEqualStrings("cc", cleanup_test_events.items);
}

fn testPathExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(loader_io.get(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    return true;
}

test "retired generation cleans an unlocked shadow copy without losing its manifest" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const dir_path = try realPathAlloc(tmp_dir.dir, allocator);
    defer allocator.free(dir_path);
    const target_path = try std.fs.path.join(allocator, &.{ dir_path, "sample-module.dll" });
    defer allocator.free(target_path);
    const load_path = try std.fs.path.join(allocator, &.{ dir_path, ".sample-module.load.dll" });
    defer allocator.free(load_path);

    try tmp_dir.dir.writeFile(loader_io.get(), .{ .sub_path = "sample-module.dll", .data = "target" });
    try tmp_dir.dir.writeFile(loader_io.get(), .{ .sub_path = ".sample-module.load.dll", .data = "shadow" });

    const live_state = try allocator.create(LiveModuleState);
    live_state.* = .{
        .id = 1,
        .status = .retired,
        .target_path = try allocator.dupe(u8, target_path),
        .load_path = try allocator.dupe(u8, load_path),
        .loader_abi = 1,
        .library = null,
        .generic_manifest = std.mem.zeroes(abi.GenericManifest),
        .cleanup = null,
    };

    try std.testing.expect(live_state.cleanupLoadFile(allocator));

    try std.testing.expect(!testPathExists(load_path));
    try std.testing.expectEqual(@as(usize, 0), live_state.load_path.len);
    try std.testing.expectEqual(@as(u32, 0), live_state.generic_manifest.exports_len);

    live_state.deinit(allocator, null);
}

test "createShadowCopyPath removes stale unlocked load copies first" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const dir_path = try realPathAlloc(tmp_dir.dir, allocator);
    defer allocator.free(dir_path);
    const target_path = try std.fs.path.join(allocator, &.{ dir_path, "sample-module.dll" });
    defer allocator.free(target_path);
    const stale_path = try std.fs.path.join(allocator, &.{ dir_path, ".sample-module.load.stale.dll" });
    defer allocator.free(stale_path);

    try tmp_dir.dir.writeFile(loader_io.get(), .{ .sub_path = "sample-module.dll", .data = "target" });
    try tmp_dir.dir.writeFile(loader_io.get(), .{ .sub_path = ".sample-module.load.stale.dll", .data = "stale" });

    const shadow_path = try createShadowCopyPath(allocator, target_path);
    defer allocator.free(shadow_path);
    defer _ = cleanupLoadPath(shadow_path, target_path);

    try std.testing.expect(!testPathExists(stale_path));
    try std.testing.expect(testPathExists(shadow_path));
}

test "module slot unload preserves stable identity and manifest path" {
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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    defer reset();

    const module = try installCandidate(&candidate, null);
    const binding = try functionHandle(module, "sample--ping", 0, 0);

    try module.unload(null);

    try std.testing.expectEqual(module, moduleForId("sample-module").?);
    try std.testing.expectEqualStrings("sample-module", module.module_id);
    try std.testing.expectEqualStrings("fixtures/ghostel-module.json", module.manifest_path);
    try std.testing.expect(!module.isLoaded());
    try std.testing.expectEqual(@as(usize, 1), module.bindings.items.len);
    try std.testing.expectEqual(module, binding.slot);
}

test "installCandidate reuses an unloaded module slot" {
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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    defer reset();

    const module = try installCandidate(&first, null);
    try module.unload(null);

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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module-next.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-next"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module-next.load"),
        .loader_abi = 1,
    };

    const reloaded = try installCandidate(&second, null);

    try std.testing.expectEqual(module, reloaded);
    try std.testing.expect(reloaded.isLoaded());
    try std.testing.expectEqualStrings("fixtures/ghostel-module-next.json", reloaded.manifest_path);
    try std.testing.expectEqualStrings("1.1", std.mem.span(reloaded.live_state.?.generic_manifest.module_version));
}

test "functionHandle reuses stable callback data for the same Lisp export contract" {
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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    defer reset();

    const module = try installCandidate(&candidate, null);
    const first = try functionHandle(module, "sample--ping", 0, 0);
    const second = try functionHandle(module, "sample--ping", 0, 0);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("sample--ping", first.lisp_name);
    try std.testing.expectEqual(module, first.slot);
}

test "functionHandle keeps incompatible arity contracts distinct" {
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
        .cleanup = null,
        .manifest_path = try std.testing.allocator.dupe(u8, "fixtures/ghostel-module.json"),
        .target_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module"),
        .load_path = try std.testing.allocator.dupe(u8, "fixtures/sample-module.load"),
        .loader_abi = 1,
    };
    defer reset();

    const module = try installCandidate(&candidate, null);
    const first = try functionHandle(module, "sample--ping", 0, 0);
    const second = try functionHandle(module, "sample--ping", 1, 1);

    try std.testing.expect(first != second);
}

test "openCandidate sees updated module contents when target path is replaced" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const allocator = std.testing.allocator;
    const dir_path = try realPathAlloc(tmp_dir.dir, allocator);
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
    const io = loader_io.get();
    try std.Io.Dir.copyFileAbsolute(first_output, live_output, io, .{});

    var first = try openCandidate(allocator, "sample-module.json", live_output, abi.LoaderAbiVersion);
    const installed = try installCandidate(&first, null);
    try std.testing.expectEqualStrings("1.0", std.mem.span(installed.live_state.?.generic_manifest.module_version));

    tmp_dir.dir.deleteFile(io, "sample-live.old") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    tmp_dir.dir.rename(std.fs.path.basename(live_output), tmp_dir.dir, "sample-live.old", io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.Io.Dir.copyFileAbsolute(second_output, live_output, io, .{});

    var reloaded = try openCandidate(allocator, "sample-module.json", live_output, abi.LoaderAbiVersion);
    defer reloaded.deinit(null);
    try std.testing.expectEqualStrings("2.0", std.mem.span(reloaded.generic_manifest.module_version));
}
