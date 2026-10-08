//! `zig build bench` — CPU-side pipeline benchmark.
//!
//! For N rows (100 / 1k / 10k / 50k) it times, per stage, the average of
//! ITERS runs: view (emit cmds), layout, hit-test, render-build and the
//! frame-diff `cmdsEqual`; then a text-heavy case that measures real text
//! through `teak-text` (stb_truetype shaper). Output is one stable,
//! fixed-width table (stderr) in milliseconds so runs diff cleanly:
//!
//!   case    rows     cmds      view    layout       hit    render    cmdsEq
//!
//! Always built ReleaseFast. Needs a system monospace font for the text
//! case (`TEAK_FONT` overrides); without one that row prints "n/a".

const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");

const Msg = union(enum) { click: u32, noop };
const CB = teak.CmdBuffer(Msg);

const ITERS = 20;
const SIZES = [_]usize{ 100, 1_000, 10_000, 50_000 };

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn ms(total_ns: u64) f64 {
    return @as(f64, @floatFromInt(total_ns)) / ITERS / 1e6;
}

fn buildRows(cb: *CB, n: usize) void {
    var tmp: [32]u8 = undefined;
    cb.pushScroll(.{ .id = 1, .flex = 1 });
    for (0..n) |i| {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 4, .gap = 8 });
        const s = std.fmt.bufPrint(&tmp, "row {d}", .{i}) catch "x";
        cb.text(cb.arena.allocator().dupe(u8, s) catch @panic("oom"));
        cb.text("some description text");
        cb.button(.{ .click = @intCast(i) }, "Edit");
        cb.popGroup();
    }
    cb.popScroll();
}

fn buildProse(cb: *CB, n: usize) void {
    const line = "The quick brown fox jumps over the lazy dog."; // 44 B: within the measure cache's 48-byte run limit
    cb.pushScroll(.{ .id = 1, .flex = 1 });
    for (0..n) |_| cb.text(line);
    cb.popScroll();
}

const Measurer = struct {
    fn measure(_: *anyopaque, bytes: []const u8, font: teak.FontSpec) teak.TextMetrics {
        return text.measure(bytes, font);
    }
    var dummy: u8 = 0;
    fn get() teak.TextMeasurer {
        return .{ .ctx = @ptrCast(&dummy), .measure_fn = measure };
    }
};

const Row = struct { rows: usize, cmds: usize, view: f64, layout: f64, hit: f64, render: f64, eq: f64 };

fn run(gpa: std.mem.Allocator, n: usize, comptime build: fn (*CB, usize) void, measurer: teak.TextMeasurer) !Row {
    var cb = CB.init(gpa);
    defer cb.deinit();
    var prev = CB.init(gpa);
    defer prev.deinit();
    var rects: std.ArrayList(teak.Rect) = .empty;
    defer rects.deinit(gpa);
    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(gpa);
    var td: std.ArrayList(teak.TextDraw) = .empty;
    defer td.deinit(gpa);
    var im: std.ArrayList(teak.ImageDraw) = .empty;
    defer im.deinit(gpa);
    var sc: std.ArrayList(teak.SceneDraw) = .empty;
    defer sc.deinit(gpa);

    var t_view: u64 = 0;
    var t_lay: u64 = 0;
    var t_hit: u64 = 0;
    var t_ren: u64 = 0;
    var t_eq: u64 = 0;
    prev.reset();
    build(&prev, n);
    for (0..ITERS) |_| {
        const a = nowNs();
        cb.reset();
        build(&cb, n);
        const b = nowNs();
        try rects.resize(gpa, cb.cmds.items.len);
        teak.LayoutEngine.doLayout(rects.items, cb.cmds.items, 1280, 800, measurer);
        const c = nowNs();
        std.mem.doNotOptimizeAway(teak.hitTest(cb.cmds.items, rects.items, 600, 400));
        const d = nowNs();
        _ = teak.buildFrame(&verts, &td, &im, &sc, gpa, cb.cmds.items, rects.items, .{}, measurer);
        const e = nowNs();
        std.mem.doNotOptimizeAway(teak.runtime.cmdsEqual(Msg, cb.cmds.items, prev.cmds.items));
        const f = nowNs();
        t_view += b - a;
        t_lay += c - b;
        t_hit += d - c;
        t_ren += e - d;
        t_eq += f - e;
    }
    return .{ .rows = n, .cmds = cb.cmds.items.len, .view = ms(t_view), .layout = ms(t_lay), .hit = ms(t_hit), .render = ms(t_ren), .eq = ms(t_eq) };
}

fn printRow(label: []const u8, r: Row) void {
    std.debug.print("{s:<6} {d:>7} {d:>8} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3}\n", .{ label, r.rows, r.cmds, r.view, r.layout, r.hit, r.render, r.eq });
}

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    std.debug.print("teak bench ({d} iters, ms/frame)\n", .{ITERS});
    std.debug.print("{s:<6} {s:>7} {s:>8} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9}\n", .{ "case", "rows", "cmds", "view", "layout", "hit", "render", "cmdsEq" });
    for (SIZES) |n| printRow("rows", try run(gpa, n, buildRows, teak.monoMeasurer()));

    if (text.faceFor(.sans, .regular) != null) {
        for ([_]usize{ 200, 2_000 }) |n| printRow("prose", try run(gpa, n, buildProse, Measurer.get()));
    } else std.debug.print("prose  n/a (no system font; set TEAK_FONT)\n", .{});
}
