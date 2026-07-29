//! zcontainer-web — the same `container` wrapper behind a local HTTP server
//! instead of a terminal.
//!
//! The data layer (`cli.zig`) is shared verbatim with the TUI; this file only
//! adds transport. It binds to the loopback interface and nothing else.
//!
//! Security notes, because this server can start, stop and delete containers:
//!
//!   * It listens on 127.0.0.1 only, so nothing off-machine can reach it.
//!   * Every request must carry a random token minted at startup. Loopback
//!     ports are not an origin boundary — any page in the user's browser can
//!     POST to them — and the token is what a cross-site request cannot guess.
//!   * Requests carrying an `Origin` header from anywhere but this server are
//!     refused, which also blocks DNS rebinding.
//!   * Container environment variables are deliberately never serialised.
//!     They routinely hold credentials, and a browser is a far leakier place
//!     for them than a terminal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const cli = @import("cli.zig");

const page = @embedFile("assets/index.html");

const default_port = 7373;
const token_bytes = 24;

const usage =
    \\zcontainer-web — browser interface for the Apple container CLI
    \\
    \\usage: zcontainer-web [options]
    \\
    \\  -p, --port <n>  port to listen on (default 7373, 0 picks a free one)
    \\  -v, --version   print the version and exit
    \\  -h, --help      print this message and exit
    \\
    \\Listens on 127.0.0.1 only. The URL printed at startup carries a token
    \\that every request must present; without it the server refuses to talk.
    \\
;

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout.interface;

    const port = switch (try parseArgs(init, out)) {
        .exit => return,
        .listen => |p| p,
    };

    var token: [token_bytes * 2]u8 = undefined;
    makeToken(io, &token);

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true }) catch |err| {
        try out.print("zcontainer-web: cannot listen on 127.0.0.1:{d} ({t})\n", .{ port, err });
        try out.flush();
        return;
    };
    defer server.deinit(io);

    const bound = server.socket.address.ip4.port;
    try out.print(
        \\zcontainer-web {s}
        \\
        \\  http://127.0.0.1:{d}/?token={s}
        \\
        \\Open that URL. Press ctrl-c to stop the server.
        \\
    , .{ build_options.version, bound, &token });
    try out.flush();

    var context: Context = .{ .gpa = gpa, .io = io, .token = &token, .port = bound };

    while (true) {
        var stream = server.accept(io) catch continue;
        defer stream.close(io);
        serveConnection(&context, stream) catch {};
    }
}

const Context = struct {
    gpa: Allocator,
    io: Io,
    token: []const u8,
    port: u16,
};

const Args = union(enum) { exit, listen: u16 };

fn parseArgs(init: std.process.Init, out: *Io.Writer) !Args {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = default_port;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            return .exit;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try out.print("zcontainer-web {s}\n", .{build_options.version});
            try out.flush();
            return .exit;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= argv.len) {
                try out.writeAll("zcontainer-web: --port needs a value\n");
                try out.flush();
                return .exit;
            }
            port = std.fmt.parseInt(u16, argv[i], 10) catch {
                try out.print("zcontainer-web: '{s}' is not a port number\n", .{argv[i]});
                try out.flush();
                return .exit;
            };
        } else {
            try out.print("zcontainer-web: unknown argument '{s}'\n\n{s}", .{ arg, usage });
            try out.flush();
            return .exit;
        }
    }
    return .{ .listen = port };
}

