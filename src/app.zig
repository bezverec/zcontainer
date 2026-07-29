//! Application state, data refresh, and the actions bound to keys.
//!
//! Rendering lives in `ui.zig`; this module never touches the terminal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");

pub const Tab = enum {
    containers,
    stacks,
    images,
    volumes,
    networks,
    stats,

    pub const count = @typeInfo(Tab).@"enum".fields.len;

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .containers => "Containers",
            .stacks => "Stacks",
            .images => "Images",
            .volumes => "Volumes",
            .networks => "Networks",
            .stats => "Stats",
        };
    }
};

/// A group of related containers. Apple's `container` has no compose-style
/// project concept, so membership is inferred: a label if one names a stack,
/// otherwise a shared name prefix ("pf-app" and "pf-db" form stack "pf").
pub const Stack = struct {
    name: []const u8,
    members: []const cli.Container,
    running: usize,
    cpus: u64,
    memory_bytes: u64,

    pub fn isRunning(self: Stack) bool {
        return self.running > 0;
    }
};

pub const View = enum {
    /// The table for the current tab.
    list,
    /// Scrollable text: inspect output or logs.
    pager,
    help,
    /// A yes/no prompt guarding a destructive action.
    confirm,
    /// A line of free text being typed, over the list.
    prompt,
};

/// A single-line text prompt over the list. Copying a file needs two paths,
/// so it runs as two consecutive steps rather than one cramped field.
const Prompt = struct {
    const Step = enum { copy_source, copy_destination };

    step: Step,
    input_buf: [512]u8 = undefined,
    input_len: usize = 0,
    /// The first path, kept while the second is typed.
    source_buf: [512]u8 = undefined,
    source_len: usize = 0,

    fn input(self: *const Prompt) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    fn source(self: *const Prompt) []const u8 {
        return self.source_buf[0..self.source_len];
    }

    fn setInput(self: *Prompt, text: []const u8) void {
        self.input_len = @min(text.len, self.input_buf.len);
        @memcpy(self.input_buf[0..self.input_len], text[0..self.input_len]);
    }
};

pub const ActionKind = enum {
    container_start,
    container_stop,
    container_kill,
    container_delete,
    image_delete,
    volume_delete,
    network_delete,
    /// Stack actions expand to one command per member at run time.
    stack_start,
    stack_stop,
    stack_delete,
    prune_containers,
    prune_images,
    prune_volumes,
    prune_networks,

    fn isStack(self: ActionKind) bool {
        return switch (self) {
            .stack_start, .stack_stop, .stack_delete => true,
            else => false,
        };
    }

    fn isPrune(self: ActionKind) bool {
        return switch (self) {
            .prune_containers, .prune_images, .prune_volumes, .prune_networks => true,
            else => false,
        };
    }

    /// The single-container action a stack action performs on each member.
    fn perMember(self: ActionKind) ActionKind {
        return switch (self) {
            .stack_start => .container_start,
            .stack_stop => .container_stop,
            .stack_delete => .container_delete,
            else => self,
        };
    }
};

/// What a queued action applies to. Stacks and marks both fan out to several
/// containers, but from different sources.
const Scope = enum { single, stack, marked };

const Pending = struct {
    kind: ActionKind,
    scope: Scope = .single,
    target_buf: [256]u8,
    target_len: usize,
    prompt_buf: [256]u8,
    prompt_len: usize,

    fn target(self: *const Pending) []const u8 {
        return self.target_buf[0..self.target_len];
    }
    fn prompt(self: *const Pending) []const u8 {
        return self.prompt_buf[0..self.prompt_len];
    }
};

