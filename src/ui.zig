//! Frame rendering. Builds a full screen into one buffer so each frame is a
//! single write, which keeps the display flicker-free without a diffing layer.

const std = @import("std");
const Writer = std.Io.Writer;
const build_options = @import("build_options");

const term = @import("term.zig");
const cli = @import("cli.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;

const esc = term.esc;
const color = term.color;

/// Rows consumed by the chrome around the list body:
/// header, tab bar, column header, status line, key hints.
const chrome_rows = 5;
const min_rows = 8;
const min_cols = 40;

pub fn bodyHeight(size: term.Size) usize {
    return @max(1, @as(usize, size.rows) -| chrome_rows);
}

pub fn render(a: *const App, size: term.Size, w: *Writer) !void {
    try w.writeAll(esc.home);

    if (size.rows < min_rows or size.cols < min_cols) {
        try w.print("terminal too small ({d}x{d})", .{ size.cols, size.rows });
        try w.writeAll("\x1b[J");
        return;
    }

    switch (a.view) {
        .list, .confirm, .prompt => try renderList(a, size, w),
        .pager => try renderPager(a, size, w),
        .help => try renderHelp(a, size, w),
    }

    // Erase anything left over from a taller previous frame.
    try w.writeAll("\x1b[J");
}

// ---------------------------------------------------------------------------
// List view
// ---------------------------------------------------------------------------

fn renderList(a: *const App, size: term.Size, w: *Writer) !void {
    const width: usize = size.cols;
    const height = bodyHeight(size);
    const now = a.now;

    try renderHeader(a, width, w);
    try renderTabs(a, width, w);

    // Every row carries a fixed-width marker gutter, present whether or not
    // anything is marked, so the table never shifts sideways under the eye.
    const cols = columnsFor(a.tab, width -| mark_width);
    try renderColumnHeader(cols, width, w);

    const start = a.scroll[@intFromEnum(a.tab)];
    const selected = a.cursor[@intFromEnum(a.tab)];
    const n = a.itemCount();

    for (0..height) |row| {
        const screen_row = start + row;
        try w.writeAll("\r\n");
        if (screen_row >= n) {
            try w.writeAll(esc.clear_line);
            continue;
        }
        // Filtering and sorting mean the row on screen is not the index in
        // the underlying list.
        const i = a.sourceIndex(a.tab, screen_row) orelse {
            try w.writeAll(esc.clear_line);
            continue;
        };

        const is_selected = screen_row == selected;
        if (is_selected) try w.writeAll(color.bg_sel ++ esc.bold);

        if (a.isMarked(a.tab, i)) {
            if (!is_selected) try w.writeAll(color.accent);
            _ = try writeCounted(w, "▸ ", mark_width);
            if (!is_selected) try w.writeAll(esc.reset);
        } else {
            _ = try writeCounted(w, "  ", mark_width);
        }

        switch (a.tab) {
            .containers => try renderContainerRow(a.containers[i], cols, now, is_selected, w),
            .stacks => try renderStackRow(a.stacks[i], cols, is_selected, w),
            .images => try renderImageRow(a.images[i], cols, now, is_selected, w),
            .volumes => try renderVolumeRow(a.volumes[i], cols, now, is_selected, w),
            .networks => try renderNetworkRow(a.networks[i], cols, is_selected, w),
            .stats => try renderStatRow(a.stats[i], a.cpuPercent(i), cols, is_selected, w),
        }

        if (is_selected) {
            // Extend the highlight to the right edge.
            const used = mark_width + cols.total();
            if (width > used) try w.splatByteAll(' ', width - used);
            try w.writeAll(esc.reset);
        } else {
            try w.writeAll(esc.clear_line);
        }
    }

    try renderEmptyHint(a, width, height, w);
    try w.writeAll("\r\n");
    try renderStatusLine(a, width, w);
    try w.writeAll("\r\n");
    try renderKeyHints(a, width, w);
}

/// Draws the "no items" / "no data" message centred in the body area. Written
/// as an absolute-positioned overlay so it does not disturb the row loop.
fn renderEmptyHint(a: *const App, width: usize, height: usize, w: *Writer) !void {
    if (a.itemCount() != 0) return;

    // A filter that hides everything must say so, or an empty table reads as
    // "nothing exists" rather than "nothing matched".
    const msg = if (a.filter().len > 0) "no rows match the filter" else switch (a.tab) {
        .containers => "no containers",
        .stacks => "no stacks",
        .images => "no images",
        .volumes => "no volumes",
        .networks => "no networks",
        .stats => "no running containers",
    };
    const row = 3 + (height / 2);
    const col = if (width > msg.len) (width - msg.len) / 2 else 0;
    try w.print("\x1b[{d};{d}H{s}{s}{s}", .{ row, col + 1, color.fg_dim, msg, esc.reset });
    // Park the cursor back at the end of the body for the rows that follow.
    try w.print("\x1b[{d};1H", .{3 + height});
}

fn renderHeader(a: *const App, width: usize, w: *Writer) !void {
    const running = countRunning(a.containers);

    try w.writeAll(color.bg_bar);
    var used: usize = 0;
    used += try writeCounted(w, " ", 1);
    try w.writeAll(esc.bold ++ color.accent);
    used += try writeCounted(w, "zcontainer", 10);
    try w.writeAll(esc.reset ++ color.bg_bar ++ color.fg_dim);

    var buf: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, " v{s}  {d}/{d} running", .{
        build_options.version,
        running,
        a.containers.len,
    }) catch "";
    used += try writeCounted(w, summary, displayWidth(summary));

    // Right-aligned system status.
    const state_color = if (std.mem.eql(u8, a.system, "running")) color.green else color.yellow;
    const right = std.fmt.bufPrint(&buf, "system: {s} ", .{a.system}) catch "";
    if (width > used + right.len) {
        try w.splatByteAll(' ', width - used - right.len);
        try w.writeAll(state_color);
        _ = try writeCounted(w, right, right.len);
    }
    try w.writeAll(esc.reset);
}

