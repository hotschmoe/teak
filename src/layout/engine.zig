const std = @import("std");
const cmd = @import("../core/cmd.zig");
const Direction = cmd.Direction;
const GroupStyle = cmd.GroupStyle;
const ScrollStyle = cmd.ScrollStyle;

// ── Types ──────────────────────────────────────────────────────────

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    // Meaningful only for push_group entries after the measure pass.
    // Carried into the position pass so flex distribution has the totals
    // without rescanning children.
    fixed_main: f32 = 0,
    flex_total: f32 = 0,
    child_count: u32 = 0,
};

const GroupContext = struct {
    cmd_index: usize,
    direction: Direction,
    padding: f32,
    gap: f32,
    group_flex: f32,
    /// Scroll containers override the final outer rect with these fixed
    /// viewport sizes. 0 = not a scroll or no fixed size.
    fixed_w: f32 = 0,
    fixed_h: f32 = 0,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    is_scroll: bool = false,
    fixed_main: f32 = 0,
    flex_total: f32 = 0,
    cross_axis_max: f32 = 0,
    child_count: u32 = 0,
};

const CursorContext = struct {
    x: f32,
    y: f32,
    direction: Direction,
    gap: f32,
    per_flex_unit: f32 = 0,
    inner_cross: f32 = 0,
    child_count: u32 = 0,
};

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
//
// Two O(n) passes over a flat []Cmd. Works for any Cmd(Msg) since we
// only read Msg-independent fields (styles, labels, content).