/// Previous `cpuUsageUsec` reading for one container. CPU time is cumulative,
/// so a percentage only exists relative to an earlier sample.
const CpuSample = struct {
    id_buf: [256]u8 = undefined,
    id_len: usize = 0,
    cpu_usec: u64 = 0,
    at_ms: i64 = 0,

    fn id(self: *const CpuSample) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

/// A running `container logs --follow` whose output is appended to the pager.
const LogStream = struct {
    child: std.process.Child,
    id_buf: [256]u8 = undefined,
    id_len: usize = 0,

    fn id(self: *const LogStream) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    /// Owns every string in `containers`/`images`/`volumes`/`networks`.
    /// Reset wholesale on each refresh.
    arena: std.heap.ArenaAllocator,

    tab: Tab = .containers,
    view: View = .list,
    cursor: [Tab.count]usize = @splat(0),
    scroll: [Tab.count]usize = @splat(0),

    containers: []cli.Container = &.{},
    stacks: []Stack = &.{},
    images: []cli.Image = &.{},
    volumes: []cli.Volume = &.{},
    networks: []cli.Network = &.{},
    stats: []cli.Stat = &.{},
    /// CPU percentages parallel to `stats`, derived from `cpu_samples`.
    stats_cpu: []f64 = &.{},
    disk: cli.DiskUsage = .{},
    system: []const u8 = "unknown",
    /// Wall-clock seconds sampled at the last refresh; drives the age column.
    now: i64 = 0,

    status_buf: [512]u8 = undefined,
    status_len: usize = 0,
    status_is_error: bool = false,
    /// Set for progress notes ("loading…") that a completed refresh should
    /// clear. Action results are not transient, so they survive the refresh
    /// that immediately follows them.
    status_transient: bool = false,

    /// Pager contents. `lines` indexes into `text`, so `text` must be fully
    /// built before `lines` is populated.
    text: std.ArrayList(u8) = .empty,
    lines: std.ArrayList([]const u8) = .empty,
    text_title_buf: [256]u8 = undefined,
    text_title_len: usize = 0,
    text_scroll: usize = 0,

    pending: ?Pending = null,
    prompt: ?Prompt = null,
    quit: bool = false,

    /// Survives arena resets, so CPU deltas span refreshes.
    cpu_samples: std.ArrayList(CpuSample) = .empty,
    follow: ?LogStream = null,
    /// While true the pager stays pinned to the newest line.
    follow_tail: bool = true,
    /// Set when the user asks for a shell; `main` owns the terminal handover
    /// and clears this once the child has exited.
    exec_target_buf: [256]u8 = undefined,
    exec_target_len: usize = 0,

    /// Row indices into the underlying list, after filtering and sorting.
    /// Everything the UI shows and every action targets goes through here, so
    /// a cursor position always means the same row the user is looking at.
    visible: [Tab.count]std.ArrayList(usize) = @splat(.empty),
    /// One query per tab. A single shared filter would empty the Images tab
    /// because the user narrowed the container list, which is not what
    /// "filter the current tab" leads anyone to expect.
    filter_buf: [Tab.count][128]u8 = undefined,
    filter_len: [Tab.count]usize = @splat(0),
    /// True while keystrokes are being typed into the filter rather than
    /// being read as commands.
    filtering: bool = false,
    /// Column to order by, or null to keep the natural order each list
    /// arrives in (running containers first, images by reference).
    sort_column: [Tab.count]?u8 = @splat(null),
    sort_desc: [Tab.count]bool = @splat(false),

    /// Rows marked for a bulk action, held by name rather than index. An
    /// index would come to mean a different container as soon as the list
    /// reordered or something was created, and these outlive refreshes.
    marked: [Tab.count]std.ArrayList([]u8) = @splat(.empty),

    pub fn init(gpa: Allocator, io: Io) App {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    pub fn deinit(self: *App) void {
        self.stopFollow();
        self.cpu_samples.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        for (&self.visible) |*rows| rows.deinit(self.gpa);
        for (0..Tab.count) |i| {
            for (self.marked[i].items) |name| self.gpa.free(name);
            self.marked[i].deinit(self.gpa);
        }
        self.arena.deinit();
    }

    pub fn status(self: *const App) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn textTitle(self: *const App) []const u8 {
        return self.text_title_buf[0..self.text_title_len];
    }

    pub fn setStatus(self: *App, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.status_buf, fmt, args) catch blk: {
            // Message longer than the buffer: keep the prefix that fit.
            break :blk self.status_buf[0..];
        };
        self.status_len = written.len;
        self.status_is_error = is_error;
        self.status_transient = false;
    }

    /// A progress note shown while a blocking call runs. Cleared by the next
    /// successful refresh.
    pub fn setProgress(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.setStatus(false, fmt, args);
        self.status_transient = true;
    }

    fn clearStatus(self: *App) void {
        self.status_len = 0;
        self.status_is_error = false;
        self.status_transient = false;
    }

    pub fn confirmPrompt(self: *const App) []const u8 {
        return if (self.pending) |*p| p.prompt() else "";
    }

    /// Progress text for the queued action, e.g. "stop pf-db…".
    pub fn pendingDescription(self: *const App, buf: []u8) []const u8 {
        const p = if (self.pending) |*pending| pending else return "working…";
        return std.fmt.bufPrint(buf, "{s} {s}…", .{ verb(p.kind), p.target() }) catch "working…";
    }

    // -----------------------------------------------------------------------
    // Data
    // -----------------------------------------------------------------------

    /// Rows the user can actually see and act on, after filtering.
    pub fn itemCount(self: *const App) usize {
        return self.visible[@intFromEnum(self.tab)].items.len;
    }

    pub fn countFor(self: *const App, tab: Tab) usize {
        return self.visible[@intFromEnum(tab)].items.len;
    }

    /// Total rows a tab holds before filtering, for the "3 of 12" hint.
    pub fn totalFor(self: *const App, tab: Tab) usize {
        return switch (tab) {
            .containers => self.containers.len,
            .stacks => self.stacks.len,
            .images => self.images.len,
            .volumes => self.volumes.len,
            .networks => self.networks.len,
            .stats => self.stats.len,
        };
    }

    /// Translates a screen row into an index in the underlying list.
    pub fn sourceIndex(self: *const App, tab: Tab, row: usize) ?usize {
        const rows = self.visible[@intFromEnum(tab)].items;
        return if (row < rows.len) rows[row] else null;
    }

    fn selectedSource(self: *const App) ?usize {
        return self.sourceIndex(self.tab, self.cursor[@intFromEnum(self.tab)]);
    }

    // -----------------------------------------------------------------------
    // Filtering and ordering
    // -----------------------------------------------------------------------

    pub fn filter(self: *const App) []const u8 {
        return self.filterFor(self.tab);
    }

    pub fn filterFor(self: *const App, tab: Tab) []const u8 {
        const i = @intFromEnum(tab);
        return self.filter_buf[i][0..self.filter_len[i]];
    }

    pub fn beginFilter(self: *App) void {
        self.filtering = true;
    }

    pub fn endFilter(self: *App) void {
        self.filtering = false;
    }

    /// Leaves filter mode and drops this tab's query, restoring its full list.
    pub fn cancelFilter(self: *App) void {
        self.filtering = false;
        self.filter_len[@intFromEnum(self.tab)] = 0;
        self.rebuildVisible();
    }

    pub fn filterAppend(self: *App, byte: u8) void {
        const i = @intFromEnum(self.tab);
        if (self.filter_len[i] >= self.filter_buf[i].len) return;
        self.filter_buf[i][self.filter_len[i]] = byte;
        self.filter_len[i] += 1;
        self.rebuildVisible();
    }

    pub fn filterBackspace(self: *App) void {
        const i = @intFromEnum(self.tab);
        if (self.filter_len[i] == 0) return;
        self.filter_len[i] -= 1;
        self.rebuildVisible();
    }

    /// Steps the sort column forward, wrapping back to the natural order the
    /// list arrived in rather than sticking on the last column.
    pub fn cycleSort(self: *App) void {
        const i = @intFromEnum(self.tab);
        const columns = sortColumnCount(self.tab);
        self.sort_column[i] = if (self.sort_column[i]) |current|
            (if (current + 1 >= columns) null else current + 1)
        else
            0;
        self.rebuildVisible();
    }

    pub fn toggleSortDirection(self: *App) void {
        const i = @intFromEnum(self.tab);
        self.sort_desc[i] = !self.sort_desc[i];
        self.rebuildVisible();
    }

    pub fn sortLabel(self: *const App, buf: []u8) []const u8 {
        const i = @intFromEnum(self.tab);
        const column = self.sort_column[i] orelse return "";
        return std.fmt.bufPrint(buf, "sorted by {s} {s}", .{
            sortColumnName(self.tab, column),
            if (self.sort_desc[i]) "desc" else "asc",
        }) catch "";
    }

    /// Rebuilds every tab's row list from the current data, filter and order.
    /// Cheap enough to redo wholesale on each keystroke.
    fn rebuildVisible(self: *App) void {
        for (0..Tab.count) |i| {
            const tab: Tab = @enumFromInt(i);
            const needle = self.filterFor(tab);
            const rows = &self.visible[i];
            rows.clearRetainingCapacity();

            for (0..self.totalFor(tab)) |index| {
                if (needle.len > 0 and !self.matchesFilter(tab, index, needle)) continue;
                rows.append(self.gpa, index) catch break;
            }

            if (self.sort_column[i]) |column| {
                const ctx: SortContext = .{ .app = self, .tab = tab, .column = column, .desc = self.sort_desc[i] };
                std.mem.sort(usize, rows.items, ctx, SortContext.lessThan);
            }
        }
        self.clampCursor();
    }

    fn matchesFilter(self: *const App, tab: Tab, index: usize, needle: []const u8) bool {
        var buf: [512]u8 = undefined;
        const haystack = self.searchText(tab, index, &buf);
        return containsIgnoreCase(haystack, needle);
    }

    /// The text a row is matched against: enough to find something by name,
    /// image or state without matching on noise like timestamps.
    fn searchText(self: *const App, tab: Tab, index: usize, buf: []u8) []const u8 {
        return switch (tab) {
            .containers => blk: {
                const c = self.containers[index];
                break :blk std.fmt.bufPrint(buf, "{s} {s} {s} {s}", .{ c.id, c.image, c.state, c.ip }) catch c.id;
            },
            .stacks => blk: {
                const s = self.stacks[index];
                break :blk std.fmt.bufPrint(buf, "{s}", .{s.name}) catch s.name;
            },
            .images => blk: {
                const img = self.images[index];
                break :blk std.fmt.bufPrint(buf, "{s} {s}", .{ img.reference, img.digest }) catch img.reference;
            },
            .volumes => blk: {
                const v = self.volumes[index];
                break :blk std.fmt.bufPrint(buf, "{s} {s} {s}", .{ v.name, v.driver, v.source }) catch v.name;
            },
            .networks => blk: {
                const n = self.networks[index];
                break :blk std.fmt.bufPrint(buf, "{s} {s} {s}", .{ n.name, n.mode, n.subnet }) catch n.name;
            },
            .stats => self.stats[index].id,
        };
    }

    // -----------------------------------------------------------------------
    // Copying files
    // -----------------------------------------------------------------------

    pub fn promptInput(self: *const App) []const u8 {
        return if (self.prompt) |*p| p.input() else "";
    }

    pub fn promptLabel(self: *const App) []const u8 {
        const p = if (self.prompt) |*prompt| prompt else return "";
        return switch (p.step) {
            .copy_source => "copy from",
            .copy_destination => "copy to",
        };
    }

    /// Opens the copy prompt, pre-filling the container side so the common
    /// case — pulling a file out of the selected container — is a path away.
    pub fn beginCopy(self: *App) void {
        var p: Prompt = .{ .step = .copy_source };
        if (self.selectedContainer()) |c| {
            var buf: [512]u8 = undefined;
            p.setInput(std.fmt.bufPrint(&buf, "{s}:", .{c.id}) catch "");
        }
        self.prompt = p;
        self.view = .prompt;
    }

    pub fn promptAppend(self: *App, byte: u8) void {
        const p = if (self.prompt) |*prompt| prompt else return;
        if (p.input_len >= p.input_buf.len) return;
        p.input_buf[p.input_len] = byte;
        p.input_len += 1;
    }

    pub fn promptBackspace(self: *App) void {
        const p = if (self.prompt) |*prompt| prompt else return;
        if (p.input_len > 0) p.input_len -= 1;
    }

    pub fn cancelPrompt(self: *App) void {
        self.prompt = null;
        self.view = .list;
        self.setStatus(false, "cancelled", .{});
    }

    /// Advances the prompt, or runs the copy once both paths are in.
    pub fn submitPrompt(self: *App) void {
        const p = if (self.prompt) |*prompt| prompt else return;
        const text = p.input();
        if (text.len == 0) return self.cancelPrompt();

        switch (p.step) {
            .copy_source => {
                p.source_len = @min(text.len, p.source_buf.len);
                @memcpy(p.source_buf[0..p.source_len], text[0..p.source_len]);
                p.input_len = 0;
                p.step = .copy_destination;
            },
            .copy_destination => {
                var source_buf: [512]u8 = undefined;
                const source_len = p.source_len;
                @memcpy(source_buf[0..source_len], p.source_buf[0..source_len]);
                var dest_buf: [512]u8 = undefined;
                const dest_len = text.len;
                @memcpy(dest_buf[0..dest_len], text);

                self.prompt = null;
                self.view = .list;
                self.runCopy(source_buf[0..source_len], dest_buf[0..dest_len]);
            },
        }
    }

    fn runCopy(self: *App, source: []const u8, destination: []const u8) void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();

        const out = cli.exec(
            scratch.allocator(),
            self.io,
            &.{ cli.exe, "copy", source, destination },
            .limited(256 * 1024),
        ) catch {
            self.setStatus(true, "could not run `{s} copy`", .{cli.exe});
            return;
        };

        if (out.ok) {
            self.setStatus(false, "copied {s} to {s}", .{ source, destination });
        } else {
            self.setStatus(true, "copy failed: {s}", .{firstLine(out.message())});
        }
        self.refresh();
    }

    // -----------------------------------------------------------------------
    // Marking rows for a bulk action
    // -----------------------------------------------------------------------

    /// Identity of a row, and also the argument an action would pass to
    /// `container`. Marks are stored as these.
    fn rowName(self: *const App, tab: Tab, index: usize) ?[]const u8 {
        return switch (tab) {
            .containers => if (index < self.containers.len) self.containers[index].id else null,
            .stacks => if (index < self.stacks.len) self.stacks[index].name else null,
            .images => if (index < self.images.len) self.images[index].reference else null,
            .volumes => if (index < self.volumes.len) self.volumes[index].name else null,
            .networks => if (index < self.networks.len) self.networks[index].name else null,
            .stats => if (index < self.stats.len) self.stats[index].id else null,
        };
    }

    pub fn isMarked(self: *const App, tab: Tab, index: usize) bool {
        const name = self.rowName(tab, index) orelse return false;
        for (self.marked[@intFromEnum(tab)].items) |marked| {
            if (std.mem.eql(u8, marked, name)) return true;
        }
        return false;
    }

    pub fn markedCount(self: *const App, tab: Tab) usize {
        return self.marked[@intFromEnum(tab)].items.len;
    }

    /// Marks or unmarks the row under the cursor and steps down, so a run of
    /// rows can be marked by holding space.
    pub fn toggleMark(self: *App) void {
        const index = self.selectedSource() orelse return;
        const name = self.rowName(self.tab, index) orelse return;
        const list = &self.marked[@intFromEnum(self.tab)];

        for (list.items, 0..) |marked, i| {
            if (!std.mem.eql(u8, marked, name)) continue;
            self.gpa.free(marked);
            _ = list.orderedRemove(i);
            self.moveCursor(1);
            return;
        }

        const copy = self.gpa.dupe(u8, name) catch return;
        list.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
        self.moveCursor(1);
    }

    pub fn clearMarks(self: *App, tab: Tab) void {
        const list = &self.marked[@intFromEnum(tab)];
        for (list.items) |name| self.gpa.free(name);
        list.clearRetainingCapacity();
    }

    fn sortValue(self: *const App, tab: Tab, index: usize, column: u8) SortValue {
        return switch (tab) {
            .containers => blk: {
                const c = self.containers[index];
                break :blk switch (column) {
                    0 => .{ .text = c.id },
                    1 => .{ .text = c.state },
                    2 => .{ .text = c.image },
                    3 => .{ .text = c.ip },
                    4 => .{ .number = c.cpus },
                    else => .{ .number = c.memory_bytes },
                };
            },
            .stacks => blk: {
                const s = self.stacks[index];
                break :blk switch (column) {
                    0 => .{ .text = s.name },
                    1 => .{ .number = s.running },
                    2 => .{ .number = s.members.len },
                    3 => .{ .number = s.cpus },
                    else => .{ .number = s.memory_bytes },
                };
            },
            .images => blk: {
                const img = self.images[index];
                break :blk switch (column) {
                    0 => .{ .text = img.name },
                    1 => .{ .text = img.tag },
                    2 => .{ .text = img.reference },
                    3 => .{ .text = img.digest },
                    4 => .{ .text = img.arch },
                    // ISO-8601 sorts correctly as text.
                    else => .{ .text = img.created },
                };
            },
            .volumes => blk: {
                const v = self.volumes[index];
                break :blk switch (column) {
                    0 => .{ .text = v.name },
                    1 => .{ .text = v.driver },
                    2 => .{ .text = v.source },
                    3 => .{ .text = v.format },
                    else => .{ .number = v.size_bytes },
                };
            },
            .networks => blk: {
                const n = self.networks[index];
                break :blk switch (column) {
                    0 => .{ .text = n.name },
                    1 => .{ .text = n.mode },
                    2 => .{ .text = n.subnet },
                    else => .{ .text = n.gateway },
                };
            },
            .stats => blk: {
                const s = self.stats[index];
                break :blk switch (column) {
                    0 => .{ .text = s.id },
                    // Scaled so the fractional percentage survives as an integer.
                    1 => .{ .number = @intFromFloat(self.cpuPercent(index) * 1000) },
                    2 => .{ .number = s.memory_bytes },
                    3 => .{ .number = s.net_rx + s.net_tx },
                    4 => .{ .number = s.block_read + s.block_write },
                    else => .{ .number = s.processes },
                };
            },
        };
    }

    /// CPU percentage for the stats row at `index`, or 0 when there is no
    /// earlier sample to compare against yet.
    pub fn cpuPercent(self: *const App, index: usize) f64 {
        return if (index < self.stats_cpu.len) self.stats_cpu[index] else 0;
    }

    /// The container the cursor denotes, for the container-only keys. The
    /// Stacks tab has no single container, so it yields null.
    pub fn selectedContainer(self: *const App) ?cli.Container {
        const i = self.selectedSource() orelse return null;
        return switch (self.tab) {
            .containers => if (i < self.containers.len) self.containers[i] else null,
            .stats => if (i < self.stats.len) self.findContainer(self.stats[i].id) else null,
            else => null,
        };
    }

    fn findContainer(self: *const App, id: []const u8) ?cli.Container {
        for (self.containers) |c| {
            if (std.mem.eql(u8, c.id, id)) return c;
        }
        return null;
    }

    /// Refetches everything. Any per-list error is surfaced in the status bar
    /// but does not stop the other lists from loading.
    pub fn refresh(self: *App) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.now = nowSeconds(self.io);

        // Every slice below borrows from the arena just reset, so all of them
        // must be repopulated before anything reads them again.
        self.containers = &.{};
        self.stacks = &.{};
        self.images = &.{};
        self.volumes = &.{};
        self.networks = &.{};
        self.stats = &.{};
        self.stats_cpu = &.{};

        var err: ?[]const u8 = null;
        self.system = cli.systemStatus(a, self.io);
        self.containers = cli.listContainers(a, self.io, &err) catch &.{};
        self.images = cli.listImages(a, self.io, &err) catch &.{};
        self.volumes = cli.listVolumes(a, self.io, &err) catch &.{};
        self.networks = cli.listNetworks(a, self.io, &err) catch &.{};
        self.stats = cli.listStats(a, self.io, &err) catch &.{};
        self.disk = cli.diskUsage(a, self.io);
        self.stacks = self.buildStacks(a) catch &.{};
        self.stats_cpu = self.deriveCpuPercent(a) catch &.{};

        if (err) |e| {
            self.setStatus(true, "{s}", .{firstLine(e)});
            // A refresh error describes the current reading, so a later
            // healthy one should clear it.
            self.status_transient = true;
        } else if (self.status_transient) {
            // Only progress notes and stale refresh errors go. An action's
            // own result — including a failure — has to outlive the refresh
            // that runs immediately after it, or it is never seen at all.
            self.clearStatus();
        }
        // Also clamps the cursor, so it runs instead of clampCursor here.
        self.rebuildVisible();
    }

    fn clampCursor(self: *App) void {
        for (0..Tab.count) |i| {
            const n = self.countFor(@enumFromInt(i));
            if (self.cursor[i] >= n) self.cursor[i] = n -| 1;
        }
    }

    /// Groups containers into stacks. `containers` is already sorted, and
    /// members keep that order, so the result is stable between refreshes.
    fn buildStacks(self: *App, a: Allocator) ![]Stack {
        if (self.containers.len == 0) return &.{};

        const names = try a.alloc([]const u8, self.containers.len);
        for (self.containers, names) |c, *name| name.* = stackNameFor(c, self.containers);

        // Collect distinct names in first-seen order.
        var distinct: std.ArrayList([]const u8) = .empty;
        defer distinct.deinit(self.gpa);
        for (names) |name| {
            for (distinct.items) |seen| {
                if (std.mem.eql(u8, seen, name)) break;
            } else try distinct.append(self.gpa, name);
        }

        const stacks = try a.alloc(Stack, distinct.items.len);
        for (distinct.items, stacks) |name, *stack| {
            var members: std.ArrayList(cli.Container) = .empty;
            defer members.deinit(self.gpa);
            var running: usize = 0;
            var cpus: u64 = 0;
            var memory: u64 = 0;
            for (self.containers, names) |c, c_name| {
                if (!std.mem.eql(u8, c_name, name)) continue;
                try members.append(self.gpa, c);
                if (c.isRunning()) running += 1;
                cpus += c.cpus;
                memory += c.memory_bytes;
            }
            stack.* = .{
                .name = name,
                .members = try a.dupe(cli.Container, members.items),
                .running = running,
                .cpus = cpus,
                .memory_bytes = memory,
            };
        }

        std.mem.sort(Stack, stacks, {}, struct {
            fn lt(_: void, x: Stack, y: Stack) bool {
                if (x.isRunning() != y.isRunning()) return x.isRunning();
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        return stacks;
    }

    fn deriveCpuPercent(self: *App, a: Allocator) ![]f64 {
        const now_ms = monotonicMs(self.io);
        const out = try a.alloc(f64, self.stats.len);

        for (self.stats, out) |s, *percent| {
            percent.* = 0;
            if (self.findSample(s.id)) |prev| {
                const elapsed_us = (now_ms - prev.at_ms) * std.time.us_per_ms;
                const used_us = s.cpu_usec -| prev.cpu_usec;
                if (elapsed_us > 0) {
                    const ratio = @as(f64, @floatFromInt(used_us)) / @as(f64, @floatFromInt(elapsed_us));
                    percent.* = ratio * 100;
                }
            }
            self.storeSample(s.id, s.cpu_usec, now_ms);
        }
        return out;
    }

    fn findSample(self: *const App, id: []const u8) ?*const CpuSample {
        for (self.cpu_samples.items) |*sample| {
            if (std.mem.eql(u8, sample.id(), id)) return sample;
        }
        return null;
    }

    fn storeSample(self: *App, id: []const u8, cpu_usec: u64, at_ms: i64) void {
        for (self.cpu_samples.items) |*sample| {
            if (!std.mem.eql(u8, sample.id(), id)) continue;
            sample.cpu_usec = cpu_usec;
            sample.at_ms = at_ms;
            return;
        }
        var sample: CpuSample = .{ .cpu_usec = cpu_usec, .at_ms = at_ms };
        sample.id_len = @min(id.len, sample.id_buf.len);
        @memcpy(sample.id_buf[0..sample.id_len], id[0..sample.id_len]);
        self.cpu_samples.append(self.gpa, sample) catch {};
    }

    // -----------------------------------------------------------------------
    // Navigation
    // -----------------------------------------------------------------------

    pub fn moveCursor(self: *App, delta: isize) void {
        const n = self.itemCount();
        if (n == 0) return;
        const i = &self.cursor[@intFromEnum(self.tab)];
        const cur: isize = @intCast(i.*);
        const max: isize = @intCast(n - 1);
        i.* = @intCast(std.math.clamp(cur + delta, 0, max));
    }

    pub fn cursorTo(self: *App, pos: enum { first, last }) void {
        const n = self.itemCount();
        if (n == 0) return;
        self.cursor[@intFromEnum(self.tab)] = switch (pos) {
            .first => 0,
            .last => n - 1,
        };
    }

    pub fn switchTab(self: *App, tab: Tab) void {
        self.tab = tab;
        self.status_len = 0;
    }

    pub fn nextTab(self: *App, delta: isize) void {
        const cur: isize = @intCast(@intFromEnum(self.tab));
        const n: isize = @intCast(Tab.count);
        const next = @mod(cur + delta + n, n);
        self.switchTab(@enumFromInt(@as(usize, @intCast(next))));
    }

    /// Keeps the cursor inside the visible window of `height` rows.
    pub fn syncScroll(self: *App, height: usize) void {
        if (height == 0) return;
        const i = self.cursor[@intFromEnum(self.tab)];
        const s = &self.scroll[@intFromEnum(self.tab)];
        if (i < s.*) s.* = i;
        if (i >= s.* + height) s.* = i - height + 1;

        const n = self.itemCount();
        const max_scroll = n -| height;
        if (s.* > max_scroll) s.* = max_scroll;
    }

    pub fn scrollPager(self: *App, delta: isize, height: usize) void {
        const max = self.lines.items.len -| height;
        const cur: isize = @intCast(self.text_scroll);
        self.text_scroll = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(max))));
        // Scrolling back detaches from the tail; returning to the bottom
        // re-attaches, which is what a `tail -f` reader expects.
        self.follow_tail = self.text_scroll >= max;
    }

    // -----------------------------------------------------------------------
    // Pager
    // -----------------------------------------------------------------------

    /// Takes ownership of the text already accumulated in `self.text` and
    /// indexes it into `self.lines`.
    fn openPager(self: *App, title: []const u8) void {
        self.text_title_len = @min(title.len, self.text_title_buf.len);
        @memcpy(self.text_title_buf[0..self.text_title_len], title[0..self.text_title_len]);

        self.reindexLines();
        self.text_scroll = 0;
        self.view = .pager;
    }

    /// Rebuilds `lines` from `text`. Slices point into `text`, so this must run
    /// again after anything appends to or trims the buffer.
    fn reindexLines(self: *App) void {
        self.lines.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, self.text.items, '\n');
        while (it.next()) |line| {
            // Trim a trailing CR so CRLF output does not shift the layout.
            const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            self.lines.append(self.gpa, trimmed) catch break;
        }
        // A trailing newline yields one empty final line; drop it.
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].len == 0) {
            _ = self.lines.pop();
        }
    }

    /// Renders the selected row into the pager as a formatted detail sheet.
    pub fn showDetails(self: *App) void {
        const i = self.selectedSource() orelse return;

        self.text.clearRetainingCapacity();
        var out: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.text);
        const w = &out.writer;

        var title_buf: [256]u8 = undefined;
        const title = switch (self.tab) {
            .containers => blk: {
                const c = self.containers[i];
                writeContainerDetails(w, c) catch {};
                break :blk std.fmt.bufPrint(&title_buf, "container {s}", .{c.id}) catch "container";
            },
            .images => blk: {
                const img = self.images[i];
                writeFields(w, &.{
                    .{ "Reference", img.reference },
                    .{ "Name", img.name },
                    .{ "Tag", img.tag },
                    .{ "Digest", img.digest },
                    .{ "Platform", img.os },
                    .{ "Architecture", img.arch },
                    .{ "Created", img.created },
                }) catch {};
                break :blk std.fmt.bufPrint(&title_buf, "image {s}", .{img.reference}) catch "image";
            },
            .volumes => blk: {
                const v = self.volumes[i];
                var size_buf: [32]u8 = undefined;
                writeFields(w, &.{
                    .{ "Name", v.name },
                    .{ "Driver", v.driver },
                    .{ "Format", v.format },
                    .{ "Size", formatBytes(&size_buf, v.size_bytes) },
                    .{ "Source", v.source },
                    .{ "Created", v.created },
                }) catch {};
                break :blk std.fmt.bufPrint(&title_buf, "volume {s}", .{v.name}) catch "volume";
            },
            .networks => blk: {
                const n = self.networks[i];
                writeFields(w, &.{
                    .{ "Name", n.name },
                    .{ "Mode", n.mode },
                    .{ "Subnet", n.subnet },
                    .{ "Gateway", n.gateway },
                    .{ "Created", n.created },
                }) catch {};
                break :blk std.fmt.bufPrint(&title_buf, "network {s}", .{n.name}) catch "network";
            },
            .stacks => blk: {
                const stack = self.stacks[i];
                writeStackDetails(w, stack) catch {};
                break :blk std.fmt.bufPrint(&title_buf, "stack {s}", .{stack.name}) catch "stack";
            },
            .stats => blk: {
                const s = self.stats[i];
                writeStatDetails(w, s, self.cpuPercent(i)) catch {};
                break :blk std.fmt.bufPrint(&title_buf, "stats {s}", .{s.id}) catch "stats";
            },
        };

        // openPager reads self.text, so hand the writer's buffer back first.
        self.text = out.toArrayList();
        self.openPager(title);
    }

    /// Fetches the last 1000 log lines for the selected container.
    pub fn showLogs(self: *App) void {
        const c = self.selectedContainer() orelse {
            self.setStatus(true, "logs are only available for containers", .{});
            return;
        };

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();

        const out = cli.exec(
            scratch.allocator(),
            self.io,
            &.{ cli.exe, "logs", "-n", "1000", c.id },
            .limited(8 * 1024 * 1024),
        ) catch {
            self.setStatus(true, "could not run `container logs`", .{});
            return;
        };

        self.text.clearRetainingCapacity();
        if (out.ok) {
            const body = if (out.stdout.len > 0) out.stdout else "(no log output)";
            self.text.appendSlice(self.gpa, body) catch {};
        } else {
            self.text.appendSlice(self.gpa, out.message()) catch {};
        }

        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "logs {s}", .{c.id}) catch "logs";
        self.openPager(title);
    }

    // -----------------------------------------------------------------------
    // Log follow
    // -----------------------------------------------------------------------

    pub fn isFollowing(self: *const App) bool {
        return self.follow != null;
    }

    pub fn followTarget(self: *const App) []const u8 {
        return if (self.follow) |*stream| stream.id() else "";
    }

    /// Starts `container logs --follow` and shows its output as it arrives.
    pub fn startFollow(self: *App) void {
        const c = self.selectedContainer() orelse {
            self.setStatus(true, "select a container to follow its logs", .{});
            return;
        };
        self.stopFollow();

        const child = std.process.spawn(self.io, .{
            .argv = &.{ cli.exe, "logs", "--follow", "-n", "200", c.id },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch {
            self.setStatus(true, "could not start `{s} logs --follow`", .{cli.exe});
            return;
        };

        var stream: LogStream = .{ .child = child };
        stream.id_len = @min(c.id.len, stream.id_buf.len);
        @memcpy(stream.id_buf[0..stream.id_len], c.id[0..stream.id_len]);
        self.follow = stream;

        self.text.clearRetainingCapacity();
        var title_buf: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "logs {s}", .{c.id}) catch "logs";
        self.openPager(title);
        self.follow_tail = true;
    }

    /// `kill` blocks until the child is gone and cleans up its pipes; it is
    /// idempotent, so this is safe to call unconditionally.
    pub fn stopFollow(self: *App) void {
        if (self.follow) |*stream| {
            stream.child.kill(self.io);
            self.follow = null;
        }
    }

    /// Reads whatever the follow child has already produced, without blocking.
    /// Returns true when new output arrived.
    pub fn drainFollow(self: *App) bool {
        if (self.follow == null) return false;
        const fd = (self.follow.?.child.stdout orelse return false).handle;

        var got = false;
        var buf: [16 * 1024]u8 = undefined;
        // Bounded so a chatty container cannot starve the input loop.
        for (0..64) |_| {
            var fds = [_]std.posix.pollfd{.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&fds, 0) catch break;
            if (ready == 0) break;

            const n = std.posix.read(fd, &buf) catch break;
            if (n == 0) {
                // Pipe closed: the container exited or logs ended.
                self.stopFollow();
                self.setStatus(false, "log stream ended", .{});
                break;
            }
            self.text.appendSlice(self.gpa, buf[0..n]) catch break;
            self.trimFollowBuffer();
            got = true;
        }

        if (got) self.reindexLines();
        return got;
    }

    /// Caps the follow buffer, dropping whole lines from the front.
    fn trimFollowBuffer(self: *App) void {
        if (self.text.items.len <= follow_buffer_limit) return;
        const excess = self.text.items.len - follow_buffer_limit;
        const boundary = std.mem.indexOfScalarPos(u8, self.text.items, excess, '\n') orelse excess;
        const drop = @min(boundary + 1, self.text.items.len);
        std.mem.copyForwards(u8, self.text.items, self.text.items[drop..]);
        self.text.shrinkRetainingCapacity(self.text.items.len - drop);
    }

    pub fn scrollToEnd(self: *App, height: usize) void {
        self.text_scroll = self.lines.items.len -| height;
    }

    // -----------------------------------------------------------------------
    // Interactive shell
    // -----------------------------------------------------------------------

    /// Records that the user wants a shell. `main` performs the handover,
    /// because only it owns the terminal state.
    pub fn requestShell(self: *App) void {
        const c = self.selectedContainer() orelse {
            self.setStatus(true, "select a container to open a shell", .{});
            return;
        };
        if (!c.isRunning()) {
            self.setStatus(true, "{s} is not running", .{c.id});
            return;
        }
        self.exec_target_len = @min(c.id.len, self.exec_target_buf.len);
        @memcpy(self.exec_target_buf[0..self.exec_target_len], c.id[0..self.exec_target_len]);
    }

    /// Hands the pending shell target to the caller, copied into `buf`.
    pub fn takeShellRequest(self: *App, buf: []u8) ?[]const u8 {
        if (self.exec_target_len == 0) return null;
        const n = @min(self.exec_target_len, buf.len);
        @memcpy(buf[0..n], self.exec_target_buf[0..n]);
        self.exec_target_len = 0;
        return buf[0..n];
    }

    // -----------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------

    /// Queues an action. Destructive kinds open a confirm prompt first;
    /// everything else runs immediately.
    /// Marked rows take precedence over the cursor: once rows are marked, the
    /// action keys mean "do this to the marks", which is the whole point of
    /// having marked them.
    pub fn request(self: *App, kind: ActionKind) void {
        if (self.markedCount(self.tab) > 0) return self.queueMarked(kind);

        const target = self.currentTarget() orelse {
            self.setStatus(true, "nothing selected", .{});
            return;
        };
        self.queue(kind, target);
    }

    fn queueMarked(self: *App, kind: ActionKind) void {
        const count = self.markedCount(self.tab);
        var p: Pending = .{
            .kind = kind,
            .scope = .marked,
            .target_buf = undefined,
            .target_len = 0,
            .prompt_buf = undefined,
            .prompt_len = 0,
        };

        const prompt = std.fmt.bufPrint(&p.prompt_buf, "{s} {d} marked {s}?", .{
            verb(kind),
            count,
            if (count == 1) "row" else "rows",
        }) catch "confirm?";
        p.prompt_len = prompt.len;
        self.pending = p;

        // Even start is confirmed here: a bulk action is worth a second look
        // regardless of which one it is.
        self.view = .confirm;
    }

    /// Kill has no stack-wide form, so it needs a single selected container
    /// rather than whatever the current row happens to name.
    pub fn requestKill(self: *App) void {
        const c = self.selectedContainer() orelse {
            self.setStatus(true, "select a container to kill", .{});
            return;
        };
        self.queue(.container_kill, c.id);
    }

    fn queue(self: *App, kind: ActionKind, target: []const u8) void {
        var p: Pending = .{
            .kind = kind,
            .target_buf = undefined,
            .target_len = @min(target.len, 256),
            .prompt_buf = undefined,
            .prompt_len = 0,
        };
        @memcpy(p.target_buf[0..p.target_len], target[0..p.target_len]);

        if (!needsConfirm(kind)) {
            self.pending = p;
            self.runPending();
            return;
        }

        const prompt = std.fmt.bufPrint(&p.prompt_buf, "{s} {s}?", .{ verb(kind), target }) catch "confirm?";
        p.prompt_len = prompt.len;
        self.pending = p;
        self.view = .confirm;
    }

    pub fn cancelPending(self: *App) void {
        self.pending = null;
        self.view = .list;
        self.setStatus(false, "cancelled", .{});
    }

    /// Queues a prune for the current tab. Always confirmed, and the prompt
    /// states how much `container system df` thinks it can reclaim.
    pub fn requestPrune(self: *App) void {
        const kind: ActionKind = switch (self.tab) {
            .containers, .stacks, .stats => .prune_containers,
            .images => .prune_images,
            .volumes => .prune_volumes,
            .networks => .prune_networks,
        };

        var p: Pending = .{
            .kind = kind,
            .target_buf = undefined,
            .target_len = 0,
            .prompt_buf = undefined,
            .prompt_len = 0,
        };

        var size_buf: [32]u8 = undefined;
        const reclaimable = switch (kind) {
            .prune_images => self.disk.images.reclaimable,
            .prune_volumes => self.disk.volumes.reclaimable,
            else => self.disk.containers.reclaimable,
        };
        const prompt = if (reclaimable > 0)
            std.fmt.bufPrint(&p.prompt_buf, "prune {s}? frees up to {s}", .{
                pruneSubject(kind),
                formatBytes(&size_buf, reclaimable),
            }) catch "prune?"
        else
            std.fmt.bufPrint(&p.prompt_buf, "prune {s}?", .{pruneSubject(kind)}) catch "prune?";

        p.prompt_len = prompt.len;
        self.pending = p;
        self.view = .confirm;
    }

    /// Runs the queued action and refreshes. Returns after the child process
    /// exits, so callers should paint a "working" frame first.
    pub fn runPending(self: *App) void {
        const p = self.pending orelse return;
        self.pending = null;
        self.view = .list;

        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();

        if (p.scope == .marked) {
            self.runMarkedAction(scratch.allocator(), p.kind);
        } else if (p.kind.isStack()) {
            self.runStackAction(scratch.allocator(), p.kind, p.target());
        } else {
            const target = p.target();
            const out = self.runOne(scratch.allocator(), p.kind, target) orelse {
                self.setStatus(true, "could not run `{s}`", .{cli.exe});
                return;
            };
            const subject = if (target.len > 0) target else pruneSubject(p.kind);
            if (out.ok) {
                self.setStatus(false, "{s} {s}: ok", .{ verb(p.kind), subject });
            } else {
                self.setStatus(true, "{s} {s}: {s}", .{ verb(p.kind), subject, firstLine(out.message()) });
            }
        }
        self.refresh();
    }

    /// Applies the action to every marked row, then clears the marks so the
    /// next keystroke does not silently repeat a bulk operation.
    fn runMarkedAction(self: *App, a: Allocator, kind: ActionKind) void {
        const list = self.marked[@intFromEnum(self.tab)];
        var ok: usize = 0;
        var failed: usize = 0;
        var last_error: []const u8 = "";

        for (list.items) |target| {
            const out = self.runOne(a, kind.perMember(), target) orelse {
                failed += 1;
                last_error = "could not spawn";
                continue;
            };
            if (out.ok) {
                ok += 1;
            } else {
                failed += 1;
                last_error = firstLine(out.message());
            }
        }

        if (failed == 0) {
            self.setStatus(false, "{s}: {d} of {d} ok", .{ verb(kind), ok, list.items.len });
        } else {
            self.setStatus(true, "{s}: {d} ok, {d} failed — {s}", .{ verb(kind), ok, failed, last_error });
        }
        self.clearMarks(self.tab);
    }

    /// Applies the per-member action to every container in the stack, then
    /// reports a tally rather than the last command's result.
    fn runStackAction(self: *App, a: Allocator, kind: ActionKind, name: []const u8) void {
        const stack = self.findStack(name) orelse {
            self.setStatus(true, "stack {s} no longer exists", .{name});
            return;
        };

        var ok: usize = 0;
        var failed: usize = 0;
        var last_error: []const u8 = "";
        // Members borrow from the arena, which refresh() only resets afterwards.
        for (stack.members) |member| {
            const out = self.runOne(a, kind.perMember(), member.id) orelse {
                failed += 1;
                last_error = "could not spawn";
                continue;
            };
            if (out.ok) {
                ok += 1;
            } else {
                failed += 1;
                last_error = firstLine(out.message());
            }
        }

        if (failed == 0) {
            self.setStatus(false, "{s} {s}: {d} of {d} ok", .{ verb(kind), name, ok, stack.members.len });
        } else {
            self.setStatus(true, "{s} {s}: {d} ok, {d} failed — {s}", .{ verb(kind), name, ok, failed, last_error });
        }
    }

    fn runOne(self: *App, a: Allocator, kind: ActionKind, target: []const u8) ?cli.Output {
        const argv: []const []const u8 = switch (kind) {
            .container_start => &.{ cli.exe, "start", target },
            .container_stop => &.{ cli.exe, "stop", target },
            .container_kill => &.{ cli.exe, "kill", target },
            .container_delete => &.{ cli.exe, "delete", "--force", target },
            .image_delete => &.{ cli.exe, "image", "delete", target },
            .volume_delete => &.{ cli.exe, "volume", "delete", target },
            .network_delete => &.{ cli.exe, "network", "delete", target },
            .prune_containers => &.{ cli.exe, "prune" },
            .prune_images => &.{ cli.exe, "image", "prune" },
            .prune_volumes => &.{ cli.exe, "volume", "prune" },
            .prune_networks => &.{ cli.exe, "network", "prune" },
            // Expanded by runStackAction before reaching here.
            .stack_start, .stack_stop, .stack_delete => return null,
        };
        return cli.exec(a, self.io, argv, .limited(256 * 1024)) catch null;
    }

    fn findStack(self: *const App, name: []const u8) ?Stack {
        for (self.stacks) |stack| {
            if (std.mem.eql(u8, stack.name, name)) return stack;
        }
        return null;
    }

    // The start/stop/kill/delete keys map to a different action per tab.

    pub fn startKind(self: *const App) ActionKind {
        return if (self.tab == .stacks) .stack_start else .container_start;
    }

    pub fn stopKind(self: *const App) ActionKind {
        return if (self.tab == .stacks) .stack_stop else .container_stop;
    }

    pub fn deleteKind(self: *const App) ActionKind {
        return switch (self.tab) {
            .containers, .stats => .container_delete,
            .stacks => .stack_delete,
            .images => .image_delete,
            .volumes => .volume_delete,
            .networks => .network_delete,
        };
    }

    fn currentTarget(self: *const App) ?[]const u8 {
        const i = self.selectedSource() orelse return null;
        return switch (self.tab) {
            .containers => self.containers[i].id,
            .stacks => self.stacks[i].name,
            .images => self.images[i].reference,
            .volumes => self.volumes[i].name,
            .networks => self.networks[i].name,
            .stats => self.stats[i].id,
        };
    }
};