fn renderTabs(a: *const App, width: usize, w: *Writer) !void {
    try w.writeAll("\r\n");
    var used: usize = 0;

    for (0..Tab.count) |i| {
        const tab: Tab = @enumFromInt(i);
        const count = a.countFor(tab);

        var buf: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, " {d} {s} {d} ", .{ i + 1, tab.title(), count }) catch continue;
        if (used + label.len > width) break;

        if (tab == a.tab) {
            try w.writeAll(esc.bold ++ color.accent ++ esc.reverse);
        } else {
            try w.writeAll(color.fg_dim);
        }
        used += try writeCounted(w, label, label.len);
        try w.writeAll(esc.reset);
    }
    if (width > used) try w.splatByteAll(' ', width - used);
    try w.writeAll(esc.clear_line);
}

// ---------------------------------------------------------------------------
// Columns
// ---------------------------------------------------------------------------

const Columns = struct {
    /// Header labels and widths, in draw order. The `flex` column absorbs
    /// whatever width is left over, up to `flex_max`.
    labels: [6][]const u8,
    widths: [6]usize,
    len: usize,
    /// Ceiling for the flexible column. Without one, a wide terminal stretches
    /// it far past anything the data needs and leaves a gap mid-table; the
    /// table simply ending short of the edge reads better.
    flex_max: usize,

    /// Total columns a rendered row occupies, including the gaps drawn
    /// between columns. Must match what the row renderers actually emit.
    fn total(self: Columns) usize {
        var sum: usize = 0;
        for (self.widths[0..self.len]) |x| sum += x;
        return sum + gap * (self.len - 1);
    }
};

const gap = 2;

/// Columns reserved at the left of every row for the mark indicator.
const mark_width = 2;

/// All four layouts place their flexible column third, after two identifying
/// columns that are always worth keeping.
const flex_column = 2;

const min_flex = 12;

/// Builds the column layout for a tab. Trailing columns are dropped until the
/// fixed part plus a usable flexible column fits, then the flexible column
/// absorbs whatever width is left. The result always satisfies
/// `total() <= width`.
fn columnsFor(tab: Tab, width: usize) Columns {
    var c: Columns = switch (tab) {
        .containers => .{
            .labels = .{ "NAME", "STATE", "IMAGE", "IP", "CPU", "MEMORY" },
            .widths = .{ 20, 10, 0, 17, 5, 10 },
            .len = 6,
            .flex_max = 54,
        },
        .stacks => .{
            .labels = .{ "STACK", "STATE", "CONTAINERS", "CPU", "MEMORY", "" },
            .widths = .{ 22, 12, 0, 6, 10, 0 },
            .len = 5,
            .flex_max = 26,
        },
        .stats => .{
            .labels = .{ "NAME", "CPU %", "MEMORY", "NET RX/TX", "BLOCK R/W", "PIDS" },
            .widths = .{ 20, 8, 0, 19, 19, 5 },
            .len = 6,
            .flex_max = 24,
        },
        .images => .{
            .labels = .{ "NAME", "TAG", "REFERENCE", "DIGEST", "ARCH", "CREATED" },
            .widths = .{ 22, 14, 0, 14, 8, 10 },
            .len = 6,
            .flex_max = 54,
        },
        .volumes => .{
            .labels = .{ "NAME", "DRIVER", "SOURCE", "FORMAT", "SIZE", "" },
            .widths = .{ 24, 10, 0, 8, 10, 0 },
            .len = 5,
            .flex_max = 64,
        },
        .networks => .{
            .labels = .{ "NAME", "MODE", "SUBNET", "GATEWAY", "", "" },
            .widths = .{ 20, 10, 0, 18, 0, 0 },
            .len = 4,
            .flex_max = 24,
        },
    };

    const flex = flex_column;
    // The flexible column and everything before it are never dropped.
    while (c.len > flex + 1 and fixedWidth(c, flex) + min_flex > width) c.len -= 1;

    // With the narrowest terminals the surviving fixed columns can still
    // overrun the line; shave the widest until the flexible column fits.
    while (fixedWidth(c, flex) + 1 > width) {
        const widest = widestFixed(c, flex) orelse break;
        c.widths[widest] -= 1;
    }

    c.widths[flex] = @max(@min(width -| fixedWidth(c, flex), c.flex_max), 1);
    return c;
}

