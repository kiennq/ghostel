const builtin = @import("builtin");
const std = @import("std");
const emacs_util_mods = @import("vendor/emacs-util-mods/build.zig");

const vendored_emacs_include_dir = emacs_util_mods.vendored_emacs_include_dir;
const EmacsIncludeSource = emacs_util_mods.EmacsIncludeSource;

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
    const strip_binaries = optimize != .Debug;
    const target_os = target.result.os.tag;
    const emacs_include = resolveEmacsIncludePath(b);
    const emacs_mod = b.createModule(.{
        .root_source_file = b.path("src/emacs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    emacs_mod.addSystemIncludePath(emacs_include);
    const dyn_loader_abi_mod = b.createModule(.{
        .root_source_file = b.path(dynLoaderAbiSourcePath()),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dyn_loader_abi_mod.addImport("emacs", emacs_mod);
    const ghostty_dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .strip = strip_binaries,
    }) orelse std.debug.panic(
        "ghostty dependency unavailable; initialize the vendor/ghostty submodule",
        .{},
    );

    const loader_mod = b.createModule(.{
        .root_source_file = b.path(dynLoaderModuleSourcePath()),
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
    if (target_os == .windows) {
        addWindowsRuntimeLibraries(b, loader_lib, target.result);
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
    addRealModuleIncludes(b, target_mod, emacs_include);
    target_mod.addImport("emacs", emacs_mod);
    target_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);
    target_mod.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));

    const target_lib = b.addLibrary(.{
        .name = "ghostel-module",
        .linkage = .dynamic,
        .root_module = target_mod,
    });
    if (target_os == .windows) {
        addWindowsRuntimeLibraries(b, target_lib, target.result);
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
    if (target_os == .windows) {
        const conpty_mod = b.createModule(.{
            .root_source_file = b.path(conptyModuleSourcePath()),
            .target = target,
            .optimize = optimize,
            .strip = strip_binaries,
            .link_libc = true,
        });
        addLoaderIncludes(conpty_mod, emacs_include);
        conpty_mod.addImport("emacs", emacs_mod);

        const conpty_lib = b.addLibrary(.{
            .name = "conpty-module",
            .linkage = .dynamic,
            .root_module = conpty_mod,
        });
        addWindowsRuntimeLibraries(b, conpty_lib, target.result);
        b.installArtifact(conpty_lib);
        const copy_conpty = b.addInstallFile(
            conpty_lib.getEmittedBin(),
            "bin/conpty-module.dll",
        );
        b.getInstallStep().dependOn(&copy_conpty.step);
    }

    const loader_check_mod = b.createModule(.{
        .root_source_file = b.path(dynLoaderModuleSourcePath()),
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
    addRealModuleIncludes(b, target_check_mod, emacs_include);
    target_check_mod.addImport("emacs", emacs_mod);
    target_check_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);
    const target_check_obj = b.addObject(.{
        .name = "ghostel-target-check",
        .root_module = target_check_mod,
    });

    const check = b.step("check", "Check that the loader and target modules compile");
    check.dependOn(&loader_check_obj.step);
    check.dependOn(&target_check_obj.step);
    if (target_os == .windows) {
        const conpty_check_mod = b.createModule(.{
            .root_source_file = b.path(conptyModuleSourcePath()),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        addLoaderIncludes(conpty_check_mod, emacs_include);
        conpty_check_mod.addImport("emacs", emacs_mod);
        const conpty_check_obj = b.addObject(.{
            .name = "conpty-module-check",
            .root_module = conpty_check_mod,
        });
        check.dependOn(&conpty_check_obj.step);
    }

    const loader_test_mod = b.createModule(.{
        .root_source_file = b.path(dynLoaderModuleSourcePath()),
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
    if (target_os == .windows) {
        addWindowsRuntimeLibraries(b, loader_tests, target.result);
    }

    const target_test_mod = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addRealModuleIncludes(b, target_test_mod, emacs_include);
    target_test_mod.addImport("emacs", emacs_mod);
    target_test_mod.addImport("dyn_loader_abi", dyn_loader_abi_mod);
    target_test_mod.linkLibrary(ghostty_dep.artifact("ghostty-vt-static"));
    const target_tests = b.addTest(.{
        .root_module = target_test_mod,
    });
    if (target_os == .windows) {
        addWindowsRuntimeLibraries(b, target_tests, target.result);
    }

    const run_loader_tests = b.addRunArtifact(loader_tests);
    const run_target_tests = b.addRunArtifact(target_tests);
    const test_step = b.step("test", "Run Zig unit tests");
    test_step.dependOn(&run_loader_tests.step);
    test_step.dependOn(&run_target_tests.step);
    if (target_os == .windows) {
        const conpty_test_mod = b.createModule(.{
            .root_source_file = b.path(conptyModuleSourcePath()),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        addLoaderIncludes(conpty_test_mod, emacs_include);
        conpty_test_mod.addImport("emacs", emacs_mod);
        const conpty_tests = b.addTest(.{
            .root_module = conpty_test_mod,
        });
        addWindowsRuntimeLibraries(b, conpty_tests, target.result);
        const run_conpty_tests = b.addRunArtifact(conpty_tests);
        test_step.dependOn(&run_conpty_tests.step);
    }
}

fn addLoaderIncludes(mod: *std.Build.Module, emacs_include: std.Build.LazyPath) void {
    mod.addSystemIncludePath(emacs_include);
}

fn addRealModuleIncludes(
    b: *std.Build,
    mod: *std.Build.Module,
    emacs_include: std.Build.LazyPath,
) void {
    addLoaderIncludes(mod, emacs_include);
    mod.addIncludePath(b.path("vendor/ghostty/include"));
}

fn resolveEmacsIncludePath(b: *std.Build) std.Build.LazyPath {
    return emacs_util_mods.resolveEmacsIncludePath(b);
}

fn resolveEmacsIncludeSource(
    emacs_include_dir: ?[]const u8,
    emacs_source_dir: ?[]const u8,
) EmacsIncludeSource {
    return emacs_util_mods.resolveEmacsIncludeSource(emacs_include_dir, emacs_source_dir);
}

fn vendoredEmacsIncludeDir() []const u8 {
    return vendored_emacs_include_dir;
}

fn dynLoaderAbiSourcePath() []const u8 {
    return "vendor/emacs-util-mods/src/dyn-loader/abi.zig";
}

fn dynLoaderModuleSourcePath() []const u8 {
    return "vendor/emacs-util-mods/src/dyn-loader/module.zig";
}

fn conptyModuleSourcePath() []const u8 {
    return "vendor/emacs-util-mods/src/conpty/module.zig";
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

test "dyn-loader sources come from emacs-util-mods submodule" {
    try std.testing.expectEqualStrings(
        "vendor/emacs-util-mods/src/dyn-loader/abi.zig",
        dynLoaderAbiSourcePath(),
    );
    try std.testing.expectEqualStrings(
        "vendor/emacs-util-mods/src/dyn-loader/module.zig",
        dynLoaderModuleSourcePath(),
    );
}

test "conpty source comes from emacs-util-mods submodule" {
    try std.testing.expectEqualStrings(
        "vendor/emacs-util-mods/src/conpty/module.zig",
        conptyModuleSourcePath(),
    );
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
