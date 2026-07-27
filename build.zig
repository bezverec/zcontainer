const std = @import("std");

/// Single source of truth for the version: the manifest the package manager
/// already reads, rather than a constant that drifts out of step with it.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zcontainer",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Browser front end. Shares cli.zig with the TUI and adds only transport.
    const web_module = b.createModule(.{
        .root_source_file = b.path("src/web.zig"),
        .target = target,
        .optimize = optimize,
    });
    web_module.addOptions("build_options", options);

    const web_exe = b.addExecutable(.{
        .name = "zcontainer-web",
        .root_module = web_module,
    });
    b.installArtifact(web_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zcontainer");
    run_step.dependOn(&run_cmd.step);

    const run_web = b.addRunArtifact(web_exe);
    run_web.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_web.addArgs(args);

    const run_web_step = b.step("web", "Run zcontainer-web");
    run_web_step.dependOn(&run_web.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const web_tests = b.addTest(.{ .root_module = web_exe.root_module });
    const run_web_tests = b.addRunArtifact(web_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_web_tests.step);
}
