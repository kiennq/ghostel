const std = @import("std");
const builtin = @import("builtin");

const EmacsIncludeSource = union(enum) {
    include_dir: []const u8,
    source_dir: []const u8,
    vendored,
};

var io: std.Io.Threaded = .init_single_threaded;

// Keep in sync with build.zig.zon (minimum_zig_version) and the CI workflows.
const required_zig = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };
comptime {
    if (builtin.zig_version.order(required_zig) != .eq)
        @compileError("ghostel requires exactly Zig 0.16.0, found " ++ builtin.zig_version_string);
}

const vendored_emacs_module_dir = "vendor";

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = switch (builtin.os.tag) {
        .windows => .{
            .cpu_arch = builtin.cpu.arch,
            .os_tag = .windows,
            .abi = .gnu,
        },
        else => .{},
    };
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const ghostty_optimize = b.option(
        std.builtin.OptimizeMode,
        "ghostty-optimize",
        "Optimization mode for the ghostty dependency (defaults to the main optimize option)",
    ) orelse optimize;
    const target_os = target.result.os.tag;
    const release_binaries = optimize != .Debug;
    const strip_binaries = shouldStripBinaries(optimize, target_os);
    const emacs_include = resolveEmacsIncludePath(b);
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = ghostty_optimize,
        .@"emit-lib-vt" = true,
        .strip = strip_binaries,
    });

    const ghostty_vt = ghostty_dep.module("ghostty-vt");

    const translate_emacs = b.addTranslateC(.{
        .root_source_file = b.path("src/emacs.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_emacs.addIncludePath(emacs_include);
    const emacs_c = translate_emacs.createModule();

    const platform_c: std.Build.Module.Import = switch (target_os) {
        .windows => platform: {
            const translate_windows = b.addTranslateC(.{
                .root_source_file = b.path("src/win32.h"),
                .target = target,
                .optimize = optimize,
            });
            break :platform .{
                .name = "windows_c",
                .module = translate_windows.createModule(),
            };
        },
        else => platform: {
            const translate_posix = b.addTranslateC(.{
                .root_source_file = b.path("src/posix.h"),
                .target = target,
                .optimize = optimize,
            });
            break :platform .{
                .name = "posix_c",
                .module = translate_posix.createModule(),
            };
        },
    };

    const translate_stb = b.addTranslateC(.{
        .root_source_file = b.path("vendor/stb/stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    const stb_image_c = translate_stb.createModule();

    const emacs_mod = b.createModule(.{
        .root_source_file = b.path("src/emacs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "emacs_c", .module = emacs_c },
        },
    });
    emacs_mod.addIncludePath(emacs_include);

    const dyn_loader_abi_mod = b.createModule(.{
        .root_source_file = dynLoaderAbiSourcePath(b),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dyn_loader_abi_mod.addImport("emacs", emacs_mod);

    const loader_mod = b.createModule(.{
        .root_source_file = dynLoaderModuleSourcePath(b),
        .target = target,
        .optimize = optimize,
        .strip = strip_binaries,
        .link_libc = true,
        .imports = &.{
            .{ .name = "emacs", .module = emacs_mod },
        },
    });
    addLoaderIncludes(loader_mod, emacs_include);

    const loader_lib = b.addLibrary(.{
        .name = "dyn-loader-module",
        .linkage = .dynamic,
        .root_module = loader_mod,
    });
    addLoaderRuntimeLibraries(loader_lib, target_os);
    b.installArtifact(loader_lib);

    const copy_loader = b.addInstallFile(
        loader_lib.getEmittedBin(),
        loaderModuleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_loader.step);

    const target_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_binaries,
        .link_libc = true,
        .imports = &.{
            .{ .name = "emacs", .module = emacs_mod },
            .{ .name = "dyn_loader_abi", .module = dyn_loader_abi_mod },
            .{ .name = "ghostty-vt", .module = ghostty_vt },
            platform_c,
            .{ .name = "stb_image_c", .module = stb_image_c },
        },
    });
    const ghostty_lib = ghostty_dep.artifact("ghostty-vt-static");
    addRealModuleIncludes(target_mod, emacs_include, ghostty_lib);
    target_mod.linkLibrary(ghostty_lib);
    addStbSupport(b, target_mod);

    const target_lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = target_mod,
    });
    if (target_os == .windows) {
        target_lib.root_module.linkSystemLibrary("kernel32", .{});
    }

    // Release optimizations: dead-code elimination and symbol visibility
    if (release_binaries) {
        target_lib.link_gc_sections = true;
        target_lib.link_function_sections = true;
        target_lib.link_data_sections = true;
        target_lib.dead_strip_dylibs = true;
    }

    b.installArtifact(target_lib);

    const copy_target = b.addInstallFile(
        target_lib.getEmittedBin(),
        targetModuleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_target.step);

    const manifest_files = b.addWriteFiles();
    const manifest_file = manifest_files.add("ghostel-module.json", b.fmt(
        "{{\"loader_abi\":1,\"module_path\":\"{s}\"}}",
        .{targetModuleFileName(target_os)},
    ));
    const copy_manifest = b.addInstallFile(
        manifest_file,
        "bin/ghostel-module.json",
    );
    b.getInstallStep().dependOn(&copy_manifest.step);

    const loader_check_mod = b.createModule(.{
        .root_source_file = dynLoaderModuleSourcePath(b),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "emacs", .module = emacs_mod },
        },
    });
    addLoaderIncludes(loader_check_mod, emacs_include);

    const loader_check_obj = b.addObject(.{
        .name = "dyn-loader-module-check",
        .root_module = loader_check_mod,
    });

    const target_check_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "emacs", .module = emacs_mod },
            .{ .name = "dyn_loader_abi", .module = dyn_loader_abi_mod },
            .{ .name = "ghostty-vt", .module = ghostty_vt },
            platform_c,
            .{ .name = "stb_image_c", .module = stb_image_c },
        },
    });
    addRealModuleIncludes(target_check_mod, emacs_include, ghostty_lib);
    addStbSupport(b, target_check_mod);

    target_check_mod.linkLibrary(ghostty_lib);
    const target_check_obj = b.addLibrary(.{
        .name = "ghostel-target-check",
        .linkage = .dynamic,
        .root_module = target_check_mod,
    });
    if (target_os == .windows) {
        target_check_obj.root_module.linkSystemLibrary("kernel32", .{});
    }

    const check = b.step("check", "Check that the loader and target modules compile");
    check.dependOn(&loader_check_obj.step);
    check.dependOn(&target_check_obj.step);

    const loader_test_mod = b.createModule(.{
        .root_source_file = dynLoaderModuleSourcePath(b),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "emacs", .module = emacs_mod },
        },
    });
    addLoaderIncludes(loader_test_mod, emacs_include);

    const loader_tests = b.addTest(.{
        .root_module = loader_test_mod,
    });
    addLoaderRuntimeLibraries(loader_tests, target_os);

    const target_test_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "emacs", .module = emacs_mod },
            .{ .name = "dyn_loader_abi", .module = dyn_loader_abi_mod },
            .{ .name = "ghostty-vt", .module = ghostty_vt },
            platform_c,
            .{ .name = "stb_image_c", .module = stb_image_c },
        },
    });
    addRealModuleIncludes(target_test_mod, emacs_include, ghostty_lib);
    target_test_mod.linkLibrary(ghostty_lib);
    addStbSupport(b, target_test_mod);

    const target_tests = b.addTest(.{
        .root_module = target_test_mod,
    });
    if (target_os == .windows) {
        target_tests.root_module.linkSystemLibrary("kernel32", .{});
    }

    const run_loader_tests = b.addRunArtifact(loader_tests);
    const run_target_tests = b.addRunArtifact(target_tests);

    if (target_os == .windows) {
        if (b.option([]const u8, "windows-conpty-package-dir", "Unpacked Microsoft.Windows.Console.ConPTY NuGet package directory")) |dir| {
            installWindowsConptyRuntime(b, target.result.cpu.arch, dir);
        }
    }

    // ----------------------------------------------------------------
    // `zig build test` — pure-Zig unit tests.
    //
    // Modules that don't depend on emacs-module are covered here. End-to-end
    // tests through the C API run via `make test-native`.
    // ----------------------------------------------------------------
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_loader_tests.step);
    test_step.dependOn(&run_target_tests.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "ghostty-vt", .module = ghostty_vt },
            platform_c,
            .{ .name = "stb_image_c", .module = stb_image_c },
        },
    });
    addStbSupport(b, tests_mod);
    const tests = b.addTest(.{ .root_module = tests_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addLoaderIncludes(mod: *std.Build.Module, emacs_include: std.Build.LazyPath) void {
    mod.addIncludePath(emacs_include);
}

fn addRealModuleIncludes(
    mod: *std.Build.Module,
    emacs_include: std.Build.LazyPath,
    ghostty_lib: *std.Build.Step.Compile,
) void {
    addLoaderIncludes(mod, emacs_include);
    mod.addIncludePath(ghostty_lib.getEmittedIncludeTree());
}

fn addStbSupport(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("vendor/stb"));
    mod.addCSourceFile(.{ .file = b.path("src/stb_image.c") });
}

fn resolveEmacsIncludePath(b: *std.Build) std.Build.LazyPath {
    return switch (resolveEmacsIncludeSource(
        b.graph.environ_map.get("EMACS_INCLUDE_DIR"),
        b.graph.environ_map.get("EMACS_SOURCE_DIR"),
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
        .vendored => b.path(vendoredEmacsIncludeDir()),
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
    return vendored_emacs_module_dir;
}

fn dynLoaderAbiSourcePath(b: *std.Build) std.Build.LazyPath {
    return b.path("vendor/emacs-util-mods/src/dyn-loader/abi.zig");
}

fn dynLoaderModuleSourcePath(b: *std.Build) std.Build.LazyPath {
    return b.path("vendor/emacs-util-mods/src/dyn-loader/module.zig");
}

fn addLoaderRuntimeLibraries(step: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        .windows => step.root_module.linkSystemLibrary("kernel32", .{}),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => step.root_module.linkSystemLibrary("dl", .{}),
        else => {},
    }
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

        if (pathExistsAbsolute(fragment_path)) max_version = version;
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
    const file = try std.Io.Dir.openFileAbsolute(io.io(), path, .{});
    defer file.close(io.io());
    var reader = file.reader(io.io(), &.{});
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io.io(), path, .{}) catch return false;
    return true;
}

fn shouldStripBinaries(optimize: std.builtin.OptimizeMode, target_os: std.Target.Os.Tag) bool {
    return optimize != .Debug and target_os != .windows;
}

test "Windows release builds keep debug info for PDB sidecars" {
    try std.testing.expect(!shouldStripBinaries(.ReleaseFast, .windows));
    try std.testing.expect(!shouldStripBinaries(.Debug, .windows));
}

test "non-Windows release builds keep existing strip behavior" {
    try std.testing.expect(shouldStripBinaries(.ReleaseFast, .linux));
    try std.testing.expect(shouldStripBinaries(.ReleaseSmall, .macos));
    try std.testing.expect(!shouldStripBinaries(.Debug, .linux));
}

test "emacs include resolution prefers include dir override" {
    const source = resolveEmacsIncludeSource("/headers", "/repos/emacs-build/git/master");
    try std.testing.expect(source == .include_dir);
    try std.testing.expectEqualStrings("/headers", source.include_dir);
}

test "emacs include resolution prefers source dir over vendored header" {
    const source = resolveEmacsIncludeSource(null, "/repos/emacs-build/git/master");
    try std.testing.expect(source == .source_dir);
    try std.testing.expectEqualStrings("/repos/emacs-build/git/master", source.source_dir);
}

test "emacs include resolution falls back to vendored header" {
    const source = resolveEmacsIncludeSource(null, null);
    try std.testing.expect(source == .vendored);
}

fn loaderModuleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "bin/dyn-loader-module.dylib",
        .windows => "bin/dyn-loader-module.dll",
        else => "bin/dyn-loader-module.so",
    };
}

