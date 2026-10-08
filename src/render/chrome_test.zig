//! Render tests for chrome styling: borders, hover/press inversion, label
//! alignment, underline inputs, overlay shadow, font weight threading.

const std = @import("std");
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const layout = @import("../layout/engine.zig");
const build = @import("build.zig");
const Vertex = @import("vertex.zig").Vertex;
const Rect = layout.Rect;
const TransientState = @import("../core/transient.zig").TransientState;

const Msg = union(enum) { a, b };
const Buf = cmd.CmdBuffer(Msg);

const ink: [4]f32 = .{ 0, 0, 0, 1 };
const paper: [4]f32 = .{ 1, 1, 0.9, 1 };
const red: [4]f32 = .{ 1, 0, 0, 1 };

/// A laid-out + rendered frame; deinit frees the buffers.
const Frame = struct {
    verts: std.ArrayList(Vertex) = .empty,
    text_draws: std.ArrayList(text.TextDraw) = .empty,
    images: std.ArrayList(build.ImageDraw) = .empty,
    rects: [32]Rect = undefined,

    fn deinit(self: *Frame) void {
        self.verts.deinit(std.testing.allocator);
        self.text_draws.deinit(std.testing.allocator);
        self.images.deinit(std.testing.allocator);
    }

    fn render(self: *Frame, cb: *Buf, w: f32, h: f32, ts: TransientState) void {
        const n = cb.cmds.items.len;
        layout.LayoutEngine.doLayout(self.rects[0..n], cb.cmds.items, w, h, text.monoMeasurer());
        build.buildVertices(&self.verts, &self.text_draws, &self.images, std.testing.allocator, cb.cmds.items, self.rects[0..n], ts, text.monoMeasurer());
    }

    fn quadCount(self: *const Frame) usize {
        return self.verts.items.len / 6;
    }

    /// Rect of the k-th emitted quad (vertex 0 = top-left, 4 = bottom-right).
    fn quad(self: *const Frame, k: usize) Rect {
        const a = self.verts.items[k * 6];
        const b = self.verts.items[k * 6 + 4];
        return .{ .x = a.x, .y = a.y, .w = b.x - a.x, .h = b.y - a.y };
    }

    fn quadColor(self: *const Frame, k: usize) [4]f32 {
        const v = self.verts.items[k * 6];
        return .{ v.r, v.g, v.b, v.a };
    }
};

fn expectRect(expected: Rect, actual: Rect) !void {
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
    try std.testing.expectEqual(expected.w, actual.w);
    try std.testing.expectEqual(expected.h, actual.h);
}

test "group border: bg first, then four inside edges, no corner overlap" {
    // The root group is window-sized; nest the card inside it.
    var outer = Buf.init(std.testing.allocator);
    defer outer.deinit();
    outer.pushGroup(.{ .padding = 0, .gap = 0 });
    outer.pushGroup(.{ .padding = 0, .gap = 0, .width = 100, .height = 50, .bg = paper, .border = ink, .border_width = 2 });
    outer.popGroup();
    outer.popGroup();

    var f: Frame = .{};
    defer f.deinit();
    f.render(&outer, 400, 300, .{});

    try std.testing.expectEqual(@as(usize, 5), f.quadCount());
    try expectRect(.{ .x = 0, .y = 0, .w = 100, .h = 50 }, f.quad(0));
    try std.testing.expectEqual(paper, f.quadColor(0));
    try expectRect(.{ .x = 0, .y = 0, .w = 100, .h = 2 }, f.quad(1)); // top
    try expectRect(.{ .x = 0, .y = 48, .w = 100, .h = 2 }, f.quad(2)); // bottom
    try expectRect(.{ .x = 0, .y = 2, .w = 2, .h = 46 }, f.quad(3)); // left
    try expectRect(.{ .x = 98, .y = 2, .w = 2, .h = 46 }, f.quad(4)); // right
    try std.testing.expectEqual(ink, f.quadColor(4));
}

test "group without a border emits no border quads" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 100, .height = 50, .bg = paper });
    cb.popGroup();
    cb.popGroup();
    var f: Frame = .{};
    defer f.deinit();
    f.render(&cb, 400, 300, .{});
    try std.testing.expectEqual(@as(usize, 1), f.quadCount());
}

fn inkButton() cmd.ButtonStyle {
    return .{
        .bg = paper,
        .hover_bg = ink,
        .press_bg = ink,
        .fg = ink,
        .hover_fg = paper,
        .press_fg = red,
        .border = ink,
        .border_width = 1,
        .press_offset_y = 2,
        .label_align = .center,
        .min_width = 0,
    };
}

test "button: hover inverts fg + bg, press shifts the label, border is drawn" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .start });
    cb.buttonStyled(.a, "OK", inkButton()); // 20 + 16 = 36 wide, 36 tall
    cb.popGroup();

    var idle: Frame = .{};
    defer idle.deinit();
    idle.render(&cb, 200, 100, .{});
    try std.testing.expectEqual(@as(usize, 5), idle.quadCount()); // bg + 4 border edges
    try std.testing.expectEqual(paper, idle.quadColor(0));
    try std.testing.expectEqual(ink, idle.text_draws.items[0].color);

    var hover: Frame = .{};
    defer hover.deinit();
    hover.render(&cb, 200, 100, .{ .hover_index = 1 });
    try std.testing.expectEqual(ink, hover.quadColor(0));
    try std.testing.expectEqual(paper, hover.text_draws.items[0].color);

    var press: Frame = .{};
    defer press.deinit();
    press.render(&cb, 200, 100, .{ .hover_index = 1, .press_index = 1 });
    try std.testing.expectEqual(red, press.text_draws.items[0].color);
    // Label y: centered in 36 -> 8; pressed -> 10.
    try std.testing.expectEqual(idle.text_draws.items[0].rect_y + 2, press.text_draws.items[0].rect_y);
}

