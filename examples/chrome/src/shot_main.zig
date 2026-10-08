//! Headless screenshot of the chrome example (no display needed):
//! `zig build shot -- out.png`. Plays a short input script against the
//! real App on the native wgpu backend and writes the last frame.
//!
//! Options (after the path): `--scale S` renders at S device px per logical
//! px (HiDPI); `--stress N` renders the text stress app with N runs instead
//! (glyph-atlas check) and prints the warm frame CPU time;
//! `--max-pages P` caps the glyph atlas (exhaustion check).

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");
const Stress = @import("textstress.zig");

const Opts = struct { path: []const u8, scale: f32 = 1, stress: usize = 0, max_pages: u8 = 8 };

fn parseArgs(init: std.process.Init) Opts {
    var o: Opts = .{ .path = "chrome.png" };
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--scale")) {
            o.scale = std.fmt.parseFloat(f32, it.next() orelse "1") catch 1;
        } else if (std.mem.eql(u8, a, "--stress")) {
            o.stress = std.fmt.parseInt(usize, it.next() orelse "640", 10) catch 640;
        } else if (std.mem.eql(u8, a, "--max-pages")) {
            o.max_pages = std.fmt.parseInt(u8, it.next() orelse "8", 10) catch 8;
        } else o.path = a;
    }
    return o;
}

pub fn main(init: std.process.Init) !void {
    const o = parseArgs(init);
    if (o.stress > 0) return stress(init, o);
    try teak.headless.shot(App, Host, Gpu, init.gpa, o.path, .{
        .width = 1280,
        .height = 800,
        .scale = o.scale,
        .run = .{ .clear_color = App.paper },
        .steps = &.{
            .{ .frames = 2 },
            .{ .click = .{ 43, 239 } }, // "< PREV": selects the previous part
            .{ .click = .{ 180, 298 } }, // focus the NAME field
            .{ .chars = "-X1" },
            .{ .move = .{ 600, 500 } },
            .{ .frames = 1 },
        },
    });
    std.debug.print("wrote {s}\n", .{o.path});
}

/// N text runs on a grid sized to fit the image; reports warm frame CPU time.
fn stress(init: std.process.Init, o: Opts) !void {
    const gpa = init.gpa;
    const many = o.stress > 640;
    const cols: usize = if (many) 48 else 16;
    const rows = (o.stress + cols - 1) / cols;
    const size_px: f32 = if (many) 8 else 11;
    const w: u32 = if (many) 1920 else 1280;
    const h: u32 = @intCast(@min(@as(usize, 8000), rows * (if (many) @as(usize, 10) else 14) + 24));

    var host = try Host.init(gpa, w, h);
    defer host.deinit();
    var gpu = try Gpu.initOffscreen(w, h, .{ .msaa = false, .scale = o.scale, .max_atlas_pages = o.max_pages });
    defer gpu.deinit();
    var rt = try teak.Runtime(Stress, Host, Gpu).init(gpa, &host, &gpu, .{});
    defer rt.deinit();
    rt.model.cols = cols;
    rt.model.rows = rows;
    rt.model.size_px = size_px;
    for (0..3) |_| try rt.frame(); // cold: shaping + rasterizing + atlas uploads

    const frames = 30;
    const t0 = std.Io.Clock.awake.now(init.io);
    for (0..frames) |_| {
        rt.model.tick +%= 1; // changes the label so the frame is not skipped as identical
        try rt.frame();
    }
    const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
    std.debug.print("stress: {d} runs, {d}x{d} px, atlas pages {d}, dropped {d}; warm frame CPU {d:.3} ms\n", .{
        o.stress,              w,                 h,
        gpu.atlas.pageCount(), gpu.atlas_dropped, @as(f64, @floatFromInt(ns)) / frames / 1e6,
    });
    try teak.headless.writeFramePng(&gpu, gpa, o.path);
    std.debug.print("wrote {s}\n", .{o.path});
}
