//! CLI canary for the scene_layers example: lays the app out headlessly with
//! the stub measurer and prints the snapshot.

const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const model: App.Model = .{};
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();
    cb.theme = App.theme;
    App.view(&model, &cb);

    const cmds = cb.cmds.items;
    const rects = try gpa.alloc(teak.Rect, cmds.len);
    defer gpa.free(rects);
    teak.LayoutEngine.doLayout(rects, cmds, 1280, 800, teak.monoMeasurer());

    const dump = try teak.snapshotAlloc(gpa, cmds, rects, .{ .header = .{ .window_w = 1280, .window_h = 800 } });
    defer gpa.free(dump);
    std.debug.print("{s}", .{dump});
}

test {
    std.testing.refAllDecls(App);
}
