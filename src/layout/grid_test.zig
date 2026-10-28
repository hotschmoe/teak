//! Grid layout tests (`push_grid` / `pop_grid`): column tracks (fixed /
//! auto / fr), row-major wrapping, row height, gaps and padding, cell
//! alignment, nesting, wrapped text in a column, and the other passes
//! (snapshot, hit-test, render, a11y, balance) seeing a grid.

const std = @import("std");
const testing = std.testing;
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const snapshot = @import("../core/snapshot.zig");
const hit_test = @import("../input/hit_test.zig");
const a11y = @import("../input/a11y.zig");
const engine = @import("engine.zig");
const Rect = engine.Rect;
const LayoutEngine = engine.LayoutEngine;

// 10 px per byte, 20 px line height.
const test_measurer = text.monoMeasurer();

const Msg = union(enum) { a, b, c, d };
const Buf = cmd.CmdBuffer(Msg);

fn layoutOf(cb: *Buf, rects: []Rect, w: f32, h: f32) []const Rect {
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, test_measurer);
    return rects[0..cb.cmds.items.len];
}

fn expectRect(r: Rect, x: f32, y: f32, w: f32, h: f32) !void {
    try testing.expectApproxEqAbs(x, r.x, 0.01);
    try testing.expectApproxEqAbs(y, r.y, 0.01);
    try testing.expectApproxEqAbs(w, r.w, 0.01);
    try testing.expectApproxEqAbs(h, r.h, 0.01);
}

test "grid: fixed / auto / fr columns share the stretched width" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.pushGrid(.{
        .tracks = &.{ .{ .fixed = 100 }, .auto, .{ .fr = 1 }, .{ .fr = 2 } },
        .padding = 10,
        .col_gap = 10,
        .row_gap = 5,
    });
    cb.text("a"); // 2
    cb.text("bbbbb");
    cb.text("c");
    cb.text("d");
    cb.text("x"); // 6: row 2
    cb.text("yyyyyyyy"); // widest in the auto column: 80
    cb.popGrid();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 500, 400);
    // Grid: 500 wide (stretch), 2 rows of 20 + row_gap 5 + padding 20.
    try expectRect(rs[1], 0, 0, 500, 65);
    // inner 480 - gaps 30 - fixed 100 - auto 80 = 270 -> fr 90 / 180.
    // Columns start at 10, 120, 210, 310.
    try expectRect(rs[2], 10, 10, 10, 20);
    try expectRect(rs[3], 120, 10, 50, 20);
    try expectRect(rs[4], 210, 10, 10, 20);
    try expectRect(rs[5], 310, 10, 10, 20);
    try expectRect(rs[6], 10, 35, 10, 20);
    try expectRect(rs[7], 120, 35, 80, 20);
}

test "grid: an fr column never goes below its content; the rest re-share" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGrid(.{ .columns = 2, .width = 200, .padding = 0, .col_gap = 0, .align_x = .stretch });
    cb.buttonStyled(.a, "aaaaaaaaaaaaaaaaaaaaaaaaaaa", .{ .h_padding = 0, .min_width = 0 }); // 270
    cb.buttonStyled(.b, "b", .{ .h_padding = 0, .min_width = 0 });
    cb.popGrid();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 800, 600);
    // Even split would be 100 / 100; column 0 needs 270 > 200, so it keeps
    // 270 and column 1 gets what is left (nothing, clamped at its content).
    try testing.expectApproxEqAbs(@as(f32, 270), rs[2].w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), rs[3].w, 0.01);

    // Narrower content: an even split.
    var cb2 = Buf.init(testing.allocator);
    defer cb2.deinit();
    cb2.pushGroup(.{ .padding = 0, .gap = 0 });
    cb2.pushGrid(.{ .columns = 2, .width = 200, .padding = 0, .col_gap = 0, .align_x = .stretch });
    cb2.buttonStyled(.a, "aaaaaaaaaaaaa", .{ .h_padding = 0, .min_width = 0 }); // 130
    cb2.buttonStyled(.b, "b", .{ .h_padding = 0, .min_width = 0 });
    cb2.popGrid();
    cb2.popGroup();
    const rs2 = layoutOf(&cb2, &rects, 800, 600);
    try expectRect(rs2[2], 0, 0, 130, 36); // 130 > 100: frozen
    try expectRect(rs2[3], 130, 0, 70, 36); // the remaining 70
}

test "grid: equal fr columns are equal whatever the labels (toolbar)" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.pushGrid(.{ .columns = 3, .padding = 0, .col_gap = 6, .align_x = .stretch });
    cb.button(.a, "Open");
    cb.button(.b, "Save as");
    cb.button(.c, "X");
    cb.popGrid();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 312, 200);
    // (312 - 12) / 3 = 100 each.
    try expectRect(rs[2], 0, 0, 100, 36);
    try expectRect(rs[3], 106, 0, 100, 36);
    try expectRect(rs[4], 212, 0, 100, 36);
}