/// A column's value for ordering. Numbers are kept as numbers so that a
/// memory column does not sort "1.0 GB" before "512 MB".
const SortValue = union(enum) {
    text: []const u8,
    number: u64,
};

const SortContext = struct {
    app: *const App,
    tab: Tab,
    column: u8,
    desc: bool,

    fn lessThan(ctx: SortContext, a: usize, b: usize) bool {
        const va = ctx.app.sortValue(ctx.tab, a, ctx.column);
        const vb = ctx.app.sortValue(ctx.tab, b, ctx.column);
        const ordered = switch (va) {
            .text => |ta| std.ascii.lessThanIgnoreCase(ta, vb.text),
            .number => |na| na < vb.number,
        };
        // Equal keys keep source order, so a sort never shuffles ties around
        // between refreshes.
        const equal = switch (va) {
            .text => |ta| std.ascii.eqlIgnoreCase(ta, vb.text),
            .number => |na| na == vb.number,
        };
        if (equal) return a < b;
        return if (ctx.desc) !ordered else ordered;
    }
};

fn sortColumnCount(tab: Tab) u8 {
    return switch (tab) {
        .containers => 6,
        .stacks => 5,
        .images => 6,
        .volumes => 5,
        .networks => 4,
        .stats => 6,
    };
}

