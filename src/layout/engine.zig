const std = @import("std");
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const text_wrap = @import("../core/text_wrap.zig");
const Direction = cmd.Direction;
const Align = cmd.Align;
const Justify = cmd.Justify;
const TextMeasurer = text.TextMeasurer;

// ── Types ──────────────────────────────────────────────────────────

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    // Meaningful only for container entries (push_group / push_scroll /
    // push_overlay / push_virtual_list) after the measure pass. Carried
    // into the position pass so flex / justify distribution has the totals
    // without rescanning children.
    fixed_main: f32 = 0,
    flex_total: f32 = 0,
    child_count: u32 = 0,
    /// Index of the matching `pop_*` (containers only). Lets the width
    /// passes hop over a child's subtree, keeping them linear.
    end: u32 = 0,
};

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
    /// Virtual lists claim `total_count * item_extent` on the main axis
    /// regardless of how many children were emitted in the visible window.
    is_virtual: bool = false,
    total_count: f32 = 0,
    item_extent: f32 = 0,
    // Accumulators.
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
};

fn FixedStack(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        // push / pop / top check the capacity and non-empty bounds with an
        // unconditional `@panic` (every optimize mode): overflow, underflow
        // and read-empty are programmer errors — the passes call
        // `assertPushable` / `assertPoppable` first to name the cmd index.

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

// ── Layout Engine ──────────────────────────────────────────────────
//
// Two O(n) passes over a flat []Cmd (four when the frame has wrapped text or
// `shrink > 0` nodes: widths resolve top-down, heights re-measure bottom-up). Works for any Cmd(Msg) since we
// only read Msg-independent fields (styles, labels, content).
//
// Sizing model (details in docs/features/layout.md):
//   - measure: every node gets an intrinsic outer size; a group/scroll
//     `width`/`height` replaces it, `min_width`/`min_height` floor it.
//   - position: a container's final size is known before its children are
//     placed. Main axis: flex children split the leftover (on top of their
//     own size); with no flex children `justify` distributes it. Cross axis:
//     `align_cross` places each child, `.stretch` sizes it to the inner extent.

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
                        // Variable-height mode claims `total_extent` as one "item".
                        .total_count = if (vl.total_extent > 0) 1 else @floatFromInt(vl.total_count),
                        .item_extent = if (vl.total_extent > 0) vl.total_extent else vl.item_extent,
                    });
                },
                .pop_group, .pop_scroll => {
                    assertPoppable(stack.len, i);
                    const grp = stack.pop();
                    var r = finishContainer(grp);
                    if (grp.is_scroll and grp.flex > 0 and stack.len > 0) {
                        // Scroll content is allowed to overflow, so a flex
                        // scroll starts from zero on the parent's main axis
                        // (unless it fixed a size there) and takes only its
                        // share of the leftover.
                        switch (stack.top().direction) {
                            .horizontal => if (grp.fixed_w <= 0) {
                                r.w = 0;
                            },
                            .vertical => if (grp.fixed_h <= 0) {
                                r.h = 0;
                            },
                        }
                        // The same holds along the scroll's own axis whatever
                        // the parent's direction (a vertical scroll inside a
                        // horizontal row must not size the row to its content).
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
                    // Overlays do NOT contribute to their parent's
                    // measured size — they hop the layout.
                    var r = finishContainer(grp);
                    r.end = @intCast(i);
                    rects[grp.cmd_index] = r;
                },
                .pop_virtual_list => {
                    assertPoppable(stack.len, i);
                    const grp = stack.pop();
                    var r = finishContainer(grp);
                    // Main axis = the full logical list, whatever was emitted.
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
                    // Intrinsic size; flex/cross-stretch expand it in the position pass.
                    const w = ti.style.min_width;
                    const h = ti.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, rowFlex(&stack, ti.style.flex));
                },
                .text_area => |ta| {
                    // Canvas-like box: explicit size; flex grows the main axis,
                    // a stretching parent fills the cross axis in pass 2/position.
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
                    // Thickness goes on the parent's main-axis; cross stretches
                    // to the inner width/height in positionPass.
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
                    // Fixed-size leaf, same sizing convention as `canvas`.
                    const w = sc.style.width;
                    const h = sc.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, sc.style.flex);
                },
                .canvas => |cv| {
                    // Intrinsic w/h come from the style; flex grows the box
                    // along the parent's main axis, `.stretch` along the cross.
                    const w = cv.style.width;
                    const h = cv.style.height;
                    rects[i] = .{ .w = w, .h = h };
                    addLeafToTop(&stack, w, h, cv.style.flex);
                },
                .rich_text => |rt| {
                    // Measure each span with its own font; fall back to
                    // default_font for any byte not covered by a span.
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

    // ── Passes 2-3: wrapped text and flex shrink (docs/features/layout.md) ──
    //
    // Only run when pass 1 saw wrapped `text` or a `shrink > 0` container.
    // Pass 2 walks forward over containers and, for each, settles its direct
    // children's WIDTHS (flex growth, shrink down to min-content, cross-axis
    // stretch, wrapped-text width) -- exactly the width decisions the position
    // pass would make later, made early so heights can depend on them. Pass 3
    // re-measures HEIGHTS bottom-up (wrapped text height = its line count)
    // and refreshes the container accumulators the position pass reads.
    // After both, the position pass finds no width left to distribute.

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
            .checkbox, .radio, .rich_text => .{},
            .push_overlay, .pop_group, .pop_scroll, .pop_overlay, .pop_virtual_list => .{},
        };
    }

    /// Next direct child of the container whose subtree ends before `end`,
    /// skipping overlays (they hop layout) and hopping over child subtrees.
    fn nextKid(rects: []const Rect, cmds: anytype, it: *usize, end: usize) ?usize {
        while (it.* < end) {
            const c = it.*;
            switch (cmds[c]) {
                .push_overlay => it.* = rects[c].end + 1,
                .push_group, .push_scroll, .push_virtual_list => {
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
            .pop_group, .pop_scroll, .pop_overlay, .pop_virtual_list, .push_virtual_list, .text, .rich_text, .button, .text_input, .text_area, .checkbox, .radio, .slider, .divider, .image, .scene3d, .canvas => null,
        };
    }

    /// Pass 2: settle the widths of every container's direct children.
    pub fn resolveWidths(rects: []Rect, cmds: anytype, measurer: TextMeasurer) void {
        for (cmds, 0..) |c, i| {
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
                        // Wrapped text fills a stretching parent (and any
                        // aligned paragraph); otherwise it takes its natural
                        // width capped by the room it has.
                        rects[k].w = if (stretch) inner_w else @min(rects[k].w, inner_w);
                    } else if (stretch and !kid.fixed_w) {
                        rects[k].w = @max(inner_w, kid.min_w);
                    }
                }
            }
        }
        // `measurer` is used by min-content (shrink) only.
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
                    // A flex scroll's main-axis size was zeroed in pass 1; keep it.
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
                .button, .text_input, .text_area, .checkbox, .radio, .slider, .divider, .image, .scene3d, .canvas, .rich_text => foldChild(&stack, rects[i].w, rects[i].h),
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

        for (cmds, 0..) |c, i| {
            switch (c) {
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
                    // Children's cursor starts shifted by the scroll offsets:
                    // an overflowing child ends up outside the viewport, and
                    // the render/hit-test clip stacks discard it.
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
                    // Absolute placement; anchor fraction shifts by
                    // (-w * frac_x, -h * frac_y). Overlays do NOT advance
                    // the parent cursor.
                    rects[i].x = ov.x - rects[i].w * ov.anchor_x_frac;
                    rects[i].y = ov.y - rects[i].h * ov.anchor_y_frac;
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
                    // Bump the cursor so the first emitted child sits at
                    // row visible_start, not row 0.
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

    // ── Stack-balance diagnostics ──────────────────────────────────
    //
    // The FixedStack push/pop already `std.debug.assert` the depth
    // invariant, but a bare assert names no cmd — so an unbalanced or
    // too-deep buffer panics without pointing at the offending command.
    // These guards run at the pass call sites (where the cmd index `i`
    // is in scope) and panic with that index before the assert would
    // fire. They sit purely on the error path: for balanced, in-bounds
    // input the condition is never true, so layout behavior is
    // unchanged. For a diagnostic that reports *without* panicking (and
    // also catches crossed pairs), run `cmd.validateBalance` first.

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

// ── Tests ──────────────────────────────────────────────────────────

/// 10-px-per-byte, 20-px-line-height stub measurer — the same numbers
/// every existing assertion was written against. Shared with
/// `src/input/hit_test.zig`, `src/render/build.zig`, and example
/// tests via `text.monoMeasurer`.
const test_measurer = text.monoMeasurer();

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
    LayoutEngine.measurePass(rects[0..cb.cmds.items.len], cb.cmds.items, test_measurer);

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
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    // Root: 800 wide.
    try testing.expectEqual(@as(f32, 800), rects[0].w);
    // Left group (cmd 1): intrinsic 60.
    try testing.expectEqual(@as(f32, 60), rects[1].w);
    // Right group (cmd 4, the flex=1 push): intrinsic 60 + 680 remainder = 740.
    try testing.expectEqual(@as(f32, 740), rects[4].w);
}

test "divider stretches on cross-axis, takes thickness on main-axis" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Vertical group: divider is a horizontal line — h=thickness, w
    // stretches to the container's full inner width (300, since the root
    // group is stretched to the window).
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.text("top");
    cb.divider();
    cb.text("bot");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 300, 200, test_measurer);

    // rects[2] is the divider. Default thickness is 1.
    try testing.expectEqual(@as(f32, 1), rects[2].h);
    try testing.expectEqual(@as(f32, 300), rects[2].w);

    // Horizontal group: divider is a vertical pillar — w=thickness, h
    // stretches to the container's full inner height (200).
    var cb2 = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb2.deinit();

    cb2.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb2.text("left");
    cb2.dividerStyled(.{ .thickness = 3 });
    cb2.text("right");
    cb2.popGroup();

    var rects2: [8]Rect = undefined;
    LayoutEngine.doLayout(rects2[0..cb2.cmds.items.len], cb2.cmds.items, 300, 200, test_measurer);

    try testing.expectEqual(@as(f32, 3), rects2[2].w);
    try testing.expectEqual(@as(f32, 200), rects2[2].h);
}

