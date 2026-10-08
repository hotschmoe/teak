//! Page 2: text entry and pickers - TextField, underline field, NumericField,
//! form rows, Dropdown, Combobox.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;
const Msg = model.Msg;

pub const sizes = [_][]const u8{ "Small", "Medium", "Large", "Extra large" };
pub const woods = [_][]const u8{ "Oak", "Maple", "Cedar", "Ash", "Pine", "Birch", "Walnut", "Beech", "Cherry", "Spruce", "Hickory", "Mahogany" };

/// Open lists hang under the closed control: `auto_anchor` (the default)
/// anchors the overlay to the dropdown's button / the combobox's input, so no
/// window coordinates are computed here.
pub const col_w: f32 = 410;

fn dropOpts() teak.DropdownViewOpts {
    return .{ .list_width = col_w - 2 * ui.card_pad };
}

fn comboOpts() teak.ComboboxViewOpts {
    return .{ .list_width = col_w - 2 * ui.card_pad, .max_visible = 6 };
}

/// Key handling only needs the counts, not the positions.
pub const combo_key_opts: teak.ComboboxViewOpts = .{ .max_visible = 6 };

fn focusMsg(f: model.Field) Msg {
    return .{ .focus_set = f };
}

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = col_w, .align_cross = .stretch });
    ui.card(cb, "Dropdown", 0, 0);
    model.Drop.viewWith(&m.drop, cb, &sizes, .{ .toggle = Msg{ .drop = .toggle }, .close = Msg{ .drop = .close }, .selectMsg = dropSelect }, dropOpts());
    cb.textMuted(ui.fmt(cb, "chosen: {s}", .{sizes[@min(m.drop.selected, sizes.len - 1)]}));
    ui.endCard(cb);

    ui.card(cb, "Text field", 0, 0);
    model.NameField.view(&m.name, cb, .{ .focus = focusMsg(.name) });
    cb.text(ui.fmt(cb, "Hello, {s}!", .{if (m.name.len == 0) "stranger" else m.name.content()}));
    cb.divider();
    cb.textMuted("Underline variant (theme.field):");
    cb.textInputStyled(focusMsg(.search), m.search.content(), m.search.cursor, cb.theme.field);
    ui.endCard(cb);

    ui.card(cb, "Numeric field in a form row", 0, 0);
    cb.pushFormRow(.{ .label = "Quantity", .units = "units" });
    model.QtyField.view(&m.qty, cb, .{ .focus = focusMsg(.qty) });
    cb.popFormRow();
    if (model.QtyField.value(&m.qty)) |v| {
        cb.textMuted(ui.fmt(cb, "parsed value: {d:.0}", .{v}));
    } else {
        cb.textMuted("no valid value yet");
    }
    ui.endCard(cb);
    cb.popGroup();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = col_w, .align_cross = .stretch });
    ui.card(cb, "Combobox (searchable)", 0, 0);
    model.Combo.viewWith(&m.combo, cb, &woods, .{ .focus = Msg{ .combo = .focus }, .close = Msg{ .combo = .close }, .selectMsg = comboSelect }, comboOpts());
    cb.textMuted(ui.fmt(cb, "chosen: {s}", .{if (m.combo.selected) |i| woods[i] else "(none)"}));
    cb.textMuted("Type to filter; Up/Down, Enter, Esc.");
    ui.endCard(cb);

    ui.card(cb, "Text area", 0, 0);
    cb.textMuted("Multi-line editing is designed");
    cb.textMuted("(TextAreaCmd, docs/features/text-engine.md)");
    cb.textMuted("and not shipped yet.");
    ui.endCard(cb);
    cb.popGroup();

    cb.popGroup();
}

fn dropSelect(i: usize) Msg {
    return .{ .drop = .{ .select = i } };
}

fn comboSelect(i: usize) Msg {
    return .{ .combo = .{ .select = i } };
}