/// Index of the widest shrinkable non-flexible column, if any.
fn widestFixed(c: Columns, flex: usize) ?usize {
    var best: ?usize = null;
    for (0..c.len) |i| {
        if (i == flex or c.widths[i] <= 1) continue;
        if (best == null or c.widths[i] > c.widths[best.?]) best = i;
    }
    return best;
}

/// Width of everything except the flexible column, gaps included.
fn fixedWidth(c: Columns, flex: usize) usize {
    var sum: usize = gap * (c.len - 1);
    for (0..c.len) |i| {
        if (i != flex) sum += c.widths[i];
    }
    return sum;
}

fn renderColumnHeader(cols: Columns, width: usize, w: *Writer) !void {
    try w.writeAll("\r\n" ++ color.fg_dim ++ esc.bold);
    // Indented past the marker gutter so headers line up with their cells.
    var used: usize = try writeCounted(w, "  ", mark_width);
    for (0..cols.len) |i| {
        used += try cell(w, cols.labels[i], cols.widths[i]);
        if (i + 1 < cols.len) used += try writeCounted(w, "  ", gap);
    }
    if (width > used) try w.splatByteAll(' ', width - used);
    try w.writeAll(esc.reset);
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

const Cell = struct {
    text: []const u8,
    /// Colour escape applied unless the row is selected, where the highlight
    /// background carries the emphasis instead.
    tint: []const u8 = color.fg_dim,
};

/// Writes the first `cols.len` cells at their assigned widths. Driving both
/// the layout and the row from `cols.len` is what keeps `Columns.total()`
/// honest when narrow terminals drop columns.
fn renderRow(w: *Writer, cells: []const Cell, cols: Columns, selected: bool) !void {
    for (0..cols.len) |i| {
        if (!selected) try w.writeAll(cells[i].tint);
        _ = try cell(w, cells[i].text, cols.widths[i]);
        if (i + 1 < cols.len) try w.splatByteAll(' ', gap);
    }
}

fn renderContainerRow(c: cli.Container, cols: Columns, now: i64, sel: bool, w: *Writer) !void {
    _ = now;
    var cpu_buf: [16]u8 = undefined;
    var mem_buf: [24]u8 = undefined;

    try renderRow(w, &.{
        .{ .text = c.id, .tint = color.fg_text },
        .{ .text = c.state, .tint = stateColor(c.state) },
        .{ .text = c.image },
        .{
            .text = if (c.ip.len > 0) c.ip else "-",
            .tint = if (c.ip.len > 0) color.magenta else color.fg_dim,
        },
        .{ .text = std.fmt.bufPrint(&cpu_buf, "{d}", .{c.cpus}) catch "" },
        .{ .text = app_mod.formatBytes(&mem_buf, c.memory_bytes) },
    }, cols, sel);
}

fn renderImageRow(img: cli.Image, cols: Columns, now: i64, sel: bool, w: *Writer) !void {
    var age_buf: [24]u8 = undefined;

    try renderRow(w, &.{
        .{ .text = img.name, .tint = color.fg_text },
        .{ .text = img.tag, .tint = color.yellow },
        .{ .text = img.reference },
        .{ .text = img.digest },
        .{ .text = img.arch },
        .{ .text = app_mod.formatAge(&age_buf, img.created, now) },
    }, cols, sel);
}

fn renderVolumeRow(v: cli.Volume, cols: Columns, now: i64, sel: bool, w: *Writer) !void {
    _ = now;
    var size_buf: [24]u8 = undefined;

    try renderRow(w, &.{
        .{ .text = v.name, .tint = color.fg_text },
        .{ .text = v.driver },
        .{ .text = v.source },
        .{ .text = v.format },
        .{ .text = app_mod.formatBytes(&size_buf, v.size_bytes) },
    }, cols, sel);
}

fn renderStackRow(stack: app_mod.Stack, cols: Columns, sel: bool, w: *Writer) !void {
    var members_buf: [64]u8 = undefined;
    var cpu_buf: [16]u8 = undefined;
    var mem_buf: [24]u8 = undefined;

    const state = if (stack.running == 0)
        "stopped"
    else if (stack.running == stack.members.len)
        "running"
    else
        "partial";

    try renderRow(w, &.{
        .{ .text = stack.name, .tint = color.fg_text },
        .{ .text = state, .tint = stackStateColor(stack) },
        .{
            .text = std.fmt.bufPrint(&members_buf, "{d} running / {d} total", .{
                stack.running,
                stack.members.len,
            }) catch "",
        },
        .{ .text = std.fmt.bufPrint(&cpu_buf, "{d}", .{stack.cpus}) catch "" },
        .{ .text = app_mod.formatBytes(&mem_buf, stack.memory_bytes) },
    }, cols, sel);
}

fn renderStatRow(s: cli.Stat, cpu_percent: f64, cols: Columns, sel: bool, w: *Writer) !void {
    var cpu_buf: [16]u8 = undefined;
    var mem_buf: [48]u8 = undefined;
    var used_buf: [24]u8 = undefined;
    var limit_buf: [24]u8 = undefined;
    var net_buf: [48]u8 = undefined;
    var rx_buf: [24]u8 = undefined;
    var tx_buf: [24]u8 = undefined;
    var block_buf: [48]u8 = undefined;
    var read_buf: [24]u8 = undefined;
    var write_buf: [24]u8 = undefined;
    var pids_buf: [16]u8 = undefined;

    try renderRow(w, &.{
        .{ .text = s.id, .tint = color.fg_text },
        .{
            .text = std.fmt.bufPrint(&cpu_buf, "{d:.2}", .{cpu_percent}) catch "",
            .tint = loadColor(cpu_percent),
        },
        .{
            .text = std.fmt.bufPrint(&mem_buf, "{s} / {s}", .{
                bytesOrZero(&used_buf, s.memory_bytes),
                bytesOrZero(&limit_buf, s.memory_limit),
            }) catch "",
            .tint = loadColor(memoryPercent(s)),
        },
        .{
            .text = std.fmt.bufPrint(&net_buf, "{s} / {s}", .{
                bytesOrZero(&rx_buf, s.net_rx),
                bytesOrZero(&tx_buf, s.net_tx),
            }) catch "",
        },
        .{
            .text = std.fmt.bufPrint(&block_buf, "{s} / {s}", .{
                bytesOrZero(&read_buf, s.block_read),
                bytesOrZero(&write_buf, s.block_write),
            }) catch "",
        },
        .{ .text = std.fmt.bufPrint(&pids_buf, "{d}", .{s.processes}) catch "" },
    }, cols, sel);
}

fn memoryPercent(s: cli.Stat) f64 {
    if (s.memory_limit == 0) return 0;
    return @as(f64, @floatFromInt(s.memory_bytes)) / @as(f64, @floatFromInt(s.memory_limit)) * 100;
}

/// Green below half, amber approaching the limit, red once saturated.
fn loadColor(percent: f64) []const u8 {
    if (percent >= 90) return color.red;
    if (percent >= 60) return color.yellow;
    return color.green;
}

fn stackStateColor(stack: app_mod.Stack) []const u8 {
    if (stack.running == 0) return color.fg_dim;
    if (stack.running == stack.members.len) return color.green;
    return color.yellow;
}

fn renderNetworkRow(n: cli.Network, cols: Columns, sel: bool, w: *Writer) !void {
    try renderRow(w, &.{
        .{ .text = n.name, .tint = color.fg_text },
        .{ .text = n.mode },
        .{ .text = n.subnet, .tint = color.magenta },
        .{ .text = n.gateway },
    }, cols, sel);
}

fn stateColor(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "running")) return color.green;
    if (std.mem.eql(u8, state, "stopped")) return color.fg_dim;
    return color.yellow;
}

