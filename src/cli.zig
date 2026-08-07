//! Thin wrapper around the Apple `container` CLI.
//!
//! Everything is fetched with `--format json` and decoded into the flat
//! structs below. All returned memory belongs to the arena passed in, which
//! the caller resets on every refresh.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The executable every command is dispatched through. A variable rather than
/// a constant so tests can point it at a stand-in; nothing else reassigns it.
pub var exe: []const u8 = "container";

/// Raw result of one CLI invocation. `ok` is false for a non-zero exit.
pub const Output = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    /// stderr if the command failed and said why, else stdout, else a stub.
    pub fn message(self: Output) []const u8 {
        const e = std.mem.trim(u8, self.stderr, " \t\r\n");
        if (e.len > 0) return e;
        const o = std.mem.trim(u8, self.stdout, " \t\r\n");
        if (o.len > 0) return o;
        return if (self.ok) "ok" else "command failed";
    }
};

pub fn exec(gpa: Allocator, io: Io, argv: []const []const u8, limit: Io.Limit) !Output {
    const res = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = limit,
        .stderr_limit = .limited(64 * 1024),
    });
    return .{
        .ok = switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        },
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

pub const Port = struct {
    host_address: []const u8,
    host_port: u16,
    container_port: u16,
    proto: []const u8,
};

pub const Mount = struct {
    source: []const u8,
    destination: []const u8,
};

/// Live resource usage for one running container, as reported by
/// `container stats`. `cpu_usec` is cumulative, so a CPU percentage only
/// exists relative to an earlier sample.
pub const Stat = struct {
    id: []const u8,
    cpu_usec: u64,
    memory_bytes: u64,
    memory_limit: u64,
    net_rx: u64,
    net_tx: u64,
    block_read: u64,
    block_write: u64,
    processes: u64,
};

/// Output of `container system df`.
pub const DiskUsage = struct {
    pub const Entry = struct {
        total: u64 = 0,
        active: u64 = 0,
        size_bytes: u64 = 0,
        reclaimable: u64 = 0,
    };

    images: Entry = .{},
    containers: Entry = .{},
    volumes: Entry = .{},
};

pub const Container = struct {
    id: []const u8,
    image: []const u8,
    state: []const u8,
    os: []const u8,
    arch: []const u8,
    ip: []const u8,
    gateway: []const u8,
    hostname: []const u8,
    cpus: u64,
    memory_bytes: u64,
    started: []const u8,
    created: []const u8,
    executable: []const u8,
    args: []const []const u8,
    workdir: []const u8,
    env: []const []const u8,
    ports: []const Port,
    mounts: []const Mount,
    /// Stack name taken from a label, or "" when the container carries none.
    /// Grouping by name prefix is decided later, once all containers are known.
    stack_label: []const u8,

    pub fn isRunning(self: Container) bool {
        return std.mem.eql(u8, self.state, "running");
    }
};

pub const Image = struct {
    /// Full reference, e.g. "docker.io/library/postgres:18".
    reference: []const u8,
    /// Reference with the registry prefix and tag stripped.
    name: []const u8,
    tag: []const u8,
    digest: []const u8,
    created: []const u8,
    os: []const u8,
    arch: []const u8,
};

pub const Volume = struct {
    name: []const u8,
    driver: []const u8,
    format: []const u8,
    size_bytes: u64,
    source: []const u8,
    created: []const u8,
};

pub const Network = struct {
    name: []const u8,
    mode: []const u8,
    subnet: []const u8,
    gateway: []const u8,
    created: []const u8,
};

// ---------------------------------------------------------------------------
// JSON mirrors
//
// Every field carries a default so that missing keys (a stopped container has
// no `status`, an untagged image no `variants`) decode rather than error.
// ---------------------------------------------------------------------------

const json_opts: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .duplicate_field_behavior = .use_last,
};

