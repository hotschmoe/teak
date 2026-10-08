//! Measured row extents of a virtual list, read from the rects the layout
//! passes already produced.
//!
//! A variable-height list cannot know its rows' heights before layout, so the
//! runtime reports them back through `virtualRowsMsg` (the same pattern as
//! `scrollLayoutMsg`): the main-axis extent of each emitted row, i.e. each
//! *direct child* of the `push_virtual_list`.

const std = @import("std");
const layout = @import("engine.zig");
const Rect = layout.Rect;

/// Main-axis extents of the direct children of the `push_virtual_list` at
/// `index`, in emission order, written into `out` (extra children are
/// ignored). Returns the number written.
pub fn rowExtents(cmds: anytype, rects: []const Rect, index: usize, out: []f32) usize {
    const vertical = cmds[index].push_virtual_list.direction == .vertical;
    var n: usize = 0;
    var depth: usize = 1;
    var i = index + 1;
    while (i < cmds.len and depth > 0) : (i += 1) {
        switch (cmds[i]) {
            .push_group, .push_virtual_list, .push_scroll, .push_overlay => {
                if (depth == 1 and n < out.len and cmds[i] != .push_overlay) {
                    out[n] = if (vertical) rects[i].h else rects[i].w;
                    n += 1;
                }
                depth += 1;
            },
            .pop_group, .pop_virtual_list, .pop_scroll, .pop_overlay => depth -= 1,
            else => if (depth == 1 and n < out.len) {
                out[n] = if (vertical) rects[i].h else rects[i].w;
                n += 1;
            },
        }
    }
    return n;
}

test "rowExtents: direct children only, groups and leaves alike" {
    const cmd = @import("../core/cmd.zig");
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    cb.pushVirtualList(.{ .total_extent = 1000, .visible_start = 5, .visible_end = 8 });
    cb.pushGroup(.{ .padding = 4, .gap = 0 });
    cb.text("a");
    cb.text("b"); // nested: not a row
    cb.popGroup();
    cb.text("c");
    cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 50 });
    cb.popGroup();
    cb.popVirtualList();
    var rects: [16]Rect = undefined;
    for (rects[0..cb.cmds.items.len], 0..) |*r, i| r.* = .{ .x = 0, .y = 0, .w = 10, .h = @floatFromInt(10 + i) };
    var out: [8]f32 = undefined;
    const n = rowExtents(cb.cmds.items, rects[0..cb.cmds.items.len], 0, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(f32, 11), out[0]); // the first group (index 1)
    try std.testing.expectEqual(@as(f32, 15), out[1]); // text "c" (index 5)
    try std.testing.expectEqual(@as(f32, 16), out[2]); // the empty group (index 6)
}
