//! A hardware monitor in the manner of a task manager: CPU, memory, disk and
//! network history, a live process table, temperatures.
//!
//! The App never touches the OS. The entry point owns a sys.Sampler and posts
//! each reading as a .sample Msg (Runtime.post); the Model keeps the latest
//! reading and sixty seconds of history, and view draws from that alone.

const std = @import("std");
const teak = @import("teak");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const Prim = teak.CanvasPrimitive;
const Color = [4]f32;

pub const history_len = 60;
pub const sample_interval_ms = 1000;

pub const TABLE_ID: u32 = 1;
pub const GRIP_BASE: u32 = 100;

pub const Table = teak.DataTable(.{ .max_rows = sys.max_procs, .max_cols = 8 });

pub const Page = enum { performance, processes, sensors };
pub const Device = enum { cpu, memory, disk, network };

pub const columns = [_]teak.DataTableColumn{
    .{ .title = "Name", .width = 320 },
    .{ .title = "PID", .width = 90, .cell_align = .right },
    .{ .title = "CPU %", .width = 90, .cell_align = .right },
    .{ .title = "Memory", .width = 120, .cell_align = .right },
    .{ .title = "Threads", .width = 90, .cell_align = .right },
};
const col_cpu = 2;

const cpu_color: Color = .{ 0.30, 0.66, 0.96, 1 };
const mem_color: Color = .{ 0.71, 0.50, 0.94, 1 };
const disk_color: Color = .{ 0.45, 0.80, 0.42, 1 };
const net_color: Color = .{ 0.96, 0.62, 0.26, 1 };

const sidebar_w: f32 = 300;
const table_pad: f32 = 12;
const pad: f32 = 16;

pub const History = struct {
    v: [history_len]f32 = @splat(0),

    pub fn push(h: *History, x: f32) void {
        std.mem.copyForwards(f32, h.v[0 .. history_len - 1], h.v[1..]);
        h.v[history_len - 1] = x;
    }

    pub fn peak(h: *const History) f32 {
        var m: f32 = 0;
        for (h.v) |x| m = @max(m, x);
        return m;
    }
};

/// Everything a sample feeds. Too big for a stack Model (Windows has 1 MiB).
pub const Data = struct {
    s: sys.Sample = .{},
    n_samples: u32 = 0,
    cpu: History = .{},
    cores: [sys.max_cores]History = @splat(.{}),
    mem: History = .{},
    disk_read: History = .{},
    disk_write: History = .{},
    net_rx: History = .{},
    net_tx: History = .{},
    title_len: u8 = 0,
    title_buf: [48]u8 = undefined,
};

pub const Msg = union(enum) {
    /// Valid until update returns; update copies it.
    sample: *const sys.Sample,
    page: Page,
    device: Device,
    per_core: bool,
    pause: bool,
    window: [2]f32,
    table: Table.Msg,
};

pub const Model = struct {
    page: Page = .performance,
    device: Device = .cpu,
    per_core: bool = false,
    paused: bool = false,
    win_w: f32 = 1100,
    win_h: f32 = 720,
    data: *Data,
    table: *Table.Model,

    pub fn init() Model {
        const a = std.heap.page_allocator;
        var m: Model = .{
            .data = a.create(Data) catch @panic("oom"),
            .table = a.create(Table.Model) catch @panic("oom"),
        };
        m.data.* = .{};
        m.table.* = .{};
        m.table.setColumns(&columns);
        m.table.sort_col = col_cpu;
        m.table.sort_desc = true;
        fitNameColumn(&m);
        return m;
    }
};

