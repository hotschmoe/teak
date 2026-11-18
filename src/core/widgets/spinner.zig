//! Number spinner: a `NumericField` with step buttons, plus arrow-key and
//! wheel stepping. Zero new Cmd variants: a `button`, a `text_input`, a
//! `button` in a row.
//!
//! Typing edits the text exactly like a NumericField (the `Msg` *is*
//! `NumericField.Msg`, so `textFieldChar` / `textFieldSpecial` drive it);
//! stepping is a plain function the app calls from its own `update` arm:
//!
//! ```zig
//! const Qty = teak.widgets.spinner.Spinner(.{ .min = 0, .max = 99, .step = 1, .big_step = 10 });
//! // Msg:  qty: Qty.Msg,  qty_step: Qty.Step
//! // update: .qty => |e| Qty.update(&m.qty, e),  .qty_step => |s| Qty.step(&m.qty, s),
//! // view:   Qty.viewWith(&m.qty, cb, .{ .focus = focusQty, .up = .{ .qty_step = .up }, .down = .{ .qty_step = .down } });
//! // keys:   if (Qty.keyStep(key)) |s| return .{ .qty_step = s } else textFieldSpecial(Msg, "qty", key)
//! // wheel:  Qty.wheelStep(dy)
//! ```
//!
//! Stepping starts from the current value (or the minimum when the text is
//! empty / invalid), rounds to the field's precision, clamps to
//! [min, max] and rewrites the text, so the field always shows a valid number
//! afterwards.

const std = @import("std");
const cmd = @import("../cmd.zig");
const numeric_field = @import("../numeric_field.zig");
const keys = @import("../../input/keys.zig");

pub const Config = struct {
    capacity: usize = 12,
    min: f64 = 0,
    max: f64 = 100,
    step: f64 = 1,
    /// Page Up / Page Down / Shift+wheel step.
    big_step: f64 = 10,
    precision: u8 = 0,
    invalid_message: []const u8 = "",
};

pub const StepKind = enum { up, down, page_up, page_down };

pub fn Spinner(comptime cfg: Config) type {
    return struct {
        pub const NF = numeric_field.NumericField(.{
            .capacity = cfg.capacity,
            .min = cfg.min,
            .max = cfg.max,
            .precision = cfg.precision,
            .invalid_message = cfg.invalid_message,
        });
        pub const Model = NF.Model;
        pub const Msg = NF.Msg;
        pub const Step = StepKind;

        pub const update = NF.update;
        pub const value = NF.value;
        pub const isValid = NF.isValid;
        pub const content = NF.content;

        /// Set the field to `v` (clamped, formatted to `cfg.precision`).
        pub fn setValue(model: *Model, v: f64) void {
            const c = std.math.clamp(v, cfg.min, cfg.max);
            var buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ c, cfg.precision }) catch return;
            model.tf.set(s);
        }

        /// Move the value one step (the app's `update` arm for its step Msg).
        pub fn step(model: *Model, s: StepKind) void {
            const cur = value(model) orelse cfg.min;
            const delta: f64 = switch (s) {
                .up => cfg.step,
                .down => -cfg.step,
                .page_up => cfg.big_step,
                .page_down => -cfg.big_step,
            };
            // Round to the field's precision so 0.1 + 0.2 style drift never shows.
            const scale = std.math.pow(f64, 10, @floatFromInt(cfg.precision));
            setValue(model, @round((cur + delta) * scale) / scale);
        }

        /// The step for a key press (Up / Down / Page Up / Page Down), else null.
        pub fn keyStep(key: keys.SpecialKey) ?StepKind {
            return switch (key) {
                .up => .up,
                .down => .down,
                .page_up => .page_up,
                .page_down => .page_down,
                else => null,
            };
        }

        /// The step for a wheel delta (DOM-signed: negative dy = up), or null.
        pub fn wheelStep(dy: f32, shift: bool) ?StepKind {
            if (dy == 0) return null;
            if (dy < 0) return if (shift) .page_up else .up;
            return if (shift) .page_down else .down;
        }

        /// Component-contract view: just the field (no step buttons); use `viewWith`.
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            NF.view(model, cb, msgs);
        }

        /// `[-] [field] [+]`. `msgs` carries `.focus`, `.up` and `.down` AppMsgs.
        pub fn viewWith(model: *const Model, cb: anytype, msgs: anytype) void {
            var st = cb.theme.button;
            st.min_width = 28;
            st.h_padding = 4;
            st.label_align = .center;
            st.height = cb.theme.text_input.height;
            const at_min = if (value(model)) |v| v <= cfg.min else false;
            const at_max = if (value(model)) |v| v >= cfg.max else false;
            cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 2, .align_cross = .center });
            if (at_min) cb.buttonStyledDisabled(msgs.down, "-", st) else cb.buttonStyled(msgs.down, "-", st);
            cb.textInputSelected(msgs.focus, model.tf.content(), model.tf.cursor, model.tf.selection_anchor, cb.theme.text_input);
            if (at_max) cb.buttonStyledDisabled(msgs.up, "+", st) else cb.buttonStyled(msgs.up, "+", st);
            cb.popGroup();
        }
    };
}

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text_mod = @import("../text.zig");

const S = Spinner(.{ .min = 0, .max = 20, .step = 1, .big_step = 5 });
const F = Spinner(.{ .min = 0, .max = 1, .step = 0.1, .big_step = 0.5, .precision = 1 });

fn typeStr(m: *S.Model, s: []const u8) void {
    for (s) |c| S.update(m, .{ .char = c });
}
