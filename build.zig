const std = @import("std");
const emacs_util_mods = @import("emacs_util_mods");
const module_version = @import("src/version.zig").version;

const vendored_emacs_include_dir = emacs_util_mods.vendored_emacs_include_dir;
const EmacsIncludeSource = emacs_util_mods.EmacsIncludeSource;

const vendored_emacs_module_dir = "vendor";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
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
    const emacs_mod = b.createModule(.{
        .root_source_file = b.path("src/emacs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    emacs_mod.addSystemIncludePath(emacs_include);
    const dyn_loader_abi_mod = b.createModule(.{
        .root_source_file = dynLoaderAbiSourcePath(b),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dyn_loader_abi_mod.addImport("emacs", emacs_mod);
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = ghostty_optimize,
        .@"emit-lib-vt" = true,
        .strip = strip_binaries,
    });

    const loader_mod = b.createModule(.{
        .root_source_file = dynLoaderModuleSourcePath(b),
        .target = target,
        .optimize = optimize,
        .strip = strip_binaries,
        .link_libc = true,
    });
    addLoaderIncludes(loader_mod, emacs_include);
    loader_mod.addImport("emacs", emacs_mod);

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
    });
    const ghostty_lib = ghostty_dep.artifact("ghostty-vt-static");
    addRealModuleIncludes(target_mod, emacs_include, ghostty_lib);
    target_mod.addImport("emacs", emacs_mod);
    target_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);
    target_mod.addImport("ghostty-vt", ghostty_dep.module("ghostty-vt"));
    target_mod.linkLibrary(ghostty_lib);
    addStbSupport(b, target_mod);

    const target_lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = target_mod,
    });
    if (target_os == .windows) {
        target_lib.linkSystemLibrary("kernel32");
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

    const version_files = b.addWriteFiles();
    const version_file = version_files.add("ghostel-module.version", module_version ++ "\n");
    const copy_version = b.addInstallFile(
        version_file,
        "bin/ghostel-module.version",
    );
    b.getInstallStep().dependOn(&copy_version.step);

    const loader_check_mod = b.createModule(.{
        .root_source_file = dynLoaderModuleSourcePath(b),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addLoaderIncludes(loader_check_mod, emacs_include);
    loader_check_mod.addImport("emacs", emacs_mod);

    const loader_check_obj = b.addObject(.{
        .name = "dyn-loader-module-check",
        .root_module = loader_check_mod,
    });

    const target_check_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addRealModuleIncludes(target_check_mod, emacs_include, ghostty_lib);
    target_check_mod.addImport("emacs", emacs_mod);
    target_check_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);
    target_check_mod.addImport("ghostty-vt", ghostty_dep.module("ghostty-vt"));
    addStbSupport(b, target_check_mod);

    const target_check_obj = b.addObject(.{
        .name = "ghostel-target-check",
        .root_module = target_check_mod,
    });

    const check = b.step("check", "Check that the loader and target modules compile");
    check.dependOn(&loader_check_obj.step);
    check.dependOn(&target_check_obj.step);

    const loader_test_mod = b.createModule(.{
        .root_source_file = dynLoaderModuleSourcePath(b),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addLoaderIncludes(loader_test_mod, emacs_include);
    loader_test_mod.addImport("emacs", emacs_mod);

    const loader_tests = b.addTest(.{
        .root_module = loader_test_mod,
    });
    addLoaderRuntimeLibraries(loader_tests, target_os);

    const target_test_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addRealModuleIncludes(target_test_mod, emacs_include, ghostty_lib);
    target_test_mod.addImport("emacs", emacs_mod);
    target_test_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);
    target_test_mod.addImport("ghostty-vt", ghostty_dep.module("ghostty-vt"));
    target_test_mod.linkLibrary(ghostty_lib);
    addStbSupport(b, target_test_mod);

    const target_tests = b.addTest(.{
        .root_module = target_test_mod,
    });
    if (target_os == .windows) {
        target_tests.linkSystemLibrary("kernel32");
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
    });
    addStbSupport(b, tests_mod);
    tests_mod.addImport("ghostty-vt", ghostty_dep.module("ghostty-vt"));
    const tests = b.addTest(.{ .root_module = tests_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addLoaderIncludes(mod: *std.Build.Module, emacs_include: std.Build.LazyPath) void {
    mod.addSystemIncludePath(emacs_include);
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
    if (b.graph.env_map.get("EMACS_INCLUDE_DIR") != null or
        b.graph.env_map.get("EMACS_SOURCE_DIR") != null)
    {
        return emacs_util_mods.resolveEmacsIncludePath(b);
    }
    return .{ .cwd_relative = vendoredEmacsIncludeDir() };
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
    const dep = b.dependency("emacs_util_mods", .{});
    return dep.path("src/dyn-loader/abi.zig");
}

fn dynLoaderModuleSourcePath(b: *std.Build) std.Build.LazyPath {
    const dep = b.dependency("emacs_util_mods", .{});
    return dep.path("src/dyn-loader/module.zig");
}

fn addLoaderRuntimeLibraries(step: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        .windows => step.linkSystemLibrary("kernel32"),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .solaris => step.linkSystemLibrary("dl"),
        else => {},
    }
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