const Rows = struct {
    s: *const sys.Sample,

    pub fn cell(self: Rows, arena: Allocator, col: u8, row: u32) []const u8 {
        const p = &self.s.procs[row];
        return switch (col) {
            0 => p.name(),
            1 => std.fmt.allocPrint(arena, "{d}", .{p.pid}) catch "?",
            2 => std.fmt.allocPrint(arena, "{d:.1}", .{p.cpu_pct}) catch "?",
            3 => fmtBytes(arena, p.rss_bytes),
            else => std.fmt.allocPrint(arena, "{d}", .{p.threads}) catch "?",
        };
    }

    pub fn compare(self: Rows, col: u8, a: u32, b: u32) std.math.Order {
        const pa = &self.s.procs[a];
        const pb = &self.s.procs[b];
        return switch (col) {
            0 => std.ascii.orderIgnoreCase(pa.name(), pb.name()),
            1 => std.math.order(pa.pid, pb.pid),
            2 => std.math.order(pa.cpu_pct, pb.cpu_pct),
            3 => std.math.order(pa.rss_bytes, pb.rss_bytes),
            else => std.math.order(pa.threads, pb.threads),
        };
    }
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .sample => |s| if (!m.paused) takeSample(m, s),
        .page => |p| m.page = p,
        .device => |d| m.device = d,
        .per_core => |on| m.per_core = on,
        .pause => |on| m.paused = on,
        .window => |wh| {
            m.win_w = wh[0];
            m.win_h = wh[1];
            fitNameColumn(m);
        },
        .table => |t| Table.update(m.table, t, Rows{ .s = &m.data.s }),
    }
}

/// The name column takes what the fixed columns leave, so the table spans the window.
fn fitNameColumn(m: *Model) void {
    var rest: f32 = 0;
    for (m.table.widths[1..columns.len]) |w| rest += w;
    m.table.widths[0] = @max(160, m.win_w - 2 * table_pad - rest);
}

fn takeSample(m: *Model, s: *const sys.Sample) void {
    const d = m.data;
    const t = m.table;

    const same_set = sameProcs(&d.s, s);
    var kept: [64]u32 = undefined;
    var n_kept: usize = 0;
    var cursor_pid: ?u32 = null;
    if (!same_set) {
        var rows: [kept.len]u32 = undefined;
        n_kept = t.selectedRows(&rows);
        for (rows[0..n_kept], 0..) |row, i| kept[i] = d.s.procs[row].pid;
        if (t.has_cursor and t.cursor < d.s.n_procs and t.isSelected(t.cursor)) cursor_pid = d.s.procs[t.cursor].pid;
    }

    d.s = s.*;
    d.n_samples +|= 1;
    d.mem.push(if (s.mem_total > 0) 100.0 * ratio(s.memUsed(), s.mem_total) else 0);
    if (s.rates_valid) {
        d.cpu.push(s.cpu_pct);
        for (0..s.n_cores) |i| d.cores[i].push(s.core_pct[i]);
        d.disk_read.push(s.disk_read_bps);
        d.disk_write.push(s.disk_write_bps);
        d.net_rx.push(s.net_rx_bps);
        d.net_tx.push(s.net_tx_bps);
    }
    const title = std.fmt.bufPrint(&d.title_buf, "System Monitor - CPU {d:.0}%", .{s.cpu_pct}) catch "System Monitor";
    d.title_len = @intCast(title.len);

    const src = Rows{ .s = &d.s };
    if (same_set) {
        t.resort(src);
        return;
    }
    t.reload(d.s.n_procs, src);
    for (kept[0..n_kept]) |pid| {
        if (d.s.findPid(pid)) |row| t.select(row);
    }
    if (cursor_pid) |pid| {
        if (d.s.findPid(pid)) |row| t.select(row);
    }
}

fn sameProcs(a: *const sys.Sample, b: *const sys.Sample) bool {
    if (a.n_procs != b.n_procs) return false;
    for (a.procs[0..a.n_procs], b.procs[0..b.n_procs]) |pa, pb| {
        if (pa.pid != pb.pid) return false;
    }
    return true;
}

