const std = @import("std");

const TargetConfig = struct {
    query: std.Target.Query,
    suffix: []const u8,
};

const release_targets = [_]TargetConfig{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .suffix = "x86_64-linux" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux }, .suffix = "aarch64-linux" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .suffix = "x86_64-windows" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = compileStep(b, target, optimize, "logsearch");
    b.installArtifact(exe);

    // release
    const release = b.step("release", "Build compressed release binaries for all supported platforms");
    releasebuild(b, release);

    // native
    const native = b.step("native", "Build an optimized, compressed release binary for the host");
    native.dependOn(nativebuild(b));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = compileModule(b, target, optimize),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn releasebuild(b: *std.Build, release: *std.Build.Step) void {
    const zupx = b.dependency("zupx", .{
        .optimize = std.builtin.OptimizeMode.fast,
        .target = b.graph.host,
    });

    for (release_targets) |config| {
        const target = b.resolveTargetQuery(config.query);
        const exe_name = b.fmt("logsearch-{s}", .{config.suffix});
        const install_name = if (config.query.os_tag == .windows)
            b.fmt("{s}.exe", .{exe_name})
        else
            exe_name;
        const exe = compileStep(b, target, std.builtin.OptimizeMode.fast, exe_name);
        const install_artifact = upxInstall(b, zupx, exe, install_name);
        release.dependOn(&install_artifact.step);
    }
}

/// Compresses the compiled executable with upx, installing only the packed
/// output so that the cached artifact is never modified in place.
fn upxInstall(
    b: *std.Build,
    zupx: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    exe_name: []const u8,
) *std.Build.Step.InstallFile {
    const upx_cmd = b.addRunArtifact(zupx.artifact("upx"));
    upx_cmd.addArg("--lzma");
    upx_cmd.addArg("-o");
    const packed_path = upx_cmd.addOutputFileArg(exe_name);
    upx_cmd.addFileArg(exe.getEmittedBin());
    return b.addInstallFileWithDir(packed_path, .bin, exe_name);
}

fn nativebuild(b: *std.Build) *std.Build.Step {
    const zupx = b.dependency("zupx", .{
        .optimize = std.builtin.OptimizeMode.fast,
        .target = b.graph.host,
    });

    const exe = compileStep(b, b.graph.host, std.builtin.OptimizeMode.fast, "logsearch");
    const install_name = if (b.graph.host.result.os.tag == .windows) "logsearch.exe" else "logsearch";
    const install_artifact = upxInstall(b, zupx, exe, install_name);
    return &install_artifact.step;
}

fn compileStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = exe_name,
        .root_module = compileModule(b, target, optimize),
    });
}

fn compileModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });

    // Expose the license and manual files to the executable as modules so that
    // they can be embedded at compile time without being copied into the
    // source tree.
    const embedded_files = b.addWriteFiles();
    _ = embedded_files.addCopyFile(b.path("LICENSE.txt"), "LICENSE.txt");
    _ = embedded_files.addCopyFile(b.path("README.md"), "README.md");
    const license_module = embeddedModule(b, embedded_files, "license.zig", "LICENSE.txt", target, optimize);
    const readme_module = embeddedModule(b, embedded_files, "readme.zig", "README.md", target, optimize);

    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = &.{
            .{ .name = "mvzr", .module = mvzr.module("mvzr") },
            .{ .name = "license", .module = license_module },
            .{ .name = "readme", .module = readme_module },
        },
    });
}

/// `@embedFile` cannot reach outside the module root, so expose an embedded
/// file as a generated module containing only a copy of that file.
fn embeddedModule(
    b: *std.Build,
    write_files: *std.Build.Step.WriteFile,
    module_name: []const u8,
    file_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = write_files.add(module_name, b.fmt(
            "pub const text = @embedFile(\"{s}\");\n",
            .{file_name},
        )),
        .target = target,
        .optimize = optimize,
    });
}