test "horizontal flex respects padding and gap" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Root: 800 wide, padding=10 (20 consumed), gap=20 (×2 gaps = 40
    // consumed between 3 children). Inner = 780. Each child has
    // intrinsic 60 (3×60 = 180 fixed_main). Extra after gaps + intrinsic:
    // 780 - 40 - 180 = 560. Three flex=1 children split 560 evenly.
    // Each child ends up at 60 + 560/3 ≈ 246.67 wide.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 10, .gap = 20 });
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .flex = 1 });
    cb.button(.a, "Hi");
    cb.popGroup();
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .flex = 1 });
    cb.button(.a, "Hi");
    cb.popGroup();
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .flex = 1 });
    cb.button(.a, "Hi");
    cb.popGroup();
    cb.popGroup();

    var rects: [32]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    // Child push_group entries are cmds 1, 4, 7 (pop_group cmds sit
    // between them in the buffer).
    const expected_w: f32 = 60 + 560.0 / 3.0;
    try testing.expectApproxEqAbs(expected_w, rects[1].w, 0.01);
    try testing.expectApproxEqAbs(expected_w, rects[4].w, 0.01);
    try testing.expectApproxEqAbs(expected_w, rects[7].w, 0.01);

    // First child starts at x=padding=10.
    try testing.expectEqual(@as(f32, 10), rects[1].x);
    // Second starts at 10 + expected_w + gap(20).
    try testing.expectApproxEqAbs(10 + expected_w + 20, rects[4].x, 0.01);
    // Third starts at 10 + 2*(expected_w + gap).
    try testing.expectApproxEqAbs(10 + 2 * (expected_w + 20), rects[7].x, 0.01);
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
    LayoutEngine.measurePass(rects[0..cb.cmds.items.len], cb.cmds.items, test_measurer);
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
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 100, test_measurer);
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
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    // Scroll container is clamped to 200x100.
    try testing.expectEqual(@as(f32, 200), rects[0].w);
    try testing.expectEqual(@as(f32, 100), rects[0].h);
    // First child should be at y = 0 - scroll_y = -50.
    try testing.expectEqual(@as(f32, -50), rects[1].y);
    // Button height = 36, so second child at y = -50 + 36 = -14.
    try testing.expectEqual(@as(f32, -14), rects[2].y);
}

