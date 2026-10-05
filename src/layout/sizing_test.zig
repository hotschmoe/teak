//! Sizing-model tests for the layout engine: fixed sizes, align, justify,
//! stretch, flex, min sizes, scroll overflow, overlays. Golden snapshots
//! assert whole screens; direct rect checks pin single numbers.


const std = @import("std");
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const snapshot = @import("../core/snapshot.zig");
const engine = @import("engine.zig");
const Rect = engine.Rect;
const LayoutEngine = engine.LayoutEngine;

const test_measurer = text.monoMeasurer();

const Msg = union(enum) { a, b, c };
const Buf = cmd.CmdBuffer(Msg);

/// view -> layout (mono measurer) -> rects, for tests that assert on rects.
fn layoutOf(cb: *Buf, rects: []Rect, w: f32, h: f32) []const Rect {
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, test_measurer);
    return rects[0..cb.cmds.items.len];
}

fn expectLayout(cb: *Buf, w: f32, h: f32, expected: []const u8) !void {
    var rects: [64]Rect = undefined;
    const rs = layoutOf(cb, &rects, w, h);
    try snapshot.expectSnapshot(cb.cmds.items, rs, .{}, expected);
}

test "golden: app shell - header 40, body flex, status 24, columns 360 / flex / 320" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    {
        // Header bar: title left, spacer, button pinned right.
        cb.pushGroup(.{ .direction = .horizontal, .pad_x = 8, .pad_y = 0, .gap = 8, .height = 40, .align_cross = .center });
        cb.text("KERF");
        cb.spacer(1);
        cb.button(.a, "Export");
        cb.popGroup();

        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
        {
            cb.pushGroup(.{ .width = 360, .padding = 8, .gap = 4, .align_cross = .stretch });
            cb.text("PARTS");
            cb.textInput(.b, "", 0);
            cb.popGroup();

            cb.pushGroup(.{ .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
            cb.canvas(.{ .width = 100, .height = 100, .flex = 1 }, &.{});
            cb.popGroup();

            cb.pushGroup(.{ .width = 320, .padding = 8, .gap = 4, .align_cross = .stretch });
            cb.text("NOTES");
            cb.popGroup();
        }
        cb.popGroup();

        cb.pushGroup(.{ .direction = .horizontal, .pad_x = 4, .pad_y = 0, .height = 24, .align_cross = .center });
        cb.text("READY");
        cb.popGroup();
    }
    cb.popGroup();

    try expectLayout(&cb, 1440, 900,
        \\group (0,0,1440,900) vertical
        \\  group (0,0,1440,40) horizontal
        \\    text (8,10,40,20) "KERF"
        \\    group (56,20,1292,0) vertical
        \\    button (1356,2,76,36) "Export"
        \\  group (0,40,1440,836) horizontal
        \\    group (0,40,360,836) vertical
        \\      text (8,48,344,20) "PARTS"
        \\      text_input (8,72,344,28) "" cursor=0
        \\    group (360,40,760,836) vertical
        \\      canvas (360,40,760,836) prims=0
        \\    group (1120,40,320,836) vertical
        \\      text (1128,48,304,20) "NOTES"
        \\  group (0,876,1440,24) horizontal
        \\    text (4,878,50,20) "READY"
        \\
    );
}

test "golden: nested stretch - a fixed width beats stretch, the rest fill the inner extent" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .padding = 10, .gap = 0, .align_cross = .stretch });
    {
        cb.pushGroup(.{ .padding = 5, .gap = 0, .align_cross = .stretch });
        cb.button(.a, "OK");
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4, .align_cross = .stretch });
        cb.button(.a, "L");
        cb.button(.b, "R");
        cb.popGroup();
        cb.text("note");
        cb.popGroup();

        cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 100 });
        cb.text("fixed");
        cb.popGroup();
    }
    cb.popGroup();

    try expectLayout(&cb, 400, 300,
        \\group (0,0,400,300) vertical
        \\  group (10,10,380,102) vertical
        \\    button (15,15,370,36) "OK"
        \\    group (15,51,370,36) horizontal
        \\      button (15,51,60,36) "L"
        \\      button (79,51,60,36) "R"
        \\    text (15,87,370,20) "note"
        \\  group (10,112,100,20) vertical
        \\    text (10,112,50,20) "fixed"
        \\
    );
}