// ---------------------------------------------------------------------------
// Status line and key hints
// ---------------------------------------------------------------------------

fn renderStatusLine(a: *const App, width: usize, w: *Writer) !void {
    if (a.view == .confirm) {
        const prompt = a.confirmPrompt();
        try w.writeAll(color.red ++ esc.bold);
        var used = try writeCounted(w, " ", 1);
        used += try writeCounted(w, prompt, prompt.len);
        try w.writeAll(esc.reset ++ color.fg_dim);
        used += try writeCounted(w, "  [y/N]", 7);
        if (width > used) try w.splatByteAll(' ', width - used);
        try w.writeAll(esc.reset);
        return;
    }

    // While typing, the status line becomes the prompt, with a block cursor so
    // it is obvious that keystrokes are being captured rather than obeyed.
    if (a.filtering) {
        return renderPrompt(w, width, "/", a.filter(), "enter to keep, esc to clear");
    }
    if (a.view == .prompt) {
        return renderPrompt(w, width, a.promptLabel(), a.promptInput(), "enter to continue, esc to cancel");
    }

    var disk_buf: [256]u8 = undefined;
    var hint_buf: [256]u8 = undefined;
    const msg = if (a.status_len > 0)
        a.status()
    else if (a.tab == .stats)
        // The Stats tab has no per-row message, so the otherwise idle status
        // line carries the `system df` summary instead.
        diskSummary(a, &disk_buf)
    else
        listHint(a, &hint_buf);

    try w.writeAll(if (a.status_is_error) color.red else color.fg_dim);
    var used = try writeCounted(w, " ", 1);
    used += try cell(w, msg, width -| 2);
    if (width > used) try w.splatByteAll(' ', width - used);
    try w.writeAll(esc.reset);
}

/// One line of text being typed: a label, what has been entered so far, a
/// block cursor, and a reminder of how to finish.
fn renderPrompt(w: *Writer, width: usize, label: []const u8, text: []const u8, hint: []const u8) !void {
    try w.writeAll(color.accent ++ esc.bold);
    var used = try writeCounted(w, " ", 1);
    used += try writeCounted(w, label, displayWidth(label));
    try w.writeAll(esc.reset ++ color.fg_text);
    used += try writeCounted(w, " ", 1);
    used += try writeCounted(w, text, displayWidth(text));
    try w.writeAll(esc.reverse);
    used += try writeCounted(w, " ", 1);
    try w.writeAll(esc.reset ++ color.fg_dim);
    used += try writeCounted(w, "  ", 2);
    used += try writeCounted(w, hint, displayWidth(hint));
    if (width > used) try w.splatByteAll(' ', width - used);
    try w.writeAll(esc.reset);
}