/// Names match the column headers so the status line reads the way the table
/// looks.
fn sortColumnName(tab: Tab, column: u8) []const u8 {
    return switch (tab) {
        .containers => switch (column) {
            0 => "name",
            1 => "state",
            2 => "image",
            3 => "ip",
            4 => "cpu",
            else => "memory",
        },
        .stacks => switch (column) {
            0 => "stack",
            1 => "state",
            2 => "containers",
            3 => "cpu",
            else => "memory",
        },
        .images => switch (column) {
            0 => "name",
            1 => "tag",
            2 => "reference",
            3 => "digest",
            4 => "arch",
            else => "created",
        },
        .volumes => switch (column) {
            0 => "name",
            1 => "driver",
            2 => "source",
            3 => "format",
            else => "size",
        },
        .networks => switch (column) {
            0 => "name",
            1 => "mode",
            2 => "subnet",
            else => "gateway",
        },
        .stats => switch (column) {
            0 => "name",
            1 => "cpu",
            2 => "memory",
            3 => "net",
            4 => "block",
            else => "pids",
        },
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn needsConfirm(kind: ActionKind) bool {
    return switch (kind) {
        .container_start => false,
        else => true,
    };
}

fn verb(kind: ActionKind) []const u8 {
    return switch (kind) {
        .container_start, .stack_start => "start",
        .container_stop, .stack_stop => "stop",
        .container_kill => "kill",
        .container_delete,
        .image_delete,
        .volume_delete,
        .network_delete,
        .stack_delete,
        => "delete",
        .prune_containers, .prune_images, .prune_volumes, .prune_networks => "prune",
    };
}

/// What a prune action removes, for the confirmation prompt.
fn pruneSubject(kind: ActionKind) []const u8 {
    return switch (kind) {
        .prune_containers => "stopped containers",
        .prune_images => "unused images",
        .prune_volumes => "unreferenced volumes",
        .prune_networks => "unused networks",
        else => "",
    };
}

pub const standalone_stack = "(standalone)";

/// The stack a container belongs to: a label if one names it, otherwise a name
/// prefix shared with at least one other container, otherwise standalone.
fn stackNameFor(c: cli.Container, all: []const cli.Container) []const u8 {
    if (c.stack_label.len > 0) return c.stack_label;

    const prefix = cli.namePrefix(c.id);
    if (prefix.len == 0) return standalone_stack;

    var shared: usize = 0;
    for (all) |other| {
        if (std.mem.eql(u8, cli.namePrefix(other.id), prefix)) shared += 1;
    }
    // A prefix only names a stack when more than one container carries it.
    return if (shared >= 2) prefix else standalone_stack;
}

// ---------------------------------------------------------------------------
// Detail sheet rendering
// ---------------------------------------------------------------------------

const Field = struct { []const u8, []const u8 };

fn writeFields(w: *std.Io.Writer, fields: []const Field) !void {
    for (fields) |f| {
        if (f[1].len == 0) continue;
        try w.print("  {s: <14}{s}\n", .{ f[0], f[1] });
    }
}

fn writeContainerDetails(w: *std.Io.Writer, c: cli.Container) !void {
    var mem_buf: [32]u8 = undefined;
    var cpu_buf: [32]u8 = undefined;

    try writeFields(w, &.{
        .{ "ID", c.id },
        .{ "State", c.state },
        .{ "Image", c.image },
        .{ "Platform", c.os },
        .{ "Architecture", c.arch },
        .{ "Hostname", c.hostname },
        .{ "IP", c.ip },
        .{ "Gateway", c.gateway },
        .{ "CPUs", std.fmt.bufPrint(&cpu_buf, "{d}", .{c.cpus}) catch "" },
        .{ "Memory", formatBytes(&mem_buf, c.memory_bytes) },
        .{ "Created", c.created },
        .{ "Started", c.started },
        .{ "Working dir", c.workdir },
        .{ "Executable", c.executable },
    });

    if (c.args.len > 0) {
        try w.writeAll("\n  Command\n");
        for (c.args) |arg| try w.print("    {s}\n", .{arg});
    }

    if (c.ports.len > 0) {
        try w.writeAll("\n  Published ports\n");
        for (c.ports) |p| {
            try w.print("    {s}:{d} -> {d}/{s}\n", .{
                if (p.host_address.len > 0) p.host_address else "0.0.0.0",
                p.host_port,
                p.container_port,
                p.proto,
            });
        }
    }

    if (c.mounts.len > 0) {
        try w.writeAll("\n  Mounts\n");
        for (c.mounts) |m| try w.print("    {s} -> {s}\n", .{ m.source, m.destination });
    }

    if (c.env.len > 0) {
        try w.writeAll("\n  Environment\n");
        for (c.env) |e| try w.print("    {s}\n", .{e});
    }
}

fn writeStackDetails(w: *std.Io.Writer, stack: Stack) !void {
    var count_buf: [32]u8 = undefined;
    var running_buf: [32]u8 = undefined;
    var cpu_buf: [32]u8 = undefined;
    var mem_buf: [32]u8 = undefined;

    try writeFields(w, &.{
        .{ "Stack", stack.name },
        .{ "Containers", std.fmt.bufPrint(&count_buf, "{d}", .{stack.members.len}) catch "" },
        .{ "Running", std.fmt.bufPrint(&running_buf, "{d}", .{stack.running}) catch "" },
        .{ "CPUs", std.fmt.bufPrint(&cpu_buf, "{d}", .{stack.cpus}) catch "" },
        .{ "Memory", formatBytes(&mem_buf, stack.memory_bytes) },
    });

    try w.writeAll("\n  Members\n");
    for (stack.members) |m| {
        try w.print("    {s: <22}{s: <10}{s}\n", .{ m.id, m.state, m.image });
    }
}

fn writeStatDetails(w: *std.Io.Writer, s: cli.Stat, cpu_percent: f64) !void {
    var cpu_buf: [32]u8 = undefined;
    var used_buf: [32]u8 = undefined;
    var limit_buf: [32]u8 = undefined;
    var rx_buf: [32]u8 = undefined;
    var tx_buf: [32]u8 = undefined;
    var read_buf: [32]u8 = undefined;
    var write_buf: [32]u8 = undefined;
    var procs_buf: [32]u8 = undefined;

    try writeFields(w, &.{
        .{ "Container", s.id },
        .{ "CPU", std.fmt.bufPrint(&cpu_buf, "{d:.2} %", .{cpu_percent}) catch "" },
        .{ "Memory used", formatBytes(&used_buf, s.memory_bytes) },
        .{ "Memory limit", formatBytes(&limit_buf, s.memory_limit) },
        .{ "Network Rx", formatBytes(&rx_buf, s.net_rx) },
        .{ "Network Tx", formatBytes(&tx_buf, s.net_tx) },
        .{ "Block read", formatBytes(&read_buf, s.block_read) },
        .{ "Block write", formatBytes(&write_buf, s.block_write) },
        .{ "Processes", std.fmt.bufPrint(&procs_buf, "{d}", .{s.processes}) catch "" },
    });
}

// ---------------------------------------------------------------------------
// Helpers shared with the UI
// ---------------------------------------------------------------------------

pub fn formatBytes(buf: []u8, n: u64) []const u8 {
    if (n == 0) return "";
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;

    // Whole numbers of bytes, and values of 100 or more, read better without
    // a decimal point.
    if (unit == 0 or value >= 100) {
        return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ value, units[unit] }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "";
}

/// "2026-07-24T12:23:12Z" -> "3d ago". Returns "" for unparseable input.
pub fn formatAge(buf: []u8, iso: []const u8, now: i64) []const u8 {
    const then = parseIso8601(iso) orelse return "";
    // The Unix epoch is what `container` reports when it has no real date —
    // Apple's own vminit image carries it. Rendering that as "56y ago" is
    // worse than saying nothing.
    if (then <= 0) return "";
    const secs = now - then;
    if (secs < 0) return "just now";
    if (secs < 60) return "just now";
    if (secs < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(secs, 60)}) catch "";
    if (secs < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(secs, 3600)}) catch "";
    if (secs < 86400 * 365) return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(secs, 86400)}) catch "";
    return std.fmt.bufPrint(buf, "{d}y ago", .{@divTrunc(secs, 86400 * 365)}) catch "";
}