fn makeToken(io: Io, out: *[token_bytes * 2]u8) void {
    var raw: [token_bytes]u8 = undefined;
    io.randomSecure(&raw) catch io.random(&raw);
    _ = std.fmt.bufPrint(out, "{x}", .{&raw}) catch unreachable;
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

fn serveConnection(ctx: *Context, stream: Io.net.Stream) !void {
    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(ctx.io, &recv_buf);
    var writer = stream.writer(ctx.io, &send_buf);

    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch return;

    // One request per connection: a single-threaded accept loop would
    // otherwise let one idle keep-alive connection starve the next.
    handleRequest(ctx, &request) catch |err| {
        request.respond("internal error\n", .{
            .status = .internal_server_error,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        }) catch {};
        return err;
    };
}

fn handleRequest(ctx: *Context, request: *std.http.Server.Request) !void {
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();

    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const query = if (path.len < target.len) target[path.len + 1 ..] else "";

    if (!originAllowed(ctx, request)) return respondText(request, .forbidden, "bad origin\n");

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        if (!tokenValid(ctx, queryParam(query, "token"))) {
            return respondText(request, .unauthorized, "missing or bad token\n");
        }
        const body = try std.fmt.allocPrint(
            arena.allocator(),
            "<script>window.ZC_TOKEN=\"{s}\";</script>\n{s}",
            .{ ctx.token, page },
        );
        return request.respond(body, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    }

    // Everything below is API surface and needs the token in a header, which
    // a cross-site form post cannot set.
    if (!tokenValid(ctx, headerValue(request, "x-zcontainer-token"))) {
        return respondText(request, .unauthorized, "missing or bad token\n");
    }

    if (std.mem.eql(u8, path, "/api/state")) return serveState(ctx, request, arena.allocator());
    if (std.mem.eql(u8, path, "/api/action")) return serveAction(ctx, request, arena.allocator(), query);
    if (std.mem.eql(u8, path, "/api/logs")) return serveLogs(ctx, request, arena.allocator(), query);

    return respondText(request, .not_found, "not found\n");
}

fn respondText(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

fn respondJson(request: *std.http.Server.Request, body: []const u8) !void {
    return request.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn headerValue(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

/// Constant-time comparison, so a token cannot be recovered a byte at a time.
fn tokenValid(ctx: *Context, given: ?[]const u8) bool {
    const value = given orelse return false;
    if (value.len != ctx.token.len) return false;
    var diff: u8 = 0;
    for (value, ctx.token) |a, b| diff |= a ^ b;
    return diff == 0;
}

/// A browser attaches `Origin` to cross-site requests. Accepting only our own
/// origin (or none at all, as with a direct navigation or curl) keeps other
/// pages, and rebound DNS names, from driving this server.
fn originAllowed(ctx: *Context, request: *std.http.Server.Request) bool {
    const origin = headerValue(request, "origin") orelse return true;
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "127.0.0.1", "localhost" }) |host| {
        const expected = std.fmt.bufPrint(&buf, "http://{s}:{d}", .{ host, ctx.port }) catch continue;
        if (std.mem.eql(u8, origin, expected)) return true;
    }
    return false;
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

/// Mirrors of the `cli` types, minus anything not worth handing to a browser.
/// Notably there is no `env`: container environments routinely carry
/// credentials.
const StateDto = struct {
    system: []const u8,
    containers: []const ContainerDto,
    images: []const cli.Image,
    volumes: []const cli.Volume,
    networks: []const cli.Network,
    stats: []const cli.Stat,
    disk: cli.DiskUsage,
    @"error": ?[]const u8,
};

const ContainerDto = struct {
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
    created: []const u8,
    started: []const u8,
    workdir: []const u8,
    executable: []const u8,
    stack: []const u8,
    ports: []const cli.Port,
    mounts: []const cli.Mount,
};

fn serveState(ctx: *Context, request: *std.http.Server.Request, arena: Allocator) !void {
    var err: ?[]const u8 = null;
    const containers = cli.listContainers(arena, ctx.io, &err) catch &.{};

    const dtos = try arena.alloc(ContainerDto, containers.len);
    for (containers, dtos) |c, *dto| dto.* = .{
        .id = c.id,
        .image = c.image,
        .state = c.state,
        .os = c.os,
        .arch = c.arch,
        .ip = c.ip,
        .gateway = c.gateway,
        .hostname = c.hostname,
        .cpus = c.cpus,
        .memory_bytes = c.memory_bytes,
        .created = c.created,
        .started = c.started,
        .workdir = c.workdir,
        .executable = c.executable,
        .stack = stackNameFor(c, containers),
        .ports = c.ports,
        .mounts = c.mounts,
    };

    const state: StateDto = .{
        .system = cli.systemStatus(arena, ctx.io),
        .containers = dtos,
        .images = cli.listImages(arena, ctx.io, &err) catch &.{},
        .volumes = cli.listVolumes(arena, ctx.io, &err) catch &.{},
        .networks = cli.listNetworks(arena, ctx.io, &err) catch &.{},
        .stats = cli.listStats(arena, ctx.io, &err) catch &.{},
        .disk = cli.diskUsage(arena, ctx.io),
        .@"error" = err,
    };

    var body: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(state, .{}, &body.writer);
    return respondJson(request, body.writer.buffered());
}

/// Same grouping rule as the TUI: a label if one names a stack, otherwise a
/// name prefix shared with at least one other container.
fn stackNameFor(c: cli.Container, all: []const cli.Container) []const u8 {
    if (c.stack_label.len > 0) return c.stack_label;
    const prefix = cli.namePrefix(c.id);
    if (prefix.len == 0) return "";
    var shared: usize = 0;
    for (all) |other| {
        if (std.mem.eql(u8, cli.namePrefix(other.id), prefix)) shared += 1;
    }
    return if (shared >= 2) prefix else "";
}

const Action = enum {
    start,
    stop,
    kill,
    @"delete-container",
    @"delete-image",
    @"delete-volume",
    @"delete-network",
    @"prune-containers",
    @"prune-images",
    @"prune-volumes",
    @"prune-networks",
};

fn serveAction(ctx: *Context, request: *std.http.Server.Request, arena: Allocator, query: []const u8) !void {
    if (request.head.method != .POST) return respondText(request, .method_not_allowed, "use POST\n");

    const kind_text = queryParam(query, "kind") orelse
        return respondText(request, .bad_request, "missing kind\n");
    const kind = std.meta.stringToEnum(Action, kind_text) orelse
        return respondText(request, .bad_request, "unknown kind\n");
    const target = queryParam(query, "target") orelse "";

    const argv: []const []const u8 = switch (kind) {
        .start => &.{ cli.exe, "start", target },
        .stop => &.{ cli.exe, "stop", target },
        .kill => &.{ cli.exe, "kill", target },
        .@"delete-container" => &.{ cli.exe, "delete", "--force", target },
        .@"delete-image" => &.{ cli.exe, "image", "delete", target },
        .@"delete-volume" => &.{ cli.exe, "volume", "delete", target },
        .@"delete-network" => &.{ cli.exe, "network", "delete", target },
        .@"prune-containers" => &.{ cli.exe, "prune" },
        .@"prune-images" => &.{ cli.exe, "image", "prune" },
        .@"prune-volumes" => &.{ cli.exe, "volume", "prune" },
        .@"prune-networks" => &.{ cli.exe, "network", "prune" },
    };

    if (target.len == 0 and !isPrune(kind)) return respondText(request, .bad_request, "missing target\n");

    const result = cli.exec(arena, ctx.io, argv, .limited(256 * 1024)) catch
        return respondText(request, .internal_server_error, "could not run container\n");

    var body: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .ok = result.ok,
        .message = firstLine(result.message()),
    }, .{}, &body.writer);
    return respondJson(request, body.writer.buffered());
}

fn isPrune(kind: Action) bool {
    return switch (kind) {
        .@"prune-containers", .@"prune-images", .@"prune-volumes", .@"prune-networks" => true,
        else => false,
    };
}

fn serveLogs(ctx: *Context, request: *std.http.Server.Request, arena: Allocator, query: []const u8) !void {
    const target = queryParam(query, "target") orelse
        return respondText(request, .bad_request, "missing target\n");

    const result = cli.exec(
        arena,
        ctx.io,
        &.{ cli.exe, "logs", "-n", "500", target },
        .limited(4 * 1024 * 1024),
    ) catch return respondText(request, .internal_server_error, "could not run container\n");

    var body: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .ok = result.ok,
        .text = if (result.ok) result.stdout else result.message(),
    }, .{}, &body.writer);
    return respondJson(request, body.writer.buffered());
}

fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return trimmed[0..end];
}

// ---------------------------------------------------------------------------
// Tests
//
// `std.http.Server` works on a Reader/Writer pair rather than a socket, so a
// whole request can be driven through the real routing by feeding it bytes.
// These are the checks that were previously only ever made by hand with curl,
// and they are the ones guarding a server that can delete containers.
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_token = "0123456789abcdef0123456789abcdef";

/// Runs one raw HTTP request through `handleRequest` and returns the raw
/// response. `cli.exe` is aimed at the fake so endpoints that shell out do
/// not touch a real daemon.
fn testRequest(gpa: Allocator, raw: []const u8) ![]u8 {
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const previous_exe = cli.exe;
    cli.exe = build_options.fake_container;
    defer cli.exe = previous_exe;

    // The fake logs its argv keyed on this process; these tests never read it,
    // so clear it rather than leaving a file in the working directory.
    defer {
        var name_buf: [64]u8 = undefined;
        const log = std.fmt.bufPrint(&name_buf, "/tmp/zc-fake-{d}.log", .{std.c.getpid()}) catch "";
        if (log.len > 0) Io.Dir.cwd().deleteFile(threaded.io(), log) catch {};
    }

    var ctx: Context = .{
        .gpa = gpa,
        .io = threaded.io(),
        .token = test_token,
        .port = 7373,
    };

    var reader: Io.Reader = .fixed(raw);
    var response: Io.Writer.Allocating = .init(gpa);
    errdefer response.deinit();

    var server: std.http.Server = .init(&reader, &response.writer);
    var request = try server.receiveHead();
    try handleRequest(&ctx, &request);
    // toOwnedSlice, not written(): the caller frees this, and the allocation
    // is longer than the bytes actually written.
    return response.toOwnedSlice();
}