/// Named so that `listContainers` can fall back to a default instance when a
/// container has no attached network.
const RawContainerNetwork = struct {
    hostname: []const u8 = "",
    ipv4Address: []const u8 = "",
    ipv4Gateway: []const u8 = "",
};

const RawContainer = struct {
    id: []const u8 = "",
    configuration: struct {
        creationDate: []const u8 = "",
        image: struct {
            reference: []const u8 = "",
        } = .{},
        platform: struct {
            architecture: []const u8 = "",
            os: []const u8 = "",
        } = .{},
        resources: struct {
            cpus: u64 = 0,
            memoryInBytes: u64 = 0,
        } = .{},
        initProcess: struct {
            executable: []const u8 = "",
            arguments: []const []const u8 = &.{},
            workingDirectory: []const u8 = "",
            environment: []const []const u8 = &.{},
        } = .{},
        publishedPorts: []const struct {
            containerPort: u16 = 0,
            hostPort: u16 = 0,
            hostAddress: []const u8 = "",
            proto: []const u8 = "",
        } = &.{},
        mounts: []const struct {
            source: []const u8 = "",
            destination: []const u8 = "",
        } = &.{},
        /// Arbitrary key/value pairs; only a few keys are ever read, so this
        /// stays an untyped value tree.
        labels: std.json.Value = .null,
    } = .{},
    status: ?struct {
        state: []const u8 = "",
        startedDate: []const u8 = "",
        networks: []const RawContainerNetwork = &.{},
    } = null,
};

/// Named for the same reason as `RawContainerNetwork`: an image may list no
/// variants, in which case a default instance stands in.
const RawImageConfig = struct {
    os: []const u8 = "",
    architecture: []const u8 = "",
};

const RawImage = struct {
    id: []const u8 = "",
    configuration: struct {
        name: []const u8 = "",
        creationDate: []const u8 = "",
        descriptor: struct {
            digest: []const u8 = "",
        } = .{},
    } = .{},
    variants: []const struct {
        config: RawImageConfig = .{},
    } = &.{},
};

const RawVolume = struct {
    id: []const u8 = "",
    configuration: struct {
        name: []const u8 = "",
        driver: []const u8 = "",
        format: []const u8 = "",
        sizeInBytes: u64 = 0,
        source: []const u8 = "",
        creationDate: []const u8 = "",
    } = .{},
};

const RawNetwork = struct {
    id: []const u8 = "",
    configuration: struct {
        name: []const u8 = "",
        mode: []const u8 = "",
        creationDate: []const u8 = "",
    } = .{},
    status: ?struct {
        ipv4Gateway: []const u8 = "",
        ipv4Subnet: []const u8 = "",
    } = null,
};

/// Runs `argv` and returns its stdout, or null when the command could not be
/// run or failed. Errors are reported through `err_out` so the UI can show the
/// CLI's own message instead of a generic failure.
///
/// Kept separate from decoding so that every parser below can be tested
/// against fixture text without spawning anything.
fn run(arena: Allocator, io: Io, argv: []const []const u8, err_out: *?[]const u8) ?[]const u8 {
    const out = exec(arena, io, argv, .limited(16 * 1024 * 1024)) catch {
        err_out.* = "cannot run `container` — is the Apple container CLI installed and on PATH?";
        return null;
    };
    if (!out.ok) {
        err_out.* = out.message();
        return null;
    }
    return out.stdout;
}

/// Decodes a JSON array of `Raw`. An empty document is an empty list, not an
/// error: `container` prints nothing when it has nothing to report.
fn decode(
    comptime Raw: type,
    arena: Allocator,
    json: []const u8,
    err_out: *?[]const u8,
) []const Raw {
    const text = std.mem.trim(u8, json, " \t\r\n");
    if (text.len == 0) return &.{};
    return std.json.parseFromSliceLeaky([]const Raw, arena, text, json_opts) catch {
        err_out.* = "could not decode JSON from `container`";
        return &.{};
    };
}

