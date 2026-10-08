//! `qa-<example> <out-dir> [--scale S] [--state name] [--list]`: renders every
//! QA state of one example to `<out-dir>/<example>-<state>@<S>x.png`.
const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app");
const cfg = @import("qa_cfg");
const scripts = @import("scripts.zig");

pub fn main(init: std.process.Init) !void {
    const spec = comptime scripts.specFor(cfg.example);
    var out_dir: []const u8 = ".";
    var scale: f32 = 1;
    var only: ?[]const u8 = null;
    var list = false;
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--scale")) {
            scale = std.fmt.parseFloat(f32, it.next() orelse "1") catch 1;
        } else if (std.mem.eql(u8, a, "--state")) {
            only = it.next();
        } else if (std.mem.eql(u8, a, "--list")) {
            list = true;
        } else out_dir = a;
    }
    var buf: [256]u8 = undefined;
    for (spec.states) |st| {
        if (list) {
            std.debug.print("{s}\n", .{st.name});
            continue;
        }
        if (only) |o| if (!std.mem.eql(u8, o, st.name)) continue;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}-{s}@{d}x.png", .{ out_dir, cfg.example, st.name, @as(u32, @intFromFloat(scale)) });
        try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
            .width = spec.width,
            .height = spec.height,
            .scale = scale,
            .msaa = st.msaa,
            .run = .{ .clear_color = st.clear orelse scripts.clearColor(App, spec) orelse (teak.RunOptions{}).clear_color },
            .steps = st.steps,
        });
        std.debug.print("wrote {s}\n", .{path});
    }
}