/// Minimal parser for the "YYYY-MM-DDTHH:MM:SSZ" form the CLI emits.
/// Fractional seconds and offsets other than Z are ignored.
fn parseIso8601(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;

    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;

    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Upper bound on the retained follow output, in bytes.
const follow_buffer_limit = 1024 * 1024;

/// Milliseconds on a monotonic clock, for intervals and CPU deltas.
pub fn monotonicMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

/// Seconds since the Unix epoch.
pub fn nowSeconds(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

pub fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return trimmed[0..end];
}

// ---------------------------------------------------------------------------
// Integration tests
//
// These drive the real action path with `cli.exe` pointed at a stand-in that
// records its argv. Unit tests cannot catch an action wired to the wrong
// subcommand, or a delete that forgets --force; these can.
// ---------------------------------------------------------------------------

const build_options = @import("build_options");

const Harness = struct {
    /// Must match `logName` in test/fake-container.zig: the fake keys its log
    /// on its parent's pid, which is this process.
    fn logName(buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "/tmp/zc-fake-{d}.log", .{std.c.getpid()}) catch "/tmp/zc-fake.log";
    }

    threaded: *Io.Threaded,
    io: Io,
    previous_exe: []const u8,
    gpa: Allocator,

    fn init(gpa: Allocator) !Harness {
        const threaded = try gpa.create(Io.Threaded);
        threaded.* = .init(gpa, .{});

        const h: Harness = .{
            .threaded = threaded,
            .io = threaded.io(),
            .previous_exe = cli.exe,
            .gpa = gpa,
        };
        var name_buf: [64]u8 = undefined;
        Io.Dir.cwd().deleteFile(h.io, logName(&name_buf)) catch {};
        cli.exe = build_options.fake_container;
        return h;
    }

    fn deinit(self: *Harness) void {
        cli.exe = self.previous_exe;
        var name_buf: [64]u8 = undefined;
        Io.Dir.cwd().deleteFile(self.io, logName(&name_buf)) catch {};
        self.threaded.deinit();
        self.gpa.destroy(self.threaded);
    }

    /// Every command the fake was asked to run, in order.
    fn invocations(self: *Harness, arena: Allocator) ![]const []const u8 {
        var name_buf: [64]u8 = undefined;
        const text = Io.Dir.cwd().readFileAlloc(self.io, logName(&name_buf), arena, .limited(1 << 20)) catch
            return &.{};
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (line.len > 0) try lines.append(arena, line);
        }
        return lines.items;
    }

    fn contains(list: []const []const u8, needle: []const u8) bool {
        for (list) |line| {
            if (std.mem.eql(u8, line, needle)) return true;
        }
        return false;
    }
};