/// Describes the active filter and ordering, so a list that is hiding rows
/// never looks like the whole truth.
fn listHint(a: *const App, buf: []u8) []const u8 {
    // Marks change what every action key does, so they outrank the rest.
    const marks = a.markedCount(a.tab);
    if (marks > 0) {
        return std.fmt.bufPrint(buf, "{d} marked — actions apply to {s}, esc clears", .{
            marks,
            if (marks == 1) "it" else "them",
        }) catch "";
    }

    var sort_buf: [64]u8 = undefined;
    const sort = a.sortLabel(&sort_buf);
    const query = a.filter();
    const shown = a.countFor(a.tab);
    const total = a.totalFor(a.tab);

    if (query.len > 0 and sort.len > 0) {
        return std.fmt.bufPrint(buf, "filter \"{s}\" — {d} of {d} · {s}", .{ query, shown, total, sort }) catch "";
    }
    if (query.len > 0) {
        return std.fmt.bufPrint(buf, "filter \"{s}\" — {d} of {d}", .{ query, shown, total }) catch "";
    }
    return sort;
}

fn diskSummary(a: *const App, buf: []u8) []const u8 {
    var images_buf: [24]u8 = undefined;
    var reclaim_buf: [24]u8 = undefined;
    var containers_buf: [24]u8 = undefined;
    var volumes_buf: [24]u8 = undefined;

    return std.fmt.bufPrint(buf, "disk — images {s} ({s} reclaimable) · containers {s} · volumes {s}", .{
        bytesOrZero(&images_buf, a.disk.images.size_bytes),
        bytesOrZero(&reclaim_buf, a.disk.images.reclaimable),
        bytesOrZero(&containers_buf, a.disk.containers.size_bytes),
        bytesOrZero(&volumes_buf, a.disk.volumes.size_bytes),
    }) catch "";
}

/// `formatBytes` renders 0 as "" so empty table cells stay blank; in prose a
/// literal zero reads better.
fn bytesOrZero(buf: []u8, n: u64) []const u8 {
    return if (n == 0) "0 B" else app_mod.formatBytes(buf, n);
}

fn renderKeyHints(a: *const App, width: usize, w: *Writer) !void {
    const hints: []const [2][]const u8 = switch (a.view) {
        .confirm => &.{ .{ "y", "confirm" }, .{ "n/esc", "cancel" } },
        .prompt => &.{ .{ "type", "a path" }, .{ "↵", "continue" }, .{ "esc", "cancel" } },
        .list => if (a.filtering)
            &.{ .{ "type", "to filter" }, .{ "↵", "keep" }, .{ "esc", "clear" } }
        else
            listHints(a),
        .pager => if (a.isFollowing())
            &.{ .{ "↑↓ j/k", "scroll" }, .{ "G", "tail" }, .{ "f", "stop follow" }, .{ "esc", "back" } }
        else
            &.{ .{ "↑↓ j/k", "scroll" }, .{ "g/G", "top/end" }, .{ "f", "follow" }, .{ "esc", "back" } },
        .help => &.{ .{ "esc", "back" }, .{ "q", "quit" } },
    };

    try w.writeAll(color.bg_bar);
    if (hints.len == 0) {
        try w.splatByteAll(' ', width);
        try w.writeAll(esc.reset);
        return;
    }

    // The last hint is the way out of the current view. It is drawn against
    // the right edge and its width reserved up front, so that it survives on
    // a terminal too narrow for the whole bar rather than being the first
    // thing dropped.
    const exit_hint = hints[hints.len - 1];
    const reserved = hintWidth(exit_hint);

    var used: usize = 0;
    for (hints[0 .. hints.len - 1]) |h| {
        if (used + hintWidth(h) + reserved > width) break;
        used += try writeHint(w, h);
    }
    if (width > used + reserved) try w.splatByteAll(' ', width - used - reserved);
    if (width >= reserved) _ = try writeHint(w, exit_hint);
    try w.writeAll(esc.reset);
}

fn listHints(a: *const App) []const [2][]const u8 {
    return switch (a.tab) {
        .containers, .stats => &.{
            .{ "↑↓ j/k", "move" },
            .{ "space", "mark" },
            .{ "↵", "details" },
            .{ "/", "filter" },
            .{ "o", "sort" },
            .{ "s", "start" },
            .{ "S", "stop" },
            .{ "K", "kill" },
            .{ "d", "delete" },
            .{ "l", "logs" },
            .{ "e", "shell" },
            .{ "c", "copy" },
            .{ "P", "prune" },
            .{ "?", "help" },
            .{ "q", "quit" },
        },
        .stacks => &.{
            .{ "↑↓ j/k", "move" },
            .{ "space", "mark" },
            .{ "↵", "members" },
            .{ "/", "filter" },
            .{ "o", "sort" },
            .{ "s", "start all" },
            .{ "S", "stop all" },
            .{ "d", "delete all" },
            .{ "?", "help" },
            .{ "q", "quit" },
        },
        .images, .volumes, .networks => &.{
            .{ "↑↓ j/k", "move" },
            .{ "space", "mark" },
            .{ "↵", "details" },
            .{ "/", "filter" },
            .{ "o", "sort" },
            .{ "d", "delete" },
            .{ "P", "prune" },
            .{ "?", "help" },
            .{ "q", "quit" },
        },
    };
}

