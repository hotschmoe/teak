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
const oom = @import("../oom.zig").oom;
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
    /// Keyboard step of the arrow keys on a focused divider, px.
    key_step: f32 = 16,
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
    /// The divider got keyboard focus or a Space / Enter (a no-op for `update`;
    /// it is the focusable divider's identity, see `dividerFocusable`).
    focus,
    /// Set the ratio directly (restoring a saved layout, or a "reset" button).
    set: f32,

    pub const Drag = struct { delta: f32, avail: f32, min_a: f32, min_b: f32 };
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .grab => model.dragging = true,
        .release => model.dragging = false,
        .focus => {},
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
        .key => blk: {
            const k = ev.key orelse break :blk null;
            const horiz = o.orientation == .horizontal;
            const delta: f32 = switch (k) {
                .left => if (horiz) -o.key_step else return null,
                .right => if (horiz) o.key_step else return null,
                .up => if (!horiz) -o.key_step else return null,
                .down => if (!horiz) o.key_step else return null,
                .home => -1.0e7,
                .end => 1.0e7,
                else => return null,
            };
            break :blk .{ .drag = .{ .delta = delta, .avail = space(o), .min_a = o.min_a, .min_b = o.min_b } };
        },
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
    dividerImpl(model, cb, o, false, {});
}

/// `divider` that is also a keyboard stop: Tab reaches it (focus ring), arrows
/// resize, Home / End collapse (through the app's `canvasMsg`, which already
/// maps pointer events with `Split.canvasMsg`). `focus_msg` is any Msg the app
/// routes to `Split.update(.., .focus)` (clicks and Space / Enter dispatch it).
pub fn dividerFocusable(model: *const Model, cb: anytype, o: Opts, focus_msg: anytype) void {
    dividerImpl(model, cb, o, true, focus_msg);
}

fn dividerImpl(model: *const Model, cb: anytype, o: Opts, comptime focusable: bool, focus_msg: anytype) void {
    const pal = cb.theme.palette;
    const horiz = o.orientation == .horizontal;
    cb.popGroup();

    const w: f32 = if (horiz) o.divider else o.width;
    const h: f32 = if (horiz) o.height else o.divider;
    const col = if (model.dragging) pal.accent else pal.border;
    const prims = cb.arena.allocator().alloc(cmd.CanvasPrimitive, 2) catch oom();
    prims[0] = .{ .filled_rect = .{ .x = 0, .y = 0, .w = w, .h = h, .color = col } };
    const grip = pal.fg_muted;
    prims[1] = if (horiz)
        .{ .filled_rect = .{ .x = w / 2 - 0.5, .y = h / 2 - 12, .w = 1, .h = 24, .color = grip } }
    else
        .{ .filled_rect = .{ .x = w / 2 - 12, .y = h / 2 - 0.5, .w = 24, .h = 1, .color = grip } };
    if (focusable) {
        cb.canvasInteractiveFocusable(.{ .width = w, .height = h }, prims, o.id, "divider", focus_msg);
    } else {
        cb.canvasInteractive(.{ .width = w, .height = h }, prims, o.id, "divider");
    }

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

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text = @import("../text.zig");

const opts: Opts = .{ .width = 506, .height = 200, .divider = 6, .min_a = 100, .min_b = 150 };

const TestMsg = union(enum) { x };
