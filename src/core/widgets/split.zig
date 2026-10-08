//! Split pane: two panes separated by a draggable divider, with minimum
//! sizes and a ratio that lives in the Model (so it survives frames, can be
//! saved with the app's state, and is trivially testable).
//!
//! Zero new Cmd variants: the divider is an interactive `canvas` (pointer
//! capture means a drag keeps working when the cursor leaves the thin
//! strip); the panes are fixed-size groups. The app's `canvasMsg` hook maps
//! the divider's pointer events to `Msg`s with `canvasMsg`:
//!
//! ```zig
//! pub fn canvasMsg(m: *const Model, ev: teak.CanvasEvent) ?Msg {
//!     if (Split.canvasMsg(&m.split, ev, split_opts)) |s| return .{ .split = s };
//!     return null;
//! }
//! // view:
//! Split.begin(&m.split, cb, split_opts);
//!     ... emit the left pane's content ...
//! Split.divider(&m.split, cb, split_opts);
//!     ... emit the right pane's content ...
//! Split.end(cb);
//! ```
//!
//! `opts.width` / `opts.height` are the OUTER size, which the app knows from
//! its `windowMsg` (the view cannot read layout).

const std = @import("std");
const cmd = @import("../cmd.zig");
const component = @import("../component.zig");
const pointer = @import("../pointer.zig");

pub const Orientation = enum {
    /// Panes side by side, a vertical divider between them.
    horizontal,
    /// Panes stacked, a horizontal divider between them.
    vertical,
};

pub const Opts = struct {
    orientation: Orientation = .horizontal,
    /// Outer size of the whole pane pair.
    width: f32,
    height: f32,
    /// Divider thickness in px.
    divider: f32 = 6,
    /// Minimum size of the first / second pane along the split axis.
    min_a: f32 = 80,
    min_b: f32 = 80,
    /// `CanvasCmd.id` of the divider (non-zero, unique among canvases).
    id: u32 = 0xD1,
    /// Padding / gap inside each pane's group.
    pane_padding: f32 = 8,
    pane_gap: f32 = 8,
};

pub const Model = struct {
    /// First pane's share of the space (excluding the divider), 0..1.
    ratio: f32 = 0.5,
    dragging: bool = false,
};

pub const Msg = union(enum) {
    /// Pointer went down on the divider.
    grab,
    /// Divider moved by `delta` px along the split axis; `avail` is the
    /// pane space (outer size minus the divider), `min_a` / `min_b` the limits.
    drag: Drag,
    release,
    /// Set the ratio directly (restoring a saved layout, or a "reset" button).
    set: f32,

    pub const Drag = struct { delta: f32, avail: f32, min_a: f32, min_b: f32 };
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .grab => model.dragging = true,
        .release => model.dragging = false,
        .set => |r| model.ratio = std.math.clamp(if (std.math.isNan(r)) 0.5 else r, 0, 1),
        .drag => |d| {
            if (d.avail <= 0) return;
            const a = (model.ratio * d.avail) + d.delta;
            model.ratio = std.math.clamp(clampSize(a, d.avail, d.min_a, d.min_b) / d.avail, 0, 1);
        },
    }
}

/// Clamp the first pane's size `a` into `[min_a, avail - min_b]`; when the
/// space cannot satisfy both minimums, split it in their proportion.
fn clampSize(a: f32, avail: f32, min_a: f32, min_b: f32) f32 {
    if (avail < min_a + min_b) {
        const t = min_a + min_b;
        return if (t <= 0) avail * 0.5 else avail * (min_a / t);
    }
    return std.math.clamp(a, min_a, avail - min_b);
}

fn space(o: Opts) f32 {
    const total = switch (o.orientation) {
        .horizontal => o.width,
        .vertical => o.height,
    };
    return @max(0, total - o.divider);
}

/// The first pane's size along the split axis, with the limits applied.
pub fn paneA(model: *const Model, o: Opts) f32 {
    const av = space(o);
    return @round(clampSize(model.ratio * av, av, o.min_a, o.min_b));
}

