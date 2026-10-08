//! Page 4: popups - tooltips, context menu, toasts, dialogs, and the menu bar.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;
const Msg = model.Msg;

/// Widgets that carry tooltips (matched by the Msg they dispatch) and their texts.
pub const tip_targets = [_]Msg{
    .{ .demo = 0 },
    .{ .demo = 1 },
    .{ .demo = 2 },
    .{ .go = .controls },
    .{ .go = .inputs },
    .{ .go = .data },
    .{ .go = .overlays },
    .{ .go = .layout },
    .{ .go = .scene },
};
pub const tip_texts = [_][]const u8{
    "Save the document (Ctrl+S)",
    "Open a file...",
    "Export as PDF",
    "Buttons, checkboxes, switches, sliders",
    "Text fields, dropdown, combobox",
    "Table, tree, virtual list, chart",
    "Menus, tooltips, toasts, dialogs",
    "Tabs, split pane, progress",
    "3D scene and images",
};

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 400, .align_cross = .stretch });
    ui.card(cb, "Tooltips", 0, 0);
    cb.textMuted("Hover a button for half a second.");
    ui.row(cb);
    cb.button(.{ .demo = 0 }, "Save");
    cb.button(.{ .demo = 1 }, "Open");
    cb.button(.{ .demo = 2 }, "Export");
    ui.endRow(cb);
    cb.textMuted("The sidebar buttons have tips too.");
    ui.endCard(cb);

    ui.card(cb, "Context menu", 0, 0);
    cb.text("Right-click anywhere in this window.");
    cb.textMuted("Up/Down, Enter, Esc and mnemonics work;");
    cb.textMuted("Properties has a submenu.");
    cb.textMuted(if (m.last_action) |a| ui.fmt(cb, "last action: {s}", .{@tagName(a)}) else "last action: none");
    ui.endCard(cb);

    ui.card(cb, "Menu bar", 0, 0);
    cb.textMuted("F10 or a tap on Alt activates the bar;");
    cb.textMuted("arrows move, Enter chooses, Esc backs out;");
    cb.textMuted("then a letter is a mnemonic (F, V, H).");
    cb.text(if (m.menubar.st.active) "menu bar: active" else "menu bar: idle");
    ui.endCard(cb);
    cb.popGroup();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 400, .align_cross = .stretch });
    ui.card(cb, "Toasts", 0, 0);
    ui.row(cb);
    cb.button(.{ .toast_push = .{ .kind = .info } }, "Info");
    cb.button(.{ .toast_push = .{ .kind = .success } }, "Success");
    ui.endRow(cb);
    ui.row(cb);
    cb.button(.{ .toast_push = .{ .kind = .warning } }, "Warning");
    cb.button(.{ .toast_push = .{ .kind = .danger } }, "Error");
    cb.button(.{ .toast_push = .{ .kind = .info, .sticky = true } }, "Sticky");
    ui.endRow(cb);
    cb.textMuted(ui.fmt(cb, "{d} showing; they expire on their own", .{m.toasts.len}));
    ui.endCard(cb);

    ui.card(cb, "Dialogs", 0, 0);
    ui.row(cb);
    cb.button(.{ .dialog = .about }, "About...");
    cb.button(.{ .dialog = .shortcuts }, "Shortcuts...");
    cb.button(.{ .dialog = .confirm_reset }, "Reset...");
    ui.endRow(cb);
    cb.textMuted("Modal: Enter confirms, Esc cancels.");
    ui.endCard(cb);
    cb.popGroup();

    cb.popGroup();
}
