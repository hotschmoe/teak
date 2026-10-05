//! CLI canary for the viewport example: builds one frame headlessly and
//! prints its snapshot (the GUI as text). No window, no GPU.

const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const model: App.Model = .{ .view_w = 560, .view_h = 460 };
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();
    App.view(&model, &cb);

    const rects = try gpa.alloc(teak.Rect, cb.cmds.items.len);
    defer gpa.free(rects);
    teak.LayoutEngine.doLayout(rects, cb.cmds.items, 900, 520, teak.monoMeasurer());

    const snap = try teak.snapshotAlloc(gpa, cb.cmds.items, rects, .{});
    defer gpa.free(snap);
    std.debug.print("{s}", .{snap});
}
