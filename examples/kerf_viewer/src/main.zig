//! CLI canary for the kerf_viewer example: loads the bundled fixture (or
//! `--mesh=<fixture>`), lays the app out headlessly with the stub measurer
//! and prints the snapshot.

const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var model = App.Model.init();
    defer if (model.loaded) |*l| l.deinit();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--mesh=")) App.update(&model, .{ .mesh_param = arg["--mesh=".len..] });
    }

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
    _ = @import("kerf_mesh.zig");
}