test "button: label_align start / center / end inside a stretched button" {
    inline for (.{ .{ .start, 8 }, .{ .center, 90 }, .{ .end, 172 } }) |case| {
        var style = inkButton();
        style.label_align = case[0];
        var cb = Buf.init(std.testing.allocator);
        defer cb.deinit();
        cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
        cb.buttonStyled(.a, "OK", style); // stretched to 200: avail 184, label 20
        cb.popGroup();
        var f: Frame = .{};
        defer f.deinit();
        f.render(&cb, 200, 100, .{});
        try std.testing.expectEqual(@as(f32, case[1]), f.text_draws.items[0].rect_x);
    }
}

test "button: disabled ignores hover/press colors and keeps its border" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.cmds.append(cb.backing, .{ .button = .{ .msg = .a, .label = "OK", .style = inkButton(), .disabled = true } }) catch unreachable;
    cb.popGroup();
    var f: Frame = .{};
    defer f.deinit();
    f.render(&cb, 200, 100, .{ .hover_index = 1, .press_index = 1 });
    try std.testing.expectEqual(inkButton().disabled_bg, f.quadColor(0));
    try std.testing.expectEqual(@as(usize, 5), f.quadCount());
    try std.testing.expectEqual(inkButton().disabled_fg, f.text_draws.items[0].color);
}

test "text_input underline: a 1px bottom rule, 2px in focus_border when focused, no box" {
    var style: cmd.TextInputStyle = .{ .variant = .underline, .border = ink, .focus_border = red };
    style.flex = 0;
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textInputStyled(.a, "ab", 0, style); // 120 x 28 (stretched to 200 in the column)
    cb.popGroup();

    var idle: Frame = .{};
    defer idle.deinit();
    idle.render(&cb, 200, 100, .{});
    try std.testing.expectEqual(@as(usize, 1), idle.quadCount());
    try expectRect(.{ .x = 0, .y = 27, .w = 200, .h = 1 }, idle.quad(0));
    try std.testing.expectEqual(ink, idle.quadColor(0));

    // Focused, blink phase off (frame 30): only the thicker focus rule.
    var focused: Frame = .{};
    defer focused.deinit();
    focused.render(&cb, 200, 100, .{ .focus_index = 1, .blink_on = false });
    try std.testing.expectEqual(@as(usize, 1), focused.quadCount());
    try expectRect(.{ .x = 0, .y = 26, .w = 200, .h = 2 }, focused.quad(0));
    try std.testing.expectEqual(red, focused.quadColor(0));

    // Blink on: the caret is drawn too, inset 2px from the left edge.
    var blink: Frame = .{};
    defer blink.deinit();
    blink.render(&cb, 200, 100, .{ .focus_index = 1, .blink_on = true });
    try std.testing.expectEqual(@as(usize, 2), blink.quadCount());
    try std.testing.expectEqual(@as(f32, 2), blink.quad(1).x);
}

test "text_input boxed: border_width and selection_bg are honored" {
    const sel: [4]f32 = .{ 0.1, 0.2, 0.3, 0.4 };
    const style: cmd.TextInputStyle = .{ .border_width = 1, .selection_bg = sel, .flex = 0 };
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textInputSelected(.a, "abcd", 4, 1, style);
    cb.popGroup();

    var f: Frame = .{};
    defer f.deinit();
    f.render(&cb, 200, 100, .{ .focus_index = 1, .blink_on = false });
    // border rect, bg inset by 1, selection (cursor blinked off).
    try std.testing.expectEqual(@as(usize, 3), f.quadCount());
    try expectRect(.{ .x = 1, .y = 1, .w = 198, .h = 26 }, f.quad(1));
    try std.testing.expectEqual(sel, f.quadColor(2));
}

test "overlay: hard shadow behind, backdrop, then border" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.pushOverlay(.{
        .x = 10,
        .y = 20,
        .width = 100,
        .height = 60,
        .backdrop = paper,
        .border = ink,
        .border_width = 1,
        .shadow = red,
        .shadow_offset = .{ 3, 4 },
    });
    cb.popOverlay();
    cb.popGroup();

    var f: Frame = .{};
    defer f.deinit();
    f.render(&cb, 400, 300, .{});
    try std.testing.expectEqual(@as(usize, 6), f.quadCount()); // shadow, backdrop, 4 edges
    try expectRect(.{ .x = 13, .y = 24, .w = 100, .h = 60 }, f.quad(0));
    try std.testing.expectEqual(red, f.quadColor(0));
    try expectRect(.{ .x = 10, .y = 20, .w = 100, .h = 60 }, f.quad(1));
    try std.testing.expectEqual(paper, f.quadColor(1));
    try expectRect(.{ .x = 10, .y = 20, .w = 100, .h = 1 }, f.quad(2));
}

test "FontSpec weight and letter_spacing reach the TextDraw" {
    var cb = Buf.init(std.testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textStyled("abc", .{ .weight = .bold, .letter_spacing = 1.5 }, ink);
    cb.popGroup();

    var f: Frame = .{};
    defer f.deinit();
    f.render(&cb, 200, 100, .{});
    const d = f.text_draws.items[0];
    try std.testing.expectEqual(text.FontWeight.bold, d.font.weight);
    try std.testing.expectEqual(@as(f32, 1.5), d.font.letter_spacing);
    // The stub measurer adds the spacing per byte: 3 * (10 + 1.5).
    try std.testing.expectEqual(@as(f32, 34.5), d.rect_w);
}