/// The second pane's size along the split axis.
pub fn paneB(model: *const Model, o: Opts) f32 {
    return space(o) - paneA(model, o);
}

/// Map a pointer event on the divider canvas to a `Msg`, or null for other canvases.
pub fn canvasMsg(model: *const Model, ev: pointer.CanvasEvent, o: Opts) ?Msg {
    if (ev.id != o.id) return null;
    return switch (ev.kind) {
        .down => if (ev.button == .left) .grab else null,
        .move => if (model.dragging) .{ .drag = .{
            .delta = switch (o.orientation) {
                .horizontal => ev.dx,
                .vertical => ev.dy,
            },
            .avail = space(o),
            .min_a = o.min_a,
            .min_b = o.min_b,
        } } else null,
        .up => if (ev.button == .left) .release else null,
        .leave, .wheel, .layout => null,
    };
}

/// Component-contract view: nothing (the panes need content; use `begin`/`divider`/`end`).
pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
    _ = model;
    _ = cb;
    _ = msgs;
}

/// Open the pair and the first pane. Emit the first pane's content next.
pub fn begin(model: *const Model, cb: anytype, o: Opts) void {
    const horiz = o.orientation == .horizontal;
    cb.pushGroup(.{
        .direction = if (horiz) .horizontal else .vertical,
        .padding = 0,
        .gap = 0,
        .width = o.width,
        .height = o.height,
        .align_cross = .stretch,
    });
    cb.pushGroup(.{
        .direction = .vertical,
        .padding = o.pane_padding,
        .gap = o.pane_gap,
        .width = if (horiz) paneA(model, o) else o.width,
        .height = if (horiz) o.height else paneA(model, o),
        .bg = cb.theme.palette.bg,
    });
}

/// Close the first pane, draw the divider, open the second pane.
pub fn divider(model: *const Model, cb: anytype, o: Opts) void {
    const pal = cb.theme.palette;
    const horiz = o.orientation == .horizontal;
    cb.popGroup();

    const w: f32 = if (horiz) o.divider else o.width;
    const h: f32 = if (horiz) o.height else o.divider;
    const col = if (model.dragging) pal.accent else pal.border;
    const prims = cb.arena.allocator().alloc(cmd.CanvasPrimitive, 2) catch unreachable;
    prims[0] = .{ .filled_rect = .{ .x = 0, .y = 0, .w = w, .h = h, .color = col } };
    // A short grip in the middle so the handle is discoverable.
    const grip = pal.fg_muted;
    prims[1] = if (horiz)
        .{ .filled_rect = .{ .x = w / 2 - 0.5, .y = h / 2 - 12, .w = 1, .h = 24, .color = grip } }
    else
        .{ .filled_rect = .{ .x = w / 2 - 12, .y = h / 2 - 0.5, .w = 24, .h = 1, .color = grip } };
    cb.canvasInteractive(.{ .width = w, .height = h }, prims, o.id, "divider");

    cb.pushGroup(.{
        .direction = .vertical,
        .padding = o.pane_padding,
        .gap = o.pane_gap,
        .width = if (horiz) paneB(model, o) else o.width,
        .height = if (horiz) o.height else paneB(model, o),
        .bg = cb.theme.palette.bg,
    });
}