test "golden: fixed table columns - cells keep their widths, rows stack" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    const cols = [_]f32{ 120, 80, 60 };
    const rows = [_][3][]const u8{
        .{ "PART", "QTY", "MM" },
        .{ "bolt", "4", "12" },
        .{ "a-very-long-part-name", "10", "7" },
    };
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    for (rows) |row| {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
        for (row, cols) |cell, w| {
            cb.pushGroup(.{ .padding = 0, .gap = 0, .width = w });
            cb.text(cell);
            cb.popGroup();
        }
        cb.popGroup();
    }
    cb.popGroup();

    try expectLayout(&cb, 400, 300,
        \\group (0,0,400,300) vertical
        \\  group (0,0,260,20) horizontal
        \\    group (0,0,120,20) vertical
        \\      text (0,0,40,20) "PART"
        \\    group (120,0,80,20) vertical
        \\      text (120,0,30,20) "QTY"
        \\    group (200,0,60,20) vertical
        \\      text (200,0,20,20) "MM"
        \\  group (0,20,260,20) horizontal
        \\    group (0,20,120,20) vertical
        \\      text (0,20,40,20) "bolt"
        \\    group (120,20,80,20) vertical
        \\      text (120,20,10,20) "4"
        \\    group (200,20,60,20) vertical
        \\      text (200,20,20,20) "12"
        \\  group (0,40,260,20) horizontal
        \\    group (0,40,120,20) vertical
        \\      text (0,40,210,20) "a-very-long-part-name"
        \\    group (120,40,80,20) vertical
        \\      text (120,40,20,20) "10"
        \\    group (200,40,60,20) vertical
        \\      text (200,40,10,20) "7"
        \\
    );
}

test "golden: space_between pins first and last, center and end shift the run" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    inline for (.{ .space_between, .center, .end }) |j| {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 10, .width = 400, .justify = j });
        cb.button(.a, "A");
        cb.button(.b, "B");
        cb.button(.c, "C");
        cb.popGroup();
    }
    cb.popGroup();

    try expectLayout(&cb, 500, 200,
        \\group (0,0,500,200) vertical
        \\  group (0,0,400,36) horizontal
        \\    button (0,0,60,36) "A"
        \\    button (170,0,60,36) "B"
        \\    button (340,0,60,36) "C"
        \\  group (0,36,400,36) horizontal
        \\    button (100,36,60,36) "A"
        \\    button (170,36,60,36) "B"
        \\    button (240,36,60,36) "C"
        \\  group (0,72,400,36) horizontal
        \\    button (200,72,60,36) "A"
        \\    button (270,72,60,36) "B"
        \\    button (340,72,60,36) "C"
        \\
    );
}

test "justify yields to flex children" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .space_between });
    cb.button(.a, "A");
    cb.spacer(1);
    cb.button(.b, "B");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 300, 100);
    try std.testing.expectEqual(@as(f32, 0), rs[1].x);
    try std.testing.expectEqual(@as(f32, 60), rs[2].x); // spacer
    try std.testing.expectEqual(@as(f32, 180), rs[2].w); // 300 - 2 * 60
    try std.testing.expectEqual(@as(f32, 240), rs[4].x);
}

test "spacer pins a footer to the bottom of a column" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.text("top");
    cb.spacer(1);
    cb.text("bottom");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 200, 100);
    try std.testing.expectEqual(@as(f32, 0), rs[1].y);
    try std.testing.expectEqual(@as(f32, 80), rs[4].y);
}

test "min_width / min_height floor the measured size, stretch and a fixed size" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    // Measured 50x20, floored to 200x100; the floor also beats the 150px stretch.
    cb.pushGroup(.{ .padding = 0, .gap = 0, .min_width = 200, .min_height = 100 });
    cb.text("hello");
    cb.popGroup();
    // Fixed 10x50, floored to 80x80.
    cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 10, .height = 50, .min_width = 80, .min_height = 80 });
    cb.popGroup();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 150, 400);
    try std.testing.expectEqual(@as(f32, 200), rs[1].w);
    try std.testing.expectEqual(@as(f32, 100), rs[1].h);
    try std.testing.expectEqual(@as(f32, 80), rs[4].w);
    try std.testing.expectEqual(@as(f32, 80), rs[4].h);
}

test "align_cross center / end place children on the cross axis" {
    var rects: [8]Rect = undefined;

    inline for (.{ .{ .center, 75 }, .{ .end, 150 } }) |case| {
        var cb = Buf.init(std.testing.allocator);
        defer cb.deinit();
        cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = case[0] });
        cb.text("12345"); // 50 wide in a 200 wide column
        cb.popGroup();
        const rs = layoutOf(&cb, &rects, 200, 100);
        try std.testing.expectEqual(@as(f32, case[1]), rs[1].x);
    }

    // Horizontal parent: the cross axis is vertical; a 36px button centers in 100.
    var row = Buf.init(std.testing.allocator);
    defer row.deinit();
    row.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .align_cross = .center });
    row.button(.a, "A");
    row.popGroup();
    const rs = layoutOf(&row, &rects, 200, 100);
    try std.testing.expectEqual(@as(f32, 32), rs[1].y);
}

test "pad_x / pad_y override the uniform padding per axis" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGroup(.{ .padding = 8, .pad_x = 10, .pad_y = 2, .gap = 0 });
    cb.text("12345");
    cb.popGroup();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 200, 100);
    try std.testing.expectEqual(@as(f32, 70), rs[1].w); // 50 + 2 * 10
    try std.testing.expectEqual(@as(f32, 24), rs[1].h); // 20 + 2 * 2
    try std.testing.expectEqual(@as(f32, 10), rs[2].x);
    try std.testing.expectEqual(@as(f32, 2), rs[2].y);
}