test "overlay positions absolutely and does NOT contribute to parent size" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Root vertical with a button + an overlay containing more content.
    // The overlay must not push the root height beyond just the button.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.a, "Anchor"); // 6 chars * 10 + 16 = 76 wide, 36 tall
    cb.pushOverlay(.{ .x = 200, .y = 50, .padding = 0, .gap = 0 });
    cb.button(.a, "OvBtn");
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    // Root height in this DSL is forced to window height (800x600) by doLayout
    // because it's the first push_group. But the OVERLAY rect must be at (200, 50),
    // and the button inside the overlay (cmd index 3) follows.
    try testing.expectEqual(@as(f32, 200), rects[2].x); // push_overlay
    try testing.expectEqual(@as(f32, 50), rects[2].y);
    // Overlay child sits at overlay's inner top-left.
    try testing.expectEqual(@as(f32, 200), rects[3].x);
    try testing.expectEqual(@as(f32, 50), rects[3].y);
}

test "overlay anchor_frac shifts overlay by -w*frac" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.pushOverlay(.{
        .x = 300,
        .y = 200,
        .width = 100,
        .height = 50,
        .padding = 0,
        .anchor_x_frac = 1.0, // right edge at x=300
        .anchor_y_frac = 1.0, // bottom edge at y=200
    });
    cb.text("x");
    cb.popOverlay();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    // Overlay's top-left = (300 - 100*1.0, 200 - 50*1.0) = (200, 150).
    try testing.expectEqual(@as(f32, 200), rects[1].x);
    try testing.expectEqual(@as(f32, 150), rects[1].y);
}

