const std = @import("std");
const cmd_mod = @import("cmd.zig");
const Cmd = cmd_mod.Cmd;
const layout_mod = @import("layout.zig");
const Rect = layout_mod.Rect;
const TransientState = @import("transient.zig").TransientState;

// ── Vertex ─────────────────────────────────────────────────────────

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    u: f32,
    v: f32,
};

// ── Quad Emission ──────────────────────────────────────────────────

pub fn emitQuad(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, rect: Rect, color: [4]f32) void {
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h;
    const r = color[0];
    const g = color[1];
    const b = color[2];
    const a = color[3];

    verts.appendSlice(alloc, &.{
        .{ .x = x0, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
        .{ .x = x1, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = 1, .v = 0 },
        .{ .x = x0, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 1 },
        .{ .x = x1, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = 1, .v = 0 },
        .{ .x = x1, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = 1, .v = 1 },
        .{ .x = x0, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 1 },
    }) catch unreachable;
}

/// Walk cmds/rects, emit quads for each visible widget.
pub fn buildVertices(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    cmds: []const Cmd,
    rects: []const Rect,
    transient: TransientState,
) void {
    verts.clearRetainingCapacity();

    for (cmds, rects, 0..) |cmd, rect, i| {
        switch (cmd) {
            .text => {
                // Placeholder: text rendered as a muted rectangle
                emitQuad(verts, alloc, rect, .{ 0.15, 0.15, 0.2, 1.0 });
            },
            .button => |btn| {
                const bg = if (transient.hover_index) |hi|
                    (if (hi == i) btn.style.hover_bg else btn.style.bg)
                else
                    btn.style.bg;
                emitQuad(verts, alloc, rect, bg);
            },
            .push_group, .pop_group => {},
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const model = @import("model.zig");

test "buildVertices produces correct quad count" {
    const testing = std.testing;
    var cb = cmd_mod.CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    model.view(.{}, &cb);
    const cmds = cb.cmds.items;

    var rects_buf: [32]Rect = undefined;
    layout_mod.LayoutEngine.doLayout(rects_buf[0..cmds.len], cmds, 400, 300);

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);

    buildVertices(&verts, testing.allocator, cmds, rects_buf[0..cmds.len], .{});

    // 1 text + 3 buttons = 4 quads * 6 verts = 24 vertices
    try testing.expectEqual(@as(usize, 24), verts.items.len);
}

test "hover changes button color" {
    const testing = std.testing;
    var cb = cmd_mod.CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    model.view(.{}, &cb);
    const cmds = cb.cmds.items;

    var rects_buf: [32]Rect = undefined;
    layout_mod.LayoutEngine.doLayout(rects_buf[0..cmds.len], cmds, 400, 300);

    // Build without hover
    var verts_no_hover: std.ArrayList(Vertex) = .empty;
    defer verts_no_hover.deinit(testing.allocator);
    buildVertices(&verts_no_hover, testing.allocator, cmds, rects_buf[0..cmds.len], .{});

    // Build with hover on button "+" (index 3)
    var verts_hover: std.ArrayList(Vertex) = .empty;
    defer verts_hover.deinit(testing.allocator);
    buildVertices(&verts_hover, testing.allocator, cmds, rects_buf[0..cmds.len], .{ .hover_index = 3 });

    // The "+" button is the 2nd quad (after text). First vertex of that quad is at index 6.
    // Hover should change its color (r component: 0.25 default -> 0.35 hover)
    try testing.expectEqual(@as(f32, 0.25), verts_no_hover.items[6].r);
    try testing.expectEqual(@as(f32, 0.35), verts_hover.items[6].r);
}
