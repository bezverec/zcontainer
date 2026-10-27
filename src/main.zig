//! zcontainer — a TUI for the Apple `container` CLI on macOS.

const std = @import("std");
const Allocator = std.mem.Allocator;

const build_options = @import("build_options");

const term = @import("term.zig");
const ui = @import("ui.zig");
const cli = @import("cli.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub const version = build_options.version;

/// How often the list reloads by itself while idle.
const auto_refresh_ms = 3000;

/// Shell started by the `e` key. `sh` is the one interpreter essentially every
/// Linux image ships, so it is the safe default.
const shell = "/bin/sh";

const ctrl_c = 0x03;
const ctrl_d = 0x04;
const ctrl_u = 0x15;

const usage =
    \\zcontainer — a TUI for the Apple container CLI
    \\
    \\usage: zcontainer [options]
    \\
    \\  -v, --version   print the version and exit
    \\  -h, --help      print this message and exit
    \\
    \\Run with no arguments to open the interface. Press ? inside it for the
    \\key bindings, or q to quit.
    \\
;

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    if (try handleArgs(init)) return;

    var terminal = term.Terminal.init(init.io) catch {
        std.debug.print("zcontainer: stdin is not a terminal\n", .{});
        return;
    };
    try terminal.enterRaw();
    defer terminal.leaveRaw();
    terminal.enterAltScreen();
    defer terminal.leaveAltScreen();

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);

    var screen: Screen = .{ .gpa = gpa, .terminal = &terminal, .frame = &frame };

    var app: App = .init(gpa, init.io);
    defer app.deinit();

    // The first refresh spawns several child processes, so show the splash
    // rather than starting on a blank screen.
    screen.drawSplash(terminal.size(), "loading…");
    app.setProgress("loading…", .{});
    app.refresh();

    var last_refresh = app_mod.monotonicMs(init.io);
    while (!app.quit) {
        const size = terminal.size();
        app.syncScroll(ui.bodyHeight(size));
        screen.draw(&app, size);

        // readKey blocks for at most ~100 ms (VTIME), which paces this loop.
        switch (terminal.readKey()) {
            .none => {},
            else => |key| {
                handleKey(&app, &screen, key, size);
                last_refresh = app_mod.monotonicMs(init.io);
            },
        }

        if (app.drainFollow() and app.follow_tail) {
            app.scrollToEnd(pagerHeight(size));
        }

        // Only main may touch the terminal, so the shell handover happens
        // here rather than inside the action that requested it.
        var target_buf: [256]u8 = undefined;
        if (app.takeShellRequest(&target_buf)) |target| {
            runShell(&terminal, &app, init.io, target);
            last_refresh = app_mod.monotonicMs(init.io);
        }

        const now = app_mod.monotonicMs(init.io);
        if (app.view == .list and now - last_refresh >= auto_refresh_ms) {
            app.refresh();
            last_refresh = now;
        }
    }
}

/// Drops out of the TUI, runs an interactive shell in the container with the
/// terminal handed over to the child, then restores the screen.
fn runShell(terminal: *term.Terminal, app: *App, io: std.Io, target: []const u8) void {
    // Following in the background would fight the child for the terminal.
    app.stopFollow();
    terminal.leaveAltScreen();
    terminal.leaveRaw();

    const banner = "\r\n\x1b[1mzcontainer\x1b[0m: shell in ";
    terminal.writeAll(banner);
    terminal.writeAll(target);
    terminal.writeAll(" — exit to return\r\n");

    const result = blk: {
        var child = std.process.spawn(io, .{
            .argv = &.{ cli.exe, "exec", "--interactive", "--tty", target, shell },
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch break :blk null;
        break :blk child.wait(io) catch null;
    };

    terminal.enterRaw() catch {};
    terminal.enterAltScreen();

    if (result) |term_status| {
        switch (term_status) {
            .exited => |code| if (code == 0)
                app.setStatus(false, "shell in {s} closed", .{target})
            else
                app.setStatus(true, "shell in {s} exited with code {d}", .{ target, code }),
            else => app.setStatus(true, "shell in {s} terminated", .{target}),
        }
    } else {
        app.setStatus(true, "could not open a shell in {s}", .{target});
    }
    app.refresh();
}

/// Handles the flags that print and exit. Returns true when the caller should
/// stop rather than open the interface.
fn handleArgs(init: std.process.Init) !bool {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return false;

    var out_buf: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const w = &out.interface;

    const arg = args[1];
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
        try w.print("zcontainer {s}\n", .{version});
    } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        try w.writeAll(usage);
    } else {
        try w.print("zcontainer: unknown argument '{s}'\n\n{s}", .{ arg, usage });
    }
    try w.flush();
    return true;
}