pub fn pointerMsg(_: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (ev.asScroll()) |s| {
        return if (s.id == TABLE_ID) .{ .table = .{ .wheel = s.dy } } else null;
    }
    if (ev.asCanvas()) |c| {
        const g = Table.gripMsg(c, GRIP_BASE) orelse return null;
        return .{ .table = g };
    }
    return null;
}

pub fn scrollLayoutMsg(_: *const Model, id: u32, vw: f32, vh: f32, cw: f32, ch: f32) ?Msg {
    if (id != TABLE_ID) return null;
    return .{ .table = .{ .viewport = .{ .vw = vw, .vh = vh, .cw = cw, .ch = ch } } };
}

pub fn modsMsg(_: *const Model, mods: teak.Modifiers) ?Msg {
    return .{ .table = .{ .mods = mods } };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    if (m.page != .processes) return null;
    return if (Table.keyMsg(key, m.table.mods)) |k| .{ .table = k } else null;
}

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    if (m.page != .processes or !m.table.focused) return null;
    return if (Table.charMsg(c)) |k| .{ .table = k } else null;
}

pub fn animationMsg(_: *const Model, dt_ms: u32) ?Msg {
    return .{ .table = .{ .frame = dt_ms } };
}

const anim_subs = [_]teak.Sub(Msg){.animation_frame};

pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    return if (m.table.animating()) &anim_subs else &.{};
}

pub fn windowMsg(_: *const Model, w: f32, h: f32) ?Msg {
    return .{ .window = .{ w, h } };
}

pub fn windowTitle(m: *const Model) ?[]const u8 {
    return if (m.data.title_len > 0) m.data.title_buf[0..m.data.title_len] else null;
}

pub fn themeFor(_: *const Model) teak.Theme {
    return teak.Theme.modern_dark;
}

const table_msgs = struct {
    pub fn sort(col: u8) Msg {
        return .{ .table = .{ .sort = col } };
    }
    pub fn row(display: u32) Msg {
        return .{ .table = .{ .row = display } };
    }
};

fn ratio(part: u64, whole: u64) f32 {
    return @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(@max(whole, 1)));
}

fn fade(c: Color, alpha: f32) Color {
    return .{ c[0], c[1], c[2], alpha };
}

fn print(arena: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "?";
}

pub fn fmtBytes(arena: Allocator, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    if (u == 0) return print(arena, "{d:.0} B", .{v});
    return if (v >= 100) print(arena, "{d:.0} {s}", .{ v, units[u] }) else print(arena, "{d:.1} {s}", .{ v, units[u] });
}

fn fmtRate(arena: Allocator, bytes_per_s: f32) []const u8 {
    return print(arena, "{s}/s", .{fmtBytes(arena, @intFromFloat(@max(bytes_per_s, 0)))});
}

fn fmtUptime(arena: Allocator, secs: u64) []const u8 {
    const d = secs / 86400;
    const h = (secs % 86400) / 3600;
    const mi = (secs % 3600) / 60;
    const s = secs % 60;
    if (d > 0) return print(arena, "{d}d {d:0>2}:{d:0>2}:{d:0>2}", .{ d, h, mi, s });
    return print(arena, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, mi, s });
}

/// A rate axis that does not jump at every sample: the next power of two, 64 KB/s at least.
fn rateCeiling(peak_a: f32, peak_b: f32) f32 {
    var top: f32 = 64 * 1024;
    while (top < @max(peak_a, peak_b)) top *= 2;
    return top;
}

const ChartOpts = struct {
    w: f32,
    h: f32,
    max: f32,
    color: Color,
    second: ?[]const f32 = null,
    second_color: Color = .{ 1, 1, 1, 1 },
    grid: bool = true,
};