pub const LayoutEngine = struct {
    const CHAR_WIDTH: f32 = 10;
    const TEXT_HEIGHT: f32 = 20;
    const BUTTON_HEIGHT: f32 = 36;
    const BUTTON_MIN_WIDTH: f32 = 60;
    const BUTTON_H_PADDING: f32 = 16;
    const INPUT_HEIGHT: f32 = 28;
    const INPUT_H_PADDING: f32 = 8;
    const SLIDER_HEIGHT: f32 = 24;

    /// Run both passes: measure then position. The first push_group (the
    /// root) is resized to the window before position runs, so flex
    /// resolves against the real window size.
    pub fn doLayout(rects: []Rect, cmds: anytype, window_w: f32, window_h: f32) void {
        measurePass(rects, cmds);
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

    /// Pass 1 — measure. Bottom-up via an explicit stack. Each command
    /// writes its intrinsic size to rects[i]; push_group entries also
    /// record fixed_main, flex_total, child_count for the position pass.
    pub fn measurePass(rects: []Rect, cmds: anytype) void {
        var stack: FixedStack(GroupContext, 32) = .{};

        for (cmds, 0..) |c, i| {
            switch (c) {
                .push_group => |grp| {
                    stack.push(.{
                        .cmd_index = i,
                        .direction = grp.direction,
                        .padding = grp.padding,
                        .gap = grp.gap,
                        .group_flex = grp.flex,
                    });
                },
                .push_scroll => |sc| {
                    stack.push(.{
                        .cmd_index = i,
                        .direction = sc.direction,
                        .padding = sc.padding,
                        .gap = sc.gap,
                        .group_flex = sc.flex,
                        .is_scroll = true,
                        .fixed_w = sc.width,
                        .fixed_h = sc.height,
                        .scroll_x = sc.scroll_x,
                        .scroll_y = sc.scroll_y,
                    });
                },
                .text => |txt| {
                    const w = @as(f32, @floatFromInt(txt.content.len)) * CHAR_WIDTH;
                    const h = TEXT_HEIGHT;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, 0);
                },
                .button => |btn| {
                    const label_w = @as(f32, @floatFromInt(btn.label.len)) * CHAR_WIDTH + BUTTON_H_PADDING;
                    const w = @max(label_w, BUTTON_MIN_WIDTH);
                    const h = BUTTON_HEIGHT;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, 0);
                },
                .text_input => |ti| {
                    // Intrinsic size is min_width × INPUT_HEIGHT; flex can
                    // grow the main axis, parent cross stretch can grow the
                    // cross axis during the position pass.
                    const w = ti.style.min_width;
                    const h = INPUT_HEIGHT;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, ti.style.flex);
                },
                .checkbox => |cb| {
                    const label_w = @as(f32, @floatFromInt(cb.label.len)) * CHAR_WIDTH;
                    const w = cb.style.size + (if (cb.label.len > 0) cb.style.label_gap + label_w else 0);
                    const h = @max(cb.style.size, TEXT_HEIGHT);
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, 0);
                },
                .radio => |rd| {
                    const label_w = @as(f32, @floatFromInt(rd.label.len)) * CHAR_WIDTH;
                    const w = rd.style.size + (if (rd.label.len > 0) rd.style.label_gap + label_w else 0);
                    const h = @max(rd.style.size, TEXT_HEIGHT);
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, 0);
                },
                .slider => |sl| {
                    const w = sl.style.min_width;
                    const h = @max(SLIDER_HEIGHT, sl.style.thumb_size);
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, sl.style.flex);
                },
                .pop_group, .pop_scroll => {
                    const grp = stack.pop();
                    const gaps: f32 = if (grp.child_count > 1)
                        @as(f32, @floatFromInt(grp.child_count - 1)) * grp.gap
                    else
                        0;

                    const main_size = grp.fixed_main + gaps + 2 * grp.padding;
                    const cross_size = grp.cross_axis_max + 2 * grp.padding;

                    var w: f32 = switch (grp.direction) {
                        .horizontal => main_size,
                        .vertical => cross_size,
                    };
                    var h: f32 = switch (grp.direction) {
                        .horizontal => cross_size,
                        .vertical => main_size,
                    };

                    // Scroll containers clamp to viewport size when set.
                    if (grp.is_scroll) {
                        if (grp.fixed_w > 0) w = grp.fixed_w;
                        if (grp.fixed_h > 0) h = grp.fixed_h;
                    }

                    rects[grp.cmd_index] = .{
                        .w = w,
                        .h = h,
                        .fixed_main = grp.fixed_main,
                        .flex_total = grp.flex_total,
                        .child_count = grp.child_count,
                    };

                    addLeafToTop(&stack, w, h, grp.group_flex);
                },
            }
        }
    }

    /// Pass 2 — position. Top-down, forward scan. Each group computes its
    /// per-flex-unit from its final size (now known) and the accumulators
    /// stored during measure; each child is placed at the running cursor.
    pub fn positionPass(rects: []Rect, cmds: anytype) void {
        var stack: FixedStack(CursorContext, 32) = .{};

        for (cmds, 0..) |c, i| {
            switch (c) {
                .push_group => |grp| {
                    placeContainer(rects, &stack, i, grp.direction, grp.padding, grp.gap, grp.flex, 0, 0);
                },
                .push_scroll => |sc| {
                    placeContainer(rects, &stack, i, sc.direction, sc.padding, sc.gap, sc.flex, sc.scroll_x, sc.scroll_y);
                },
                .text, .button, .checkbox, .radio => {
                    const ctx = stack.top();
                    if (ctx.child_count > 0) advanceCursor(ctx, ctx.gap);

                    rects[i].x = ctx.x;
                    rects[i].y = ctx.y;
                    ctx.child_count += 1;

                    const advance_by: f32 = switch (ctx.direction) {
                        .horizontal => rects[i].w,
                        .vertical => rects[i].h,
                    };
                    advanceCursor(ctx, advance_by);
                },
                .text_input => |ti| {
                    placeFlexLeaf(rects, &stack, i, ti.style.flex);
                },
                .slider => |sl| {
                    placeFlexLeaf(rects, &stack, i, sl.style.flex);
                },
                .pop_group, .pop_scroll => {
                    _ = stack.pop();
                },
            }
        }
    }

    /// Place a push-{group|scroll} entry inside its parent and push a
    /// fresh CursorContext for its children. `scroll_x`/`scroll_y` are 0
    /// for ordinary groups; scroll containers pass the Model-owned offset
    /// so children's cursors start shifted.
    fn placeContainer(
        rects: []Rect,
        stack: *FixedStack(CursorContext, 32),
        i: usize,
        direction: Direction,
        padding: f32,
        gap: f32,
        flex: f32,
        scroll_x: f32,
        scroll_y: f32,
    ) void {
        if (stack.len > 0) {
            const parent = stack.top();
            if (parent.child_count > 0) advanceCursor(parent, parent.gap);

            if (flex > 0 and parent.per_flex_unit > 0) {
                switch (parent.direction) {
                    .horizontal => rects[i].w += flex * parent.per_flex_unit,
                    .vertical => rects[i].h += flex * parent.per_flex_unit,
                }
            }

            rects[i].x = parent.x;
            rects[i].y = parent.y;
            parent.child_count += 1;

            const advance_by: f32 = switch (parent.direction) {
                .horizontal => rects[i].w,
                .vertical => rects[i].h,
            };
            advanceCursor(parent, advance_by);
        }

        const inner_w = @max(0, rects[i].w - 2 * padding);
        const inner_h = @max(0, rects[i].h - 2 * padding);
        const inner_main: f32 = switch (direction) {
            .horizontal => inner_w,
            .vertical => inner_h,
        };
        const inner_cross: f32 = switch (direction) {
            .horizontal => inner_h,
            .vertical => inner_w,
        };
        const fixed_main = rects[i].fixed_main;
        const flex_total = rects[i].flex_total;
        const count = rects[i].child_count;
        const gaps: f32 = if (count > 1)
            @as(f32, @floatFromInt(count - 1)) * gap
        else
            0;
        const extra = @max(0, inner_main - fixed_main - gaps);
        const per_flex_unit: f32 = if (flex_total > 0) extra / flex_total else 0;

        stack.push(.{
            .x = rects[i].x + padding - scroll_x,
            .y = rects[i].y + padding - scroll_y,
            .direction = direction,
            .gap = gap,
            .per_flex_unit = per_flex_unit,
            .inner_cross = inner_cross,
        });
    }

    /// Shared placement for leaves that support main-axis flex growth
    /// and cross-axis stretch (text_input, slider).
    fn placeFlexLeaf(rects: []Rect, stack: *FixedStack(CursorContext, 32), i: usize, flex: f32) void {
        const ctx = stack.top();
        if (ctx.child_count > 0) advanceCursor(ctx, ctx.gap);

        if (flex > 0 and ctx.per_flex_unit > 0) {
            switch (ctx.direction) {
                .horizontal => rects[i].w += flex * ctx.per_flex_unit,
                .vertical => rects[i].h += flex * ctx.per_flex_unit,
            }
        }

        if (ctx.inner_cross > 0) {
            switch (ctx.direction) {
                .horizontal => rects[i].h = ctx.inner_cross,
                .vertical => rects[i].w = ctx.inner_cross,
            }
        }

        rects[i].x = ctx.x;
        rects[i].y = ctx.y;
        ctx.child_count += 1;

        const advance_by: f32 = switch (ctx.direction) {
            .horizontal => rects[i].w,
            .vertical => rects[i].h,
        };
        advanceCursor(ctx, advance_by);
    }

    fn advanceCursor(ctx: *CursorContext, delta: f32) void {
        switch (ctx.direction) {
            .horizontal => ctx.x += delta,
            .vertical => ctx.y += delta,
        }
    }

    fn addLeafToTop(stack: *FixedStack(GroupContext, 32), child_w: f32, child_h: f32, child_flex: f32) void {
        if (stack.len == 0) return;
        const t = stack.top();
        const main: f32 = switch (t.direction) {
            .horizontal => child_w,
            .vertical => child_h,
        };
        const cross: f32 = switch (t.direction) {
            .horizontal => child_h,
            .vertical => child_w,
        };
        t.fixed_main += main;
        t.flex_total += child_flex;
        t.cross_axis_max = @max(t.cross_axis_max, cross);
        t.child_count += 1;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "measure pass sizes basic widgets" {
    const testing = std.testing;
    const Msg = union(enum) { a, b, c };
    const CmdBuffer = cmd.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 20, .gap = 12 });
    cb.text("Count: 0"); // 8 chars * 10 = 80
    cb.pushGroup(.{ .direction = .horizontal, .gap = 8 });
    cb.button(.a, "+");
    cb.button(.b, "-");
    cb.popGroup();
    cb.button(.c, "Reset");
    cb.popGroup();

    var rects: [32]Rect = undefined;
    LayoutEngine.measurePass(rects[0..cb.cmds.items.len], cb.cmds.items);

    try testing.expectEqual(@as(f32, 80), rects[1].w);
    try testing.expectEqual(@as(f32, 20), rects[1].h);
    try testing.expectEqual(@as(f32, 60), rects[3].w); // "+" min 60
    try testing.expectEqual(@as(f32, 66), rects[6].w); // "Reset" = 5*10+16 = 66
    try testing.expectEqual(@as(f32, 144), rects[2].w); // 60+8+60+2*8
}