/// Rows the pager shows: header, title and key hints take the rest.
fn pagerHeight(size: term.Size) usize {
    return @max(1, @as(usize, size.rows) -| 3);
}

/// Owns the frame buffer and pushes completed frames to the terminal.
const Screen = struct {
    gpa: Allocator,
    terminal: *term.Terminal,
    frame: *std.ArrayList(u8),

    fn draw(self: *Screen, app: *const App, size: term.Size) void {
        self.frame.clearRetainingCapacity();
        var out: std.Io.Writer.Allocating = .fromArrayList(self.gpa, self.frame);
        ui.render(app, size, &out.writer) catch {};
        self.frame.* = out.toArrayList();
        self.terminal.writeAll(self.frame.items);
    }

    /// Paints a one-off status message before a blocking child process runs,
    /// so the UI does not appear frozen.
    fn drawBusy(self: *Screen, app: *App, size: term.Size, comptime fmt: []const u8, args: anytype) void {
        app.setProgress(fmt, args);
        self.draw(app, size);
    }

    fn drawSplash(self: *Screen, size: term.Size, note: []const u8) void {
        self.frame.clearRetainingCapacity();
        var out: std.Io.Writer.Allocating = .fromArrayList(self.gpa, self.frame);
        ui.renderSplash(size, note, &out.writer) catch {};
        self.frame.* = out.toArrayList();
        self.terminal.writeAll(self.frame.items);
    }
};

fn handleKey(app: *App, screen: *Screen, key: term.Key, size: term.Size) void {
    // Ctrl-C always quits: ISIG is off in raw mode, so it arrives as a byte.
    if (key == .ch and key.ch == ctrl_c) {
        app.quit = true;
        return;
    }

    switch (app.view) {
        .confirm => handleConfirmKey(app, screen, key, size),
        .prompt => handlePromptKey(app, screen, key, size),
        .help => handleHelpKey(app, key),
        .pager => handlePagerKey(app, key, size),
        .list => handleListKey(app, screen, key, size),
    }
}

fn handleConfirmKey(app: *App, screen: *Screen, key: term.Key, size: term.Size) void {
    switch (key) {
        .ch => |c| switch (c) {
            'y', 'Y' => {
                // Leave the confirm view before painting: the status line
                // gives the prompt priority, so the progress note would
                // otherwise stay hidden for the whole (blocking) command.
                app.view = .list;
                var buf: [512]u8 = undefined;
                screen.drawBusy(app, size, "{s}", .{app.pendingDescription(&buf)});
                app.runPending();
            },
            else => app.cancelPending(),
        },
        else => app.cancelPending(),
    }
}

/// The copy prompt: keystrokes are a path, not commands.
fn handlePromptKey(app: *App, screen: *Screen, key: term.Key, size: term.Size) void {
    switch (key) {
        .enter => {
            // The second enter runs `container copy`, which blocks.
            screen.drawBusy(app, size, "copying…", .{});
            app.submitPrompt();
        },
        .escape => app.cancelPrompt(),
        .backspace => app.promptBackspace(),
        .ch => |c| switch (c) {
            0x20...0x7e => app.promptAppend(c),
            else => {},
        },
        else => {},
    }
}

fn handleHelpKey(app: *App, key: term.Key) void {
    switch (key) {
        .escape => app.view = .list,
        .ch => |c| switch (c) {
            '?' => app.view = .list,
            'q' => app.quit = true,
            else => {},
        },
        else => {},
    }
}

