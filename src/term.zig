//! Terminal control: raw mode, alternate screen, window size, key decoding.

const std = @import("std");
const posix = std.posix;

pub const Size = struct {
    rows: u16 = 24,
    cols: u16 = 80,
};

/// Escape sequences. Kept as plain strings so frames can be built by
/// concatenating into a single buffer and written with one syscall.
pub const esc = struct {
    pub const alt_screen_on = "\x1b[?1049h";
    pub const alt_screen_off = "\x1b[?1049l";
    pub const cursor_hide = "\x1b[?25l";
    pub const cursor_show = "\x1b[?25h";
    pub const home = "\x1b[H";
    pub const clear_line = "\x1b[K";
    pub const clear_screen = "\x1b[2J";
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const reverse = "\x1b[7m";
};

/// 256-colour palette used across the UI.
pub const color = struct {
    pub const fg_dim = "\x1b[38;5;244m";
    pub const fg_text = "\x1b[38;5;252m";
    pub const accent = "\x1b[38;5;39m";
    pub const green = "\x1b[38;5;42m";
    pub const yellow = "\x1b[38;5;220m";
    pub const red = "\x1b[38;5;203m";
    pub const magenta = "\x1b[38;5;170m";
    pub const bg_sel = "\x1b[48;5;24m";
    pub const bg_bar = "\x1b[48;5;236m";
};

pub const Key = union(enum) {
    ch: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    enter,
    escape,
    tab,
    back_tab,
    backspace,
    /// The poll timed out without input; used to drive periodic refresh.
    none,
};

test "escape does not swallow the keystrokes after it" {
    // A pipe stands in for the terminal: readKey only ever reads bytes, and
    // this is the one part of term.zig that can be exercised without a tty.
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);

    var t: Terminal = .{
        .io = undefined,
        .orig = undefined,
        .in_fd = fds[0],
        .out = std.Io.File.stdout(),
    };

    // Escape immediately followed by typing, which is what a fast typist and
    // a pasted string both look like.
    _ = std.c.write(fds[1], "\x1b/ab", 4);
    // Real cursor keys must still decode, including the four-byte page keys.
    _ = std.c.write(fds[1], "\x1b[A\x1b[5~", 7);
    _ = std.c.close(fds[1]);

    try std.testing.expectEqual(Key.escape, t.readKey());
    try std.testing.expectEqual(Key{ .ch = '/' }, t.readKey());
    try std.testing.expectEqual(Key{ .ch = 'a' }, t.readKey());
    try std.testing.expectEqual(Key{ .ch = 'b' }, t.readKey());
    try std.testing.expectEqual(Key.up, t.readKey());
    try std.testing.expectEqual(Key.page_up, t.readKey());
    try std.testing.expectEqual(Key.none, t.readKey());
}

pub const Terminal = struct {
    io: std.Io,
    orig: posix.termios,
    in_fd: posix.fd_t,
    out: std.Io.File,
    raw: bool = false,
    alt: bool = false,
    /// One byte read while probing an escape sequence that turned out not to
    /// be part of one, handed back to the next `readKey`.
    pending: ?u8 = null,

    pub fn init(io: std.Io) !Terminal {
        const in = std.Io.File.stdin();
        return .{
            .io = io,
            .orig = try posix.tcgetattr(in.handle),
            .in_fd = in.handle,
            .out = std.Io.File.stdout(),
        };
    }

    /// Raw mode with VMIN=0/VTIME=1, so `readKey` returns `.none` after
    /// roughly 100 ms instead of blocking. That timeout is the app's tick.
    pub fn enterRaw(self: *Terminal) !void {
        var raw = self.orig;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;
        try posix.tcsetattr(self.in_fd, .FLUSH, raw);
        self.raw = true;
    }

    pub fn leaveRaw(self: *Terminal) void {
        if (!self.raw) return;
        posix.tcsetattr(self.in_fd, .FLUSH, self.orig) catch {};
        self.raw = false;
    }

    pub fn enterAltScreen(self: *Terminal) void {
        self.writeAll(esc.alt_screen_on ++ esc.cursor_hide);
        self.alt = true;
    }

    pub fn leaveAltScreen(self: *Terminal) void {
        if (!self.alt) return;
        // Clear before leaving. When the alternate screen works this wipes a
        // buffer that is about to be discarded anyway, but when the terminal
        // does not support it the frame was drawn on the primary screen and
        // would otherwise be left behind on exit.
        self.writeAll(esc.home ++ esc.clear_screen ++ esc.cursor_show ++ esc.alt_screen_off);
        self.alt = false;
    }

    /// Best-effort raw write; a failing terminal write is not worth aborting on.
    pub fn writeAll(self: *Terminal, bytes: []const u8) void {
        self.out.writeStreamingAll(self.io, bytes) catch {};
    }

    pub fn size(self: *Terminal) Size {
        var ws: posix.winsize = undefined;
        if (std.c.ioctl(self.out.handle, std.c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0) {
            return .{ .rows = ws.row, .cols = ws.col };
        }
        return .{};
    }

    pub fn readKey(self: *Terminal) Key {
        const first = self.nextByte() orelse return .none;
        return switch (first) {
            0x1b => self.readEscapeSeq(),
            '\r', '\n' => .enter,
            '\t' => .tab,
            127, 8 => .backspace,
            else => |c| .{ .ch = c },
        };
    }

    fn nextByte(self: *Terminal) ?u8 {
        if (self.pending) |byte| {
            self.pending = null;
            return byte;
        }
        var buf: [1]u8 = undefined;
        const n = posix.read(self.in_fd, &buf) catch return null;
        return if (n == 0) null else buf[0];
    }

    /// Called after a lone ESC byte. A bare ESC — nothing follows within the
    /// VTIME window — is the escape key itself.
    ///
    /// Reads one byte at a time and pushes back anything that turns out not to
    /// belong to the sequence. Reading two bytes eagerly and discarding them
    /// meant that pressing escape and then typing swallowed the next two
    /// keystrokes, which on the list view were commands.
    fn readEscapeSeq(self: *Terminal) Key {
        const introducer = self.nextByte() orelse return .escape;
        if (introducer != '[') {
            self.pending = introducer;
            return .escape;
        }

        const final = self.nextByte() orelse return .escape;
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => .back_tab,
            // "\x1b[5~" / "\x1b[6~" — consume the trailing '~'.
            '5', '6' => |c| blk: {
                _ = self.nextByte();
                break :blk if (c == '5') .page_up else .page_down;
            },
            else => .none,
        };
    }
};
