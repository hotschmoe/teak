//! Headless screenshot + frame-time bench of the tables example (no display):
//!
//!   zig build shot -Doptimize=ReleaseFast -- out.png [--tab table|list|tree] [--bench]
//!
//! `--bench` scrolls the page by a fresh offset every frame (so every frame
//! re-emits its visible rows) and reports the warm CPU time of a whole
//! `Runtime.frame` (view + layout + render + upload + submit), the number a
//! display-rate scroll has to stay under.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

const Opts = struct { path: []const u8 = "tables.png", tab: App.Tab = .table, bench: bool = false, sort: bool = false };

fn parseArgs(init: std.process.Init) Opts {
    var o: Opts = .{};
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--tab")) {
            o.tab = std.meta.stringToEnum(App.Tab, it.next() orelse "table") orelse .table;
        } else if (std.mem.eql(u8, a, "--bench")) {
            o.bench = true;
        } else if (std.mem.eql(u8, a, "--sort")) {
            o.sort = true;
        } else o.path = a;
    }
    return o;
}

pub fn main(init: std.process.Init) !void {
    const o = parseArgs(init);
    const gpa = init.gpa;
    const w: u32 = 1100;
    const h: u32 = 700;
    var host = try Host.init(gpa, w, h);
    defer host.deinit();
    var gpu = try Gpu.initOffscreen(w, h, .{ .msaa = false });
    defer gpu.deinit();
    var rt = try teak.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, .{ .clear_color = .{ 0.08, 0.09, 0.11, 1 }, .idle_skip = false });
    defer rt.deinit();

    rt.model.tab = o.tab;
    for (0..4) |_| try rt.frame();
    if (o.sort) {
        App.update(&rt.model, .{ .table = .{ .sort = 4 } });
        App.update(&rt.model, .{ .table = .{ .sort = 4 } }); // price, descending
    }
    // Land somewhere deep so the shot shows virtualization, not the top.
    const sc = switch (o.tab) {
        .table => &rt.model.table.sc,
        .list => &rt.model.list.sc,
        .tree => &rt.model.tree.sc,
    };
    sc.jumpTo(@min(sc.max, 61_000 * 22));
    if (o.tab == .table) {
        App.update(&rt.model, .{ .table = .{ .row = 61_003 } });
        App.update(&rt.model, .{ .table = .{ .mods = .{ .ctrl = true } } });
        App.update(&rt.model, .{ .table = .{ .row = 61_006 } });
        App.update(&rt.model, .{ .table = .{ .mods = .{} } });
    }
    for (0..4) |_| try rt.frame();

    if (o.bench) {
        const frames = 200;
        const t0 = std.Io.Clock.awake.now(init.io);
        var y: f32 = 0;
        for (0..frames) |i| {
            y = @floatFromInt((i * 7919) % 2_000_000);
            sc.jumpTo(y + @as(f32, @floatFromInt(i % 17)) * 3);
            try rt.frame();
        }
        const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
        std.debug.print("bench[{s}]: {d} rows/nodes/messages, warm frame CPU {d:.3} ms (view+layout+render+submit)\n", .{
            @tagName(o.tab),
            switch (o.tab) {
                .table => rt.model.table.n_rows,
                .list => rt.model.list.n,
                .tree => rt.model.tree.n_visible,
            },
            @as(f64, @floatFromInt(ns)) / frames / 1e6,
        });
    }
    std.debug.print("table: pos {d:.0} max {d:.0} sel {d} sort {?d} view_h {d}\n", .{ rt.model.table.sc.pos, rt.model.table.sc.max, rt.model.table.sel_count, rt.model.table.sort_col, rt.model.table.view_h });
    try teak.headless.writeFramePng(&gpu, gpa, o.path);
    std.debug.print("wrote {s}\n", .{o.path});
}
