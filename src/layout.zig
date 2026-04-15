const std = @import("std");
const cmd = @import("cmd.zig");
const Cmd = cmd.Cmd;
const Direction = cmd.Direction;
const GroupStyle = cmd.GroupStyle;

// ── Types ──────────────────────────────────────────────────────────

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

const GroupContext = struct {
    cmd_index: usize,
    direction: Direction,
    padding: f32,
    gap: f32,
    main_axis_total: f32 = 0,
    cross_axis_max: f32 = 0,
    child_count: u32 = 0,
};

const CursorContext = struct {
    x: f32,
    y: f32,
    direction: Direction,
    gap: f32,
    child_count: u32 = 0,
};

// Fixed-capacity stack for layout passes (no heap allocation)
fn FixedStack(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        fn push(self: *Self, item: T) void {
            self.buffer[self.len] = item;
            self.len += 1;
        }

        fn pop(self: *Self) T {
            self.len -= 1;
            return self.buffer[self.len];
        }

        fn top(self: *Self) *T {
            return &self.buffer[self.len - 1];
        }
    };
}

// ── Layout Engine ──────────────────────────────────────────────────

pub const LayoutEngine = struct {
    // Hardcoded sizes for the prototype
    const CHAR_WIDTH = 10;
    const TEXT_HEIGHT = 20;
    const BUTTON_HEIGHT = 36;
    const BUTTON_MIN_WIDTH = 60;
    const BUTTON_H_PADDING = 16;

    /// Run both passes: measure then position.
    pub fn doLayout(rects: []Rect, cmds: []const Cmd, window_w: f32, window_h: f32) void {
        measurePass(rects, cmds);
        // Root group (if any) gets sized to window
        if (cmds.len > 0) {
            switch (cmds[0]) {
                .push_group => {
                    rects[0].w = window_w;
                    rects[0].h = window_h;
                },
                else => {},
            }
        }
        positionPass(rects, cmds);
    }

    /// Pass 1 — Measure (bottom-up via stack).
    pub fn measurePass(rects: []Rect, cmds: []const Cmd) void {
        var stack: FixedStack(GroupContext, 32) = .{};

        for (cmds, 0..) |c, i| {
            switch (c) {
                .push_group => |grp| {
                    stack.push(.{
                        .cmd_index = i,
                        .direction = grp.direction,
                        .padding = grp.padding,
                        .gap = grp.gap,
                    });
                },
                .text => |txt| {
                    const w: f32 = @as(f32, @floatFromInt(txt.content.len)) * CHAR_WIDTH;
                    const h: f32 = TEXT_HEIGHT;
                    rects[i] = .{ .w = w, .h = h };
                    addChildToTop(&stack, w, h);
                },
                .button => |btn| {
                    const label_w: f32 = @as(f32, @floatFromInt(btn.label.len)) * CHAR_WIDTH + BUTTON_H_PADDING;
                    const w: f32 = @max(label_w, BUTTON_MIN_WIDTH);
                    const h: f32 = BUTTON_HEIGHT;
                    rects[i] = .{ .w = w, .h = h };
                    addChildToTop(&stack, w, h);
                },
                .pop_group => {
                    const grp = stack.pop();
                    const gaps = if (grp.child_count > 1)
                        @as(f32, @floatFromInt(grp.child_count - 1)) * grp.gap
                    else
                        0;

                    const w: f32 = switch (grp.direction) {
                        .vertical => grp.cross_axis_max + 2 * grp.padding,
                        .horizontal => grp.main_axis_total + gaps + 2 * grp.padding,
                    };
                    const h: f32 = switch (grp.direction) {
                        .vertical => grp.main_axis_total + gaps + 2 * grp.padding,
                        .horizontal => grp.cross_axis_max + 2 * grp.padding,
                    };

                    rects[grp.cmd_index] = .{ .w = w, .h = h };
                    addChildToTop(&stack, w, h);
                },
            }
        }
    }

    /// Pass 2 — Position (top-down).
    pub fn positionPass(rects: []Rect, cmds: []const Cmd) void {
        var stack: FixedStack(CursorContext, 32) = .{};

        for (cmds, 0..) |c, i| {
            switch (c) {
                .push_group => |grp| {
                    // Position this group as a child of its parent
                    if (stack.len > 0) {
                        const parent = stack.top();
                        if (parent.child_count > 0) {
                            switch (parent.direction) {
                                .vertical => parent.y += parent.gap,
                                .horizontal => parent.x += parent.gap,
                            }
                        }
                        rects[i].x = parent.x;
                        rects[i].y = parent.y;
                        parent.child_count += 1;
                        switch (parent.direction) {
                            .vertical => parent.y += rects[i].h,
                            .horizontal => parent.x += rects[i].w,
                        }
                    }

                    const r = rects[i];
                    stack.push(.{
                        .x = r.x + grp.padding,
                        .y = r.y + grp.padding,
                        .direction = grp.direction,
                        .gap = grp.gap,
                    });
                },
                .text, .button => {
                    const ctx = stack.top();

                    // Add gap before non-first children
                    if (ctx.child_count > 0) {
                        switch (ctx.direction) {
                            .vertical => ctx.y += ctx.gap,
                            .horizontal => ctx.x += ctx.gap,
                        }
                    }

                    rects[i].x = ctx.x;
                    rects[i].y = ctx.y;
                    ctx.child_count += 1;

                    // Advance cursor past this child
                    switch (ctx.direction) {
                        .vertical => ctx.y += rects[i].h,
                        .horizontal => ctx.x += rects[i].w,
                    }
                },
                .pop_group => {
                    _ = stack.pop();
                },
            }
        }
    }

    fn addChildToTop(stack: *FixedStack(GroupContext, 32), w: f32, h: f32) void {
        if (stack.len == 0) return;
        const t = stack.top();
        switch (t.direction) {
            .vertical => {
                t.main_axis_total += h;
                t.cross_axis_max = @max(t.cross_axis_max, w);
            },
            .horizontal => {
                t.main_axis_total += w;
                t.cross_axis_max = @max(t.cross_axis_max, h);
            },
        }
        t.child_count += 1;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const model = @import("model.zig");

test "layout produces correct rect count" {
    const testing = std.testing;
    var cb = cmd.CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    model.view(.{}, &cb);
    const cmds = cb.cmds.items;

    var rects: [32]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    // Root group should be window-sized
    try testing.expectEqual(@as(f32, 400), rects[0].w);
    try testing.expectEqual(@as(f32, 300), rects[0].h);
}

test "layout measure pass sizes" {
    const testing = std.testing;
    var cb = cmd.CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    model.view(.{}, &cb);
    const cmds = cb.cmds.items;

    var rects: [32]Rect = undefined;
    LayoutEngine.measurePass(rects[0..cmds.len], cmds);

    // [1] text "Count: 0" = 8 chars * 10 = 80w, 20h
    try testing.expectEqual(@as(f32, 80), rects[1].w);
    try testing.expectEqual(@as(f32, 20), rects[1].h);

    // [3] button "+" = max(1*10+16, 60) = 60w, 36h
    try testing.expectEqual(@as(f32, 60), rects[3].w);
    try testing.expectEqual(@as(f32, 36), rects[3].h);

    // [4] button "-" = same as "+"
    try testing.expectEqual(@as(f32, 60), rects[4].w);
    try testing.expectEqual(@as(f32, 36), rects[4].h);

    // [6] button "Reset" = max(5*10+16, 60) = 66w, 36h
    try testing.expectEqual(@as(f32, 66), rects[6].w);
    try testing.expectEqual(@as(f32, 36), rects[6].h);

    // [2] horizontal group:
    //   main_axis_total = 60 + 60 = 120, gaps = 1*8 = 8, padding = 8
    //   w = 120 + 8 + 16 = 144
    //   h = 36 + 16 = 52
    try testing.expectEqual(@as(f32, 144), rects[2].w);
    try testing.expectEqual(@as(f32, 52), rects[2].h);
}

test "layout position pass places children correctly" {
    const testing = std.testing;
    var cb = cmd.CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    model.view(.{}, &cb);
    const cmds = cb.cmds.items;

    var rects: [32]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    // Root group at (0,0)
    try testing.expectEqual(@as(f32, 0), rects[0].x);
    try testing.expectEqual(@as(f32, 0), rects[0].y);

    // Text at (20, 20) — root padding = 20
    try testing.expectEqual(@as(f32, 20), rects[1].x);
    try testing.expectEqual(@as(f32, 20), rects[1].y);

    // Horizontal group at (20, 52) — after text(20h) + gap(12)
    try testing.expectEqual(@as(f32, 20), rects[2].x);
    try testing.expectEqual(@as(f32, 52), rects[2].y);

    // "+" button at (28, 60) — horiz group padding = 8
    try testing.expectEqual(@as(f32, 28), rects[3].x);
    try testing.expectEqual(@as(f32, 60), rects[3].y);

    // "-" button at (96, 60) — after "+"(60w) + gap(8)
    try testing.expectEqual(@as(f32, 96), rects[4].x);
    try testing.expectEqual(@as(f32, 60), rects[4].y);

    // "Reset" button at (20, 116) — after horiz group(52h) + gap(12)
    try testing.expectEqual(@as(f32, 20), rects[6].x);
    try testing.expectEqual(@as(f32, 116), rects[6].y);
}