pub fn listContainers(arena: Allocator, io: Io, err_out: *?[]const u8) ![]Container {
    const argv = &.{ exe, "list", "--all", "--format", "json" };
    const text = run(arena, io, argv, err_out) orelse return &.{};
    return parseContainers(arena, text, err_out);
}

pub fn parseContainers(arena: Allocator, json: []const u8, err_out: *?[]const u8) ![]Container {
    const raws = decode(RawContainer, arena, json, err_out);
    const list = try arena.alloc(Container, raws.len);

    for (raws, list) |raw, *c| {
        const cfg = raw.configuration;
        const net: RawContainerNetwork = if (raw.status) |s|
            (if (s.networks.len > 0) s.networks[0] else .{})
        else
            .{};

        const ports = try arena.alloc(Port, cfg.publishedPorts.len);
        for (cfg.publishedPorts, ports) |p, *dst| dst.* = .{
            .host_address = p.hostAddress,
            .host_port = p.hostPort,
            .container_port = p.containerPort,
            .proto = p.proto,
        };

        const mounts = try arena.alloc(Mount, cfg.mounts.len);
        for (cfg.mounts, mounts) |m, *dst| dst.* = .{
            .source = m.source,
            .destination = m.destination,
        };

        c.* = .{
            .id = raw.id,
            .image = cfg.image.reference,
            .state = if (raw.status) |s| s.state else "stopped",
            .os = cfg.platform.os,
            .arch = cfg.platform.architecture,
            .ip = stripCidr(net.ipv4Address),
            .gateway = net.ipv4Gateway,
            .hostname = net.hostname,
            .cpus = cfg.resources.cpus,
            .memory_bytes = cfg.resources.memoryInBytes,
            .started = if (raw.status) |s| s.startedDate else "",
            .created = cfg.creationDate,
            .executable = cfg.initProcess.executable,
            .args = cfg.initProcess.arguments,
            .workdir = cfg.initProcess.workingDirectory,
            .env = cfg.initProcess.environment,
            .ports = ports,
            .mounts = mounts,
            .stack_label = stackLabel(cfg.labels),
        };
    }

    std.mem.sort(Container, list, {}, struct {
        fn lt(_: void, a: Container, b: Container) bool {
            // Running containers first, then alphabetical.
            if (a.isRunning() != b.isRunning()) return a.isRunning();
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lt);
    return list;
}

pub fn listImages(arena: Allocator, io: Io, err_out: *?[]const u8) ![]Image {
    const argv = &.{ exe, "image", "list", "--format", "json" };
    const text = run(arena, io, argv, err_out) orelse return &.{};
    return parseImages(arena, text, err_out);
}

pub fn parseImages(arena: Allocator, json: []const u8, err_out: *?[]const u8) ![]Image {
    const raws = decode(RawImage, arena, json, err_out);
    const list = try arena.alloc(Image, raws.len);

    for (raws, list) |raw, *img| {
        const cfg = raw.configuration;
        const variant: RawImageConfig = if (raw.variants.len > 0) raw.variants[0].config else .{};
        const split = splitReference(cfg.name);
        img.* = .{
            .reference = cfg.name,
            .name = split.name,
            .tag = split.tag,
            .digest = shortDigest(cfg.descriptor.digest),
            .created = cfg.creationDate,
            .os = variant.os,
            .arch = variant.architecture,
        };
    }

    std.mem.sort(Image, list, {}, struct {
        fn lt(_: void, a: Image, b: Image) bool {
            return std.mem.lessThan(u8, a.reference, b.reference);
        }
    }.lt);
    return list;
}

pub fn listVolumes(arena: Allocator, io: Io, err_out: *?[]const u8) ![]Volume {
    const argv = &.{ exe, "volume", "list", "--format", "json" };
    const text = run(arena, io, argv, err_out) orelse return &.{};
    return parseVolumes(arena, text, err_out);
}

pub fn parseVolumes(arena: Allocator, json: []const u8, err_out: *?[]const u8) ![]Volume {
    const raws = decode(RawVolume, arena, json, err_out);
    const list = try arena.alloc(Volume, raws.len);
    for (raws, list) |raw, *v| {
        const cfg = raw.configuration;
        v.* = .{
            .name = if (cfg.name.len > 0) cfg.name else raw.id,
            .driver = cfg.driver,
            .format = cfg.format,
            .size_bytes = cfg.sizeInBytes,
            .source = cfg.source,
            .created = cfg.creationDate,
        };
    }
    return list;
}

pub fn listNetworks(arena: Allocator, io: Io, err_out: *?[]const u8) ![]Network {
    const argv = &.{ exe, "network", "list", "--format", "json" };
    const text = run(arena, io, argv, err_out) orelse return &.{};
    return parseNetworks(arena, text, err_out);
}

pub fn parseNetworks(arena: Allocator, json: []const u8, err_out: *?[]const u8) ![]Network {
    const raws = decode(RawNetwork, arena, json, err_out);
    const list = try arena.alloc(Network, raws.len);
    for (raws, list) |raw, *n| {
        const cfg = raw.configuration;
        n.* = .{
            .name = if (cfg.name.len > 0) cfg.name else raw.id,
            .mode = cfg.mode,
            .subnet = if (raw.status) |s| s.ipv4Subnet else "",
            .gateway = if (raw.status) |s| s.ipv4Gateway else "",
            .created = cfg.creationDate,
        };
    }
    return list;
}

const RawStat = struct {
    id: []const u8 = "",
    cpuUsageUsec: u64 = 0,
    memoryUsageBytes: u64 = 0,
    memoryLimitBytes: u64 = 0,
    networkRxBytes: u64 = 0,
    networkTxBytes: u64 = 0,
    blockReadBytes: u64 = 0,
    blockWriteBytes: u64 = 0,
    numProcesses: u64 = 0,
};

/// `--no-stream` takes a single sample and exits, which is what a polling UI
/// wants; the streaming form would never return.
pub fn listStats(arena: Allocator, io: Io, err_out: *?[]const u8) ![]Stat {
    const argv = &.{ exe, "stats", "--no-stream", "--format", "json" };
    const text = run(arena, io, argv, err_out) orelse return &.{};
    return parseStats(arena, text, err_out);
}

pub fn parseStats(arena: Allocator, json: []const u8, err_out: *?[]const u8) ![]Stat {
    const raws = decode(RawStat, arena, json, err_out);
    const list = try arena.alloc(Stat, raws.len);
    for (raws, list) |raw, *s| s.* = .{
        .id = raw.id,
        .cpu_usec = raw.cpuUsageUsec,
        .memory_bytes = raw.memoryUsageBytes,
        .memory_limit = raw.memoryLimitBytes,
        .net_rx = raw.networkRxBytes,
        .net_tx = raw.networkTxBytes,
        .block_read = raw.blockReadBytes,
        .block_write = raw.blockWriteBytes,
        .processes = raw.numProcesses,
    };

    // `container stats` does not guarantee an order, and rows that reshuffle
    // between refreshes would move the cursor onto a different container
    // under the user's hands.
    std.mem.sort(Stat, list, {}, struct {
        fn lt(_: void, a: Stat, b: Stat) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lt);
    return list;
}

const RawDiskEntry = struct {
    total: u64 = 0,
    active: u64 = 0,
    sizeInBytes: u64 = 0,
    reclaimable: u64 = 0,

    fn to(self: RawDiskEntry) DiskUsage.Entry {
        return .{
            .total = self.total,
            .active = self.active,
            .size_bytes = self.sizeInBytes,
            .reclaimable = self.reclaimable,
        };
    }
};

const RawDiskUsage = struct {
    images: RawDiskEntry = .{},
    containers: RawDiskEntry = .{},
    volumes: RawDiskEntry = .{},
};

/// `container system df` returns a single object rather than an array, so it
/// does not go through `fetch`.
pub fn diskUsage(arena: Allocator, io: Io) DiskUsage {
    const out = exec(arena, io, &.{ exe, "system", "df", "--format", "json" }, .limited(256 * 1024)) catch
        return .{};
    if (!out.ok) return .{};
    return parseDiskUsage(arena, out.stdout);
}

pub fn parseDiskUsage(arena: Allocator, json: []const u8) DiskUsage {
    const text = std.mem.trim(u8, json, " \t\r\n");
    if (text.len == 0) return .{};

    const raw = std.json.parseFromSliceLeaky(RawDiskUsage, arena, text, json_opts) catch return .{};
    return .{
        .images = raw.images.to(),
        .containers = raw.containers.to(),
        .volumes = raw.volumes.to(),
    };
}

/// Label keys that name the stack a container belongs to, most specific first.
const stack_label_keys = [_][]const u8{
    "com.docker.compose.project",
    "io.podman.compose.project",
    "zcontainer.stack",
    "com.apple.container.plugin",
};

fn stackLabel(labels: std.json.Value) []const u8 {
    if (labels != .object) return "";
    for (stack_label_keys) |key| {
        const value = labels.object.get(key) orelse continue;
        if (value == .string and value.string.len > 0) return value.string;
    }
    return "";
}

/// Reads `container system status`, which prints a FIELD/VALUE table rather
/// than JSON. Returns the value of the `status` row.
pub fn systemStatus(arena: Allocator, io: Io) []const u8 {
    const out = exec(arena, io, &.{ exe, "system", "status" }, .limited(64 * 1024)) catch return "unknown";
    if (!out.ok) return "not running";
    var lines = std.mem.splitScalar(u8, out.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "status")) continue;
        const rest = std.mem.trim(u8, line["status".len..], " \t\r");
        if (rest.len > 0) return rest;
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Small string helpers
// ---------------------------------------------------------------------------

/// "192.168.64.132/24" -> "192.168.64.132"
fn stripCidr(addr: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, addr, '/')) |i| addr[0..i] else addr;
}

/// "sha256:16e22a55…" -> "16e22a550f38"
fn shortDigest(digest: []const u8) []const u8 {
    const hex = if (std.mem.indexOfScalar(u8, digest, ':')) |i| digest[i + 1 ..] else digest;
    return hex[0..@min(hex.len, 12)];
}

/// Leading segment of a container name, up to the first '-' or '_'. Returns ""
/// when there is no separator or the segment is too short to name a stack.
pub fn namePrefix(id: []const u8) []const u8 {
    const sep = std.mem.indexOfAny(u8, id, "-_") orelse return "";
    return if (sep < 2) "" else id[0..sep];
}

const Reference = struct { name: []const u8, tag: []const u8 };

/// Splits "docker.io/library/postgres:18" into {"postgres", "18"}. The tag
/// separator is only a tag when it comes after the last '/', otherwise it is
/// a registry port.
fn splitReference(reference: []const u8) Reference {
    var name = reference;
    var tag: []const u8 = "latest";

    const last_slash = std.mem.lastIndexOfScalar(u8, reference, '/');
    const tail_start = if (last_slash) |i| i + 1 else 0;
    if (std.mem.lastIndexOfScalar(u8, reference[tail_start..], ':')) |rel| {
        const colon = tail_start + rel;
        name = reference[0..colon];
        tag = reference[colon + 1 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name = name[i + 1 ..];
    return .{ .name = name, .tag = tag };
}

test splitReference {
    const cases = .{
        .{ "docker.io/library/postgres:18", "postgres", "18" },
        .{ "shop-api:latest", "shop-api", "latest" },
        .{ "ghcr.io/apple/container-builder-shim/builder:0.12.0", "builder", "0.12.0" },
        .{ "alpine", "alpine", "latest" },
        .{ "localhost:5000/team/app", "app", "latest" },
    };
    inline for (cases) |c| {
        const got = splitReference(c[0]);
        try std.testing.expectEqualStrings(c[1], got.name);
        try std.testing.expectEqualStrings(c[2], got.tag);
    }
}

test shortDigest {
    try std.testing.expectEqualStrings("16e22a550f38", shortDigest("sha256:16e22a550f3863206a3f"));
    try std.testing.expectEqualStrings("abc", shortDigest("abc"));
}

// ---------------------------------------------------------------------------
// Decoding tests
//
// These run against fixtures rather than the live daemon, so they cover shapes
// this machine has never produced: a stopped container, one with no `status`
// at all, an untagged image, an empty list and malformed output.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return .init(testing.allocator);
}

test "parseContainers decodes running, stopped and status-less containers" {
    var arena = testArena();
    defer arena.deinit();
    var err: ?[]const u8 = null;

    const list = try parseContainers(arena.allocator(), @embedFile("testdata/containers.json"), &err);
    try testing.expectEqual(@as(?[]const u8, null), err);
    try testing.expectEqual(@as(usize, 3), list.len);

    // Running containers sort first, then alphabetically.
    try testing.expectEqualStrings("web-api", list[0].id);
    try testing.expect(list[0].isRunning());
    try testing.expectEqualStrings("192.168.64.10", list[0].ip);
    try testing.expectEqualStrings("shop", list[0].stack_label);
    try testing.expectEqual(@as(usize, 1), list[0].ports.len);
    try testing.expectEqual(@as(u16, 8080), list[0].ports[0].host_port);
    try testing.expectEqual(@as(usize, 1), list[0].mounts.len);

    // Stopped containers follow, alphabetically among themselves.
    // No `status` key at all must read as stopped rather than crash.
    const loner = list[1];
    try testing.expectEqualStrings("loner", loner.id);
    try testing.expectEqualStrings("stopped", loner.state);

    // An explicit stopped state, with no network attached.
    const db = list[2];
    try testing.expectEqualStrings("web-db", db.id);
    try testing.expectEqualStrings("stopped", db.state);
    try testing.expectEqualStrings("", db.ip);
}

test "unknown fields from a newer CLI are ignored, not fatal" {
    var arena = testArena();
    defer arena.deinit();
    var err: ?[]const u8 = null;

    // Shaped like a future `container` that has grown fields we know nothing
    // about — `maskedPaths` and `readonlyPaths` are the ones 1.2.1 added — at
    // every level we decode. Forward compatibility is what makes a CLI upgrade
    // safe, so it is worth pinning rather than assuming.
    const future =
        \\[{
        \\  "id": "web-api",
        \\  "somethingNew": {"nested": [1, 2, 3]},
        \\  "configuration": {
        \\    "id": "web-api",
        \\    "image": {"reference": "alpine:3.20", "unknownImageField": true},
        \\    "resources": {"cpus": 2, "memoryInBytes": 536870912, "gpus": 1},
        \\    "maskedPaths": ["/proc/kcore"],
        \\    "readonlyPaths": ["/proc/sys"],
        \\    "platform": {"architecture": "arm64", "os": "linux"}
        \\  },
        \\  "status": {"state": "running", "unknownStatusField": "x", "networks": []}
        \\}]
    ;

    const list = try parseContainers(arena.allocator(), future, &err);
    try testing.expectEqual(@as(?[]const u8, null), err);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("web-api", list[0].id);
    try testing.expectEqualStrings("alpine:3.20", list[0].image);
    try testing.expectEqualStrings("running", list[0].state);
    try testing.expectEqual(@as(u64, 2), list[0].cpus);
    try testing.expectEqual(@as(u64, 536870912), list[0].memory_bytes);
}

test "parseContainers accepts an empty list and blank output" {
    var arena = testArena();
    defer arena.deinit();
    var err: ?[]const u8 = null;

    const empty = try parseContainers(arena.allocator(), @embedFile("testdata/containers_empty.json"), &err);
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expectEqual(@as(?[]const u8, null), err);

    // `container` prints nothing when it has nothing to report.
    const blank = try parseContainers(arena.allocator(), "   \n", &err);
    try testing.expectEqual(@as(usize, 0), blank.len);
    try testing.expectEqual(@as(?[]const u8, null), err);
}

test "malformed JSON reports an error instead of failing" {
    var arena = testArena();
    defer arena.deinit();
    var err: ?[]const u8 = null;

    const list = try parseContainers(arena.allocator(), "{not json", &err);
    try testing.expectEqual(@as(usize, 0), list.len);
    try testing.expect(err != null);
}

test "parseImages splits references and tolerates missing variants" {
    var arena = testArena();
    defer arena.deinit();
    var err: ?[]const u8 = null;

    const list = try parseImages(arena.allocator(), @embedFile("testdata/images.json"), &err);
    try testing.expectEqual(@as(usize, 2), list.len);

    // Sorted by full reference, so docker.io comes before example.com.
    try testing.expectEqualStrings("postgres", list[0].name);
    try testing.expectEqualStrings("18", list[0].tag);
    try testing.expectEqualStrings("aaaabbbbcccc", list[0].digest);
    try testing.expectEqualStrings("arm64", list[0].arch);

    // A registry with a port must not be mistaken for a tag.
    try testing.expectEqualStrings("example.com:5000/team/web-api", list[1].reference);
    try testing.expectEqualStrings("web-api", list[1].name);
    try testing.expectEqualStrings("latest", list[1].tag);
    try testing.expectEqualStrings("", list[1].arch); // no variants in the fixture
}

test "parseStats sorts by id so the cursor cannot drift" {
    var arena = testArena();
    defer arena.deinit();
    var err: ?[]const u8 = null;

    // The fixture lists web-db first; the parser must reorder.
    const list = try parseStats(arena.allocator(), @embedFile("testdata/stats.json"), &err);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("web-api", list[0].id);
    try testing.expectEqualStrings("web-db", list[1].id);
    try testing.expectEqual(@as(u64, 1000000), list[0].cpu_usec);
}

test "parseVolumes and parseNetworks" {
    var arena = testArena();
    defer arena.deinit();
    var err: ?[]const u8 = null;

    const volumes = try parseVolumes(arena.allocator(), @embedFile("testdata/volumes.json"), &err);
    try testing.expectEqual(@as(usize, 1), volumes.len);
    try testing.expectEqualStrings("pgdata", volumes[0].name);
    try testing.expectEqual(@as(u64, 549755813888), volumes[0].size_bytes);

    const networks = try parseNetworks(arena.allocator(), @embedFile("testdata/networks.json"), &err);
    try testing.expectEqual(@as(usize, 1), networks.len);
    try testing.expectEqualStrings("192.168.64.0/24", networks[0].subnet);
    try testing.expectEqualStrings("nat", networks[0].mode);
}

test "parseDiskUsage" {
    var arena = testArena();
    defer arena.deinit();

    const disk = parseDiskUsage(arena.allocator(), @embedFile("testdata/df.json"));
    try testing.expectEqual(@as(u64, 82645798912), disk.images.size_bytes);
    try testing.expectEqual(@as(u64, 81035415552), disk.images.reclaimable);
    try testing.expectEqual(@as(u64, 3), disk.containers.total);
    try testing.expectEqual(@as(DiskUsage, .{}), parseDiskUsage(arena.allocator(), ""));
}

test namePrefix {
    try std.testing.expectEqualStrings("shop", namePrefix("shop-api"));
    try std.testing.expectEqualStrings("web", namePrefix("web_worker_1"));
    try std.testing.expectEqualStrings("", namePrefix("buildkit"));
    // Too short to be a meaningful group name.
    try std.testing.expectEqualStrings("", namePrefix("a-b"));
}

test stripCidr {
    try std.testing.expectEqualStrings("192.168.64.132", stripCidr("192.168.64.132/24"));
    try std.testing.expectEqualStrings("", stripCidr(""));
}
