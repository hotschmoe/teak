//! Numeric input component: TextField + float parsing + range validation.
//!
//! Closes a consumer DX gap: every form that needs a number used to
//! re-implement a TextField wrapper + `std.fmt.parseFloat` + an
//! out-of-range check + a danger-colored validation row. `NumericField`
//! ships that once as a composable component, so a numeric input is a
//! one-liner in the `Components(.{...})` map plus a `value()` accessor
//! in `update`.
//!
//! Composition model (mirrors `TextField`):
//!   - `NumericField(config)` returns a component (Model / Msg / update /
//!     view) — the standard `validateComponent` shape, so it composes via
//!     `Components(.{ .qty = NumericField(.{}), ... })` like any other
//!     component.
//!   - Msg vocabulary is REUSED verbatim from `TextField(config.capacity)`
//!     (focus / char / backspace / cursor_* / select_* / replace_selection).
//!     Because the variant names match, the existing host-side dispatch
//!     helpers in text_field.zig (`textFieldChar`, `textFieldSpecial`,
//!     `textFieldReplaceSelection`) drive a NumericField field UNCHANGED.
//!
//! Design choices (documented per the task spec):
//!   - Model wraps a `TextField(config.capacity).Model` in a single `tf`
//!     field. The text buffer / cursor / selection state lives entirely
//!     in the embedded TextField model — no duplicated edit logic.
//!   - `value()` / `isValid()` / `content()` / `formatValue()` are decls
//!     on the returned struct (struct scope), matching how TextField
//!     exposes `update`/`view`. They take `*const Model`.
//!   - Empty buffer counts as INVALID: a numeric field expects a number,
//!     so `value("") == null` and `isValid()` is false on an empty field.
//!     (No `allow_empty` knob — kept simple per spec.)
//!   - view: when the value is valid, emit just the text_input. When it is
//!     invalid AND `config.invalid_message` is non-empty, wrap the input
//!     in a vertical group and emit `cb.textDanger(...)` below it. An empty
//!     `invalid_message` suppresses the validation row entirely (the input
//!     is emitted bare in that case).
//!
//! HARDLINE: Msg is a tagged union of data (no fn pointers), update is a
//! pure switch (delegated to TextField.update), view is pure (no allocator
//! parameters beyond cb's arena, no wall-clock), all state in Model, no
//! platform imports.

const std = @import("std");
const teak_text_field = @import("text_field.zig");

// ── Config ──────────────────────────────────────────────────────────

pub const NumericConfig = struct {
    /// Max chars in the underlying text buffer.
    capacity: usize = 16,
    /// Inclusive lower bound; null = unbounded.
    min: ?f64 = null,
    /// Inclusive upper bound; null = unbounded.
    max: ?f64 = null,
    /// Decimal places shown by `formatValue`; parsing accepts any precision.
    precision: u8 = 2,
    /// Validation message shown below the field when the current text does
    /// not parse or is out of range. Empty = no validation row emitted.
    invalid_message: []const u8 = "invalid number",
};

// ── Component factory ───────────────────────────────────────────────
//
// `NumericField(config)` returns a struct exposing Model/Msg/update/view
// (so `validateComponent` passes and `Components()` composes it) plus the
// `value`/`isValid`/`content`/`formatValue` accessors.

pub fn NumericField(comptime config: NumericConfig) type {
    return struct {
        /// The wrapped text-field component, instantiated at the configured
        /// capacity. All character/cursor/selection editing lives here.
        pub const TF = teak_text_field.TextField(config.capacity);

        /// Reuse the TextField message vocabulary verbatim. Identical
        /// variant names mean the text_field.zig host dispatch helpers
        /// drive a NumericField field with no changes.
        pub const Msg = TF.Msg;

        /// Wraps the TextField model in a single `tf` field. Default-
        /// initializable (the TextField model is).
        pub const Model = struct {
            tf: TF.Model = .{},
        };

        /// Delegate every edit to TextField.update — NumericField adds no
        /// editing behavior of its own, only parsing + validation on read.
        pub fn update(model: *Model, msg: Msg) void {
            TF.update(&model.tf, msg);
        }

        /// Emit the text_input. When the current value is invalid and a
        /// non-empty `invalid_message` is configured, wrap the input in a
        /// vertical group and stack a danger-colored message below it.
        /// Otherwise emit the input bare (consistent shape either way:
        /// valid fields and message-suppressed fields both emit one cmd).
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            const show_error = !isValid(model) and config.invalid_message.len > 0;
            if (show_error) {
                cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 4 });
            }
            cb.textInputSelected(
                msgs.focus,
                model.tf.content(),
                model.tf.cursor,
                model.tf.selection_anchor,
                cb.theme.text_input,
            );
            if (show_error) {
                cb.textDanger(config.invalid_message);
                cb.popGroup();
            }
        }

        // ── Accessors ───────────────────────────────────────────────

        /// Parse the buffer with `std.fmt.parseFloat`. Returns null if it
        /// doesn't parse OR falls outside [min, max]. Empty buffer → null.
        pub fn value(model: *const Model) ?f64 {
            const text = model.tf.content();
            if (text.len == 0) return null;
            const parsed = std.fmt.parseFloat(f64, text) catch return null;
            if (config.min) |lo| {
                if (parsed < lo) return null;
            }
            if (config.max) |hi| {
                if (parsed > hi) return null;
            }
            return parsed;
        }

        /// True when the buffer holds a parseable, in-range number. An
        /// empty field counts as invalid (a numeric field expects a number).
        pub fn isValid(model: *const Model) bool {
            return value(model) != null;
        }

        /// Raw text slice of the buffer (no null terminator).
        pub fn content(model: *const Model) []const u8 {
            return model.tf.content();
        }

        /// Replace the whole text from code (call it from your `update`, e.g.
        /// when loading a record or applying a preset). The caret goes to the
        /// end; the text is NOT validated until read (`value` / `isValid`).
        pub fn setText(model: *Model, text: []const u8) void {
            model.tf.set(text);
        }

        /// Set the field to `v` formatted with `config.precision` decimals
        /// (trailing text beyond `capacity` is dropped, leaving it invalid).
        pub fn setValue(model: *Model, v: f64) void {
            var buf: [config.capacity]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, config.precision }) catch buf[0..0];
            model.tf.set(text);
        }

        /// Format the parsed value to `config.precision` decimals into the
        /// caller's buffer. Returns null if the field is invalid or the
        /// buffer is too small.
        pub fn formatValue(model: *const Model, buf: []u8) ?[]const u8 {
            const v = value(model) orelse return null;
            return std.fmt.bufPrint(buf, "{d:.[1]}", .{ v, config.precision }) catch return null;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd_mod = @import("cmd.zig");
const component_mod = @import("component.zig");














