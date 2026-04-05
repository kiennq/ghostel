const builtin = @import("builtin");
const std = @import("std");

const vendored_emacs_include_dir = "include";
const EmacsIncludeSource = union(enum) {
    include_dir: []const u8,
    source_dir: []const u8,
    vendored,
};

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.os.tag == .windows)
        .{
            .cpu_arch = builtin.cpu.arch,
            .os_tag = .windows,
            .abi = .gnu,
        }
    else
        .{};
    const target = b.standardTargetOptions(.{
        .default_target = default_target,
    });
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;
    const emacs_include = resolveEmacsIncludePath(b);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addModuleIncludes(b, mod, emacs_include);

    const lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = mod,
    });
    addGhosttyLibraries(b, lib);
    if (target.result.abi != .msvc) {
        lib.linkLibCpp();
    }
    if (target_os == .windows) {
        addWindowsRuntimeLibraries(b, lib, target.result);
    }

    b.installArtifact(lib);

    const copy_step = b.addInstallFile(
        lib.getEmittedBin(),
        moduleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_step.step);

    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addModuleIncludes(b, check_mod, emacs_include);

    const check_obj = b.addObject(.{
        .name = "ghostel-module-check",
        .root_module = check_mod,
    });

    const check = b.step("check", "Check that the module compiles (no linking)");
    check.dependOn(&check_obj.step);
}

fn addModuleIncludes(
    b: *std.Build,
    mod: *std.Build.Module,
    emacs_include: std.Build.LazyPath,
) void {
    mod.addSystemIncludePath(emacs_include);
    mod.addIncludePath(b.path("vendor/ghostty/include"));
    mod.addIncludePath(b.path("vendor/ghostty/zig-out/include"));
}

fn resolveEmacsIncludePath(b: *std.Build) std.Build.LazyPath {
    return switch (resolveEmacsIncludeSource(
        b.graph.env_map.get("EMACS_INCLUDE_DIR"),
        b.graph.env_map.get("EMACS_SOURCE_DIR"),
    )) {
        .include_dir => |dir| .{ .cwd_relative = dir },
        .source_dir => |dir| blk: {
            const generated = b.addWriteFiles();
            const header = generateEmacsModuleHeader(b.allocator, dir) catch |err|
                std.debug.panic("failed to generate emacs-module.h from {s}: {s}", .{
                    dir,
                    @errorName(err),
                });
            _ = generated.add("emacs-module.h", header);
            break :blk generated.getDirectory();
        },
        .vendored => .{ .cwd_relative = vendoredEmacsIncludeDir() },
    };
}

fn resolveEmacsIncludeSource(
    emacs_include_dir: ?[]const u8,
    emacs_source_dir: ?[]const u8,
) EmacsIncludeSource {
    if (emacs_include_dir) |dir| return .{ .include_dir = dir };
    if (emacs_source_dir) |dir| return .{ .source_dir = dir };
    return .vendored;
}

fn vendoredEmacsIncludeDir() []const u8 {
    return vendored_emacs_include_dir;
}

fn generateEmacsModuleHeader(allocator: std.mem.Allocator, source_dir: []const u8) ![]u8 {
    const src_dir = try std.fs.path.join(allocator, &.{ source_dir, "src" });
    defer allocator.free(src_dir);

    const template_path = try std.fs.path.join(allocator, &.{ src_dir, "emacs-module.in.h" });
    defer allocator.free(template_path);

    var header = try readFileAllocAbsolute(allocator, template_path);
    errdefer allocator.free(header);

    const major_version = try detectEmacsModuleVersion(allocator, src_dir);
    const version_text = try std.fmt.allocPrint(allocator, "{d}", .{major_version});
    defer allocator.free(version_text);

    header = try replaceOwned(allocator, header, "@emacs_major_version@", version_text);

    var version: usize = 25;
    while (version <= major_version) : (version += 1) {
        const fragment_name = try std.fmt.allocPrint(allocator, "module-env-{d}.h", .{version});
        defer allocator.free(fragment_name);
        const fragment_path = try std.fs.path.join(allocator, &.{ src_dir, fragment_name });
        defer allocator.free(fragment_path);
        const fragment = try readFileAllocAbsolute(allocator, fragment_path);
        defer allocator.free(fragment);

        const placeholder = try std.fmt.allocPrint(allocator, "@module_env_snippet_{d}@", .{version});
        defer allocator.free(placeholder);

        header = try replaceOwned(allocator, header, placeholder, fragment);
    }

    return header;
}