/// Columns one hint occupies: a leading space, the key, a space, the label
/// and a trailing space.
fn hintWidth(h: [2][]const u8) usize {
    return displayWidth(h[0]) + displayWidth(h[1]) + 3;
}

fn writeHint(w: *Writer, h: [2][]const u8) !usize {
    try w.writeAll(color.accent ++ esc.bold);
    var used = try writeCounted(w, " ", 1);
    used += try writeCounted(w, h[0], displayWidth(h[0]));
    try w.writeAll(esc.reset ++ color.bg_bar ++ color.fg_dim);
    used += try writeCounted(w, " ", 1);
    used += try writeCounted(w, h[1], displayWidth(h[1]));
    used += try writeCounted(w, " ", 1);
    return used;
}

// ---------------------------------------------------------------------------
// Logo
// ---------------------------------------------------------------------------

/// Box-drawing wordmark spelling "zcontainer", one glyph per letter:
///
///     z    c    o    n    t    a   i   n    e    r
///    ┌─┐  ┌─┐  ┌─┐  ┌┐┌  ┌┬┐  ┌─┐  ┬  ┌┐┌  ┌─┐  ┬─┐
///    ┌─┘  │    │ │  │││   │   ├─┤  │  │││  ├┤   ├┬┘
///    └─┘  └─┘  └─┘  ┘└┘   ┴   ┴ ┴  ┴  ┘└┘  └─┘  ┴└─
///
/// Every row must be exactly `logo_width` columns; a row that is one glyph
/// too wide shifts the letters after it out of alignment. A test checks this.
/// The rows carry no padding of their own — callers centre them.
const logo_word = [_][]const u8{
    "┌─┐┌─┐┌─┐┌┐┌┌┬┐┌─┐┬┌┐┌┌─┐┬─┐",
    "┌─┘│  │ ││││ │ ├─┤││││├┤ ├┬┘",
    "└─┘└─┘└─┘┘└┘ ┴ ┴ ┴┴┘└┘└─┘┴└─",
};

const logo_width = 28;
const tagline = "a TUI for Apple container";

fn writeCentered(w: *Writer, row: usize, width: usize, text: []const u8, tint: []const u8) !void {
    const text_width = displayWidth(text);
    const col = if (width > text_width) (width - text_width) / 2 else 0;
    try w.print("\x1b[{d};{d}H{s}{s}{s}", .{ row, col + 1, tint, text, esc.reset });
}

/// Full-screen splash, shown while the first refresh runs.
pub fn renderSplash(size: term.Size, note: []const u8, w: *Writer) !void {
    try w.writeAll(esc.home ++ "\x1b[2J");
    if (size.rows < logo_word.len + 4 or size.cols < logo_width) {
        try w.print("{s}{s}{s}", .{ color.accent, note, esc.reset });
        return;
    }

    // wordmark, blank, tagline, blank, note
    const block = logo_word.len + 4;
    const top = (@as(usize, size.rows) -| block) / 2 + 1;

    for (logo_word, 0..) |line, i| {
        try writeCentered(w, top + i, size.cols, line, esc.bold ++ color.accent);
    }

    var buf: [128]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&buf, "{s} · v{s}", .{ tagline, build_options.version }) catch tagline;
    try writeCentered(w, top + logo_word.len + 1, size.cols, subtitle, color.fg_dim);
    try writeCentered(w, top + logo_word.len + 3, size.cols, note, color.fg_dim);
}

// ---------------------------------------------------------------------------
// Pager and help
// ---------------------------------------------------------------------------

fn renderPager(a: *const App, size: term.Size, w: *Writer) !void {
    const width: usize = size.cols;
    // header + title + body + key hints
    const height = @max(1, @as(usize, size.rows) -| 3);

    try renderHeader(a, width, w);

    try w.writeAll("\r\n" ++ color.accent ++ esc.bold);
    var used = try writeCounted(w, " ", 1);
    const title = a.textTitle();
    used += try cell(w, title, @min(title.len, width -| 2));
    try w.writeAll(esc.reset ++ color.fg_dim);

    var pos_buf: [64]u8 = undefined;
    const shown = @min(a.text_scroll + height, a.lines.items.len);
    const pos = if (a.isFollowing())
        std.fmt.bufPrint(&pos_buf, "following · {d}/{d} ", .{ shown, a.lines.items.len }) catch ""
    else
        std.fmt.bufPrint(&pos_buf, "{d}/{d} ", .{ shown, a.lines.items.len }) catch "";
    if (width > used + pos.len) {
        try w.splatByteAll(' ', width - used - pos.len);
        _ = try writeCounted(w, pos, pos.len);
    }
    try w.writeAll(esc.reset);

    for (0..height) |row| {
        try w.writeAll("\r\n");
        const i = a.text_scroll + row;
        if (i >= a.lines.items.len) {
            try w.writeAll(esc.clear_line);
            continue;
        }
        try w.writeAll(color.fg_text);
        _ = try cell(w, a.lines.items[i], width);
        try w.writeAll(esc.reset);
    }

    try w.writeAll("\r\n");
    try renderKeyHints(a, width, w);
}

