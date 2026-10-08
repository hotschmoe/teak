//! Wrapped text and flex shrink in layout (text-engine PR8): paragraph
//! height-for-width, shrinking rows, min-content floors, scroll content, and
//! the pass-structure guarantee that frames without wrapped nodes never run
//! the extra width passes. Mono measurer: 10 px per byte, 20 px lines.

const std = @import("std");
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const text_wrap = @import("../core/text_wrap.zig");
const snapshot = @import("../core/snapshot.zig");
const engine = @import("engine.zig");
const Rect = engine.Rect;
const LayoutEngine = engine.LayoutEngine;

const mono = text.monoMeasurer();
const Msg = union(enum) { a, b };
const Buf = cmd.CmdBuffer(Msg);

fn layout(cb: *Buf, rects: []Rect, w: f32, h: f32) []const Rect {
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, mono);
    return rects[0..cb.cmds.items.len];
}

test "paragraph in a stretching column wraps to the column and grows its height" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 10, .gap = 0, .align_cross = .stretch });
    cb.paragraph("hello world foo bar"); // 19 bytes = 190 px unwrapped
    cb.button(.a, "OK");
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const rs = layout(&cb, &rects, 120, 400); // inner width 100 = 10 chars
    // "hello " / "world foo" is 9 chars... lines: "hello", "world foo", "bar"
    try std.testing.expectEqual(@as(f32, 100), rs[1].w);
    try std.testing.expectEqual(@as(f32, 60), rs[1].h); // 3 lines
    // The button below is pushed down by the paragraph's real height.
    try std.testing.expectEqual(@as(f32, 10 + 60), rs[2].y);
    try snapshot.expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,120,400) vertical
        \\  text (10,10,100,60) "hello world foo bar" wrap=word
        \\  button (10,70,100,36) "OK"
        \\
    );
}

test "natural width when it fits; cap by the room it has when it does not" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 }); // align .start
    cb.paragraph("short");
    cb.popGroup();
    var rects: [4]Rect = undefined;
    const rs = layout(&cb, &rects, 300, 100);
    try std.testing.expectEqual(@as(f32, 50), rs[1].w);
    try std.testing.expectEqual(@as(f32, 20), rs[1].h);
}

test "two paragraphs in a row shrink proportionally and re-wrap" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 10, .align_cross = .start });
    cb.paragraph("aaa bbb ccc ddd"); // 150
    cb.paragraph("eee fff ggg"); // 110
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const rs = layout(&cb, &rects, 170, 200); // needs 150+110+10 = 270, has 170: deficit 100
    // shrink ~ weight*width: 150/260*100 = 57.7 off the first, 42.3 off the second.
    try std.testing.expectApproxEqAbs(@as(f32, 92.3), rs[1].w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 67.7), rs[2].w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 170 - 10), rs[1].w + rs[2].w, 0.01);
    // Both re-wrapped taller than one line; the row is as tall as the taller one.
    try std.testing.expect(rs[1].h >= 40 and rs[2].h >= 40);
}

test "shrink stops at min-content and the deficit moves to the other child" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.paragraph("supercalifragilistic is long"); // min-content 20 chars = 200
    cb.paragraph("aa bb cc dd ee ff"); // 170, min 20
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const rs = layout(&cb, &rects, 300, 200);
    try std.testing.expect(rs[1].w >= 200);
    try std.testing.expect(rs[2].w >= 20);
    try std.testing.expectApproxEqAbs(@as(f32, 300), rs[1].w + rs[2].w, 0.01);
}

test "flex + shrink: a flex sibling keeps its basis while a paragraph shrinks" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.button(.a, "BUTTON"); // 6*10+16 = 76
    cb.paragraph("one two three four five"); // 230
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const rs = layout(&cb, &rects, 200, 200);
    try std.testing.expectEqual(@as(f32, 76), rs[1].w); // buttons do not shrink
    try std.testing.expectEqual(@as(f32, 124), rs[2].w);
    try std.testing.expect(rs[2].h > 20);
}

test "an explicitly shrinkable group shrinks to its content's min-content" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.pushGroup(.{ .padding = 0, .gap = 0, .shrink = 1 });
    cb.paragraph("alpha beta gamma delta"); // 220, min 50 ("gamma"/"delta"/"alpha")
    cb.popGroup();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 100 });
    cb.text("fixed");
    cb.popGroup();
    cb.popGroup();
    var rects: [16]Rect = undefined;
    const rs = layout(&cb, &rects, 180, 200);
    try std.testing.expectEqual(@as(f32, 80), rs[1].w); // 180 - 100
    try std.testing.expectEqual(@as(f32, 80), rs[2].w); // paragraph filled its shrunk parent
    try std.testing.expect(rs[2].h >= 60); // 3 lines at 8 chars
    try std.testing.expectEqual(rs[2].h, rs[1].h);
}