test "horizontal flex distributes remaining space" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Root horizontal, no padding, no gap, 800 wide.
    // Child A: vertical group, intrinsic, no flex.
    // Child B: vertical group, flex=1.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.a, "Hi"); // 2*10+16=36 -> max 60
    cb.popGroup();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .flex = 1 });
    cb.button(.a, "Yo");
    cb.popGroup();

    cb.popGroup();

    var rects: [32]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600);

    // Root: 800 wide.
    try testing.expectEqual(@as(f32, 800), rects[0].w);
    // Left group (cmd 1): intrinsic 60.
    try testing.expectEqual(@as(f32, 60), rects[1].w);
    // Right group (cmd 4, the flex=1 push): intrinsic 60 + 680 remainder = 740.
    try testing.expectEqual(@as(f32, 740), rects[4].w);
}

test "checkbox sizes include label and box" {
    const testing = std.testing;
    const Msg = union(enum) { toggle };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.checkbox(.toggle, false, "agree"); // 5 chars
    cb.popGroup();

    var rects: [8]Rect = undefined;
    LayoutEngine.measurePass(rects[0..cb.cmds.items.len], cb.cmds.items);
    // size 18 + gap 8 + 5*10 = 76
    try testing.expectEqual(@as(f32, 76), rects[1].w);
}