fn targetModuleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "bin/ghostel-module.dylib",
        .windows => "bin/ghostel-module.dll",
        else => "bin/ghostel-module.so",
    };
}

fn targetModuleFileName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "ghostel-module.dylib",
        .windows => "ghostel-module.dll",
        else => "ghostel-module.so",
    };
}

fn installWindowsConptyRuntime(b: *std.Build, arch: std.Target.Cpu.Arch, package_dir: []const u8) void {
    const runtime_arch = windowsConptyRuntimeArch(arch) orelse return;
    const conpty_path = b.pathJoin(&.{ package_dir, "runtimes", b.fmt("win-{s}", .{runtime_arch}), "native", "conpty.dll" });
    const copy_conpty = b.addInstallFile(.{ .cwd_relative = conpty_path }, "bin/conpty.dll");
    b.getInstallStep().dependOn(&copy_conpty.step);

    switch (arch) {
        .x86 => {
            installWindowsOpenConsole(b, package_dir, "x86");
            installWindowsOpenConsole(b, package_dir, "x64");
            installWindowsOpenConsole(b, package_dir, "arm64");
        },
        .x86_64 => {
            installWindowsOpenConsole(b, package_dir, "x64");
            installWindowsOpenConsole(b, package_dir, "arm64");
        },
        .aarch64 => installWindowsOpenConsole(b, package_dir, "arm64"),
        else => {},
    }
}

fn windowsConptyRuntimeArch(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86 => "x86",
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => null,
    };
}

fn installWindowsOpenConsole(b: *std.Build, package_dir: []const u8, host_arch: []const u8) void {
    const source = b.pathJoin(&.{ package_dir, "build", "native", "runtimes", host_arch, "OpenConsole.exe" });
    const dest = b.fmt("bin/{s}/OpenConsole.exe", .{host_arch});
    const copy = b.addInstallFile(.{ .cwd_relative = source }, dest);
    b.getInstallStep().dependOn(&copy.step);
}