fn expectStatus(gpa: Allocator, raw: []const u8, expected: []const u8) !void {
    const response = try testRequest(gpa, raw);
    defer gpa.free(response);
    testing.expect(std.mem.startsWith(u8, response, expected)) catch |err| {
        const end = std.mem.indexOfScalar(u8, response, '\r') orelse response.len;
        std.debug.print("expected status {s}, got {s}\n", .{ expected, response[0..end] });
        return err;
    };
}

test "the page is refused without a valid token" {
    const gpa = testing.allocator;
    try expectStatus(gpa, "GET / HTTP/1.1\r\nHost: 127.0.0.1:7373\r\n\r\n", "HTTP/1.1 401");
    try expectStatus(gpa, "GET /?token=wrong HTTP/1.1\r\nHost: x\r\n\r\n", "HTTP/1.1 401");
    // A token of the right length but wrong content must not pass either.
    try expectStatus(
        gpa,
        "GET /?token=ffffffffffffffffffffffffffffffff HTTP/1.1\r\nHost: x\r\n\r\n",
        "HTTP/1.1 401",
    );
}

test "the page is served with a valid token and carries it to the script" {
    const gpa = testing.allocator;
    const response = try testRequest(gpa, "GET /?token=" ++ test_token ++ " HTTP/1.1\r\nHost: x\r\n\r\n");
    defer gpa.free(response);

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, response, "text/html") != null);
    try testing.expect(std.mem.indexOf(u8, response, "window.ZC_TOKEN=\"" ++ test_token ++ "\"") != null);
}

test "api endpoints need the token in a header, not the query" {
    const gpa = testing.allocator;

    try expectStatus(gpa, "GET /api/state HTTP/1.1\r\nHost: x\r\n\r\n", "HTTP/1.1 401");
    // A cross-site form post can set a query string but not a header, so a
    // query-string token must not be accepted here.
    try expectStatus(gpa, "GET /api/state?token=" ++ test_token ++ " HTTP/1.1\r\nHost: x\r\n\r\n", "HTTP/1.1 401");
    try expectStatus(
        gpa,
        "GET /api/state HTTP/1.1\r\nHost: x\r\nx-zcontainer-token: " ++ test_token ++ "\r\n\r\n",
        "HTTP/1.1 200",
    );
}

