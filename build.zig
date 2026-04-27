const builtin = @import("builtin");
const std = @import("std");
const emacs_util_mods = @import("emacs_util_mods");

const vendored_emacs_include_dir = emacs_util_mods.vendored_emacs_include_dir;
const EmacsIncludeSource = emacs_util_mods.EmacsIncludeSource;

const vendored_emacs_module_dir = "vendor";

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
    const ghostty_optimize = b.option(
        std.builtin.OptimizeMode,
        "ghostty-optimize",
        "Optimization mode for the ghostty dependency (defaults to the main optimize option)",
    ) orelse optimize;
    const strip_binaries = optimize != .Debug;
    const resolved_target = target.result;
    const target_os = resolved_target.os.tag;
    const is_windows = target_os == .windows;
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
    if (is_windows) {
        addWindowsRuntimeLibraries(b, loader_lib, resolved_target);
    }
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
    target_mod.linkLibrary(ghostty_lib);
    addStbSupport(b, target_mod);

    const target_lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = target_mod,
    });
    if (is_windows) {
        addWindowsRuntimeLibraries(b, target_lib, resolved_target);
    }

    // Release optimizations: dead-code elimination and symbol visibility
    if (strip_binaries) {
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

    if (is_windows) {
        const conpty_mod = b.createModule(.{
            .root_source_file = conptyModuleSourcePath(b),
            .target = target,
            .optimize = optimize,
            .strip = strip_binaries,
            .link_libc = true,
        });
        addLoaderIncludes(conpty_mod, emacs_include);
        conpty_mod.addImport("emacs", emacs_mod);
        conpty_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);

        const conpty_lib = b.addLibrary(.{
            .name = "conpty-module",
            .linkage = .dynamic,
            .root_module = conpty_mod,
        });
        addWindowsRuntimeLibraries(b, conpty_lib, resolved_target);
        b.installArtifact(conpty_lib);

        const copy_conpty = b.addInstallFile(
            conpty_lib.getEmittedBin(),
            "bin/conpty-module.dll",
        );
        b.getInstallStep().dependOn(&copy_conpty.step);

        const conpty_manifest_file = manifest_files.add("conpty-module.json", b.fmt(
            "{{\"loader_abi\":1,\"module_path\":\"{s}\"}}",
            .{"conpty-module.dll"},
        ));
        const copy_conpty_manifest = b.addInstallFile(
            conpty_manifest_file,
            "bin/conpty-module.json",
        );
        b.getInstallStep().dependOn(&copy_conpty_manifest.step);
    }

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
    addStbSupport(b, target_check_mod);

    const target_check_obj = b.addObject(.{
        .name = "ghostel-target-check",
        .root_module = target_check_mod,
    });

    const check = b.step("check", "Check that the loader and target modules compile");
    check.dependOn(&loader_check_obj.step);
    check.dependOn(&target_check_obj.step);
    if (is_windows) {
        const conpty_check_mod = b.createModule(.{
            .root_source_file = conptyModuleSourcePath(b),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        addLoaderIncludes(conpty_check_mod, emacs_include);
        conpty_check_mod.addImport("emacs", emacs_mod);
        conpty_check_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);

        const conpty_check_obj = b.addObject(.{
            .name = "conpty-module-check",
            .root_module = conpty_check_mod,
        });
        check.dependOn(&conpty_check_obj.step);
    }

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
    if (is_windows) {
        addWindowsRuntimeLibraries(b, loader_tests, resolved_target);
    }

    const target_test_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addRealModuleIncludes(target_test_mod, emacs_include, ghostty_lib);
    target_test_mod.addImport("emacs", emacs_mod);
    target_test_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);
    target_test_mod.linkLibrary(ghostty_lib);
    addStbSupport(b, target_test_mod);

    const target_tests = b.addTest(.{
        .root_module = target_test_mod,
    });
    if (is_windows) {
        addWindowsRuntimeLibraries(b, target_tests, resolved_target);
    }

    const run_loader_tests = b.addRunArtifact(loader_tests);
    const run_target_tests = b.addRunArtifact(target_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_loader_tests.step);
    test_step.dependOn(&run_target_tests.step);

    const ppm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ppm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ppm_tests).step);

    const png_test_mod = b.createModule(.{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addStbSupport(b, png_test_mod);
    const png_tests = b.addTest(.{ .root_module = png_test_mod });
    test_step.dependOn(&b.addRunArtifact(png_tests).step);

    if (is_windows) {
        const conpty_test_mod = b.createModule(.{
            .root_source_file = conptyModuleSourcePath(b),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        addLoaderIncludes(conpty_test_mod, emacs_include);
        conpty_test_mod.addImport("emacs", emacs_mod);
        conpty_test_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);

        const conpty_tests = b.addTest(.{
            .root_module = conpty_test_mod,
        });
        addWindowsRuntimeLibraries(b, conpty_tests, resolved_target);

        const run_conpty_tests = b.addRunArtifact(conpty_tests);
        test_step.dependOn(&run_conpty_tests.step);
    }
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

fn conptyModuleSourcePath(b: *std.Build) std.Build.LazyPath {
    const dep = b.dependency("emacs_util_mods", .{});
    return dep.path("src/conpty/module.zig");
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

fn addLoaderRuntimeLibraries(step: *std.Build.Step.Compile, target_os: std.Target.Os.Tag) void {
    switch (target_os) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .solaris => step.linkSystemLibrary("dl"),
        else => {},
    }
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