fn handlePagerKey(app: *App, key: term.Key, size: term.Size) void {
    const height = pagerHeight(size);
    const half: isize = @intCast(@max(1, height / 2));
    const page: isize = @intCast(height);
    const to_top = std.math.minInt(isize) / 2;
    const to_end = std.math.maxInt(isize) / 2;

    switch (key) {
        .down => app.scrollPager(1, height),
        .up => app.scrollPager(-1, height),
        .page_down => app.scrollPager(page, height),
        .page_up => app.scrollPager(-page, height),
        .home => app.scrollPager(to_top, height),
        .end => app.scrollPager(to_end, height),
        .escape => {
            app.stopFollow();
            app.view = .list;
        },
        .ch => |c| switch (c) {
            'j' => app.scrollPager(1, height),
            'k' => app.scrollPager(-1, height),
            'g' => app.scrollPager(to_top, height),
            'G' => app.scrollPager(to_end, height),
            ctrl_d => app.scrollPager(half, height),
            ctrl_u => app.scrollPager(-half, height),
            'f' => if (app.isFollowing()) {
                app.stopFollow();
                app.setStatus(false, "stopped following", .{});
            } else {
                app.startFollow();
            },
            'q' => {
                app.stopFollow();
                app.quit = true;
            },
            else => {},
        },
        else => {},
    }
}

/// While a filter is being typed, keystrokes are text rather than commands.
/// Only the keys that edit or end the query are interpreted.
fn handleFilterKey(app: *App, key: term.Key) void {
    switch (key) {
        .enter => app.endFilter(),
        .escape => app.cancelFilter(),
        .backspace => app.filterBackspace(),
        .down, .up => app.endFilter(),
        .ch => |c| switch (c) {
            // Printable ASCII only; anything else would not survive the
            // round trip through a fixed byte buffer anyway.
            0x20...0x7e => app.filterAppend(c),
            else => {},
        },
        else => {},
    }
}

fn handleListKey(app: *App, screen: *Screen, key: term.Key, size: term.Size) void {
    if (app.filtering) return handleFilterKey(app, key);

    const height = ui.bodyHeight(size);
    const half: isize = @intCast(@max(1, height / 2));
    const page: isize = @intCast(height);

    switch (key) {
        .down => app.moveCursor(1),
        .up => app.moveCursor(-1),
        .page_down => app.moveCursor(page),
        .page_up => app.moveCursor(-page),
        .home => app.cursorTo(.first),
        .end => app.cursorTo(.last),
        .tab => app.nextTab(1),
        .back_tab => app.nextTab(-1),
        .left => app.nextTab(-1),
        .right => app.nextTab(1),
        .enter => app.showDetails(),
        // Escape backs out of whatever is narrowing the view: marks first,
        // since they are the more surprising thing to leave behind.
        .escape => if (app.markedCount(app.tab) > 0)
            app.clearMarks(app.tab)
        else
            app.cancelFilter(),
        .backspace, .none => {},
        .ch => |c| switch (c) {
            'q' => app.quit = true,
            'j' => app.moveCursor(1),
            'k' => app.moveCursor(-1),
            'g' => app.cursorTo(.first),
            'G' => app.cursorTo(.last),
            ctrl_d => app.moveCursor(half),
            ctrl_u => app.moveCursor(-half),
            '1'...'6' => app.switchTab(@fromBackingInt(@intCast(c - '1'))),
            ' ' => app.toggleMark(),
            '/' => app.beginFilter(),
            'o' => app.cycleSort(),
            'O' => app.toggleSortDirection(),
            '?' => app.view = .help,
            'r' => {
                screen.drawBusy(app, size, "refreshing…", .{});
                app.refresh();
            },
            'd' => app.request(app.deleteKind()),
            'P' => app.requestPrune(),
            's' => {
                screen.drawBusy(app, size, "starting…", .{});
                app.request(app.startKind());
            },
            'S' => app.request(app.stopKind()),
            'K' => app.requestKill(),
            // showLogs and requestShell report for themselves when the
            // current row is not a single container.
            'l' => {
                screen.drawBusy(app, size, "fetching logs…", .{});
                app.showLogs();
            },
            'e' => app.requestShell(),
            'c' => app.beginCopy(),
            else => {},
        },
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("cli.zig");
    _ = @import("app.zig");
    _ = @import("ui.zig");
}
