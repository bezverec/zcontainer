//! A stand-in for the Apple `container` CLI, used by the tests.
//!
//! It does two things: serve fixture JSON for the list subcommands, and record
//! the argv it was invoked with so a test can assert exactly which command the
//! program decided to run. That second part is the point — no amount of unit
//! testing catches a `delete` that forgets `--force`, or an action wired to
//! the wrong subcommand.
//!
//! Every invocation appends its argv to `log_name` in the working directory,
//! one line per call. The path is fixed rather than configurable because a
//! test's `Io` is created with an empty environment, so the child would never
//! see a variable the test tried to set.
//!
//! Failure paths are not simulated here — a test that wants a non-zero exit
//! points `cli.exe` at `/usr/bin/false`, which is simpler and needs no flag.

const std = @import("std");

// Supplied by build.zig as named imports; see the comment there.
const containers = @embedFile("containers.json");
const images = @embedFile("images.json");
const volumes = @embedFile("volumes.json");
const networks = @embedFile("networks.json");
const stats = @embedFile("stats.json");
const df = @embedFile("df.json");

/// Kept in step with `Harness.log_name` in src/app.zig.
pub const log_name = "zc-fake-invocations.log";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    const args = if (argv.len > 1) argv[1..] else &.{};

    try recordInvocation(arena, io, args);

    var out_buf: [64 * 1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out.interface;
    try w.writeAll(responseFor(args));
    try w.flush();
}

/// Appends one line per invocation. Rewrites the whole file rather than
/// seeking: the log only ever holds a handful of lines per test.
fn recordInvocation(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    var log: std.Io.Writer.Allocating = .init(arena);
    if (cwd.readFileAlloc(io, log_name, arena, .limited(1 << 20))) |previous| {
        try log.writer.writeAll(previous);
    } else |_| {}

    for (args, 0..) |arg, i| {
        if (i > 0) try log.writer.writeByte(' ');
        try log.writer.writeAll(arg);
    }
    try log.writer.writeByte('\n');

    try cwd.writeFile(io, .{ .sub_path = log_name, .data = log.writer.buffered() });
}

fn responseFor(args: []const []const u8) []const u8 {
    if (args.len == 0) return "";
    const first = args[0];

    if (eq(first, "list")) return containers;
    if (eq(first, "stats")) return stats;
    if (eq(first, "system")) {
        if (args.len > 1 and eq(args[1], "df")) return df;
        if (args.len > 1 and eq(args[1], "status")) return "FIELD    VALUE\nstatus   running\n";
        return "";
    }
    if (args.len > 1 and eq(args[1], "list")) {
        if (eq(first, "image")) return images;
        if (eq(first, "volume")) return volumes;
        if (eq(first, "network")) return networks;
    }
    if (eq(first, "logs")) return "line one\nline two\n";

    // Actions (start/stop/kill/delete/prune) succeed silently, as the real
    // CLI mostly does.
    return "";
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