test "refresh runs exactly the expected read-only commands" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    // The fixture the fake serves has three containers.
    try std.testing.expectEqual(@as(usize, 3), app.containers.len);
    try std.testing.expectEqual(@as(usize, 2), app.images.len);
    try std.testing.expectEqualStrings("running", app.system);

    const calls = try h.invocations(arena.allocator());
    try std.testing.expect(Harness.contains(calls, "list --all --format json"));
    try std.testing.expect(Harness.contains(calls, "image list --format json"));
    try std.testing.expect(Harness.contains(calls, "stats --no-stream --format json"));
    try std.testing.expect(Harness.contains(calls, "system df --format json"));

    // A refresh must never mutate anything.
    for (calls) |call| {
        for ([_][]const u8{ "start", "stop", "kill", "delete", "prune" }) |mutating| {
            try std.testing.expect(!std.mem.startsWith(u8, call, mutating));
        }
    }
}

test "each action dispatches the command it claims to" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { kind: ActionKind, expected: []const u8 }{
        .{ .kind = .container_start, .expected = "start web-api" },
        .{ .kind = .container_stop, .expected = "stop web-api" },
        .{ .kind = .container_kill, .expected = "kill web-api" },
        // The one that matters most: a forgotten --force silently fails on a
        // running container.
        .{ .kind = .container_delete, .expected = "delete --force web-api" },
    };

    for (cases) |case| {
        var h = try Harness.init(gpa);
        defer h.deinit();

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        var app: App = .init(gpa, h.io);
        defer app.deinit();
        app.refresh();
        app.tab = .containers;
        app.cursor[@intFromEnum(Tab.containers)] = 0; // web-api, the running one

        app.request(case.kind);
        if (app.pending != null) app.runPending();

        const calls = try h.invocations(arena.allocator());
        std.testing.expect(Harness.contains(calls, case.expected)) catch |err| {
            std.debug.print("expected {s}\ngot:\n", .{case.expected});
            for (calls) |c| std.debug.print("  {s}\n", .{c});
            return err;
        };
    }
}