test "a foreign origin is refused even with a valid token" {
    const gpa = testing.allocator;

    try expectStatus(
        gpa,
        "GET /api/state HTTP/1.1\r\nHost: x\r\nOrigin: https://evil.example\r\n" ++
            "x-zcontainer-token: " ++ test_token ++ "\r\n\r\n",
        "HTTP/1.1 403",
    );
    // Our own origin, in both spellings, is fine.
    for ([_][]const u8{ "http://127.0.0.1:7373", "http://localhost:7373" }) |origin| {
        var buf: [256]u8 = undefined;
        const raw = try std.fmt.bufPrint(
            &buf,
            "GET /api/state HTTP/1.1\r\nHost: x\r\nOrigin: {s}\r\nx-zcontainer-token: " ++
                test_token ++ "\r\n\r\n",
            .{origin},
        );
        try expectStatus(gpa, raw, "HTTP/1.1 200");
    }
}

test "actions refuse anything but POST" {
    const gpa = testing.allocator;
    const auth = "x-zcontainer-token: " ++ test_token ++ "\r\n";

    try expectStatus(
        gpa,
        "GET /api/action?kind=stop&target=web-api HTTP/1.1\r\nHost: x\r\n" ++ auth ++ "\r\n",
        "HTTP/1.1 405",
    );
    try expectStatus(
        gpa,
        "POST /api/action?kind=stop&target=web-api HTTP/1.1\r\nHost: x\r\n" ++ auth ++ "\r\n",
        "HTTP/1.1 200",
    );
    // An unknown action must be rejected rather than guessed at.
    try expectStatus(
        gpa,
        "POST /api/action?kind=rm-rf&target=web-api HTTP/1.1\r\nHost: x\r\n" ++ auth ++ "\r\n",
        "HTTP/1.1 400",
    );
    // A non-prune action with no target must not run against nothing.
    try expectStatus(
        gpa,
        "POST /api/action?kind=stop HTTP/1.1\r\nHost: x\r\n" ++ auth ++ "\r\n",
        "HTTP/1.1 400",
    );
}

test "unknown paths are not found" {
    const gpa = testing.allocator;
    try expectStatus(
        gpa,
        "GET /etc/passwd HTTP/1.1\r\nHost: x\r\nx-zcontainer-token: " ++ test_token ++ "\r\n\r\n",
        "HTTP/1.1 404",
    );
}

test "state never serialises container environments" {
    const gpa = testing.allocator;
    const response = try testRequest(
        gpa,
        "GET /api/state HTTP/1.1\r\nHost: x\r\nx-zcontainer-token: " ++ test_token ++ "\r\n\r\n",
    );
    defer gpa.free(response);

    // The fixture the fake serves carries a deliberately named secret.
    try testing.expect(std.mem.indexOf(u8, response, "must-not-be-shown") == null);
    try testing.expect(std.mem.indexOf(u8, response, "SECRET_TOKEN") == null);
    // But the data the page actually needs is there.
    try testing.expect(std.mem.indexOf(u8, response, "web-api") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"stack\":\"shop\"") != null);
}

test tokenValid {
    var ctx: Context = .{ .gpa = testing.allocator, .io = undefined, .token = "abcdef", .port = 1 };
    try testing.expect(tokenValid(&ctx, "abcdef"));
    try testing.expect(!tokenValid(&ctx, "abcdeg"));
    try testing.expect(!tokenValid(&ctx, "abcde"));
    try testing.expect(!tokenValid(&ctx, null));
    try testing.expect(!tokenValid(&ctx, ""));
}

test queryParam {
    try std.testing.expectEqualStrings("x", queryParam("token=x", "token").?);
    try std.testing.expectEqualStrings("b", queryParam("a=1&kind=b", "kind").?);
    try std.testing.expectEqual(@as(?[]const u8, null), queryParam("a=1", "token"));
}
