//! CLI canary for the todo example. Drives a scripted input trace
//! through the full update → view → layout → hit-test pipeline and
//! prints the resulting frame. No GPU.

const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var model: App.Model = .{};
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();

    std.debug.print("── Teak Todo — CLI Canary ──\n", .{});

    for ([_][]const u8{ "buy milk", "ship teak", "read spec" }) |label| {
        App.update(&model, .input_focus);
        for (label) |c| App.update(&model, .{ .input_char = c });
        App.update(&model, .add_item);
    }
    std.debug.print("added 3 items; items_len = {d}\n", .{model.items_len});

    App.update(&model, .{ .toggle = 0 });
    App.update(&model, .{ .toggle = 2 });
    std.debug.print("toggled items 0 and 2\n", .{});

    App.update(&model, .clear_completed);
    std.debug.print("clear_completed -> items_len = {d}\n", .{model.items_len});
    for (model.items[0..model.items_len], 0..) |it, i| {
        std.debug.print("  [{d}] \"{s}\" done={}\n", .{ i, it.label[0..it.label_len], it.done });
    }

    App.view(&model, &cb);
    var rects: [512]teak.Rect = undefined;
    const cmds = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 800, 500, teak.monoMeasurer());

    std.debug.print("\nframe has {d} commands\n", .{cmds.len});
}

test "cli trace: add / toggle / clear_completed leaves 1 pending item" {
    const testing = std.testing;
    var model: App.Model = .{};
    for ([_][]const u8{ "a", "b", "c" }) |label| {
        for (label) |c| App.update(&model, .{ .input_char = c });
        App.update(&model, .add_item);
    }
    App.update(&model, .{ .toggle = 0 });
    App.update(&model, .{ .toggle = 2 });
    App.update(&model, .clear_completed);

    try testing.expectEqual(@as(u16, 1), model.items_len);
    try testing.expectEqualStrings("b", model.items[0].label[0..model.items[0].label_len]);
}