test "prune targets the current tab" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { tab: Tab, expected: []const u8 }{
        .{ .tab = .containers, .expected = "prune" },
        .{ .tab = .images, .expected = "image prune" },
        .{ .tab = .volumes, .expected = "volume prune" },
        .{ .tab = .networks, .expected = "network prune" },
    };

    for (cases) |case| {
        var h = try Harness.init(gpa);
        defer h.deinit();

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        var app: App = .init(gpa, h.io);
        defer app.deinit();
        app.refresh();
        app.tab = case.tab;

        app.requestPrune();
        try std.testing.expect(app.pending != null); // prune always confirms
        app.runPending();

        const calls = try h.invocations(arena.allocator());
        try std.testing.expect(Harness.contains(calls, case.expected));
    }
}

test "a stack action touches every member and nothing else" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();
    app.tab = .stacks;

    // The fixture labels web-api into stack "shop"; it is the only member.
    const shop = for (app.stacks, 0..) |stack, i| {
        if (std.mem.eql(u8, stack.name, "shop")) break i;
    } else return error.StackNotFound;

    app.cursor[@intFromEnum(Tab.stacks)] = shop;
    app.request(.stack_stop);
    try std.testing.expect(app.pending != null);
    app.runPending();

    const calls = try h.invocations(arena.allocator());
    try std.testing.expect(Harness.contains(calls, "stop web-api"));
    // web-db is in a different stack and must not have been touched.
    try std.testing.expect(!Harness.contains(calls, "stop web-db"));
}

test "a missing container binary is reported, not fatal" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    cli.exe = "/nonexistent/definitely-not-here";

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    try std.testing.expectEqual(@as(usize, 0), app.containers.len);
    try std.testing.expect(app.status_is_error);
    try std.testing.expect(std.mem.indexOf(u8, app.status(), "cannot run") != null);
}

test "filtering hides rows and keeps actions pointed at what is shown" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();
    try std.testing.expectEqual(@as(usize, 3), app.itemCount());

    // The fixture holds web-api, web-db and loner.
    for ("db") |c| app.filterAppend(c);
    try std.testing.expectEqual(@as(usize, 1), app.itemCount());
    try std.testing.expectEqual(@as(usize, 3), app.totalFor(.containers));

    // The cursor is at row 0, which is now web-db rather than web-api. An
    // action must follow the visible row, not the underlying index.
    app.cursor[@intFromEnum(Tab.containers)] = 0;
    app.request(.container_delete);
    try std.testing.expect(app.pending != null);
    app.runPending();

    const calls = try h.invocations(arena.allocator());
    try std.testing.expect(Harness.contains(calls, "delete --force web-db"));
    try std.testing.expect(!Harness.contains(calls, "delete --force web-api"));
}

test "filtering matches case-insensitively across name, image and state" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    // By image, in the wrong case.
    for ("POSTGRES") |c| app.filterAppend(c);
    try std.testing.expectEqual(@as(usize, 1), app.itemCount());

    app.cancelFilter();
    try std.testing.expectEqual(@as(usize, 3), app.itemCount());

    // By state.
    for ("stopped") |c| app.filterAppend(c);
    try std.testing.expectEqual(@as(usize, 2), app.itemCount());

    // Backspacing widens the result again.
    app.filterBackspace();
    try std.testing.expectEqual(@as(usize, 2), app.itemCount());

    // Nothing matches: an empty list, not an error.
    app.cancelFilter();
    for ("zzzz") |c| app.filterAppend(c);
    try std.testing.expectEqual(@as(usize, 0), app.itemCount());
    try std.testing.expectEqual(@as(?[]const u8, null), app.currentTarget());
}

test "sorting orders by the chosen column and reverses" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    const nameAt = struct {
        fn get(a: *const App, row: usize) []const u8 {
            return a.containers[a.sourceIndex(.containers, row).?].id;
        }
    }.get;

    // Natural order: running first, then alphabetical.
    try std.testing.expectEqualStrings("web-api", nameAt(&app, 0));

    // Column 0 is the name, so ascending is strictly alphabetical.
    app.cycleSort();
    try std.testing.expectEqualStrings("loner", nameAt(&app, 0));
    try std.testing.expectEqualStrings("web-db", nameAt(&app, 2));

    app.toggleSortDirection();
    try std.testing.expectEqualStrings("web-db", nameAt(&app, 0));
    try std.testing.expectEqualStrings("loner", nameAt(&app, 2));
}