test "virtual list claims total_count * item_extent on main axis" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // 10,000 rows of 24px each, visible window 0..3.
    cb.pushVirtualList(.{
        .direction = .vertical,
        .total_count = 10_000,
        .item_extent = 24,
        .visible_start = 0,
        .visible_end = 3,
    });
    cb.text("row 0");
    cb.text("row 1");
    cb.text("row 2");
    cb.popVirtualList();

    var rects: [16]Rect = undefined;
    LayoutEngine.measurePass(rects[0..cb.cmds.items.len], cb.cmds.items, test_measurer);

    // The virtual-list container's height = 10000 * 24 = 240000 even
    // though only three rows were emitted.
    try testing.expectEqual(@as(f32, 240000), rects[0].h);
}

test "variable-height virtual list claims total_extent and starts at start_offset" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 0, .width = 400, .height = 200 });
    cb.pushVirtualList(.{ .total_extent = 5000, .start_offset = 1234, .visible_start = 40, .visible_end = 42 });
    cb.text("row 40");
    cb.text("row 41");
    cb.popVirtualList();
    cb.popScroll();
    var rects: [16]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);
    try testing.expectEqual(@as(f32, 5000), rects[1].h);
    try testing.expectEqual(@as(f32, 1234), rects[2].y);
    try testing.expect(rects[3].y >= rects[2].y + rects[2].h); // rows flow after each other
}