test "grid: children wrap row-major; a row is as tall as its tallest cell" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGrid(.{ .tracks = &.{ .auto, .auto, .auto }, .padding = 4, .col_gap = 2, .row_gap = 3, .align_y = .center });
    cb.text("t"); // 20 tall
    cb.button(.a, "b"); // 60 x 36
    cb.canvas(.{ .width = 30, .height = 50 }, &.{}); // tallest: row 0 = 50
    cb.text("u");
    cb.text("v");
    cb.text("w"); // row 1 = 20
    cb.text("z"); // row 2 = 20, alone
    cb.popGrid();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 800, 600);
    // Columns: 10 / 60 / 30 + 2 gaps of 2 + padding 8 = 112.
    // Rows: 50 + 20 + 20 + 2 gaps of 3 + padding 8 = 104.
    try expectRect(rs[1], 0, 0, 112, 104);
    try expectRect(rs[2], 4, 4 + 15, 10, 20); // centered in the 50 row
    try expectRect(rs[3], 16, 4 + 7, 60, 36);
    try expectRect(rs[4], 78, 4, 30, 50);
    try expectRect(rs[5], 4, 57, 10, 20); // row 1 at 4 + 50 + 3
    try expectRect(rs[7], 78, 57, 10, 20);
    try expectRect(rs[8], 4, 80, 10, 20); // row 2 at 57 + 20 + 3
}

test "grid: a nested group is one cell; stretch fills the cell" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.pushGrid(.{ .tracks = &.{ .auto, .{ .fr = 1 } }, .padding = 0, .col_gap = 10, .row_gap = 0, .align_x = .stretch, .align_y = .stretch });
    cb.text("Size");
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4 });
    cb.button(.a, "-");
    cb.spacer(1);
    cb.button(.b, "+");
    cb.popGroup();
    cb.text("Name");
    cb.textInput(.c, "", 0);
    cb.popGrid();
    cb.popGroup();

    var rects: [20]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 400, 300);
    // auto column = 40 ("Size" / "Name"); fr column = 400 - 40 - 10 = 350.
    try expectRect(rs[2], 0, 0, 40, 36); // stretched to the row height
    try expectRect(rs[3], 50, 0, 350, 36); // the nested group fills the cell
    // Its children lay out inside it: "+" pinned to the far end by the spacer.
    try testing.expectApproxEqAbs(@as(f32, 50), rs[4].x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 400 - 60), rs[7].x, 0.01);
    // Row 1: the text input takes the column width.
    try expectRect(rs[10], 50, 36, 350, rs[10].h);
}

test "grid: inside a vertical group with flex, and a flex group beside it" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.text("header");
    cb.pushGrid(.{ .columns = 2, .flex = 1, .padding = 0, .bg = .{ 0, 0, 0, 1 } });
    cb.text("a");
    cb.text("b");
    cb.popGrid();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 300, 200);
    // The grid takes the leftover height and the full width.
    try expectRect(rs[2], 0, 20, 300, 180);
    // Two fr columns: (300 - 8) / 2 = 146.
    try testing.expectApproxEqAbs(@as(f32, 154), rs[4].x, 0.01);

    // Horizontal parent: the grid flexes along the row.
    var cb2 = Buf.init(testing.allocator);
    defer cb2.deinit();
    cb2.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb2.text("side");
    cb2.pushGrid(.{ .columns = 1, .flex = 1, .padding = 0 });
    cb2.text("a");
    cb2.popGrid();
    cb2.popGroup();
    const rs2 = layoutOf(&cb2, &rects, 300, 200);
    try expectRect(rs2[2], 40, 0, 260, 20);
}

test "grid: wrapped text in an fr column wraps to the column" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.pushGrid(.{ .tracks = &.{ .auto, .{ .fr = 1 } }, .padding = 0, .col_gap = 10, .row_gap = 0 });
    cb.text("Note");
    cb.paragraph("aaaa bbbb cccc dddd"); // 190 wide unwrapped
    cb.text("Next");
    cb.text("v");
    cb.popGrid();
    cb.popGroup();

    var rects: [12]Rect = undefined;
    const st = LayoutEngine.doLayoutStats(rects[0..cb.cmds.items.len], cb.cmds.items, 150, 400, test_measurer);
    try testing.expect(st.wrap_passes);
    const rs = rects[0..cb.cmds.items.len];
    // fr column = 150 - 40 - 10 = 100: "aaaa bbbb " fits per line -> 2 lines.
    try testing.expect(rs[3].w <= 100.01);
    try testing.expectApproxEqAbs(@as(f32, 40), rs[3].h, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 50), rs[3].x, 0.01);
    // Row 1 starts below the two-line row.
    try testing.expectApproxEqAbs(@as(f32, 40), rs[4].y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 60), rs[1].h, 0.01);
}