const help_text =
    \\  Navigation — the arrow keys work everywhere the vi keys do
    \\    ↑ ↓  or  j / k  move                 ← →             previous / next tab
    \\    home / end      first / last         g / G           first / last
    \\    pg up / pg dn   move a screen        ctrl-d / ctrl-u half a screen
    \\    1 … 6           select tab           tab / shift-tab cycle tabs
    \\
    \\  Containers and Stats tabs
    \\    s  start           S  stop           K  kill         d  delete
    \\    l  logs            e  shell          c  copy files    P  prune stopped
    \\
    \\  Stacks — containers grouped by label or shared name prefix
    \\    s  start all       S  stop all       d  delete all   enter  members
    \\
    \\  Images, Volumes and Networks tabs
    \\    d  delete selected                   P  prune unused
    \\
    \\  Log viewer
    \\    f  start / stop following            G  newest, re-attach to the tail
    \\
    \\  Marking rows for a bulk action
    \\    space           mark the row and step down; actions then apply to
    \\                    every mark instead of the cursor, and always confirm
    \\    esc             clear the marks
    \\
    \\  Filtering and ordering
    \\    /  filter the current tab; enter keeps it, esc clears it
    \\    o  step the sort column, past the last back to the natural order
    \\    O  reverse the sort direction
    \\
    \\  General
    \\    r  refresh now     ?  this help      q  quit         esc  clear filter
    \\
    \\  Destructive actions confirm on the status line: y proceeds, n cancels.
    \\  The list refreshes every three seconds.
;

fn renderHelp(a: *const App, size: term.Size, w: *Writer) !void {
    const width: usize = size.cols;
    const height = @max(1, @as(usize, size.rows) -| 3);

    try renderHeader(a, width, w);

    try w.writeAll("\r\n" ++ color.accent ++ esc.bold);
    const used = try writeCounted(w, " zcontainer help", 16);
    if (width > used) try w.splatByteAll(' ', width - used);
    try w.writeAll(esc.reset);

    // The wordmark is a nicety; drop it when the help itself would not fit.
    const help_lines = std.mem.count(u8, help_text, "\n") + 1;
    const show_logo = height >= help_lines + logo_word.len + 2 and width >= logo_width;

    var row: usize = 0;
    if (show_logo) {
        for (logo_word) |line| {
            try w.writeAll("\r\n" ++ esc.bold ++ color.accent);
            // Indented to sit under the help text's own margin.
            _ = try writeCounted(w, "  ", 2);
            _ = try cell(w, line, width -| 2);
            try w.writeAll(esc.reset);
            row += 1;
        }
        try w.writeAll("\r\n" ++ esc.clear_line);
        row += 1;
    }

    var it = std.mem.splitScalar(u8, help_text, '\n');
    while (row < height) : (row += 1) {
        try w.writeAll("\r\n");
        const line = it.next() orelse {
            try w.writeAll(esc.clear_line);
            continue;
        };
        try w.writeAll(color.fg_text);
        _ = try cell(w, line, width);
        try w.writeAll(esc.reset);
    }

    try w.writeAll("\r\n");
    try renderKeyHints(a, width, w);
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

fn countRunning(containers: []const cli.Container) usize {
    var n: usize = 0;
    for (containers) |c| {
        if (c.isRunning()) n += 1;
    }
    return n;
}

/// Writes `text` and returns the display width it consumed. Used where the
/// caller already knows the width and just needs the running total.
fn writeCounted(w: *Writer, text: []const u8, width: usize) !usize {
    try w.writeAll(text);
    return width;
}

/// Writes `text` padded or truncated to exactly `width` columns.
/// Truncation appends an ellipsis and never splits a UTF-8 sequence.
fn cell(w: *Writer, text: []const u8, width: usize) !usize {
    if (width == 0) return 0;
    const shown = displayWidth(text);
    if (shown <= width) {
        try writeSanitized(w, text);
        try w.splatByteAll(' ', width - shown);
        return width;
    }
    const cut = truncateAt(text, width - 1);
    try writeSanitized(w, text[0..cut]);
    try w.writeAll("…");
    // The ellipsis occupies one column but the truncation point may have
    // landed short of it, so pad the remainder.
    const drawn = displayWidth(text[0..cut]) + 1;
    if (drawn < width) try w.splatByteAll(' ', width - drawn);
    return width;
}

/// Writes `text` with every control character replaced by a single space.
///
/// Container logs and image metadata are untrusted input. A tab would advance
/// the cursor to the next tab stop and desynchronise the column accounting,
/// and a raw escape sequence could recolour or repaint the screen. Each
/// control byte becomes exactly one column, which is what `displayWidth`
/// already assumes.
fn writeSanitized(w: *Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte >= 0x20 and byte != 0x7f) continue;
        try w.writeAll(text[start..i]);
        try w.writeByte(' ');
        start = i + 1;
    }
    try w.writeAll(text[start..]);
}

