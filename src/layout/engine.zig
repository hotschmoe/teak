const std = @import("std");
const cmd = @import("../core/cmd.zig");
const eql_mod = @import("../core/eql.zig");
const text = @import("../core/text.zig");
const text_wrap = @import("../core/text_wrap.zig");
const Direction = cmd.Direction;
const Align = cmd.Align;
const Justify = cmd.Justify;
const TextMeasurer = text.TextMeasurer;


pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    fixed_main: f32 = 0,
    flex_total: f32 = 0,
    child_count: u32 = 0,
    /// Index of the matching `pop_*` (containers only). Lets the width
    /// passes hop over a child's subtree, keeping them linear.
    end: u32 = 0,
};

/// The rect of the nearest leaf BEFORE `overlay_index` whose click / focus
/// Msg equals `want` (by value). Rects of earlier cmds are final by the time
/// the position pass reaches a later overlay, so this needs no extra pass.
fn findAnchor(cmds: anytype, rects: []const Rect, overlay_index: usize, want: anytype) ?Rect {
    const Msg = @TypeOf(want);
    var j = overlay_index;
    while (j > 0) {
        j -= 1;
        const m = cmd.leafMsg(cmds[j]) orelse continue;
        if (eql_mod.deepEql(Msg, m, want)) return rects[j];
    }
    return null;
}

/// Move `r` (whose w/h are already measured) against the anchor rect `a`.
fn placeAnchored(r: *Rect, a: Rect, side: cmd.AnchorSide, gap: f32) void {
    switch (side) {
        .below_start => {
            r.x = a.x;
            r.y = a.y + a.h + gap;
        },
        .below_end => {
            r.x = a.x + a.w - r.w;
            r.y = a.y + a.h + gap;
        },
        .above_start => {
            r.x = a.x;
            r.y = a.y - r.h - gap;
        },
        .above_end => {
            r.x = a.x + a.w - r.w;
            r.y = a.y - r.h - gap;
        },
        .right_start => {
            r.x = a.x + a.w + gap;
            r.y = a.y;
        },
        .left_start => {
            r.x = a.x - r.w - gap;
            r.y = a.y;
        },
    }
}

/// Intersect two rects. Returns a zero-size rect if fully disjoint.
pub fn clipRect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return .{};
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// The content box of a `text_area` inside its layout rect: inset by the
/// border and padding. Render, pointer resolution and the metrics event all
/// use this one function so they agree on where text starts and how wide it
/// wraps.
pub fn textAreaInner(rect: Rect, ta: anytype) Rect {
    const inset = ta.style.border_width + ta.padding;
    return .{
        .x = rect.x + inset,
        .y = rect.y + inset,
        .w = @max(0, rect.w - 2 * inset),
        .h = @max(0, rect.h - 2 * inset),
    };
}

/// Width a `text_area` wraps at: its inner width, or unbounded for `.none`.
pub fn textAreaWrapWidth(inner: Rect, ta: anytype) f32 {
    return switch (ta.wrap) {
        .word, .char => inner.w,
        .none, .ellipsis => std.math.inf(f32),
    };
}

/// Container nesting capacity of every fixed stack in the passes. One value
/// with `cmd.validateBalance`, so a buffer it accepts can never overflow.
const MAX_DEPTH = cmd.MAX_BALANCE_DEPTH;

/// Scroll-clip stack shared by hit-test, render and a11y. Fixed depth
/// (`MAX_DEPTH`, same as the layout stacks) — exceeding it is a bug, not an
/// allocation trigger. `top()` returns a huge sentinel rect when empty so
/// callers don't branch on depth.
///
/// Overflow on `push` and underflow on `pop` are programmer errors (an
/// unbalanced or too-deep buffer), reported with an unconditional `@panic`
/// in EVERY optimize mode — never an out-of-bounds write. The run loop runs
/// `cmd.validateBalance` first, which names the offending cmd index.
pub const ClipStack = struct {
    buffer: [MAX_DEPTH]Rect = undefined,
    len: usize = 0,

    pub fn push(self: *ClipStack, r: Rect) void {
        if (self.len >= self.buffer.len) @panic("teak: clip stack overflow (scroll/overlay nesting too deep; see cmd.validateBalance)");
        self.buffer[self.len] = r;
        self.len += 1;
    }

    pub fn pop(self: *ClipStack) void {
        if (self.len == 0) @panic("teak: clip stack underflow (stray pop_scroll/pop_overlay; see cmd.validateBalance)");
        self.len -= 1;
    }

    pub fn top(self: *const ClipStack) Rect {
        if (self.len == 0) return .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 };
        return self.buffer[self.len - 1];
    }
};

/// Measure-pass bookkeeping for one open container (group, scroll, overlay,
/// virtual list). Children fold their size into the accumulators; the pop
/// arm turns it into the container's own rect.
const GroupContext = struct {
    cmd_index: usize,
    direction: Direction,
    pad_x: f32,
    pad_y: f32,
    gap: f32,
    /// Flex weight this container carries into its parent.
    flex: f32 = 0,
    /// Forced outer size per axis (0 = measured from children) and the
    /// floor applied to the measured size.
    fixed_w: f32 = 0,
    fixed_h: f32 = 0,
    min_w: f32 = 0,
    min_h: f32 = 0,
    is_scroll: bool = false,
    /// A grid sizes itself from a scan of its direct children at its pop
    /// (`measureGrid`); the accumulators are unused.
    is_grid: bool = false,
    /// Virtual lists claim `total_count * item_extent` on the main axis
    /// regardless of how many children were emitted in the visible window.
    is_virtual: bool = false,
    total_count: f32 = 0,
    item_extent: f32 = 0,
    fixed_main: f32 = 0,
    flex_total: f32 = 0,
    cross_axis_max: f32 = 0,
    child_count: u32 = 0,
};

/// Position-pass cursor for the children of one open container.
const CursorContext = struct {
    x: f32,
    y: f32,
    direction: Direction,
    /// Effective gap between children: the style gap plus the extra
    /// spacing `Justify.space_between` hands out.
    gap: f32,
    per_flex_unit: f32 = 0,
    inner_cross: f32 = 0,
    align_cross: Align = .start,
    child_count: u32 = 0,
    /// Set for a grid: its children go to cells instead of the cursor.
    /// Points into the position pass's fixed grid stack.
    grid: ?*GridCursor = null,
};

/// Position-pass state of one open grid: resolved column widths and the
/// running row. Lives in a fixed stack parallel to the cursor stack.
const GridCursor = struct {
    n: usize,
    col_w: [cmd.MAX_GRID_COLUMNS]f32,
    col_x: [cmd.MAX_GRID_COLUMNS]f32,
    row_gap: f32,
    align_x: Align,
    align_y: Align,
    /// Top of the current row and its height (the tallest cell in it).
    y: f32,
    row_h: f32 = 0,
    /// Cells placed so far.
    count: usize = 0,
    /// Cmd index of the next direct child, and the grid's `pop_grid`.
    next: usize,
    end: usize,
};