fn chartPrims(cb: anytype, series: []const f32, o: ChartOpts) []const Prim {
    const arena = cb.arena.allocator();
    const grid_color = fade(cb.theme.palette.border, 0.55);
    const first = teak.chart.lineChartPrimitives(arena, series, .{
        .width = o.w,
        .height = o.h,
        .min = 0,
        .max = o.max,
        .padding = 0,
        .line_color = o.color,
        .line_thickness = 1.5,
        .grid_color = grid_color,
        .grid_lines = if (o.grid) 5 else 0,
        .fill = fade(o.color, 0.16),
    });
    const second: []const Prim = if (o.second) |s| teak.chart.lineChartPrimitives(arena, s, .{
        .width = o.w,
        .height = o.h,
        .min = 0,
        .max = o.max,
        .padding = 0,
        .line_color = o.second_color,
        .line_thickness = 1.5,
        .grid_lines = 0,
    }) else &.{};
    const n_vlines: usize = if (o.grid) 5 else 0;
    const out = arena.alloc(Prim, n_vlines + first.len + second.len) catch return first;
    for (0..n_vlines) |i| {
        const x = o.w * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n_vlines + 1));
        out[i] = .{ .vline = .{ .x = x, .color = grid_color } };
    }
    @memcpy(out[n_vlines..][0..first.len], first);
    @memcpy(out[n_vlines + first.len ..], second);
    return out;
}

fn chart(cb: anytype, series: []const f32, o: ChartOpts) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .padding = 1, .gap = 0, .border = fade(o.color, 0.55) });
    cb.canvas(.{ .width = o.w - 2, .height = o.h - 2, .bg = pal.bg_sunken, .antialias = true }, chartPrims(cb, series, .{
        .w = o.w - 2,
        .h = o.h - 2,
        .max = o.max,
        .color = o.color,
        .second = o.second,
        .second_color = o.second_color,
        .grid = o.grid,
    }));
    cb.popGroup();
}

fn rects(arena: Allocator, list: []const Prim.FilledRect) []const Prim {
    const out = arena.alloc(Prim, list.len) catch return &.{};
    for (list, out) |r, *o| o.* = .{ .filled_rect = r };
    return out;
}

const small: teak.FontSpec = .{ .size_px = 12 };
const body: teak.FontSpec = .{ .size_px = 14 };
const big: teak.FontSpec = .{ .size_px = 20 };
const title_font: teak.FontSpec = .{ .size_px = 24, .weight = .bold };

fn stat(cb: anytype, label: []const u8, value: []const u8) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .padding = 0, .gap = 2 });
    cb.textStyled(label, small, pal.fg_muted);
    cb.textStyled(value, big, pal.fg);
    cb.popGroup();
}

fn pushStats(cb: anytype, w: f32) void {
    const cols: u16 = @intFromFloat(std.math.clamp(@floor(w / 170), 2, 6));
    cb.pushGrid(.{ .columns = cols, .padding = 0, .col_gap = 24, .row_gap = 12 });
}

fn caption(cb: anytype, left: []const u8, right: []const u8) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8 });
    cb.textStyled(left, small, pal.fg_muted);
    cb.spacer(1);
    cb.textStyled(right, small, pal.fg_muted);
    cb.popGroup();
}

fn tabButton(cb: anytype, m: *const Model, page: Page, label: []const u8) void {
    var s = if (m.page == page) cb.theme.button_primary else cb.theme.button;
    s.min_width = 110;
    s.height = 30;
    s.label_align = .center;
    cb.buttonStyled(.{ .page = page }, label, s);
}

