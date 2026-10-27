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
        .link_libc = true,
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
        .link_libc = true,
    });
    web_module.addOptions("build_options", options);

    const web_exe = b.addExecutable(.{
        .name = "zcontainer-web",
        .root_module = web_module,
    });
    b.installArtifact(web_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run zcontainer");
    run_step.dependOn(&run_cmd.step);

    const run_web = b.addRunArtifact(web_exe);
    run_web.step.dependOn(b.getInstallStep());
    run_web.addPassthruArgs();

    const run_web_step = b.step("web", "Run zcontainer-web");
    run_web_step.dependOn(&run_web.step);

    // Stands in for the `container` CLI so the tests can assert which command
    // the program actually chose to run.
    const fake_module = b.createModule(.{
        .root_source_file = b.path("test/fake-container.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // @embedFile cannot reach outside a module's directory, so the fixtures
    // the fake serves are handed to it as named imports instead.
    for ([_][]const u8{
        "containers.json",
        "images.json",
        "volumes.json",
        "networks.json",
        "stats.json",
        "df.json",
    }) |fixture| {
        fake_module.addAnonymousImport(fixture, .{
            .root_source_file = b.path(b.fmt("src/testdata/{s}", .{fixture})),
        });
    }

    const fake = b.addExecutable(.{ .name = "fake-container", .root_module = fake_module });

    // The tests get their own module so they can be handed an extra option —
    // the path to the fake — without that path ending up in the real binary.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "version", version);
    test_options.addOptionPath("fake_container", fake.getEmittedBin());

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", test_options);

    const exe_tests = b.addTest(.{ .root_module = test_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const web_test_module = b.createModule(.{
        .root_source_file = b.path("src/web.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    web_test_module.addOptions("build_options", test_options);

    const web_tests = b.addTest(.{ .root_module = web_test_module });
    const run_web_tests = b.addRunArtifact(web_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_web_tests.step);
}
