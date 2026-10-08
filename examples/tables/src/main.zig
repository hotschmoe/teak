//! CLI canary for the tables example: builds one frame headlessly and prints its
//! snapshot (the GUI as text). No window, no GPU.

const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var model = App.Model.init();
    model.table.view_h = 400;
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();
    cb.theme = App.themeFor(&model);
    App.view(&model, &cb);

    const rects = try gpa.alloc(teak.Rect, cb.cmds.items.len);
    defer gpa.free(rects);
    teak.LayoutEngine.doLayout(rects, cb.cmds.items, 1000, 600, teak.monoMeasurer());
    const dump = try teak.snapshotAlloc(gpa, cb.cmds.items, rects, .{ .header = .{ .window_w = 1000, .window_h = 600 } });
    defer gpa.free(dump);
    std.debug.print("{s}", .{dump});
}

test {
    _ = App;
}
