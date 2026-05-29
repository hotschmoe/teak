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

test "NumericField(.{}) passes validateComponent" {
    component_mod.validateComponent(NumericField(.{}));
}

test "NumericField: typing digits yields the parsed value" {
    const NF = NumericField(.{});
    var m: NF.Model = .{};
    NF.update(&m, .{ .char = '4' });
    NF.update(&m, .{ .char = '2' });
    try std.testing.expectEqual(@as(?f64, 42.0), NF.value(&m));
    try std.testing.expect(NF.isValid(&m));
}

test "NumericField: parses a decimal" {
    const NF = NumericField(.{});
    var m: NF.Model = .{};
    for ("3.14") |c| NF.update(&m, .{ .char = c });
    try std.testing.expectEqual(@as(?f64, 3.14), NF.value(&m));
}

test "NumericField: out-of-range value reads as null / invalid" {
    const NF = NumericField(.{ .min = 0, .max = 10 });
    var m: NF.Model = .{};
    for ("20") |c| NF.update(&m, .{ .char = c });
    try std.testing.expectEqual(@as(?f64, null), NF.value(&m));
    try std.testing.expect(!NF.isValid(&m));

    // In-range still parses.
    var m2: NF.Model = .{};
    for ("7") |c| NF.update(&m2, .{ .char = c });
    try std.testing.expectEqual(@as(?f64, 7.0), NF.value(&m2));
    try std.testing.expect(NF.isValid(&m2));
}

test "NumericField: non-numeric text reads as null" {
    const NF = NumericField(.{});
    var m: NF.Model = .{};
    for ("abc") |c| NF.update(&m, .{ .char = c });
    try std.testing.expectEqual(@as(?f64, null), NF.value(&m));
    try std.testing.expect(!NF.isValid(&m));
}

test "NumericField: empty buffer reads as null / invalid" {
    const NF = NumericField(.{});
    const m: NF.Model = .{};
    try std.testing.expectEqual(@as(?f64, null), NF.value(&m));
    try std.testing.expect(!NF.isValid(&m));
}

test "NumericField: content returns the raw text" {
    const NF = NumericField(.{});
    var m: NF.Model = .{};
    for ("1.5") |c| NF.update(&m, .{ .char = c });
    try std.testing.expectEqualStrings("1.5", NF.content(&m));
}

test "NumericField: formatValue rounds to config precision" {
    const NF = NumericField(.{ .precision = 2 });
    var m: NF.Model = .{};
    for ("3.14159") |c| NF.update(&m, .{ .char = c });
    var buf: [32]u8 = undefined;
    const out = NF.formatValue(&m, &buf).?;
    try std.testing.expectEqualStrings("3.14", out);

    // Invalid field → null.
    var bad: NF.Model = .{};
    for ("nope") |c| NF.update(&bad, .{ .char = c });
    try std.testing.expectEqual(@as(?[]const u8, null), NF.formatValue(&bad, &buf));
}

test "NumericField composes via Components and routes char msgs" {
    const App = component_mod.Components(.{ .qty = NumericField(.{}) }, null);

    var m: App.Model = .{};
    App.update(&m, .{ .qty = .{ .char = '5' } });
    try std.testing.expectEqualStrings("5", m.qty.tf.content());
    try std.testing.expectEqual(@as(?f64, 5.0), NumericField(.{}).value(&m.qty));
}

test "NumericField: textFieldChar host helper builds the right composed Msg" {
    const NF = NumericField(.{});
    const App = component_mod.Components(.{ .qty = NF }, null);

    // The text_field.zig host helper works UNCHANGED because the Msg
    // vocabulary is shared — proving compatibility.
    const built = teak_text_field.textFieldChar(App.Msg, "qty", '7');
    try std.testing.expectEqual(@as(u8, '7'), built.qty.char);

    // Routing the built Msg actually edits the buffer.
    var m: App.Model = .{};
    App.update(&m, built);
    try std.testing.expectEqualStrings("7", m.qty.tf.content());
    try std.testing.expectEqual(@as(?f64, 7.0), NF.value(&m.qty));
}

test "NumericField.view: valid field emits one text_input, no danger cmd" {
    const testing = std.testing;
    const NF = NumericField(.{});
    const App = component_mod.Components(.{ .qty = NF }, null);

    var cb = cmd_mod.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    var m: NF.Model = .{};
    for ("42") |c| NF.update(&m, .{ .char = c });
    NF.view(&m, &cb, .{ .focus = App.Msg{ .qty = .focus } });

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[0]));
}

test "NumericField.view: invalid field also emits a danger text cmd" {
    const testing = std.testing;
    const NF = NumericField(.{ .invalid_message = "must be a number" });
    const App = component_mod.Components(.{ .qty = NF }, null);

    var cb = cmd_mod.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    // Empty buffer is invalid → wrapped in a vertical group with a danger row.
    const m: NF.Model = .{};
    NF.view(&m, &cb, .{ .focus = App.Msg{ .qty = .focus } });

    // Sequence: push_group, text_input, text (danger), pop_group.
    try testing.expectEqual(@as(usize, 4), cb.cmds.items.len);
    try testing.expectEqual(.push_group, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[1]));
    try testing.expectEqual(.text, std.meta.activeTag(cb.cmds.items[2]));
    try testing.expectEqualStrings("must be a number", cb.cmds.items[2].text.content);
    try testing.expectEqual(cb.theme.danger_color, cb.cmds.items[2].text.color);
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[3]));
}

test "NumericField.view: empty invalid_message suppresses the validation row" {
    const testing = std.testing;
    const NF = NumericField(.{ .invalid_message = "" });
    const App = component_mod.Components(.{ .qty = NF }, null);

    var cb = cmd_mod.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    // Invalid (empty) field, but no message → bare input, no group.
    const m: NF.Model = .{};
    NF.view(&m, &cb, .{ .focus = App.Msg{ .qty = .focus } });

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[0]));
}