/// Close the second pane and the pair.
pub fn end(cb: anytype) void {
    cb.popGroup();
    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text = @import("../text.zig");

const opts: Opts = .{ .width = 506, .height = 200, .divider = 6, .min_a = 100, .min_b = 150 };

test "split: satisfies the component contract" {
    component.validateComponent(@This());
}

test "split: pane sizes follow the ratio, respect the minimums, and sum to the space" {
    var m: Model = .{ .ratio = 0.5 };
    try testing.expectEqual(@as(f32, 250), paneA(&m, opts));
    try testing.expectEqual(@as(f32, 250), paneB(&m, opts));
    m.ratio = 0.05; // below min_a
    try testing.expectEqual(@as(f32, 100), paneA(&m, opts));
    m.ratio = 0.99; // leaves less than min_b
    try testing.expectEqual(@as(f32, 350), paneA(&m, opts)); // 500 - 150
    try testing.expectEqual(@as(f32, 150), paneB(&m, opts));
    // Not enough room for both minimums: proportional split.
    const tiny: Opts = .{ .width = 106, .height = 50, .min_a = 100, .min_b = 100 };
    try testing.expectEqual(@as(f32, 50), paneA(&m, tiny));
}

test "split: dragging moves the ratio by delta/avail and clamps at the minimums" {
    var m: Model = .{ .ratio = 0.5 };
    const ev = pointer.CanvasEvent{ .id = opts.id, .kind = .down, .button = .left };
    update(&m, canvasMsg(&m, ev, opts).?);
    try testing.expect(m.dragging);

    var mv = pointer.CanvasEvent{ .id = opts.id, .kind = .move, .dx = 50, .dy = 9 };
    update(&m, canvasMsg(&m, mv, opts).?);
    try testing.expectApproxEqAbs(@as(f32, 0.6), m.ratio, 1e-4);
    mv.dx = -1000; // far past min_a
    update(&m, canvasMsg(&m, mv, opts).?);
    try testing.expectApproxEqAbs(@as(f32, 0.2), m.ratio, 1e-4); // min_a 100 / 500
    mv.dx = 5000;
    update(&m, canvasMsg(&m, mv, opts).?);
    try testing.expectApproxEqAbs(@as(f32, 0.7), m.ratio, 1e-4); // (500-150)/500

    update(&m, canvasMsg(&m, .{ .id = opts.id, .kind = .up, .button = .left }, opts).?);
    try testing.expect(!m.dragging);
    // Hover moves without a grab do nothing; other canvases are ignored.
    try testing.expect(canvasMsg(&m, .{ .id = opts.id, .kind = .move, .dx = 3 }, opts) == null);
    try testing.expect(canvasMsg(&m, .{ .id = 999, .kind = .down, .button = .left }, opts) == null);
}

test "split: a vertical split drags along y" {
    var m: Model = .{ .dragging = true };
    const o: Opts = .{ .orientation = .vertical, .width = 300, .height = 306, .min_a = 50, .min_b = 50 };
    update(&m, canvasMsg(&m, .{ .id = o.id, .kind = .move, .dx = 99, .dy = 30 }, o).?);
    try testing.expectApproxEqAbs(@as(f32, 0.6), m.ratio, 1e-4); // (150 + 30) / 300
}

test "split: set clamps and survives NaN" {
    var m: Model = .{};
    update(&m, .{ .set = 3 });
    try testing.expectEqual(@as(f32, 1), m.ratio);
    update(&m, .{ .set = std.math.nan(f32) });
    try testing.expectEqual(@as(f32, 0.5), m.ratio);
}

const TestMsg = union(enum) { x };

test "split: snapshot golden" {
    const m: Model = .{ .ratio = 0.4 };
    var cb = cmd.CmdBuffer(TestMsg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    begin(&m, &cb, opts);
    cb.text("left");
    divider(&m, &cb, opts);
    cb.text("right");
    end(&cb);
    cb.popGroup();
    var rects: [16]engine.Rect = undefined;
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 600, 300, text.monoMeasurer());
    try snapshot.expectSnapshot(cb.cmds.items, rects[0..n], .{},
        \\group (0,0,600,300) vertical
        \\  group (0,0,506,200) horizontal
        \\    group (0,0,200,200) vertical bg
        \\      text (8,8,40,20) "left"
        \\    canvas (200,0,6,200) prims=2 id=209 pointer "divider"
        \\    group (206,0,300,200) vertical bg
        \\      text (214,8,50,20) "right"
        \\
    );
}
