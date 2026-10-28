//! Drag value: a number you change by dragging horizontally across it (the
//! egui `DragValue` / ImGui `DragFloat` idiom), with arrow keys and the wheel
//! as alternatives. Zero new Cmd variants: one focusable interactive `canvas`
//! draws the box and the formatted value; pointer input arrives through the
//! App's `pointerMsg` as plain `CanvasEvent` data and `eventMsg` turns it
//! into this widget's Msg.
//!
//! ```zig
//! const Load = teak.widgets.drag_value.DragValue(.{ .min = 0, .max = 500, .speed = 0.5, .precision = 1 });
//! // Model:  load: Load.Model = .{ .value = 25 },   Msg: load: Load.Msg, focus_load
//! // update: .load => |e| Load.update(&m.load, e)
//! // view:   Load.view(&m.load, cb, .{ .id = LOAD_ID, .focus = .focus_load, .label = "kN" })
//! // hooks:  pointerMsg: if (ev.asCanvas()) |c| if (c.id == LOAD_ID) if (Load.eventMsg(c)) |e| return .{ .load = e };
//! ```
//!
//! Dragging moves the value by `speed` per pixel (Shift: x0.1, Ctrl: x10);
//! the result is rounded to `precision` decimals and clamped. Left / Right
//! (or Down / Up) step by `step`, Page Up / Page Down by ten steps, Home /
//! End jump to the limits. All state is the Model's: the value and the
//! unrounded drag accumulator.

const std = @import("std");
const cmd = @import("../cmd.zig");
const pointer = @import("../pointer.zig");
const keys = @import("../../input/keys.zig");
const oom = @import("../oom.zig").oom;

pub const Config = struct {
    min: f64 = -std.math.inf(f64),
    max: f64 = std.math.inf(f64),
    /// Value change per dragged pixel.
    speed: f64 = 1,
    /// Arrow-key step (Page keys: ten of these).
    step: f64 = 1,
    /// Decimals shown and kept.
    precision: u8 = 0,
};

pub const ViewOpts = struct {
    /// Distinct non-zero canvas id (names the target in `CanvasEvent.id`).
    id: u32,
    /// Suffix drawn after the number (a unit).
    label: []const u8 = "",
    width: f32 = 96,
    height: f32 = 26,
};