test "grid: empty grid and fewer children than columns" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGrid(.{ .columns = 3, .padding = 5, .col_gap = 10 });
    cb.popGrid();
    cb.pushGrid(.{ .tracks = &.{ .auto, .auto, .{ .fixed = 7 } }, .padding = 0, .col_gap = 1 });
    cb.text("a");
    cb.popGrid();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 300, 200);
    try testing.expectApproxEqAbs(@as(f32, 30), rs[1].w, 0.01); // only gaps + padding
    try testing.expectApproxEqAbs(@as(f32, 10), rs[1].h, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10 + 0 + 7 + 2), rs[3].w, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), rs[3].h, 0.01);
}

test "grid: an overlay inside a grid takes no cell" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGrid(.{ .tracks = &.{ .auto, .auto }, .padding = 0, .col_gap = 0 });
    cb.text("a");
    cb.pushOverlay(.{ .x = 200, .y = 200 });
    cb.text("tip");
    cb.popOverlay();
    cb.text("bb");
    cb.popGrid();
    cb.popGroup();

    var rects: [12]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 400, 400);
    try expectRect(rs[6], 10, 0, 20, 20); // "bb" is cell 1 (row 0, col 1)
    try testing.expectApproxEqAbs(@as(f32, 200), rs[3].x, 0.01);
}

test "grid: golden snapshot of a key/value panel" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.pushGrid(.{ .tracks = &.{ .auto, .{ .fr = 1 } }, .padding = 8, .col_gap = 12, .row_gap = 4, .align_y = .center, .bg = .{ 0.1, 0.1, 0.1, 1 } });
    cb.text("Width");
    cb.textInput(.a, "120", 0);
    cb.text("Material");
    cb.button(.b, "Oak");
    cb.popGrid();
    cb.popGroup();

    var rects: [12]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 400, 300);
    try snapshot.expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,400,300) vertical
        \\  grid (0,0,400,84) cols=2 bg
        \\    text (8,12,50,20) "Width"
        \\    text_input (100,8,292,28) "120" cursor=0
        \\    text (8,48,80,20) "Material"
        \\    button (100,40,60,36) "Oak"
        \\
    );
}

test "grid: hit-test finds a button in a cell; render fills bg; a11y sees a group" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGrid(.{ .columns = 2, .width = 200, .padding = 0, .col_gap = 0, .row_gap = 0, .bg = .{ 0.2, 0.2, 0.2, 1 } });
    cb.button(.a, "A");
    cb.button(.b, "B");
    cb.button(.c, "C");
    cb.button(.d, "D");
    cb.popGrid();
    cb.popGroup();

    var rects: [12]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 400, 300);
    // D is row 1, column 1: x 100, y 36.
    try expectRect(rs[5], 100, 36, 60, 36);
    const hit = hit_test.hitTest(cb.cmds.items, rs, 130, 50).?;
    try testing.expectEqual(@as(usize, 5), hit.index);
    try testing.expectEqual(Msg.d, hit.msg.?);
    try testing.expect(hit_test.hitTest(cb.cmds.items, rs, 180, 50) == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = try a11y.buildTree(arena.allocator(), cb.cmds.items, rs, null);
    // root group, grid, 4 buttons; the buttons' parent is the grid node.
    try testing.expectEqual(@as(usize, 6), nodes.len);
    try testing.expectEqual(a11y.Role.group, nodes[1].role);
    try testing.expectEqual(@as(@TypeOf(nodes[1].cmd_index), 1), nodes[1].cmd_index);
    try testing.expectEqual(nodes[5].parent, nodes[2].parent);
}

test "grid: validateBalance knows the pair" {
    var cb = Buf.init(testing.allocator);
    defer cb.deinit();
    cb.pushGrid(.{ .columns = 2 });
    cb.text("a");
    cb.popGroup();
    const err = cmd.validateBalance(cb.cmds.items).?;
    try testing.expectEqual(cmd.BalanceError.Tag.mismatched_pop, err.tag);
    try testing.expectEqual(cmd.BalanceKind.grid, err.open_kind);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("push_grid at cmd #0 was closed by pop_group at cmd #2", cmd.formatBalanceError(err, &buf));

    var ok = Buf.init(testing.allocator);
    defer ok.deinit();
    ok.pushGroup(.{});
    ok.pushGrid(.{ .columns = 2 });
    ok.pushGroup(.{});
    ok.popGroup();
    ok.popGrid();
    ok.popGroup();
    try testing.expectEqual(@as(?cmd.BalanceError, null), cmd.validateBalance(ok.cmds.items));
}

test "grid: columnCount clamps and missing tracks are fr 1" {
    const g: cmd.GridStyle = .{ .columns = 3, .tracks = &.{.auto} };
    try testing.expectEqual(@as(usize, 3), g.columnCount());
    try testing.expectEqual(cmd.GridTrack.auto, g.track(0));
    try testing.expectEqual(cmd.GridTrack{ .fr = 1 }, g.track(2));
    try testing.expectEqual(@as(usize, 1), (cmd.GridStyle{}).columnCount());
    try testing.expectEqual(@as(usize, cmd.MAX_GRID_COLUMNS), (cmd.GridStyle{ .columns = 999 }).columnCount());
}