fn detectEmacsModuleVersion(allocator: std.mem.Allocator, src_dir: []const u8) !usize {
    var max_version: usize = 0;
    var version: usize = 25;
    while (version < 80) : (version += 1) {
        const fragment_name = try std.fmt.allocPrint(allocator, "module-env-{d}.h", .{version});
        defer allocator.free(fragment_name);
        const fragment_path = try std.fs.path.join(allocator, &.{ src_dir, fragment_name });
        defer allocator.free(fragment_path);

        if (pathExistsAbsolute(fragment_path)) {
            max_version = version;
        }
    }

    if (max_version == 0) return error.EmacsModuleFragmentsNotFound;
    return max_version;
}

fn replaceOwned(
    allocator: std.mem.Allocator,
    text: []u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const replaced = try std.mem.replaceOwned(u8, allocator, text, needle, replacement);
    allocator.free(text);
    return replaced;
}

fn readFileAllocAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn addGhosttyLibraries(b: *std.Build, step: *std.Build.Step.Compile) void {
    addFirstExistingObjectFile(b, step, &.{
        "vendor/ghostty/zig-out/lib/ghostty-vt-static.lib",
        "vendor/ghostty/zig-out/lib/ghostty-vt.lib",
        "vendor/ghostty/zig-out/lib/libghostty-vt.a",
    });
    addFirstExistingObjectFile(b, step, &.{
        "vendor/ghostty/zig-out/lib/simdutf.lib",
        "vendor/ghostty/zig-out/lib/libsimdutf.a",
    });
    addFirstExistingObjectFile(b, step, &.{
        "vendor/ghostty/zig-out/lib/highway.lib",
        "vendor/ghostty/zig-out/lib/libhighway.a",
    });
}

fn addWindowsRuntimeLibraries(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    resolved_target: std.Target,
) void {
    lib.linkSystemLibrary("kernel32");
    if (resolved_target.abi != .msvc) return;

    lib.linkSystemLibrary("libvcruntime");

    const arch = resolved_target.cpu.arch;
    const sdk = std.zig.WindowsSdk.find(b.allocator, arch) catch null;
    if (sdk) |s| {
        if (s.windows10sdk) |w10| {
            const arch_str: []const u8 = switch (arch) {
                .x86_64 => "x64",
                .x86 => "x86",
                .aarch64 => "arm64",
                else => "x64",
            };
            const ucrt_lib_path = std.fmt.allocPrint(
                b.allocator,
                "{s}\\Lib\\{s}\\ucrt\\{s}",
                .{ w10.path, w10.version, arch_str },
            ) catch null;

            if (ucrt_lib_path) |path| {
                lib.addLibraryPath(.{ .cwd_relative = path });
            }
        }
    }

    lib.linkSystemLibrary("libucrt");
}

fn addFirstExistingObjectFile(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    candidates: []const []const u8,
) void {
    const path = firstExistingPath(candidates) orelse candidates[0];
    step.addObjectFile(b.path(path));
}

fn firstExistingPath(candidates: []const []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        std.fs.cwd().access(candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

test "emacs include resolution prefers include dir override" {
    const source = resolveEmacsIncludeSource("C:/headers", "Q:/repos/emacs-build/git/master");
    try std.testing.expect(source == .include_dir);
    try std.testing.expectEqualStrings("C:/headers", source.include_dir);
}

test "emacs include resolution prefers source dir over vendored header" {
    const source = resolveEmacsIncludeSource(null, "Q:/repos/emacs-build/git/master");
    try std.testing.expect(source == .source_dir);
    try std.testing.expectEqualStrings("Q:/repos/emacs-build/git/master", source.source_dir);
}

test "emacs include resolution falls back to vendored header" {
    const source = resolveEmacsIncludeSource(null, null);
    try std.testing.expect(source == .vendored);
}

fn moduleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "../ghostel-module.dylib",
        .windows => "../ghostel-module.dll",
        else => "../ghostel-module.so",
    };
}
