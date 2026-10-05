//! CLI canary for the chrome example: lays the app out headlessly with the
//! stub measurer and prints the snapshot of the top of the frame.

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
    teak.LayoutEngine.doLayout(rects, cmds, 1440, 900, teak.monoMeasurer());

    const dump = try teak.snapshotAlloc(gpa, cmds, rects, .{ .header = .{ .window_w = 1440, .window_h = 900 } });
    defer gpa.free(dump);
    std.debug.print("{s}", .{dump});
}

test {
    // Pull in the app's tests (layout geometry, update).
    std.testing.refAllDecls(App);
    _ = App;
}
