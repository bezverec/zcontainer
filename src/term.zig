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

pub const Terminal = struct {
    io: std.Io,
    orig: posix.termios,
    in_fd: posix.fd_t,
    out: std.Io.File,
    raw: bool = false,
    alt: bool = false,

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
        var buf: [8]u8 = undefined;
        const n = posix.read(self.in_fd, buf[0..1]) catch return .none;
        if (n == 0) return .none;

        return switch (buf[0]) {
            0x1b => self.readEscapeSeq(&buf),
            '\r', '\n' => .enter,
            '\t' => .tab,
            127, 8 => .backspace,
            else => |c| .{ .ch = c },
        };
    }

    /// Called after a lone ESC byte. A bare ESC (no follow-up within the
    /// VTIME window) is the escape key itself.
    fn readEscapeSeq(self: *Terminal, buf: []u8) Key {
        const n = posix.read(self.in_fd, buf[0..2]) catch return .escape;
        if (n < 2 or buf[0] != '[') return .escape;
        return switch (buf[1]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => .back_tab,
            // "\x1b[5~" / "\x1b[6~" — consume the trailing '~'.
            '5', '6' => |c| blk: {
                var tilde: [1]u8 = undefined;
                _ = posix.read(self.in_fd, &tilde) catch {};
                break :blk if (c == '5') .page_up else .page_down;
            },
            else => .none,
        };
    }
};