test "memory sorts numerically, not as rendered text" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    // Column 5 is memory: 256 MB, 1 GB and 2 GB in the fixture. Sorted as
    // text, "1.0 GB" would come before "256 MB".
    app.sort_column[@intFromEnum(Tab.containers)] = 5;
    app.sort_desc[@intFromEnum(Tab.containers)] = false;
    app.rebuildVisible();

    var previous: u64 = 0;
    for (0..app.itemCount()) |row| {
        const bytes = app.containers[app.sourceIndex(.containers, row).?].memory_bytes;
        try std.testing.expect(bytes >= previous);
        previous = bytes;
    }
    try std.testing.expectEqual(@as(u64, 268435456), app.containers[app.sourceIndex(.containers, 0).?].memory_bytes);
}

test "the sort column wraps back to the natural order" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    const tab = @intFromEnum(Tab.containers);
    try std.testing.expectEqual(@as(?u8, null), app.sort_column[tab]);
    for (0..sortColumnCount(.containers)) |i| {
        app.cycleSort();
        try std.testing.expectEqual(@as(?u8, @intCast(i)), app.sort_column[tab]);
    }
    app.cycleSort();
    try std.testing.expectEqual(@as(?u8, null), app.sort_column[tab]);
}

test "the copy prompt collects two paths and runs container copy" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();
    app.cursor[@intFromEnum(Tab.containers)] = 0;

    // The container side is pre-filled, so only the path has to be typed.
    app.beginCopy();
    try std.testing.expectEqualStrings("web-api:", app.promptInput());
    try std.testing.expectEqualStrings("copy from", app.promptLabel());

    for ("/etc/hosts") |c| app.promptAppend(c);
    app.submitPrompt();

    // Second step starts empty and asks for the other side.
    try std.testing.expectEqualStrings("copy to", app.promptLabel());
    try std.testing.expectEqualStrings("", app.promptInput());

    for ("/tmp/hosts") |c| app.promptAppend(c);
    app.submitPrompt();

    try std.testing.expect(app.prompt == null);
    const calls = try h.invocations(arena.allocator());
    try std.testing.expect(Harness.contains(calls, "copy web-api:/etc/hosts /tmp/hosts"));
}

test "an empty copy path cancels rather than running a half-formed command" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    app.beginCopy();
    app.promptBackspace();
    while (app.promptInput().len > 0) app.promptBackspace();
    app.submitPrompt();

    try std.testing.expect(app.prompt == null);
    const calls = try h.invocations(arena.allocator());
    for (calls) |call| try std.testing.expect(!std.mem.startsWith(u8, call, "copy"));
}

test "a failed action keeps its message through the refresh that follows" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    // Only the action fails; listing still works, so the refresh that runs
    // straight afterwards has no error of its own to report. It used to wipe
    // the action's error anyway, leaving nothing on screen.
    app.queue(.container_stop, "zc-fail");
    try std.testing.expect(app.pending != null);
    app.runPending();

    try std.testing.expect(app.status_is_error);
    try std.testing.expect(std.mem.indexOf(u8, app.status(), "zc-fail") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.status(), "no such container") != null);
    // And the lists are intact, so this really is an action-only failure.
    try std.testing.expectEqual(@as(usize, 3), app.containers.len);
}

test "a bulk action hits every marked row and nothing else" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    // Names must be copied out: runPending refreshes, which resets the arena
    // every container string lives in.
    const expect_alloc = arena.allocator();
    const first = try expect_alloc.dupe(u8, app.containers[app.sourceIndex(.containers, 0).?].id);
    const second = try expect_alloc.dupe(u8, app.containers[app.sourceIndex(.containers, 1).?].id);
    const third = try expect_alloc.dupe(u8, app.containers[app.sourceIndex(.containers, 2).?].id);

    // Mark the first two rows; toggleMark steps down, so two presses do it.
    app.cursor[@intFromEnum(Tab.containers)] = 0;
    app.toggleMark();
    app.toggleMark();
    try std.testing.expectEqual(@as(usize, 2), app.markedCount(.containers));

    app.request(.container_delete);
    try std.testing.expect(app.pending != null); // bulk always confirms
    app.runPending();

    const calls = try h.invocations(expect_alloc);
    for ([_][]const u8{ first, second }) |name| {
        const line = try std.fmt.allocPrint(expect_alloc, "delete --force {s}", .{name});
        try std.testing.expect(Harness.contains(calls, line));
    }
    const untouched = try std.fmt.allocPrint(expect_alloc, "delete --force {s}", .{third});
    try std.testing.expect(!Harness.contains(calls, untouched));

    // Marks are consumed, so the next keystroke cannot repeat the action.
    try std.testing.expectEqual(@as(usize, 0), app.markedCount(.containers));
}

test "marks are held by name, so a reorder cannot move them" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    app.cursor[@intFromEnum(Tab.containers)] = 0;
    const marked_name = app.containers[app.sourceIndex(.containers, 0).?].id;
    app.toggleMark();

    // Reversing the order must not transfer the mark to a different row.
    app.cycleSort();
    app.toggleSortDirection();

    var found = false;
    for (0..app.itemCount()) |row| {
        const index = app.sourceIndex(.containers, row).?;
        if (!app.isMarked(.containers, index)) continue;
        try std.testing.expectEqualStrings(marked_name, app.containers[index].id);
        found = true;
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 1), app.markedCount(.containers));
}

test "toggling twice leaves nothing marked" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    app.cursor[@intFromEnum(Tab.containers)] = 0;
    app.toggleMark();
    try std.testing.expectEqual(@as(usize, 1), app.markedCount(.containers));

    app.cursor[@intFromEnum(Tab.containers)] = 0;
    app.toggleMark();
    try std.testing.expectEqual(@as(usize, 0), app.markedCount(.containers));

    // With nothing marked, an action falls back to the cursor row, and start
    // runs without a confirmation the way it always has.
    app.cursor[@intFromEnum(Tab.containers)] = 0;
    app.request(.container_start);
    try std.testing.expect(app.pending == null);
}

test "each tab keeps its own filter" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    for ("pf") |c| app.filterAppend(c);
    try std.testing.expectEqual(@as(usize, 0), app.itemCount());

    // Narrowing the container list must not empty an unrelated tab.
    app.switchTab(.images);
    try std.testing.expectEqualStrings("", app.filter());
    try std.testing.expectEqual(app.totalFor(.images), app.itemCount());

    // And the container query is still there on the way back.
    app.switchTab(.containers);
    try std.testing.expectEqualStrings("pf", app.filter());
}

test "a filter survives a refresh" {
    const gpa = std.testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();

    var app: App = .init(gpa, h.io);
    defer app.deinit();
    app.refresh();

    for ("loner") |c| app.filterAppend(c);
    try std.testing.expectEqual(@as(usize, 1), app.itemCount());

    // The list reloads every few seconds; that must not silently widen it.
    app.refresh();
    try std.testing.expectEqual(@as(usize, 1), app.itemCount());
    try std.testing.expectEqualStrings("loner", app.filter());
}

test stackNameFor {
    const blank: cli.Container = .{
        .id = "",
        .image = "",
        .state = "stopped",
        .os = "",
        .arch = "",
        .ip = "",
        .gateway = "",
        .hostname = "",
        .cpus = 0,
        .memory_bytes = 0,
        .started = "",
        .created = "",
        .executable = "",
        .args = &.{},
        .workdir = "",
        .env = &.{},
        .ports = &.{},
        .mounts = &.{},
        .stack_label = "",
    };

    var pf_app = blank;
    pf_app.id = "pf-app";
    var pf_db = blank;
    pf_db.id = "pf-db";
    var lonely = blank;
    lonely.id = "solo-one";
    var labelled = blank;
    labelled.id = "buildkit";
    labelled.stack_label = "builder";

    const all = [_]cli.Container{ pf_app, pf_db, lonely, labelled };

    // A prefix two containers share names a stack.
    try std.testing.expectEqualStrings("pf", stackNameFor(pf_app, &all));
    try std.testing.expectEqualStrings("pf", stackNameFor(pf_db, &all));
    // A prefix nobody else shares does not.
    try std.testing.expectEqualStrings(standalone_stack, stackNameFor(lonely, &all));
    // A label always wins, even without a separator in the name.
    try std.testing.expectEqualStrings("builder", stackNameFor(labelled, &all));
}

test formatBytes {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.0 GB", formatBytes(&buf, 1073741824));
    try std.testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
    try std.testing.expectEqualStrings("", formatBytes(&buf, 0));
}

test parseIso8601 {
    try std.testing.expectEqual(@as(?i64, 0), parseIso8601("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i64, 1000000000), parseIso8601("2001-09-09T01:46:40Z"));
    try std.testing.expectEqual(@as(?i64, null), parseIso8601("nope"));
}

test formatAge {
    var buf: [32]u8 = undefined;
    const base = parseIso8601("2026-07-24T12:00:00Z").?;
    try std.testing.expectEqualStrings("3d ago", formatAge(&buf, "2026-07-24T12:00:00Z", base + 3 * 86400));
    try std.testing.expectEqualStrings("5m ago", formatAge(&buf, "2026-07-24T12:00:00Z", base + 300));
    try std.testing.expectEqualStrings("", formatAge(&buf, "", base));
    // `container` uses the epoch for "no date"; it must not read as an age.
    try std.testing.expectEqualStrings("", formatAge(&buf, "1970-01-01T00:00:00Z", base));
}

test firstLine {
    try std.testing.expectEqualStrings("a", firstLine("  a\nb\n"));
    try std.testing.expectEqualStrings("", firstLine("   "));
}
