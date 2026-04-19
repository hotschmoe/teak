//! CLI canary for the tree example. Prints the initial visible tree,
//! toggles a collapsed node, and prints again. No GPU.

const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var model = App.Model.init();
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();

    std.debug.print("── Teak Tree — CLI Canary ──\n", .{});
    std.debug.print("nodes_len = {d}\n\n", .{model.nodes_len});

    std.debug.print("initial visible:\n", .{});
    printVisible(&model);

    // Find "input" (collapsed by default) and expand it.
    var input_idx: ?u16 = null;
    for (model.nodes[0..model.nodes_len], 0..) |node, i| {
        if (std.mem.eql(u8, node.label[0..node.label_len], "input")) {
            input_idx = @intCast(i);
            break;
        }
    }
    if (input_idx) |i| {
        App.update(&model, .{ .toggle = i });
        std.debug.print("\nafter toggle('input'):\n", .{});
        printVisible(&model);
    }

    // Full layout pass to confirm the pipeline end-to-end.
    App.view(&model, &cb);
    var rects: [512]teak.Rect = undefined;
    const cmds = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 700, 500);
    std.debug.print("\nframe has {d} commands\n", .{cmds.len});
}

fn printVisible(m: *const App.Model) void {
    var hide_below: u8 = std.math.maxInt(u8);
    for (m.nodes[0..m.nodes_len]) |node| {
        if (node.depth < hide_below) hide_below = std.math.maxInt(u8);
        if (node.depth >= hide_below) continue;

        var indent_buf: [64]u8 = undefined;
        const indent_n = @min(@as(usize, node.depth) * 2, indent_buf.len);
        @memset(indent_buf[0..indent_n], ' ');

        const marker: []const u8 = if (node.is_leaf)
            "  "
        else if (node.expanded)
            "v "
        else
            "> ";
        std.debug.print("  {s}{s}{s}\n", .{ indent_buf[0..indent_n], marker, node.label[0..node.label_len] });

        if (!node.is_leaf and !node.expanded) hide_below = node.depth + 1;
    }
}

test "cli trace: toggling collapsed 'input' reveals focus.zig in the next view" {
    const testing = std.testing;
    var m = App.Model.init();

    var input_idx: ?u16 = null;
    for (m.nodes[0..m.nodes_len], 0..) |node, i| {
        if (std.mem.eql(u8, node.label[0..node.label_len], "input")) {
            input_idx = @intCast(i);
            break;
        }
    }
    try testing.expect(input_idx != null);
    App.update(&m, .{ .toggle = input_idx.? });

    var cb = teak.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    App.view(&m, &cb);

    var saw_focus = false;
    for (cb.cmds.items) |c| {
        if (c == .button and std.mem.eql(u8, c.button.label, "focus.zig")) saw_focus = true;
    }
    try testing.expect(saw_focus);
}
