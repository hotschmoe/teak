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







