//! Headless screenshot of the viewport example: `zig build shot -- out.png [--zoom Z] [--scale S]`.
//! `--zoom` sets the canvas zoom (the canvas labels are scalable text: one distance-field glyph set
//! serves every zoom); `--scale` renders HiDPI.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    var path: []const u8 = "viewport.png";
    var zoom: f32 = 1;
    var scale: f32 = 1;
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--zoom")) {
            zoom = std.fmt.parseFloat(f32, it.next() orelse "1") catch 1;
        } else if (std.mem.eql(u8, a, "--scale")) {
            scale = std.fmt.parseFloat(f32, it.next() orelse "1") catch 1;
        } else path = a;
    }
    const gpa = init.gpa;
    var host = try Host.init(gpa, 900, 520);
    defer host.deinit();
    var gpu = try Gpu.initOffscreen(900, 520, .{ .msaa = false, .scale = scale });
    defer gpu.deinit();
    var rt = try teak.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, .{ .idle_skip = false });
    defer rt.deinit();
    for (0..3) |_| try rt.frame();
    // Zoom about the canvas centre so a different set of labels fills the view.
    rt.model.zoom = zoom;
    rt.model.pan_x = 280 - 130 * zoom;
    rt.model.pan_y = 230 - 100 * zoom;
    for (0..3) |_| try rt.frame();
    std.debug.print("zoom {d:.2}, atlas pages {d}\n", .{ zoom, gpu.text.atlas.pageCount() });
    try teak.headless.writeFramePng(&gpu, gpa, path);
    std.debug.print("wrote {s}\n", .{path});
}
