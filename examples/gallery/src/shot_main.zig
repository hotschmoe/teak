//! Headless screenshots of the gallery (no display needed):
//! `zig build shot -- out.png [--state <name>]`. One state per page and per
//! look, plus the overlays (menus, dialog, toast, tooltip, context menu).

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

const Step = teak.headless.Step;
const State = struct { name: []const u8, steps: []const Step };

const states = [_]State{
    .{ .name = "controls", .steps = &.{.{ .frames = 3 }} },
    .{ .name = "inputs", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .frames = 2 } } },
    .{ .name = "inputs_dropdown", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .click = .{ 300, 125 } }, .{ .frames = 2 } } },
    .{ .name = "inputs_combo", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .click = .{ 720, 125 } }, .{ .chars = "a" }, .{ .frames = 2 } } },
};

pub fn main(init: std.process.Init) !void {
    var path: []const u8 = "gallery.png";
    var want: []const u8 = states[0].name;
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--state")) want = it.next() orelse return error.MissingState else path = a;
    }
    for (states) |st| if (std.mem.eql(u8, st.name, want)) {
        try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{ .width = 1280, .height = 800, .steps = st.steps });
        std.debug.print("wrote {s} (state {s})\n", .{ path, st.name });
        return;
    };
    return error.UnknownState;
}