test "unbreakable overlong token breaks at graphemes instead of overflowing" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.paragraph("abcdefghijklmnopqrstuvwxyz"); // 260
    cb.popGroup();
    var rects: [4]Rect = undefined;
    const rs = layout(&cb, &rects, 100, 400);
    try std.testing.expectEqual(@as(f32, 100), rs[1].w);
    try std.testing.expectEqual(@as(f32, 60), rs[1].h); // 10 + 10 + 6 chars
}

test "max_lines caps the height; ellipsis is one line" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.paragraphStyled("one two three four five six seven eight", cb.theme.typography.body, cb.theme.text_color, .{ .max_lines = 2 });
    cb.textEllipsis("one two three four five six seven eight");
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const rs = layout(&cb, &rects, 100, 400);
    try std.testing.expectEqual(@as(f32, 40), rs[1].h);
    try std.testing.expectEqual(@as(f32, 20), rs[2].h);
}

test "CJK wraps per character with kinsoku" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.paragraph("日本語です。"); // 6 chars x 30 px
    cb.popGroup();
    var rects: [4]Rect = undefined;
    const rs = layout(&cb, &rects, 65, 400);
    try std.testing.expectEqual(@as(f32, 60), rs[1].h); // 日本 / 語で / す。
}

test "vertical scroll: wrapped content wraps at the viewport width" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.pushScroll(.{ .width = 100, .height = 60, .align_cross = .stretch });
    cb.paragraph("one two three four five six seven eight nine ten");
    cb.popScroll();
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const rs = layout(&cb, &rects, 300, 400);
    try std.testing.expectEqual(@as(f32, 100), rs[2].w);
    try std.testing.expect(rs[2].h >= 100); // content taller than the 60px viewport
    try std.testing.expectEqual(@as(f32, 60), rs[1].h);
}

test "frames without wrapped nodes skip the extra passes" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 4, .gap = 4, .align_cross = .stretch });
    cb.text("plain");
    cb.button(.a, "go");
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const st = LayoutEngine.doLayoutStats(rects[0..cb.cmds.items.len], cb.cmds.items, 200, 200, mono);
    try std.testing.expect(!st.wrap_passes);

    cb.reset();
    cb.pushGroup(.{ .padding = 4, .gap = 4 });
    cb.paragraph("now wrapped");
    cb.popGroup();
    const st2 = LayoutEngine.doLayoutStats(rects[0..cb.cmds.items.len], cb.cmds.items, 200, 200, mono);
    try std.testing.expect(st2.wrap_passes);

    cb.reset();
    cb.pushGroup(.{ .direction = .horizontal, .shrink = 1 });
    cb.popGroup();
    const st3 = LayoutEngine.doLayoutStats(rects[0..cb.cmds.items.len], cb.cmds.items, 200, 200, mono);
    try std.testing.expect(st3.wrap_passes);
}

test "layout height equals render line count for random strings and widths" {
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();
    const words = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "supercalifragilistic", "日本", "。", "-", "x-y", "\n" };
    var text_buf: [256]u8 = undefined;
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    var rects: [8]Rect = undefined;
    var iter: usize = 0;
    while (iter < 1000) : (iter += 1) {
        var n: usize = 0;
        for (0..rnd.uintLessThan(usize, 12)) |_| {
            const w = words[rnd.uintLessThan(usize, words.len)];
            if (n + w.len + 1 > text_buf.len) break;
            @memcpy(text_buf[n..][0..w.len], w);
            n += w.len;
            if (rnd.boolean()) {
                text_buf[n] = ' ';
                n += 1;
            }
        }
        const s = text_buf[0..n];
        const width: f32 = @floatFromInt(20 + rnd.uintLessThan(u32, 300));
        const max_lines: u16 = @intCast(rnd.uintLessThan(u32, 4));
        cb.reset();
        cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
        cb.paragraphStyled(s, cb.theme.typography.body, cb.theme.text_color, .{ .max_lines = max_lines });
        cb.popGroup();
        const rs = layout(&cb, &rects, width, 2000);
        var it = text_wrap.LineIter.init(s, cb.theme.typography.body, rs[1].w, .word, max_lines, mono);
        var lines: f32 = 0;
        while (it.next()) |_| lines += 1;
        try std.testing.expectEqual(lines * 20, rs[1].h);
    }
}