test "slider measures intrinsic min_width, grows with flex" {
    const testing = std.testing;
    const Msg = union(enum) { grab };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.slider(.grab, 0.5);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 100);
    // Slider has flex=1 by default and no siblings, so it expands to fill.
    try testing.expectEqual(@as(f32, 400), rects[1].w);
}

test "scroll container clamps to fixed viewport size" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushScroll(.{
        .direction = .vertical,
        .padding = 0,
        .gap = 0,
        .width = 200,
        .height = 100,
        .scroll_y = 50,
    });
    // Many buttons that would overflow 100px height.
    cb.button(.a, "A");
    cb.button(.a, "B");
    cb.button(.a, "C");
    cb.button(.a, "D");
    cb.popScroll();

    var rects: [16]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600);

    // Scroll container is clamped to 200x100.
    try testing.expectEqual(@as(f32, 200), rects[0].w);
    try testing.expectEqual(@as(f32, 100), rects[0].h);
    // First child should be at y = 0 - scroll_y = -50.
    try testing.expectEqual(@as(f32, -50), rects[1].y);
    // Button height = 36, so second child at y = -50 + 36 = -14.
    try testing.expectEqual(@as(f32, -14), rects[2].y);
}

test "text_input cross-axis stretches in vertical parent" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    const CmdBuffer = cmd.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 10, .gap = 0 });
    cb.textInput(.focus, "", 0);
    cb.popGroup();

    var rects: [16]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300);

    // Parent inner width = 400 - 20 = 380.
    try testing.expectEqual(@as(f32, 380), rects[1].w);
}