test "flex grows every leaf kind that carries a flex field" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.buttonStyled(.a, "A", .{ .flex = 1 }); // 60 + 1 unit
    cb.canvas(.{ .width = 40, .height = 10, .flex = 1 }, &.{}); // 40 + 1 unit
    cb.image(1, .{ .width = 20, .height = 10, .flex = 2 }); // 20 + 2 units
    cb.text("ab"); // 20, fixed
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 500, 100);
    // leftover = 500 - (60 + 40 + 20 + 20) = 360 -> 90 per flex unit.
    try std.testing.expectEqual(@as(f32, 150), rs[1].w);
    try std.testing.expectEqual(@as(f32, 130), rs[2].w);
    try std.testing.expectEqual(@as(f32, 200), rs[3].w);
    try std.testing.expectEqual(@as(f32, 150 + 130 + 200), rs[4].x);
}

test "a text_input only flexes along a horizontal main axis" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textInput(.a, "", 0);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 300, 500);
    try std.testing.expectEqual(@as(f32, 28), rs[1].h); // not stretched to 500
    try std.testing.expectEqual(@as(f32, 300), rs[1].w); // still fills the cross axis
}

test "scroll: a flex scroll takes the leftover and clips overflowing content" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.text("header");
    cb.pushScroll(.{ .padding = 0, .gap = 0, .flex = 1, .scroll_y = 100, .align_cross = .stretch });
    var n: usize = 0;
    while (n < 10) : (n += 1) cb.button(.a, "row"); // 360px of content
    cb.popScroll();
    cb.text("footer");
    cb.popGroup();

    var rects: [32]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 400, 300);
    // 300 - header 20 - footer 20 = 260, NOT the 360px content height.
    try std.testing.expectEqual(@as(f32, 260), rs[2].h);
    try std.testing.expectEqual(@as(f32, 400), rs[2].w);
    try std.testing.expectEqual(@as(f32, 280), rs[14].y); // footer sits below the viewport
    // Children start at viewport top minus the scroll offset and fill its width.
    try std.testing.expectEqual(@as(f32, 20 - 100), rs[3].y);
    try std.testing.expectEqual(@as(f32, 400), rs[3].w);
}

test "scroll: fixed width / height beat stretch; a fixed main size is the flex basis" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.pushScroll(.{ .padding = 0, .gap = 0, .width = 150, .height = 80 });
    cb.button(.a, "x");
    cb.popScroll();
    cb.pushScroll(.{ .padding = 0, .gap = 0, .height = 100, .flex = 1 });
    cb.popScroll();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 400, 400);
    try std.testing.expectEqual(@as(f32, 150), rs[1].w);
    try std.testing.expectEqual(@as(f32, 80), rs[1].h);
    try std.testing.expectEqual(@as(f32, 400), rs[4].w); // stretched
    try std.testing.expectEqual(@as(f32, 320), rs[4].h); // 100 basis + (400 - 180) leftover
}

test "overlay: fixed size, anchor fraction, nested stretch + flex, no parent contribution" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGroup(.{ .padding = 0, .gap = 0 }); // intrinsic parent
    cb.text("anchor");
    cb.pushOverlay(.{ .x = 300, .y = 50, .width = 200, .height = 100, .padding = 10, .gap = 0, .anchor_x_frac = 0.5, .align_cross = .stretch });
    cb.pushGroup(.{ .padding = 0, .gap = 0, .flex = 1 });
    cb.text("body");
    cb.popGroup();
    cb.popOverlay();
    cb.popGroup();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 800, 600);
    try std.testing.expectEqual(@as(f32, 60), rs[1].w); // "anchor" only, overlay ignored
    try std.testing.expectEqual(@as(f32, 20), rs[1].h);
    try std.testing.expectEqual(@as(f32, 200), rs[3].w);
    try std.testing.expectEqual(@as(f32, 100), rs[3].h);
    try std.testing.expectEqual(@as(f32, 200), rs[3].x); // 300 - 200 * 0.5
    try std.testing.expectEqual(@as(f32, 50), rs[3].y);
    // Inner box 180x80: the flex group fills its height, stretch its width.
    try std.testing.expectEqual(@as(f32, 210), rs[4].x);
    try std.testing.expectEqual(@as(f32, 60), rs[4].y);
    try std.testing.expectEqual(@as(f32, 180), rs[4].w);
    try std.testing.expectEqual(@as(f32, 80), rs[4].h);
}

test "a flex vertical scroll inside a row does not size the row to its content" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.text("HEAD"); // 20 px
    // Row: [scroll | bar], the row takes the leftover height.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
    cb.pushScroll(.{ .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
    for (0..50) |_| cb.text("a long list of rows"); // 1000 px of content
    cb.popScroll();
    cb.pushGroup(.{ .width = 6, .padding = 0, .gap = 0 });
    cb.popGroup();
    cb.popGroup();
    cb.popGroup();
    var rects: [128]Rect = undefined;
    const rs = layoutOf(&cb, &rects, 300, 400);
    try std.testing.expectEqual(@as(f32, 400), rs[0].h); // root = window
    try std.testing.expectEqual(@as(f32, 380), rs[2].h); // the row: window - head
    try std.testing.expectEqual(@as(f32, 380), rs[3].h); // the scroll viewport fills the row
}
