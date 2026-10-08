//! Progress bar: determinate (a fraction) and indeterminate (a block
//! sliding across the track). Zero new Cmd variants: a non-interactive
//! `canvas` draws the border, track and fill.
//!
//! Determinate is a pure function of the value the app holds:
//! `progress.bar(cb, m.upload_fraction, .{})`. Indeterminate needs a phase
//! that advances over time; the component keeps it in the Model (HARDLINE
//! §1) and the app advances it from a `Sub.every(TICK_MS)` only while the
//! work is running:
//!
//! ```zig
//! pub fn subscribe(m: *const Model) []const Sub(Msg) {
//!     return if (m.busy) &.{.{ .every = .{ .interval_ms = progress.TICK_MS, .msg = .{ .spin = .tick } } }} else &.{};
//! }
//! ```

const std = @import("std");
const cmd = @import("../cmd.zig");
const component = @import("../component.zig");

/// Ticks for the indeterminate block to cross the track once.
pub const PERIOD: u16 = 50;
/// Suggested `Sub.every` interval for the indeterminate phase.
pub const TICK_MS: u32 = 30;

pub const Style = struct {
    width: f32 = 200,
    height: f32 = 10,
    /// Flex weight on the parent's main axis (a bar that fills a row).
    flex: f32 = 0,
    /// Null = derive from `cb.theme.palette` (sunken track, accent fill).
    track_color: ?[4]f32 = null,
    fill_color: ?[4]f32 = null,
    border_color: ?[4]f32 = null,
    /// Indeterminate block width as a fraction of the track.
    block: f32 = 0.3,
};

pub const Model = struct {
    /// Position of the indeterminate block, `0 .. PERIOD`.
    phase: u16 = 0,
};

pub const Msg = union(enum) {
    /// Advance the indeterminate block by one step.
    tick,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .tick => model.phase = (model.phase + 1) % PERIOD,
    }
}

/// Component-contract view: an indeterminate bar with the default style.
pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
    _ = msgs;
    indeterminate(cb, model.phase, .{});
}

/// Determinate bar, `value` clamped to 0..1.
pub fn bar(cb: anytype, value: f32, style: Style) void {
    const v = std.math.clamp(if (std.math.isNan(value)) 0 else value, 0, 1);
    const pct: u32 = @intFromFloat(@round(v * 100));
    emit(cb, style, 0, v * (style.width - 2), cb.arena.allocator().dupe(u8, pctLabel(cb, pct)) catch unreachable);
}

/// Indeterminate bar: the block's position follows `phase` (0 .. PERIOD).
pub fn indeterminate(cb: anytype, phase: u16, style: Style) void {
    const inner = style.width - 2;
    const bw = inner * style.block;
    const p = @as(f32, @floatFromInt(phase % PERIOD)) / @as(f32, @floatFromInt(PERIOD));
    const x = -bw + p * (inner + bw);
    const x0 = @max(0, x);
    const x1 = @min(inner, x + bw);
    emit(cb, style, x0, @max(0, x1 - x0), "busy");
}

fn pctLabel(cb: anytype, pct: u32) []const u8 {
    return std.fmt.allocPrint(cb.arena.allocator(), "{d}%", .{pct}) catch unreachable;
}

fn emit(cb: anytype, style: Style, fill_x: f32, fill_w: f32, label: []const u8) void {
    const pal = cb.theme.palette;
    const prims = cb.arena.allocator().alloc(cmd.CanvasPrimitive, 3) catch unreachable;
    prims[0] = .{ .filled_rect = .{ .x = 0, .y = 0, .w = style.width, .h = style.height, .color = style.border_color orelse pal.border } };
    prims[1] = .{ .filled_rect = .{ .x = 1, .y = 1, .w = style.width - 2, .h = style.height - 2, .color = style.track_color orelse pal.bg_sunken } };
    prims[2] = .{ .filled_rect = .{ .x = 1 + fill_x, .y = 1, .w = fill_w, .h = style.height - 2, .color = style.fill_color orelse pal.accent } };
    cb.canvasLabeled(.{ .width = style.width, .height = style.height, .flex = style.flex }, prims, label);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text = @import("../text.zig");

const TestMsg = union(enum) { x };

test "progress: satisfies the component contract" {
    component.validateComponent(@This());
}

test "progress: determinate fill is proportional and clamped; NaN reads as 0" {
    var cb = cmd.CmdBuffer(TestMsg).init(testing.allocator);
    defer cb.deinit();
    bar(&cb, 0.5, .{ .width = 102 });
    try testing.expectEqual(@as(f32, 50), cb.cmds.items[0].canvas.primitives[2].filled_rect.w);
    try testing.expectEqualStrings("50%", cb.cmds.items[0].canvas.label);
    bar(&cb, 7, .{ .width = 102 });
    try testing.expectEqual(@as(f32, 100), cb.cmds.items[1].canvas.primitives[2].filled_rect.w);
    bar(&cb, -1, .{ .width = 102 });
    try testing.expectEqual(@as(f32, 0), cb.cmds.items[2].canvas.primitives[2].filled_rect.w);
    bar(&cb, std.math.nan(f32), .{ .width = 102 });
    try testing.expectEqual(@as(f32, 0), cb.cmds.items[3].canvas.primitives[2].filled_rect.w);
}

test "progress: the indeterminate block enters, crosses and leaves the track" {
    var cb = cmd.CmdBuffer(TestMsg).init(testing.allocator);
    defer cb.deinit();
    const s: Style = .{ .width = 102, .block = 0.3 }; // inner 100, block 30
    indeterminate(&cb, 0, s); // fully off the left edge
    try testing.expectEqual(@as(f32, 0), cb.cmds.items[0].canvas.primitives[2].filled_rect.w);
    indeterminate(&cb, PERIOD / 2, s); // mid-track: whole block visible
    const mid = cb.cmds.items[1].canvas.primitives[2].filled_rect;
    try testing.expectEqual(@as(f32, 30), mid.w);
    try testing.expect(mid.x > 1 and mid.x + mid.w < 101);
    indeterminate(&cb, PERIOD - 1, s); // clipped at the right edge
    const end = cb.cmds.items[2].canvas.primitives[2].filled_rect;
    try testing.expect(end.w < 30 and end.x + end.w <= 101.0001);
}

test "progress: update wraps the phase" {
    var m: Model = .{ .phase = PERIOD - 1 };
    update(&m, .tick);
    try testing.expectEqual(@as(u16, 0), m.phase);
}

test "progress: snapshot golden" {
    var cb = cmd.CmdBuffer(TestMsg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 4 });
    bar(&cb, 0.25, .{ .width = 120 });
    indeterminate(&cb, 10, .{ .width = 120 });
    cb.popGroup();
    var rects: [8]engine.Rect = undefined;
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 200, 60, text.monoMeasurer());
    try snapshot.expectSnapshot(cb.cmds.items, rects[0..n], .{},
        \\group (0,0,200,60) vertical
        \\  canvas (0,0,120,10) prims=3 "25%"
        \\  canvas (0,14,120,10) prims=3 "busy"
        \\
    );
}