fn FixedStack(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        // Bounds failures panic in every optimization mode.

        fn push(self: *Self, item: T) void {
            if (self.len >= capacity) @panic("teak layout: container stack overflow");
            self.buffer[self.len] = item;
            self.len += 1;
        }

        fn pop(self: *Self) T {
            if (self.len == 0) @panic("teak layout: container stack underflow");
            self.len -= 1;
            return self.buffer[self.len];
        }

        fn top(self: *Self) *T {
            if (self.len == 0) @panic("teak layout: container stack is empty");
            return &self.buffer[self.len - 1];
        }
    };
}

// Layout sizing and pass invariants: docs/features/layout.md and SRC.md.

pub const LayoutEngine = struct {
    const TEXT_HEIGHT: f32 = 20;
    const SLIDER_HEIGHT: f32 = 24;

    /// What `doLayoutStats` did, for tests that pin the pass structure.
    pub const Stats = struct {
        /// Passes 2 (resolve widths) and 3 (re-measure heights) ran: the frame
        /// has wrapped text or `shrink > 0` containers.
        wrap_passes: bool = false,
    };

    /// Run the layout passes: measure, position -- and, only when the frame
    /// contains wrapped text or shrinkable containers, resolve widths and
    /// re-measure heights in between. The first push_group (the root) is
    /// resized to the window before widths resolve, so flex and wrapping
    /// resolve against the real window size.
    pub fn doLayout(
        rects: []Rect,
        cmds: anytype,
        window_w: f32,
        window_h: f32,
        measurer: TextMeasurer,
    ) void {
        _ = doLayoutStats(rects, cmds, window_w, window_h, measurer);
    }

    /// `doLayout`, reporting which passes ran.
    pub fn doLayoutStats(
        rects: []Rect,
        cmds: anytype,
        window_w: f32,
        window_h: f32,
        measurer: TextMeasurer,
    ) Stats {
        const needs_wrap = measurePassImpl(rects, cmds, measurer);
        const root_is_group = cmds.len > 0 and cmds[0] == .push_group;
        if (root_is_group) {
            rects[0].w = window_w;
            rects[0].h = window_h;
        }
        if (needs_wrap) {
            resolveWidths(rects, cmds, measurer);
            remeasureHeights(rects, cmds, measurer);
            if (root_is_group) rects[0].h = window_h;
        }
        positionPass(rects, cmds);
        return .{ .wrap_passes = needs_wrap };
    }

    /// Pass 1 — measure. Bottom-up via an explicit stack. Each command
    /// writes its intrinsic size to rects[i]; container entries also
    /// record fixed_main, flex_total, child_count for the position pass.
    pub fn measurePass(rects: []Rect, cmds: anytype, measurer: TextMeasurer) void {
        _ = measurePassImpl(rects, cmds, measurer);
    }

    /// Pass 1 body. Returns true when the frame needs passes 2-3: some `text`
    /// wraps or some group/scroll has `shrink > 0`. Wrapped text measures at
    /// its max-content width (one line per hard break) here; the real width
    /// comes from pass 2.
    fn measurePassImpl(rects: []Rect, cmds: anytype, measurer: TextMeasurer) bool {
        var stack: FixedStack(GroupContext, MAX_DEPTH) = .{};
        var needs_wrap = false;

        for (cmds, 0..) |c, i| {
            switch (c) {
                .push_group => |grp| {
                    assertPushable(stack.len, stack.buffer.len, i);
                    if (grp.shrink > 0) needs_wrap = true;
                    stack.push(.{
                        .cmd_index = i,
                        .direction = grp.direction,
                        .pad_x = grp.padX(),
                        .pad_y = grp.padY(),
                        .gap = grp.gap,
                        .flex = grp.flex,
                        .fixed_w = grp.width,
                        .fixed_h = grp.height,
                        .min_w = grp.min_width,
                        .min_h = grp.min_height,
                    });
                },
                .push_grid => |g| {
                    assertPushable(stack.len, stack.buffer.len, i);
                    stack.push(.{
                        .cmd_index = i,
                        .direction = .vertical,
                        .pad_x = g.padX(),
                        .pad_y = g.padY(),
                        .gap = 0,
                        .flex = g.flex,
                        .fixed_w = g.width,
                        .fixed_h = g.height,
                        .min_w = g.min_width,
                        .min_h = g.min_height,
                        .is_grid = true,
                    });
                },
                .pop_grid => {
                    assertPoppable(stack.len, i);
                    const grp = stack.pop();
                    var r = measureGrid(rects, cmds, grp, i);
                    r.end = @intCast(i);
                    rects[grp.cmd_index] = r;
                    addLeafToTop(&stack, r.w, r.h, grp.flex);
                },
                .push_scroll => |sc| {
                    assertPushable(stack.len, stack.buffer.len, i);
                    if (sc.shrink > 0) needs_wrap = true;
                    stack.push(.{
                        .cmd_index = i,
                        .direction = sc.direction,
                        .pad_x = sc.padding,
                        .pad_y = sc.padding,
                        .gap = sc.gap,
                        .flex = sc.flex,
                        .fixed_w = sc.width,
                        .fixed_h = sc.height,
                        .is_scroll = true,
                    });
                },
                .push_overlay => |ov| {
                    assertPushable(stack.len, stack.buffer.len, i);
                    stack.push(.{
                        .cmd_index = i,
                        .direction = ov.direction,
                        .pad_x = ov.padding,
                        .pad_y = ov.padding,
                        .gap = ov.gap,
                        .fixed_w = ov.width,
                        .fixed_h = ov.height,
                    });
                },
                .push_virtual_list => |vl| {
                    assertPushable(stack.len, stack.buffer.len, i);
                    stack.push(.{
                        .cmd_index = i,
                        .direction = vl.direction,
                        .pad_x = vl.padding,
                        .pad_y = vl.padding,
                        .gap = vl.gap,
                        .is_virtual = true,
                        .total_count = if (vl.total_extent > 0) 1 else @floatFromInt(vl.total_count),
                        .item_extent = if (vl.total_extent > 0) vl.total_extent else vl.item_extent,
                    });
                },
                .pop_group, .pop_scroll => {
                    assertPoppable(stack.len, i);
                    const grp = stack.pop();
                    var r = finishContainer(grp);
                    if (grp.is_scroll and grp.flex > 0 and stack.len > 0 and !stack.top().is_grid) {
                        switch (stack.top().direction) {
                            .horizontal => if (grp.fixed_w <= 0) {
                                r.w = 0;
                            },
                            .vertical => if (grp.fixed_h <= 0) {
                                r.h = 0;
                            },
                        }
                        switch (grp.direction) {
                            .horizontal => if (grp.fixed_w <= 0) {
                                r.w = 0;
                            },
                            .vertical => if (grp.fixed_h <= 0) {
                                r.h = 0;
                            },
                        }
                    }
                    r.end = @intCast(i);
                    rects[grp.cmd_index] = r;
                    addLeafToTop(&stack, r.w, r.h, grp.flex);
                },
                .pop_overlay => {
                    assertPoppable(stack.len, i);
                    const grp = stack.pop();
                    var r = finishContainer(grp);
                    r.end = @intCast(i);
                    rects[grp.cmd_index] = r;
                },
                .pop_virtual_list => {
                    assertPoppable(stack.len, i);
                    const grp = stack.pop();
                    var r = finishContainer(grp);
                    const total_main = grp.total_count * grp.item_extent;
                    switch (grp.direction) {
                        .horizontal => r.w = total_main + 2 * grp.pad_x,
                        .vertical => r.h = total_main + 2 * grp.pad_y,
                    }
                    r.fixed_main = total_main;
                    r.end = @intCast(i);
                    rects[grp.cmd_index] = r;
                    addLeafToTop(&stack, r.w, r.h, 0);
                },
                .text => |txt| {
                    if (txt.wrap != .none) {
                        needs_wrap = true;
                        const mw = text_wrap.measureWrapped(txt.content, txt.font, std.math.inf(f32), txt.wrap, txt.max_lines, measurer);
                        rects[i] = .{ .w = mw.w, .h = mw.h };
                        addLeafToTop(&stack, mw.w, mw.h, 0);
                        continue;
                    }
                    const m = measurer.measure(txt.content, txt.font);
                    rects[i] = .{ .w = m.width, .h = m.height };
                    addLeafToTop(&stack, m.width, m.height, 0);
                },
                .button => |btn| {
                    const label_w = measurer.measure(btn.label, btn.font).width + 2 * btn.style.h_padding;
                    const w = if (btn.style.ellipsis) btn.style.min_width else @max(label_w, btn.style.min_width);
                    const h = btn.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, btn.style.flex);
                },
                .text_input => |ti| {
                    const w = ti.style.min_width;
                    const h = ti.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, rowFlex(&stack, ti.style.flex));
                },
                .text_area => |ta| {
                    const w = if (ta.width > 0) ta.width else ta.min_width;
                    rects[i] = .{ .w = w, .h = ta.height };
                    addLeafToTop(&stack, w, ta.height, ta.flex);
                },
                .checkbox => |cb| {
                    const label_w = measurer.measure(cb.label, cb.font).width;
                    const w = cb.style.size + (if (cb.label.len > 0) cb.style.label_gap + label_w else 0);
                    const h = @max(cb.style.size, TEXT_HEIGHT);
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, 0);
                },
                .radio => |rd| {
                    const label_w = measurer.measure(rd.label, rd.font).width;
                    const w = rd.style.size + (if (rd.label.len > 0) rd.style.label_gap + label_w else 0);
                    const h = @max(rd.style.size, TEXT_HEIGHT);
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, 0);
                },
                .slider => |sl| {
                    const w = sl.style.min_width;
                    const h = @max(SLIDER_HEIGHT, sl.style.thumb_size);
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, rowFlex(&stack, sl.style.flex));
                },
                .divider => |dv| {
                    const parent_dir = if (stack.len > 0) stack.top().direction else .horizontal;
                    const w: f32 = switch (parent_dir) {
                        .horizontal => dv.thickness,
                        .vertical => 0,
                    };
                    const h: f32 = switch (parent_dir) {
                        .horizontal => 0,
                        .vertical => dv.thickness,
                    };
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, 0);
                },
                .image => |img| {
                    const w = img.style.width;
                    const h = img.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, img.style.flex);
                },
                .scene3d => |sc| {
                    const w = sc.style.width;
                    const h = sc.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, sc.style.flex);
                },
                .canvas => |cv| {
                    const w = cv.style.width;
                    const h = cv.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, cv.style.flex);
                },
                .rich_text => |rt| {
                    if (rt.wrap != .none) {
                        needs_wrap = true;
                        const rm = text_wrap.RichMeasure.init(rt.content, rt.spans, rt.default_font, measurer);
                        const mw = text_wrap.measureWrapped(rt.content, rt.default_font, std.math.inf(f32), rt.wrap, rt.max_lines, rm.measurer());
                        rects[i] = .{ .w = mw.w, .h = mw.h };
                        addLeafToTop(&stack, mw.w, mw.h, 0);
                        continue;
                    }
                    var max_h: f32 = 0;
                    var total_w: f32 = 0;
                    var cursor: u32 = 0;
                    for (rt.spans) |sp| {
                        if (sp.start > cursor) {
                            const m = measurer.measure(
                                rt.content[cursor..sp.start],
                                rt.default_font,
                            );
                            total_w += m.width;
                            max_h = @max(max_h, m.height);
                        }
                        const end = @min(sp.end, std.math.lossyCast(u32, rt.content.len));
                        if (end > sp.start) {
                            const m = measurer.measure(rt.content[sp.start..end], sp.font);
                            total_w += m.width;
                            max_h = @max(max_h, m.height);
                        }
                        cursor = end;
                    }
                    if (cursor < rt.content.len) {
                        const m = measurer.measure(
                            rt.content[cursor..],
                            rt.default_font,
                        );
                        total_w += m.width;
                        max_h = @max(max_h, m.height);
                    }
                    if (max_h == 0) max_h = rt.default_font.size_px;
                    rects[i] = .{ .w = total_w, .h = max_h };
                    addLeafToTop(&stack, total_w, max_h, 0);
                },
            }
        }
        return needs_wrap;
    }


    /// A direct child as the width passes see it.
    const Kid = struct {
        flex: f32 = 0,
        /// Shrink weight (wrapped text counts as 1).
        shrink: f32 = 0,
        fixed_w: bool = false,
        min_w: f32 = 0,
        fills_cross: bool = false,
        /// Wrapped text: width is decided by wrapping, not by plain stretch.
        wrapped: bool = false,
    };

    fn kidOf(c: anytype) Kid {
        return switch (c) {
            .push_group => |g| .{ .flex = g.flex, .shrink = g.shrink, .fixed_w = g.width > 0, .min_w = g.min_width },
            .push_grid => |g| .{ .flex = g.flex, .fixed_w = g.width > 0, .min_w = g.min_width },
            .push_scroll => |sc| .{ .flex = sc.flex, .shrink = sc.shrink, .fixed_w = sc.width > 0 },
            .push_virtual_list => .{},
            .text => |t| if (t.wrap != .none) .{ .shrink = 1, .wrapped = true, .fills_cross = t.text_align != .start } else .{},
            .button => |b| .{ .flex = b.style.flex },
            .image => |img| .{ .flex = img.style.flex },
            .canvas => |cv| .{ .flex = cv.style.flex },
            .scene3d => |sc| .{ .flex = sc.style.flex },
            .text_input => |ti| .{ .flex = ti.style.flex, .fills_cross = true },
            .text_area => |ta| .{ .flex = ta.flex, .fixed_w = ta.width > 0, .fills_cross = true },
            .slider => |sl| .{ .flex = sl.style.flex, .fills_cross = true },
            .divider => .{ .fills_cross = true },
            .rich_text => |rt| if (rt.wrap != .none) .{ .shrink = 1, .wrapped = true, .fills_cross = rt.text_align != .start } else .{},
            .checkbox, .radio => .{},
            .push_overlay, .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => .{},
        };
    }

    /// Next direct child of the container whose subtree ends before `end`,
    /// skipping overlays (they hop layout) and hopping over child subtrees.
    fn nextKid(rects: []const Rect, cmds: anytype, it: *usize, end: usize) ?usize {
        while (it.* < end) {
            const c = it.*;
            switch (cmds[c]) {
                .push_overlay => it.* = rects[c].end + 1,
                .push_group, .push_grid, .push_scroll, .push_virtual_list => {
                    it.* = rects[c].end + 1;
                    return c;
                },
                else => {
                    it.* += 1;
                    return c;
                },
            }
        }
        return null;
    }

    /// Container facts pass 2 needs; null for non-containers.
    const WidthSpec = struct { direction: Direction, pad_x: f32, pad_y: f32, gap: f32, align_cross: Align, can_shrink: bool };

    fn widthSpecOf(c: anytype) ?WidthSpec {
        return switch (c) {
            .push_group => |g| .{ .direction = g.direction, .pad_x = g.padX(), .pad_y = g.padY(), .gap = g.gap, .align_cross = g.align_cross, .can_shrink = true },
            .push_scroll => |sc| .{ .direction = sc.direction, .pad_x = sc.padding, .pad_y = sc.padding, .gap = sc.gap, .align_cross = sc.align_cross, .can_shrink = sc.direction == .vertical },
            .push_overlay => |ov| .{ .direction = ov.direction, .pad_x = ov.padding, .pad_y = ov.padding, .gap = ov.gap, .align_cross = ov.align_cross, .can_shrink = true },
            .push_grid, .pop_grid, .pop_group, .pop_scroll, .pop_overlay, .pop_virtual_list, .push_virtual_list, .text, .rich_text, .button, .text_input, .text_area, .checkbox, .radio, .slider, .divider, .image, .scene3d, .canvas => null,
        };
    }

    /// Pass 2: settle the widths of every container's direct children.
    pub fn resolveWidths(rects: []Rect, cmds: anytype, measurer: TextMeasurer) void {
        for (cmds, 0..) |c, i| {
            if (c == .push_grid) {
                resolveGridWidths(rects, cmds, i, c.push_grid.*, measurer);
                continue;
            }
            const spec = widthSpecOf(c) orelse continue;
            const r = rects[i];
            const inner_w = @max(0, r.w - 2 * spec.pad_x);
            if (spec.direction == .horizontal) {
                const left = inner_w - (r.fixed_main + gapTotal(r.child_count, spec.gap));
                if (left > EPS and r.flex_total > 0) {
                    const per = left / r.flex_total;
                    var it = i + 1;
                    while (nextKid(rects, cmds, &it, r.end)) |k| rects[k].w += kidOf(cmds[k]).flex * per;
                } else if (left < -EPS and spec.can_shrink) {
                    shrinkChildren(rects, cmds, i, spec, inner_w, measurer);
                }
            } else if (inner_w > 0) {
                var it = i + 1;
                while (nextKid(rects, cmds, &it, r.end)) |k| {
                    const kid = kidOf(cmds[k]);
                    const stretch = spec.align_cross == .stretch or (spec.align_cross == .start and kid.fills_cross);
                    if (kid.wrapped) {
                        rects[k].w = if (stretch) inner_w else @min(rects[k].w, inner_w);
                    } else if (stretch and !kid.fixed_w) {
                        rects[k].w = @max(inner_w, kid.min_w);
                    }
                }
            }
        }
    }

    const EPS: f32 = 0.001;

    /// CSS-style flex-shrink with floors: share the deficit among shrinkable
    /// children in proportion to `shrink * width`, clamping each at its
    /// min-content and redistributing what the clamped ones could not give.
    fn shrinkChildren(rects: []Rect, cmds: anytype, i: usize, spec: WidthSpec, inner_w: f32, measurer: TextMeasurer) void {
        const r = rects[i];
        const gaps = gapTotal(r.child_count, spec.gap);
        var round: usize = 0;
        while (round <= r.child_count) : (round += 1) {
            var sum: f32 = gaps;
            var scaled: f32 = 0;
            var it = i + 1;
            while (nextKid(rects, cmds, &it, r.end)) |k| {
                sum += rects[k].w;
                const kid = kidOf(cmds[k]);
                if (kid.shrink > 0 and rects[k].w > minWidth(rects, cmds, k, measurer) + EPS) scaled += kid.shrink * rects[k].w;
            }
            const deficit = sum - inner_w;
            if (deficit <= EPS or scaled <= 0) break;
            it = i + 1;
            while (nextKid(rects, cmds, &it, r.end)) |k| {
                const kid = kidOf(cmds[k]);
                if (kid.shrink <= 0) continue;
                const floor = minWidth(rects, cmds, k, measurer);
                const w = rects[k].w;
                if (w <= floor + EPS) continue;
                rects[k].w = @max(floor, w - deficit * (kid.shrink * w) / scaled);
            }
        }
    }

    /// Narrowest width node `k` may be shrunk to (its pass-1 width when it
    /// cannot shrink): wrapped text -> its min-content; a shrinkable
    /// container -> what its children need at their own minimums.
    fn minWidth(rects: []const Rect, cmds: anytype, k: usize, measurer: TextMeasurer) f32 {
        const w = rects[k].w;
        switch (cmds[k]) {
            .text => |t| {
                if (t.wrap == .none) return w;
                return @min(w, text_wrap.minContentFor(t.content, t.font, t.wrap, measurer));
            },
            .rich_text => |rt| {
                if (rt.wrap == .none) return w;
                const rm = text_wrap.RichMeasure.init(rt.content, rt.spans, rt.default_font, measurer);
                return @min(w, text_wrap.minContentFor(rt.content, rt.default_font, rt.wrap, rm.measurer()));
            },
            .push_group, .push_scroll => {
                const kid = kidOf(cmds[k]);
                const spec = widthSpecOf(cmds[k]).?;
                if (kid.shrink <= 0 or !spec.can_shrink) return w;
                var sum: f32 = 0;
                var widest: f32 = 0;
                var n: u32 = 0;
                var it = k + 1;
                while (nextKid(rects, cmds, &it, rects[k].end)) |ch| {
                    const m = if (kidOf(cmds[ch]).shrink > 0) minWidth(rects, cmds, ch, measurer) else rects[ch].w;
                    sum += m;
                    widest = @max(widest, m);
                    n += 1;
                }
                const content = if (spec.direction == .horizontal) sum + gapTotal(n, spec.gap) else widest;
                return @min(w, @max(kid.min_w, content + 2 * spec.pad_x));
            },
            else => return w,
        }
    }

    /// Pass 3: re-measure heights bottom-up with the resolved widths. Widths
    /// are final (pass 2); containers recompute their height and their
    /// `fixed_main` (so the position pass sees the real child sizes).
    pub fn remeasureHeights(rects: []Rect, cmds: anytype, measurer: TextMeasurer) void {
        var stack: FixedStack(GroupContext, MAX_DEPTH) = .{};
        for (cmds, 0..) |c, i| {
            switch (c) {
                .push_group => |g| stack.push(refreshCtx(rects[i], i, .{
                    .cmd_index = i,
                    .direction = g.direction,
                    .pad_x = g.padX(),
                    .pad_y = g.padY(),
                    .gap = g.gap,
                    .fixed_w = g.width,
                    .fixed_h = g.height,
                    .min_w = g.min_width,
                    .min_h = g.min_height,
                })),
                .push_grid => |g| stack.push(refreshCtx(rects[i], i, .{
                    .cmd_index = i,
                    .direction = .vertical,
                    .pad_x = g.padX(),
                    .pad_y = g.padY(),
                    .gap = 0,
                    .fixed_w = g.width,
                    .fixed_h = g.height,
                    .min_w = g.min_width,
                    .min_h = g.min_height,
                    .is_grid = true,
                })),
                .pop_grid => {
                    const grp = stack.pop();
                    const old = rects[grp.cmd_index];
                    var r = measureGrid(rects, cmds, grp, i);
                    r.w = old.w;
                    r.end = old.end;
                    rects[grp.cmd_index] = r;
                    foldChild(&stack, r.w, r.h);
                },
                .push_scroll => |sc| stack.push(refreshCtx(rects[i], i, .{
                    .cmd_index = i,
                    .direction = sc.direction,
                    .pad_x = sc.padding,
                    .pad_y = sc.padding,
                    .gap = sc.gap,
                    .flex = sc.flex,
                    .fixed_w = sc.width,
                    .fixed_h = sc.height,
                    .is_scroll = true,
                })),
                .push_overlay => |ov| stack.push(refreshCtx(rects[i], i, .{
                    .cmd_index = i,
                    .direction = ov.direction,
                    .pad_x = ov.padding,
                    .pad_y = ov.padding,
                    .gap = ov.gap,
                    .fixed_w = ov.width,
                    .fixed_h = ov.height,
                })),
                .push_virtual_list => |vl| stack.push(refreshCtx(rects[i], i, .{
                    .cmd_index = i,
                    .direction = vl.direction,
                    .pad_x = vl.padding,
                    .pad_y = vl.padding,
                    .gap = vl.gap,
                    .is_virtual = true,
                })),
                .pop_group, .pop_scroll => {
                    const grp = stack.pop();
                    const old = rects[grp.cmd_index];
                    var r = finishContainer(grp);
                    r.w = old.w;
                    r.end = old.end;
                    if (grp.is_scroll and grp.flex > 0) r.h = old.h;
                    rects[grp.cmd_index] = r;
                    foldChild(&stack, r.w, r.h);
                },
                .pop_overlay => {
                    const grp = stack.pop();
                    const old = rects[grp.cmd_index];
                    var r = finishContainer(grp);
                    r.w = old.w;
                    r.end = old.end;
                    rects[grp.cmd_index] = r;
                },
                .pop_virtual_list => {
                    const grp = stack.pop();
                    foldChild(&stack, rects[grp.cmd_index].w, rects[grp.cmd_index].h);
                },
                .text => |t| {
                    if (t.wrap != .none) {
                        rects[i].h = text_wrap.measureWrapped(t.content, t.font, rects[i].w, t.wrap, t.max_lines, measurer).h;
                    }
                    foldChild(&stack, rects[i].w, rects[i].h);
                },
                .rich_text => |rt| {
                    if (rt.wrap != .none) {
                        const rm = text_wrap.RichMeasure.init(rt.content, rt.spans, rt.default_font, measurer);
                        rects[i].h = text_wrap.measureWrapped(rt.content, rt.default_font, rects[i].w, rt.wrap, rt.max_lines, rm.measurer()).h;
                    }
                    foldChild(&stack, rects[i].w, rects[i].h);
                },
                .button, .text_input, .text_area, .checkbox, .radio, .slider, .divider, .image, .scene3d, .canvas => foldChild(&stack, rects[i].w, rects[i].h),
            }
        }
    }

    /// A pass-3 container context: accumulators reset, flex/child totals kept
    /// from pass 1 (the child set is unchanged).
    fn refreshCtx(old: Rect, i: usize, base: GroupContext) GroupContext {
        var g = base;
        g.cmd_index = i;
        g.flex_total = old.flex_total;
        g.child_count = old.child_count;
        return g;
    }

    /// Fold a child's (possibly re-measured) size into its parent's accumulators.
    fn foldChild(stack: *FixedStack(GroupContext, MAX_DEPTH), child_w: f32, child_h: f32) void {
        if (stack.len == 0) return;
        const t = stack.top();
        const horizontal = t.direction == .horizontal;
        t.fixed_main += if (horizontal) child_w else child_h;
        t.cross_axis_max = @max(t.cross_axis_max, if (horizontal) child_h else child_w);
    }

    /// Pass 4 — position (pass 2 when the frame has no wrapped nodes). Top-down, forward scan. A container is sized
    /// (flex growth, stretch) while it is placed in its parent, so by the
    /// time its own children are placed its final rect is known; each child
    /// goes at the running cursor.
    pub fn positionPass(rects: []Rect, cmds: anytype) void {
        var stack: FixedStack(CursorContext, MAX_DEPTH) = .{};
        var grids: FixedStack(GridCursor, MAX_DEPTH) = .{};

        for (cmds, 0..) |c, i| {
            if (stack.len > 0) if (stack.top().grid) |g| if (i == g.next) beginGridCell(rects, cmds, g, i);
            switch (c) {
                .push_grid => |g| {
                    if (stack.len > 0) placeChild(rects, &stack, i, .{
                        .flex = g.flex,
                        .fixed_w = g.width > 0,
                        .fixed_h = g.height > 0,
                        .min_w = g.min_width,
                        .min_h = g.min_height,
                    });
                    const r = rects[i];
                    const inner_w = @max(0, r.w - 2 * g.padX());
                    const content = gridContentWidths(rects, cmds, i, g.*, null);
                    const n = g.columnCount();
                    var gc: GridCursor = .{
                        .n = n,
                        .col_w = resolveGridColumns(g.*, &content, inner_w),
                        .col_x = undefined,
                        .row_gap = g.row_gap,
                        .align_x = g.align_x,
                        .align_y = g.align_y,
                        .y = r.y + g.padY(),
                        .next = i + 1,
                        .end = r.end,
                    };
                    var x = r.x + g.padX();
                    for (0..n) |col| {
                        gc.col_x[col] = x;
                        x += gc.col_w[col] + g.col_gap;
                    }
                    var it = i + 1;
                    gc.next = nextKid(rects, cmds, &it, r.end) orelse no_cell;
                    assertPushable(grids.len, grids.buffer.len, i);
                    grids.push(gc);
                    assertPushable(stack.len, stack.buffer.len, i);
                    stack.push(.{ .x = r.x, .y = r.y, .direction = .vertical, .gap = 0, .grid = grids.top() });
                },
                .pop_grid => {
                    assertPoppable(stack.len, i);
                    _ = stack.pop();
                    _ = grids.pop();
                },
                .push_group => |g| {
                    if (stack.len > 0) placeChild(rects, &stack, i, .{
                        .flex = g.flex,
                        .fixed_w = g.width > 0,
                        .fixed_h = g.height > 0,
                        .min_w = g.min_width,
                        .min_h = g.min_height,
                    });
                    pushChildren(rects, &stack, i, .{
                        .direction = g.direction,
                        .pad_x = g.padX(),
                        .pad_y = g.padY(),
                        .gap = g.gap,
                        .align_cross = g.align_cross,
                        .justify = g.justify,
                    });
                },
                .push_scroll => |sc| {
                    if (stack.len > 0) placeChild(rects, &stack, i, .{
                        .flex = sc.flex,
                        .fixed_w = sc.width > 0,
                        .fixed_h = sc.height > 0,
                    });
                    pushChildren(rects, &stack, i, .{
                        .direction = sc.direction,
                        .pad_x = sc.padding,
                        .pad_y = sc.padding,
                        .gap = sc.gap,
                        .align_cross = sc.align_cross,
                        .scroll_x = sc.scroll_x,
                        .scroll_y = sc.scroll_y,
                    });
                },
                .push_overlay => |ov| {
                    rects[i].x = ov.x - rects[i].w * ov.anchor_x_frac;
                    rects[i].y = ov.y - rects[i].h * ov.anchor_y_frac;
                    if (ov.anchor_msg) |am| {
                        if (findAnchor(cmds, rects, i, am)) |a| placeAnchored(&rects[i], a, ov.anchor_side, ov.anchor_gap);
                    }
                    pushChildren(rects, &stack, i, .{
                        .direction = ov.direction,
                        .pad_x = ov.padding,
                        .pad_y = ov.padding,
                        .gap = ov.gap,
                        .align_cross = ov.align_cross,
                    });
                },
                .push_virtual_list => |vl| {
                    if (stack.len > 0) placeChild(rects, &stack, i, .{});
                    pushChildren(rects, &stack, i, .{
                        .direction = vl.direction,
                        .pad_x = vl.padding,
                        .pad_y = vl.padding,
                        .gap = vl.gap,
                        .align_cross = vl.align_cross,
                    });
                    const ctx = stack.top();
                    const offset: f32 = if (vl.total_extent > 0) vl.start_offset else @as(f32, @floatFromInt(vl.visible_start)) * vl.item_extent;
                    switch (vl.direction) {
                        .horizontal => ctx.x += offset,
                        .vertical => ctx.y += offset,
                    }
                },
                .pop_group, .pop_scroll, .pop_overlay, .pop_virtual_list => {
                    assertPoppable(stack.len, i);
                    _ = stack.pop();
                },
                .text, .checkbox, .radio, .rich_text => placeChild(rects, &stack, i, .{}),
                .button => |b| placeChild(rects, &stack, i, .{ .flex = b.style.flex }),
                .image => |img| placeChild(rects, &stack, i, .{ .flex = img.style.flex }),
                .canvas => |cv| placeChild(rects, &stack, i, .{ .flex = cv.style.flex }),
                .text_area => |ta| placeChild(rects, &stack, i, .{ .flex = ta.flex, .fixed_w = ta.width > 0, .fixed_h = true, .fills_cross = true }),
                .scene3d => |sc| placeChild(rects, &stack, i, .{ .flex = sc.style.flex }),
                .text_input => |ti| placeChild(rects, &stack, i, .{ .flex = ti.style.flex, .row_only = true, .fills_cross = true }),
                .slider => |sl| placeChild(rects, &stack, i, .{ .flex = sl.style.flex, .row_only = true, .fills_cross = true }),
                .divider => placeChild(rects, &stack, i, .{ .fills_cross = true }),
            }
        }
    }

    /// What `placeChild` needs to know about the child beyond its measured rect.
    const ChildSpec = struct {
        /// Main-axis flex weight.
        flex: f32 = 0,
        /// The child fixed its own outer size on that axis (group/scroll
        /// `width`/`height` > 0); stretch leaves it alone.
        fixed_w: bool = false,
        fixed_h: bool = false,
        /// Floor applied when stretching.
        min_w: f32 = 0,
        min_h: f32 = 0,
        /// Single-line controls (text_input, slider) are one row tall: their
        /// flex grows them along a horizontal main axis only, never a
        /// vertical one (see `rowFlex`).
        row_only: bool = false,
        /// Legacy leaves (text_input, slider, divider) fill the cross axis
        /// of a `.start` parent too.
        fills_cross: bool = false,
    };

    /// Place one child (leaf or container) at the parent's cursor: grow it
    /// along the main axis by its flex share, size it along the cross axis
    /// per the parent's `align_cross`, then advance the cursor.
    fn placeChild(rects: []Rect, stack: *FixedStack(CursorContext, MAX_DEPTH), i: usize, spec: ChildSpec) void {
        const ctx = stack.top();
        if (ctx.grid) |g| return placeGridCell(rects, g, i, spec);
        if (ctx.child_count > 0) advanceCursor(ctx, ctx.gap);
        const r = &rects[i];
        const horizontal = ctx.direction == .horizontal;

        const flex = if (spec.row_only and !horizontal) 0 else spec.flex;
        if (flex > 0 and ctx.per_flex_unit > 0) {
            if (horizontal) r.w += flex * ctx.per_flex_unit else r.h += flex * ctx.per_flex_unit;
        }

        const stretch = ctx.align_cross == .stretch or (ctx.align_cross == .start and spec.fills_cross);
        const cross_fixed = if (horizontal) spec.fixed_h else spec.fixed_w;
        if (stretch and !cross_fixed and ctx.inner_cross > 0) {
            if (horizontal) r.h = @max(ctx.inner_cross, spec.min_h) else r.w = @max(ctx.inner_cross, spec.min_w);
        }

        const cross_size = if (horizontal) r.h else r.w;
        const slack = @max(0, ctx.inner_cross - cross_size);
        const cross_offset: f32 = switch (ctx.align_cross) {
            .start, .stretch => 0,
            .center => slack * 0.5,
            .end => slack,
        };
        r.x = ctx.x + (if (horizontal) 0 else cross_offset);
        r.y = ctx.y + (if (horizontal) cross_offset else 0);
        ctx.child_count += 1;
        advanceCursor(ctx, if (horizontal) r.w else r.h);
    }

    const ContainerSpec = struct {
        direction: Direction,
        pad_x: f32,
        pad_y: f32,
        gap: f32,
        align_cross: Align = .start,
        justify: Justify = .start,
        scroll_x: f32 = 0,
        scroll_y: f32 = 0,
    };

    /// Open the cursor for the children of container `i`, whose rect is
    /// final by now: split the leftover main-axis space (flex weights, else
    /// `justify`) and record the inner cross extent for `align_cross`.
    fn pushChildren(rects: []Rect, stack: *FixedStack(CursorContext, MAX_DEPTH), i: usize, spec: ContainerSpec) void {
        const r = rects[i];
        const horizontal = spec.direction == .horizontal;
        const inner_w = @max(0, r.w - 2 * spec.pad_x);
        const inner_h = @max(0, r.h - 2 * spec.pad_y);
        const inner_main = if (horizontal) inner_w else inner_h;
        const gaps = gapTotal(r.child_count, spec.gap);
        const extra = @max(0, inner_main - r.fixed_main - gaps);

        var gap = spec.gap;
        var lead: f32 = 0;
        var per_flex_unit: f32 = 0;
        if (r.flex_total > 0) {
            per_flex_unit = extra / r.flex_total;
        } else switch (spec.justify) {
            .start => {},
            .center => lead = extra * 0.5,
            .end => lead = extra,
            .space_between => if (r.child_count > 1) {
                gap += extra / @as(f32, @floatFromInt(r.child_count - 1));
            },
        }

        assertPushable(stack.len, stack.buffer.len, i);
        stack.push(.{
            .x = r.x + spec.pad_x - spec.scroll_x + (if (horizontal) lead else 0),
            .y = r.y + spec.pad_y - spec.scroll_y + (if (horizontal) 0 else lead),
            .direction = spec.direction,
            .gap = gap,
            .per_flex_unit = per_flex_unit,
            .inner_cross = if (horizontal) inner_h else inner_w,
            .align_cross = spec.align_cross,
        });
    }

    // Grid layout: docs/features/layout.md#grid.

    const GridCols = [cmd.MAX_GRID_COLUMNS]f32;

    /// `GridCursor.next` once the grid has no further direct child.
    const no_cell = std.math.maxInt(usize);

    /// Widest direct child per column. With a `measurer` (pass 2), `fr`
    /// columns count a shrinkable child (wrapped text, `shrink > 0` group)
    /// at its min-content width, so wrapped text can wrap to fit.
    fn gridContentWidths(rects: []const Rect, cmds: anytype, i: usize, g: cmd.GridStyle, measurer: ?TextMeasurer) GridCols {
        var out: GridCols = @splat(0);
        const n = g.columnCount();
        var idx: usize = 0;
        var it = i + 1;
        while (nextKid(rects, cmds, &it, rects[i].end)) |k| : (idx += 1) {
            const col = idx % n;
            const w = if (measurer != null and g.track(col) == .fr) minWidth(rects, cmds, k, measurer.?) else rects[k].w;
            out[col] = @max(out[col], w);
        }
        return out;
    }

    /// Column widths for an inner width: `fixed` = px, `auto` = content,
    /// `fr` = a weighted share of what is left, floored at content (a column
    /// whose share is below its content is frozen there and the rest
    /// re-share; at most `n` rounds).
    fn resolveGridColumns(g: cmd.GridStyle, content: *const GridCols, inner_w: f32) GridCols {
        const n = g.columnCount();
        var out: GridCols = @splat(0);
        var frozen: [cmd.MAX_GRID_COLUMNS]bool = @splat(true);
        var used = gapTotal(@intCast(n), g.col_gap);
        for (0..n) |c| switch (g.track(c)) {
            .auto => {
                out[c] = content[c];
                used += out[c];
            },
            .fixed => |px| {
                out[c] = @max(0, px);
                used += out[c];
            },
            .fr => |wt| if (wt > 0) {
                out[c] = content[c];
                frozen[c] = false;
            } else {
                out[c] = content[c];
                used += out[c];
            },
        };
        var round: usize = 0;
        while (round < n) : (round += 1) {
            var total: f32 = 0;
            for (0..n) |c| if (!frozen[c]) {
                total += g.track(c).fr;
            };
            if (total <= 0) break;
            const unit = (inner_w - used) / total;
            var froze_any = false;
            for (0..n) |c| if (!frozen[c] and g.track(c).fr * unit < content[c]) {
                frozen[c] = true;
                used += content[c];
                froze_any = true;
            };
            if (froze_any) continue;
            for (0..n) |c| if (!frozen[c]) {
                out[c] = g.track(c).fr * unit;
            };
            break;
        }
        return out;
    }

    /// Pass-1 / pass-3 size of the grid closed by `pop_index`: column
    /// widths per track at content size, rows as tall as their tallest cell,
    /// plus gaps and padding; then `width` / `height` / min floors.
    fn measureGrid(rects: []const Rect, cmds: anytype, grp: GroupContext, pop_index: usize) Rect {
        const g = cmds[grp.cmd_index].push_grid.*;
        const n = g.columnCount();
        var col_max: GridCols = @splat(0);
        var rows_h: f32 = 0;
        var row_h: f32 = 0;
        var count: u32 = 0;
        var it = grp.cmd_index + 1;
        while (nextKid(rects, cmds, &it, pop_index)) |k| : (count += 1) {
            const col = count % n;
            col_max[col] = @max(col_max[col], rects[k].w);
            row_h = @max(row_h, rects[k].h);
            if (col == n - 1) {
                rows_h += row_h;
                row_h = 0;
            }
        }
        if (count % n != 0) rows_h += row_h;
        const rows: u32 = @intCast((count + n - 1) / n);
        var cols_w = gapTotal(@intCast(n), g.col_gap);
        for (0..n) |c| cols_w += switch (g.track(c)) {
            .fixed => |px| @max(0, px),
            .auto, .fr => col_max[c],
        };
        const w = cols_w + 2 * grp.pad_x;
        const h = rows_h + gapTotal(rows, g.row_gap) + 2 * grp.pad_y;
        return .{
            .w = @max(if (grp.fixed_w > 0) grp.fixed_w else w, grp.min_w),
            .h = @max(if (grp.fixed_h > 0) grp.fixed_h else h, grp.min_h),
            .child_count = count,
        };
    }

    /// Pass 2 for a grid (its own width is final): give each cell's child
    /// the width the position pass will give it, so wrapped text and nested
    /// containers re-measure against their column.
    fn resolveGridWidths(rects: []Rect, cmds: anytype, i: usize, g: cmd.GridStyle, measurer: TextMeasurer) void {
        const inner_w = @max(0, rects[i].w - 2 * g.padX());
        const content = gridContentWidths(rects, cmds, i, g, measurer);
        const cols = resolveGridColumns(g, &content, inner_w);
        const n = g.columnCount();
        var idx: usize = 0;
        var it = i + 1;
        while (nextKid(rects, cmds, &it, rects[i].end)) |k| : (idx += 1) {
            const cw = cols[idx % n];
            const kid = kidOf(cmds[k]);
            const stretch = g.align_x == .stretch or (g.align_x == .start and kid.fills_cross);
            if (kid.wrapped) {
                rects[k].w = if (stretch) cw else @min(rects[k].w, cw);
            } else if (stretch and !kid.fixed_w) {
                rects[k].w = @max(cw, kid.min_w);
            } else if (kid.shrink > 0 and rects[k].w > cw) {
                rects[k].w = @max(cw, minWidth(rects, cmds, k, measurer));
            }
        }
    }

    /// Position pass: cmd `i` is the grid's next direct child. At a row's
    /// first cell, move to the row and take its height from the (up to)
    /// `n` children in it; then point `next` at the following child.
    fn beginGridCell(rects: []const Rect, cmds: anytype, g: *GridCursor, i: usize) void {
        if (g.count % g.n == 0) {
            if (g.count > 0) g.y += g.row_h + g.row_gap;
            g.row_h = 0;
            var it = i;
            var seen: usize = 0;
            while (seen < g.n) : (seen += 1) {
                const k = nextKid(rects, cmds, &it, g.end) orelse break;
                g.row_h = @max(g.row_h, rects[k].h);
            }
        }
        var it = i;
        _ = nextKid(rects, cmds, &it, g.end);
        g.next = nextKid(rects, cmds, &it, g.end) orelse no_cell;
    }

    /// Place cmd `i` in the grid's next cell (`align_x` / `align_y`).
    fn placeGridCell(rects: []Rect, g: *GridCursor, i: usize, spec: ChildSpec) void {
        const col = g.count % g.n;
        const cw = g.col_w[col];
        const r = &rects[i];
        const stretch_x = g.align_x == .stretch or (g.align_x == .start and spec.fills_cross);
        if (stretch_x and !spec.fixed_w) r.w = @max(cw, spec.min_w);
        if (g.align_y == .stretch and !spec.fixed_h and !spec.row_only) r.h = @max(g.row_h, spec.min_h);
        r.x = g.col_x[col] + alignOffset(g.align_x, cw - r.w);
        r.y = g.y + alignOffset(g.align_y, g.row_h - r.h);
        g.count += 1;
    }

    fn alignOffset(a: Align, slack: f32) f32 {
        return switch (a) {
            .start, .stretch => 0,
            .center => @max(0, slack) * 0.5,
            .end => @max(0, slack),
        };
    }

    fn advanceCursor(ctx: *CursorContext, delta: f32) void {
        switch (ctx.direction) {
            .horizontal => ctx.x += delta,
            .vertical => ctx.y += delta,
        }
    }

    fn gapTotal(child_count: u32, gap: f32) f32 {
        return if (child_count > 1) @as(f32, @floatFromInt(child_count - 1)) * gap else 0;
    }

    /// Turn a closed container's accumulators into its outer rect: content
    /// size plus padding, replaced by a fixed size, then floored by the minimum.
    fn finishContainer(grp: GroupContext) Rect {
        const horizontal = grp.direction == .horizontal;
        const main = grp.fixed_main + gapTotal(grp.child_count, grp.gap) +
            2 * (if (horizontal) grp.pad_x else grp.pad_y);
        const cross = grp.cross_axis_max + 2 * (if (horizontal) grp.pad_y else grp.pad_x);
        const w = if (horizontal) main else cross;
        const h = if (horizontal) cross else main;
        return .{
            .w = @max(if (grp.fixed_w > 0) grp.fixed_w else w, grp.min_w),
            .h = @max(if (grp.fixed_h > 0) grp.fixed_h else h, grp.min_h),
            .fixed_main = grp.fixed_main,
            .flex_total = grp.flex_total,
            .child_count = grp.child_count,
        };
    }


    fn assertPushable(len: usize, cap: usize, cmd_index: usize) void {
        if (len >= cap) std.debug.panic(
            "teak layout: push_* at cmd #{d} exceeds container nesting depth {d} " ++
                "(unbalanced or too-deeply-nested buffer; run cmd.validateBalance)",
            .{ cmd_index, cap },
        );
    }

    fn assertPoppable(len: usize, cmd_index: usize) void {
        if (len == 0) std.debug.panic(
            "teak layout: pop_* at cmd #{d} underflows the container stack " ++
                "(stray pop_* or crossed push/pop; run cmd.validateBalance)",
            .{cmd_index},
        );
    }

    /// Flex weight of a single-line control (text_input, slider): it only
    /// grows along a horizontal main axis. In a vertical parent its height
    /// stays fixed instead of ballooning into the leftover column space.
    fn rowFlex(stack: *FixedStack(GroupContext, MAX_DEPTH), flex: f32) f32 {
        return if (stack.len > 0 and stack.top().direction == .horizontal) flex else 0;
    }

    /// Fold a finished child into its parent's accumulators.
    fn addLeafToTop(stack: *FixedStack(GroupContext, MAX_DEPTH), child_w: f32, child_h: f32, child_flex: f32) void {
        if (stack.len == 0) return;
        const t = stack.top();
        const horizontal = t.direction == .horizontal;
        t.fixed_main += if (horizontal) child_w else child_h;
        t.cross_axis_max = @max(t.cross_axis_max, if (horizontal) child_h else child_w);
        t.flex_total += child_flex;
        t.child_count += 1;
    }
};


/// 10-px-per-byte, 20-px-line-height stub measurer — the same numbers
/// every existing assertion was written against. Shared with
/// `src/input/hit_test.zig`, `src/render/build.zig`, and example
/// tests via `text.monoMeasurer`.
const test_measurer = text.monoMeasurer();





