fn deviceCard(cb: anytype, m: *const Model, dev: Device, name: []const u8, value: []const u8, series: []const f32, max: f32, color: Color) void {
    const pal = cb.theme.palette;
    const on = m.device == dev;
    cb.pushGroup(.{
        .direction = .horizontal,
        .padding = 8,
        .gap = 10,
        .align_cross = .center,
        .bg = if (on) pal.bg_raised else null,
        .border = if (on) fade(color, 0.7) else null,
        .radius = cb.theme.tokens.radii(.md),
    });
    const spark = chartPrims(cb, series, .{ .w = 72, .h = 40, .max = max, .color = color, .grid = false });
    cb.canvasClickable(.{ .device = dev }, .{ .width = 72, .height = 40, .bg = pal.bg_sunken, .antialias = true }, spark, name);
    cb.pushGroup(.{ .padding = 0, .gap = 0, .flex = 1 });
    var s = cb.theme.button;
    s.bg = .{ 0, 0, 0, 0 };
    s.hover_bg = .{ 0, 0, 0, 0 };
    s.press_bg = .{ 0, 0, 0, 0 };
    s.border = null;
    s.fg = pal.fg;
    s.hover_fg = color;
    s.h_padding = 0;
    s.min_width = 0;
    s.height = 22;
    s.label_align = .start;
    s.soft_shadow = null;
    s.gradient = null;
    cb.buttonStyled(.{ .device = dev }, name, s);
    cb.textStyled(value, small, pal.fg_muted);
    cb.popGroup();
    cb.popGroup();
}

fn sidebar(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    const pal = cb.theme.palette;
    const d = m.data;
    const s = &d.s;
    cb.pushGroup(.{ .padding = 8, .gap = 4, .width = sidebar_w, .bg = pal.bg_panel, .align_cross = .stretch });
    deviceCard(cb, m, .cpu, "CPU", print(arena, "{d:.0}%  {d:.2} GHz", .{ s.cpu_pct, s.cpu_mhz / 1000 }), &d.cpu.v, 100, cpu_color);
    deviceCard(cb, m, .memory, "Memory", print(arena, "{s} of {s} ({d:.0}%)", .{
        fmtBytes(arena, s.memUsed()),
        fmtBytes(arena, s.mem_total),
        100 * ratio(s.memUsed(), s.mem_total),
    }), &d.mem.v, 100, mem_color);
    deviceCard(cb, m, .disk, "Disk", print(arena, "R {s} W {s}", .{ fmtRate(arena, s.disk_read_bps), fmtRate(arena, s.disk_write_bps) }), &d.disk_read.v, rateCeiling(d.disk_read.peak(), 0), disk_color);
    deviceCard(cb, m, .network, "Network", print(arena, "Rx {s} Tx {s}", .{ fmtRate(arena, s.net_rx_bps), fmtRate(arena, s.net_tx_bps) }), &d.net_rx.v, rateCeiling(d.net_rx.peak(), 0), net_color);
    cb.popGroup();
}

fn detailHead(cb: anytype, name: []const u8, right: []const u8) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 12, .align_cross = .end });
    cb.textStyled(name, title_font, pal.fg);
    cb.spacer(1);
    cb.textStyled(right, body, pal.fg_muted);
    cb.popGroup();
}

fn coreGrid(m: *const Model, cb: anytype, w: f32, h: f32) void {
    const s = &m.data.s;
    const n: u32 = @max(s.n_cores, 1);
    const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n)) * 2)));
    const rows: u32 = (n + cols - 1) / cols;
    const gap: f32 = 6;
    const cell_w = @floor((w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols)));
    const cell_h = @max(28, @floor((h - gap * @as(f32, @floatFromInt(rows - 1))) / @as(f32, @floatFromInt(rows))));
    cb.pushGroup(.{ .padding = 0, .gap = gap });
    var core: u32 = 0;
    for (0..rows) |_| {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = gap });
        for (0..cols) |_| {
            if (core == n) break;
            chart(cb, &m.data.cores[core].v, .{ .w = cell_w, .h = cell_h, .max = 100, .color = cpu_color, .grid = false });
            core += 1;
        }
        cb.popGroup();
    }
    cb.popGroup();
}