test "virtual list children sit at visible_start * item_extent offset" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Render rows 500..503 — first child should land at y=500*24=12000.
    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 0, .width = 400, .height = 200 });
    cb.pushVirtualList(.{
        .direction = .vertical,
        .total_count = 1000,
        .item_extent = 24,
        .visible_start = 500,
        .visible_end = 503,
    });
    cb.text("row 500");
    cb.text("row 501");
    cb.text("row 502");
    cb.popVirtualList();
    cb.popScroll();

    var rects: [16]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    // First text (index 2 — after push_scroll + push_virtual_list).
    try testing.expectEqual(@as(f32, 12000), rects[2].y);
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
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, test_measurer);

    // Parent inner width = 400 - 20 = 380.
    try testing.expectEqual(@as(f32, 380), rects[1].w);
}

test "canvas is a fixed-size leaf sized from its style" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 10, .gap = 0 });
    cb.text("Title"); // 5*10 = 50 wide, 20 tall
    cb.canvas(.{ .width = 300, .height = 120 }, &.{});
    cb.popGroup();

    var rects: [8]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    // Canvas keeps its declared box regardless of parent size.
    try testing.expectEqual(@as(f32, 300), rects[2].w);
    try testing.expectEqual(@as(f32, 120), rects[2].h);
    // Placed under the title (y = padding 10 + title height 20 = 30) at x=10.
    try testing.expectEqual(@as(f32, 10), rects[2].x);
    try testing.expectEqual(@as(f32, 30), rects[2].y);
}

test "ClipStack: round-trip up to capacity without tripping bounds" {
    const testing = std.testing;
    var clips: ClipStack = .{};

    // top() on empty returns the huge sentinel; this is documented
    // behavior, not a bug. We do NOT assert here — only push/pop do.
    const empty_top = clips.top();
    try testing.expect(empty_top.w > 1e8);

    // Push the full capacity and confirm the stack accepts every
    // one without a panic.
    var i: usize = 0;
    while (i < clips.buffer.len) : (i += 1) {
        clips.push(.{ .x = @floatFromInt(i), .y = 0, .w = 10, .h = 10 });
    }
    try testing.expectEqual(@as(usize, MAX_DEPTH), clips.len);
    try testing.expectEqual(@as(f32, MAX_DEPTH - 1), clips.top().x);

    // Pop them all; depth returns to zero, no underflow.
    i = 0;
    while (i < MAX_DEPTH) : (i += 1) clips.pop();
    try testing.expectEqual(@as(usize, 0), clips.len);
}

test "FixedStack (via MAX_DEPTH-deep group nesting): documented depth is reachable" {
    const testing = std.testing;
    const Msg = union(enum) { noop };
    const CmdBuffer = cmd.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Documented max for the measure-pass FixedStack is MAX_DEPTH. Push that
    // many groups, all of which must coexist on the stack simultaneously
    // during the measure pass — this is the boundary case.
    const DEPTH: usize = MAX_DEPTH;
    var i: usize = 0;
    while (i < DEPTH) : (i += 1) {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    }
    // Add a single leaf so the innermost group has measured content.
    cb.text("leaf");
    i = 0;
    while (i < DEPTH) : (i += 1) cb.popGroup();

    const rects = try testing.allocator.alloc(Rect, cb.cmds.items.len);
    defer testing.allocator.free(rects);
    // The stacks panic on overflow in every mode — this must not, because
    // MAX_DEPTH is the documented capacity.
    LayoutEngine.doLayout(rects, cb.cmds.items, 800, 600, test_measurer);
    try testing.expectEqual(@as(f32, 800), rects[0].w);
}

// Sizing-model tests (fixed sizes, align, justify, stretch, flex, golden
// snapshots) live in their own file to keep this one readable.
test {
    _ = @import("sizing_test.zig");
    _ = @import("wrap_test.zig");
}

test "scene3d is a fixed-size leaf sized from its style" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 10, .gap = 0 });
    cb.text("Title"); // 50 x 20
    cb.scene3d(.{ .style = .{ .width = 320, .height = 200 } });
    cb.popGroup();

    var rects: [8]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, test_measurer);

    try testing.expectEqual(@as(f32, 320), rects[2].w);
    try testing.expectEqual(@as(f32, 200), rects[2].h);
    try testing.expectEqual(@as(f32, 10), rects[2].x);
    try testing.expectEqual(@as(f32, 30), rects[2].y);
}