pub fn DragValue(comptime cfg: Config) type {
    return struct {
        pub const Model = struct {
            value: f64 = if (std.math.isInf(cfg.min)) 0 else cfg.min,
            /// The unrounded value while dragging, so slow drags at a coarse
            /// precision still accumulate.
            raw: ?f64 = null,
            /// Drag in progress (the canvas captured the pointer).
            dragging: bool = false,
        };

        pub const Msg = union(enum) {
            /// Button down on the box: start a drag.
            begin,
            /// Pointer moved while dragging: `dx` px, already scaled by the
            /// Shift / Ctrl modifiers.
            drag: f64,
            /// Button released.
            end,
            step: enum { up, down, page_up, page_down, home, end },
            /// Set the value directly (clamped and rounded).
            set: f64,
        };

        fn round(v: f64) f64 {
            const scale = std.math.pow(f64, 10, @floatFromInt(cfg.precision));
            return std.math.clamp(@round(v * scale) / scale, cfg.min, cfg.max);
        }

        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .begin => {
                    m.dragging = true;
                    m.raw = m.value;
                },
                .drag => |dx| if (m.dragging) {
                    const r = std.math.clamp((m.raw orelse m.value) + dx * cfg.speed, cfg.min, cfg.max);
                    m.raw = r;
                    m.value = round(r);
                },
                .end => {
                    m.dragging = false;
                    m.raw = null;
                },
                .step => |s| {
                    const v: f64 = switch (s) {
                        .up => m.value + cfg.step,
                        .down => m.value - cfg.step,
                        .page_up => m.value + 10 * cfg.step,
                        .page_down => m.value - 10 * cfg.step,
                        .home => if (std.math.isInf(cfg.min)) m.value else cfg.min,
                        .end => if (std.math.isInf(cfg.max)) m.value else cfg.max,
                    };
                    m.value = round(v);
                },
                .set => |v| m.value = round(v),
            }
        }

        /// Map one canvas event (already filtered to this widget's id) to a Msg.
        pub fn eventMsg(ev: pointer.CanvasEvent) ?Msg {
            return switch (ev.kind) {
                .down => if (ev.button == .left) .begin else null,
                .up => if (ev.button == .left) .end else null,
                .move => if (ev.buttons.left and ev.dx != 0) .{ .drag = @as(f64, ev.dx) * modScale(ev.mods) } else null,
                .wheel => if (ev.dy < 0) .{ .step = .up } else if (ev.dy > 0) .{ .step = .down } else null,
                .key => if (ev.key) |k| keyMsg(k) else null,
                .layout, .leave => null,
            };
        }

        fn modScale(mods: pointer.Modifiers) f64 {
            if (mods.shift) return 0.1;
            if (mods.ctrl) return 10;
            return 1;
        }

        /// Keyboard stepping while the box has focus.
        pub fn keyMsg(k: keys.SpecialKey) ?Msg {
            return switch (k) {
                .right, .up => .{ .step = .up },
                .left, .down => .{ .step = .down },
                .page_up => .{ .step = .page_up },
                .page_down => .{ .step = .page_down },
                .home => .{ .step = .home },
                .end => .{ .step = .end },
                else => null,
            };
        }

        /// The box: a focusable interactive canvas with the value centred.
        /// `msgs.focus` is the AppMsg a click sends (keyboard focus).
        pub fn view(m: *const Model, cb: anytype, msgs: anytype, opts: ViewOpts) void {
            const a = cb.arena.allocator();
            const pal = cb.theme.palette;
            const text = if (opts.label.len > 0)
                std.fmt.allocPrint(a, "{[0]d:.[1]} {[2]s}", .{ m.value, cfg.precision, opts.label }) catch oom()
            else
                std.fmt.allocPrint(a, "{d:.[1]}", .{ m.value, cfg.precision }) catch oom();
            const font = cb.theme.typography.body;
            const prims = a.alloc(cmd.CanvasPrimitive, 3) catch oom();
            prims[0] = .{ .filled_rect = .{ .x = 0, .y = 0, .w = opts.width, .h = opts.height, .color = if (m.dragging) pal.accent else pal.border } };
            prims[1] = .{ .filled_rect = .{ .x = 1, .y = 1, .w = opts.width - 2, .h = opts.height - 2, .color = pal.bg_sunken } };
            // Left-padded; canvas text has no measurer at view time.
            prims[2] = .{ .text = .{ .x = 8, .y = @max(0, (opts.height - font.size_px * 1.2) / 2), .content = text, .font = font, .color = pal.fg } };
            // A focusable pointer canvas (as `canvasInteractiveFocusable`) with
            // the horizontal-resize cursor.
            cb.cmds.append(cb.backing, cb.box(.canvas, .{
                .style = .{ .width = opts.width, .height = opts.height },
                .primitives = prims,
                .label = text,
                .pointer = true,
                .id = opts.id,
                .msg = msgs.focus,
                .cursor = .resize_ew,
            })) catch oom();
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const DV = DragValue(.{ .min = 0, .max = 10, .speed = 0.25, .step = 1, .precision = 1 });

test "drag accumulates per pixel, rounds, clamps; modifiers scale" {
    var m: DV.Model = .{ .value = 5 };
    DV.update(&m, DV.eventMsg(.{ .id = 1, .kind = .down, .button = .left, .buttons = .{ .left = true } }).?);
    try testing.expect(m.dragging);
    // 1 px at 0.25/px with precision 1 -> 5.3 after rounding 5.25 ... raw keeps 5.25.
    DV.update(&m, DV.eventMsg(.{ .id = 1, .kind = .move, .dx = 1, .buttons = .{ .left = true } }).?);
    try testing.expectApproxEqAbs(@as(f64, 5.3), m.value, 1e-9);
    DV.update(&m, DV.eventMsg(.{ .id = 1, .kind = .move, .dx = 1, .buttons = .{ .left = true } }).?);
    try testing.expectApproxEqAbs(@as(f64, 5.5), m.value, 1e-9); // raw 5.5, no drift
    // Shift: a tenth of the speed.
    DV.update(&m, DV.eventMsg(.{ .id = 1, .kind = .move, .dx = 4, .buttons = .{ .left = true }, .mods = .{ .shift = true } }).?);
    try testing.expectApproxEqAbs(@as(f64, 5.6), m.value, 1e-9);
    // Far past the max clamps.
    DV.update(&m, DV.eventMsg(.{ .id = 1, .kind = .move, .dx = 1000, .buttons = .{ .left = true } }).?);
    try testing.expectEqual(@as(f64, 10), m.value);
    DV.update(&m, DV.eventMsg(.{ .id = 1, .kind = .up, .button = .left }).?);
    try testing.expect(!m.dragging and m.raw == null);
    // A move without the button does nothing.
    try testing.expect(DV.eventMsg(.{ .id = 1, .kind = .move, .dx = 3 }) == null);
}

test "keys, wheel and set step and clamp" {
    var m: DV.Model = .{ .value = 2 };
    DV.update(&m, DV.keyMsg(.right).?);
    try testing.expectEqual(@as(f64, 3), m.value);
    DV.update(&m, DV.keyMsg(.page_down).?);
    try testing.expectEqual(@as(f64, 0), m.value);
    DV.update(&m, DV.keyMsg(.end).?);
    try testing.expectEqual(@as(f64, 10), m.value);
    DV.update(&m, DV.eventMsg(.{ .id = 1, .kind = .wheel, .dy = 48 }).?);
    try testing.expectEqual(@as(f64, 9), m.value);
    DV.update(&m, .{ .set = 3.14159 });
    try testing.expectApproxEqAbs(@as(f64, 3.1), m.value, 1e-9);
    try testing.expect(DV.keyMsg(.enter) == null);
}

test "view: one focusable pointer canvas with the formatted value and an ew cursor" {
    const Msg = union(enum) { focus_load };
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    const m: DV.Model = .{ .value = 2.5 };
    DV.view(&m, &cb, .{ .focus = Msg.focus_load }, .{ .id = 7, .label = "kN" });
    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    const cv = cb.cmds.items[0].canvas;
    try testing.expect(cv.pointer);
    try testing.expectEqual(@as(u32, 7), cv.id);
    try testing.expectEqualStrings("2.5 kN", cv.label);
    try testing.expectEqual(@as(?@import("../cursor.zig").CursorShape, .resize_ew), cv.cursor);
}