fn detail(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    const d = m.data;
    const s = &d.s;
    const w = @max(280, m.win_w - sidebar_w - 2 * pad);
    const h = std.math.clamp(m.win_h - 300, 160, 600);

    cb.pushGroup(.{ .padding = pad, .gap = 10, .flex = 1, .align_cross = .stretch });
    switch (m.device) {
        .cpu => {
            detailHead(cb, "CPU", s.cpuName());
            caption(cb, "% utilization, last 60 seconds", "100%");
            if (m.per_core) coreGrid(m, cb, w, h) else chart(cb, &d.cpu.v, .{ .w = w, .h = h, .max = 100, .color = cpu_color });
            cb.checkbox(.{ .per_core = !m.per_core }, m.per_core, "Logical processors");
            pushStats(cb, w);
            stat(cb, "Utilization", print(arena, "{d:.0}%", .{s.cpu_pct}));
            stat(cb, "Speed", print(arena, "{d:.2} GHz", .{s.cpu_mhz / 1000}));
            stat(cb, "Processes", print(arena, "{d}", .{s.n_procs}));
            stat(cb, "Threads", print(arena, "{d}", .{s.n_threads}));
            stat(cb, "Logical processors", print(arena, "{d}", .{s.n_cores}));
            stat(cb, "Up time", fmtUptime(arena, s.uptime_s));
            cb.popGrid();
        },
        .memory => {
            detailHead(cb, "Memory", fmtBytes(arena, s.mem_total));
            caption(cb, "% in use, last 60 seconds", "100%");
            chart(cb, &d.mem.v, .{ .w = w, .h = h, .max = 100, .color = mem_color });
            caption(cb, "Composition: in use, cached, free", "");
            const used = ratio(s.memUsed(), s.mem_total);
            const cached = @min(1 - used, ratio(s.mem_cached, s.mem_total));
            cb.canvas(.{ .width = w, .height = 18, .bg = cb.theme.palette.bg_sunken }, rects(arena, &.{
                .{ .x = 0, .y = 0, .w = w * used, .h = 18, .color = mem_color },
                .{ .x = w * used, .y = 0, .w = w * cached, .h = 18, .color = fade(mem_color, 0.35) },
            }));
            pushStats(cb, w);
            stat(cb, "In use", fmtBytes(arena, s.memUsed()));
            stat(cb, "Available", fmtBytes(arena, s.mem_available));
            stat(cb, "Cached", fmtBytes(arena, s.mem_cached));
            stat(cb, "Committed", print(arena, "{s} / {s}", .{ fmtBytes(arena, s.commit_used), fmtBytes(arena, s.commit_limit) }));
            if (s.swap_total > 0) stat(cb, "Swap", print(arena, "{s} / {s}", .{ fmtBytes(arena, s.swap_used), fmtBytes(arena, s.swap_total) }));
            cb.popGrid();
        },
        .disk => {
            const top = rateCeiling(d.disk_read.peak(), d.disk_write.peak());
            detailHead(cb, "Disk", "all physical disks");
            caption(cb, "Transfer rate, last 60 seconds: read (solid), write (line)", fmtRate(arena, top));
            chart(cb, &d.disk_read.v, .{ .w = w, .h = h, .max = top, .color = disk_color, .second = &d.disk_write.v, .second_color = .{ 0.85, 0.93, 0.55, 1 } });
            pushStats(cb, w);
            stat(cb, "Read", fmtRate(arena, s.disk_read_bps));
            stat(cb, "Write", fmtRate(arena, s.disk_write_bps));
            stat(cb, "Peak read", fmtRate(arena, d.disk_read.peak()));
            stat(cb, "Peak write", fmtRate(arena, d.disk_write.peak()));
            cb.popGrid();
        },
        .network => {
            const top = rateCeiling(d.net_rx.peak(), d.net_tx.peak());
            detailHead(cb, "Network", "all connected adapters");
            caption(cb, "Throughput, last 60 seconds: receive (solid), send (line)", fmtRate(arena, top));
            chart(cb, &d.net_rx.v, .{ .w = w, .h = h, .max = top, .color = net_color, .second = &d.net_tx.v, .second_color = .{ 0.98, 0.85, 0.45, 1 } });
            pushStats(cb, w);
            stat(cb, "Receive", fmtRate(arena, s.net_rx_bps));
            stat(cb, "Send", fmtRate(arena, s.net_tx_bps));
            stat(cb, "Peak receive", fmtRate(arena, d.net_rx.peak()));
            stat(cb, "Peak send", fmtRate(arena, d.net_tx.peak()));
            cb.popGrid();
        },
    }
    cb.popGroup();
}