/// Number of terminal columns `text` occupies, counting each UTF-8 sequence
/// as one column. Adequate for the ASCII-plus-symbols content shown here.
fn displayWidth(text: []const u8) usize {
    var n: usize = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Largest byte offset whose display width is at most `max_width` and which
/// falls on a UTF-8 boundary.
fn truncateAt(text: []const u8, max_width: usize) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (width + 1 > max_width) break;
        width += 1;
        i += @min(len, text.len - i);
    }
    return i;
}

/// Removes CSI escape sequences so a rendered frame can be compared as text.
fn stripAnsi(out: []u8, input: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != 0x1b) {
            out[n] = input[i];
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i < input.len and input[i] == '[') i += 1;
        while (i < input.len and (input[i] < 0x40 or input[i] > 0x7e)) i += 1;
        if (i < input.len) i += 1;
    }
    return out[0..n];
}

test "key hint bar keeps the exit hint at every width" {
    var frame: [4096]u8 = undefined;
    var plain: [4096]u8 = undefined;

    var app: App = .init(std.testing.allocator, undefined);
    defer app.deinit();
    app.view = .list;

    for (std.enums.values(Tab)) |tab| {
        app.tab = tab;
        var width: usize = min_cols;
        while (width <= 200) : (width += 7) {
            var w: Writer = .fixed(&frame);
            try renderKeyHints(&app, width, &w);
            const text = stripAnsi(&plain, w.buffered());

            // The bar fills its line exactly, and the way out is never the
            // hint that gets dropped when space runs short.
            try std.testing.expectEqual(width, displayWidth(text));
            try std.testing.expect(std.mem.endsWith(u8, text, "q quit "));
        }
    }
}

test "logo rows are all exactly logo_width columns" {
    // A row one glyph too wide shifts every letter after it, which is how the
    // wordmark's middle row was broken before.
    for (logo_word, 0..) |line, i| {
        errdefer std.debug.print("logo row {d}: {s}\n", .{ i, line });
        try std.testing.expectEqual(logo_width, displayWidth(line));
    }
}

test displayWidth {
    try std.testing.expectEqual(@as(usize, 3), displayWidth("abc"));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("…"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("ab…c"));
}

test truncateAt {
    try std.testing.expectEqual(@as(usize, 2), truncateAt("abcdef", 2));
    // Must not split the 3-byte ellipsis.
    try std.testing.expectEqual(@as(usize, 1), truncateAt("a…b", 1));
    try std.testing.expectEqual(@as(usize, 4), truncateAt("a…b", 2));
}

test "Columns.total matches the width a rendered row emits" {
    // A mismatch makes the selected row overflow the terminal width and wrap,
    // which shifts every subsequent frame by a line.
    var buf: [4096]u8 = undefined;
    for ([_]usize{ 40, 80, 100, 200 }) |width| {
        const cols = columnsFor(.containers, width);
        var w: std.Io.Writer = .fixed(&buf);
        try renderContainerRow(.{
            .id = "pf-app",
            .image = "docker.io/library/postgres:18",
            .state = "running",
            .os = "linux",
            .arch = "arm64",
            .ip = "192.168.64.2",
            .gateway = "",
            .hostname = "",
            .cpus = 4,
            .memory_bytes = 1073741824,
            .started = "",
            .created = "",
            .executable = "",
            .args = &.{},
            .workdir = "",
            .env = &.{},
            .ports = &.{},
            .mounts = &.{},
            .stack_label = "",
        }, cols, 0, true, &w);

        try std.testing.expectEqual(cols.total(), displayWidth(w.buffered()));
        try std.testing.expect(cols.total() <= width);
    }
}

test "column layout fits every tab at every supported width" {
    var width: usize = min_cols;
    while (width <= 400) : (width += 1) {
        for (std.enums.values(Tab)) |tab| {
            const cols = columnsFor(tab, width);
            try std.testing.expect(cols.len >= 1);
            try std.testing.expect(cols.total() <= width);
        }
    }
}

test "cell neutralises control characters without changing width" {
    var buf: [128]u8 = undefined;

    // A tab would otherwise jump to the next tab stop and break alignment.
    var w: Writer = .fixed(&buf);
    _ = try cell(&w, "a\tb", 6);
    try std.testing.expectEqualStrings("a b   ", w.buffered());

    // An embedded escape sequence must not reach the terminal as one.
    var w2: Writer = .fixed(&buf);
    _ = try cell(&w2, "x\x1b[31my", 8);
    try std.testing.expectEqualStrings("x [31my ", w2.buffered());
    try std.testing.expectEqual(@as(usize, 8), displayWidth(w2.buffered()));
}

test "cell pads and truncates to exact width" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    _ = try cell(&w, "ab", 5);
    try std.testing.expectEqualStrings("ab   ", w.buffered());

    var w2: Writer = .fixed(&buf);
    _ = try cell(&w2, "abcdef", 4);
    try std.testing.expectEqual(@as(usize, 4), displayWidth(w2.buffered()));
}