fn sensors(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    const pal = cb.theme.palette;
    const s = &m.data.s;
    cb.pushGroup(.{ .padding = pad, .gap = 8, .flex = 1 });
    cb.textStyled("Temperatures", title_font, pal.fg);
    if (s.n_sensors == 0) {
        cb.textStyled("No temperature sensors are readable on this system.", body, pal.fg_muted);
        cb.textStyled("Linux: needs /sys/class/hwmon. Windows: temperatures are only available through WMI or vendor drivers, which this demo does not use.", small, pal.fg_muted);
    }
    const two_columns = s.n_sensors > 12 and m.win_w >= 1000;
    const bar_w: f32 = if (two_columns) 150 else 320;
    cb.pushGrid(.{ .columns = if (two_columns) 2 else 1, .padding = 0, .col_gap = 32, .row_gap = 8 });
    for (s.sensors[0..s.n_sensors]) |*sensor| {
        const frac = std.math.clamp(sensor.celsius / 100, 0, 1);
        const color = if (sensor.celsius >= 85) pal.danger else if (sensor.celsius >= 70) pal.warning else cpu_color;
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 12, .align_cross = .center });
        cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 260 });
        cb.textStyled(sensor.label(), body, pal.fg);
        cb.popGroup();
        cb.canvas(.{ .width = bar_w, .height = 10, .bg = pal.bg_sunken }, rects(arena, &.{
            .{ .x = 0, .y = 0, .w = bar_w * frac, .h = 10, .color = color },
        }));
        cb.textStyled(print(arena, "{d:.1} C", .{sensor.celsius}), body, pal.fg);
        cb.popGroup();
    }
    cb.popGrid();
    cb.popGroup();
}

fn processes(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    const pal = cb.theme.palette;
    const s = &m.data.s;
    cb.pushGroup(.{ .padding = table_pad, .gap = 8, .flex = 1, .align_cross = .stretch });
    cb.textStyled(print(arena, "{d} processes, {d} threads, {d} selected", .{ s.n_procs, s.n_threads, m.table.sel_count }), small, pal.fg_muted);
    Table.view(m.table, cb, &columns, Rows{ .s = s }, table_msgs, .{ .id = TABLE_ID, .grip_base = GRIP_BASE });
    cb.popGroup();
}

pub fn view(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    const pal = cb.theme.palette;
    const s = &m.data.s;
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });

    cb.pushGroup(.{ .direction = .horizontal, .padding = 10, .gap = 8, .align_cross = .center, .bg = pal.bg_panel });
    tabButton(cb, m, .performance, "Performance");
    tabButton(cb, m, .processes, "Processes");
    tabButton(cb, m, .sensors, "Sensors");
    cb.spacer(1);
    const status = if (m.data.n_samples == 0)
        "waiting for the first sample"
    else
        print(arena, "CPU {d:.0}%   Mem {d:.0}%   up {s}", .{ s.cpu_pct, 100 * ratio(s.memUsed(), s.mem_total), fmtUptime(arena, s.uptime_s) });
    cb.textStyled(status, .{ .size_px = 13, .family = .mono }, pal.fg_muted);
    var pause = cb.theme.button;
    pause.min_width = 80;
    pause.height = 30;
    pause.label_align = .center;
    cb.buttonStyled(.{ .pause = !m.paused }, if (m.paused) "Resume" else "Pause", pause);
    cb.popGroup();

    switch (m.page) {
        .performance => {
            cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
            sidebar(m, cb);
            detail(m, cb);
            cb.popGroup();
        },
        .processes => processes(m, cb),
        .sensors => sensors(m, cb),
    }
    cb.popGroup();
}
