//! Canonical text-input component + key-dispatch helpers.
//!
//! Closes ergonomic gap 2: every component that wraps a `text_input`
//! Cmd used to re-define its own name_char / name_backspace / name_*
//! Msgs and the main loop dispatched by `Model.focused`. This file
//! ships the canonical set once and supplies comptime helpers that
//! wrap a raw key event into the right composed `AppMsg`.
//!
//! Composition model:
//!   - `TextField(capacity)` returns a component (Model / Msg / update /
//!     view) — the standard `validateComponent` shape, so it composes
//!     via `Components(.{ .name = TextField(32), ... })` like any
//!     other component.
//!   - The host's input loop converts a SpecialKey or u8 into an
//!     `AppMsg` by calling `textFieldChar` / `textFieldSpecial` /
//!     `textFieldReplaceSelection`. These helpers reflect on the
//!     composed `AppMsg` type via `@FieldType` so the same call works
//!     no matter what capacity the component was instantiated with.
//!
//! HARDLINE: Msg is a tagged union of data (no fn pointers), update is
//! a pure switch, view is pure, no allocator parameters, no platform
//! imports.

const std = @import("std");
const keys = @import("../input/keys.zig");
const editor_mod = @import("editor.zig");

const SpecialKey = keys.SpecialKey;

// ── Component factory ───────────────────────────────────────────────
//
// `TextField(N)` returns a struct exposing Model/Msg/update/view.
// `validateComponent(TextField(N))` passes; `Components()` happily
// stitches it alongside hand-written components.
//
// Each capacity instantiates its own Msg type, but they share the same
// shape — the dispatch helpers below use `@FieldType` so they work for
// any capacity uniformly.

pub fn TextField(comptime capacity: usize) type {
    return struct {
        /// Canonical text-field message vocabulary. Same variant names
        /// across all TextField(N) — the dispatch helpers below rely on
        /// this convention.
        pub const Msg = union(enum) {
            /// Mouse click on the input — the app sets focus from this.
            focus,
            /// One byte of typed UTF-8 (multi-byte characters are assembled
            /// across consecutive `char` Msgs and inserted atomically).
            char: u8,
            /// Backspace. Deletes the selection if any, else one grapheme
            /// before the cursor.
            backspace,
            /// Delete key: the selection, else one grapheme after the cursor.
            delete,
            /// Left arrow (collapses selection if any).
            cursor_left,
            /// Right arrow.
            cursor_right,
            /// Shift+left (extends selection).
            select_left,
            /// Shift+right.
            select_right,
            /// Home / End (single line: start / end of the text).
            home,
            end,
            select_home,
            select_end,
            /// Ctrl+Left / Ctrl+Right word jumps and their Shift variants.
            word_left,
            word_right,
            select_word_left,
            select_word_right,
            /// Ctrl+Backspace / Ctrl+Delete.
            delete_word_left,
            delete_word_right,
            /// Ctrl+Z / Ctrl+Y.
            undo,
            redo,
            /// Ctrl+A. Selects everything, cursor at the end.
            select_all,
            /// Escape. Clears selection without moving the cursor.
            select_none,
            /// Replace the selected range (or the empty range at the
            /// cursor) with the supplied bytes. Used by paste at the
            /// host boundary.
            replace_selection: []const u8,
        };

        /// The text, cursor, selection and undo history live in an `Editor`
        /// (`core/editor.zig`); its fields (`len`, `cursor`,
        /// `selection_anchor`) and `content()` / `selectionText()` /
        /// `hasSelection()` are the Model's public surface.
        pub const Model = editor_mod.Editor(capacity, undo_bytes);

        const undo_bytes = @min(@max(capacity * 4, 64), 1024);

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .focus => {},
                .char => |c| model.typeByte(c),
                .backspace => model.backspace(),
                .delete => model.delete(),
                .cursor_left => model.move(.left, false),
                .cursor_right => model.move(.right, false),
                .select_left => model.move(.left, true),
                .select_right => model.move(.right, true),
                .home => model.move(.home, false),
                .end => model.move(.end, false),
                .select_home => model.move(.home, true),
                .select_end => model.move(.end, true),
                .word_left => model.move(.word_left, false),
                .word_right => model.move(.word_right, false),
                .select_word_left => model.move(.word_left, true),
                .select_word_right => model.move(.word_right, true),
                .delete_word_left => model.deleteWordLeft(),
                .delete_word_right => model.deleteWordRight(),
                .undo => _ = model.undoEdit(),
                .redo => _ = model.redoEdit(),
                .select_all => model.selectAll(),
                .select_none => model.deselect(),
                .replace_selection => |bytes| model.insert(bytes),
            }
        }

        /// Emit the input cmd. `msgs.focus` is the composed AppMsg that
        /// the framework will dispatch on click (per the standard
        /// component protocol).
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            cb.textInputSelected(
                msgs.focus,
                model.content(),
                model.cursor,
                model.selection_anchor,
                cb.theme.text_input,
            );
        }
    };
}

// ── Host-side key dispatch helpers ──────────────────────────────────
//
// These are comptime helpers that convert a SpecialKey / char into an
// `AppMsg` for the focused TextField field — wrapping the local Msg
// in the composed Msg using `@FieldType` + `@unionInit`. They work
// for any AppMsg that contains a variant whose payload is a Msg-shaped
// union (i.e. has `char: u8`, `backspace`, etc. variants).

/// Build the AppMsg for a typed character into the named field.
/// `field_name` is the field on the composed AppMsg (e.g. "search").
pub fn textFieldChar(
    comptime AppMsg: type,
    comptime field_name: []const u8,
    c: u8,
) AppMsg {
    const FieldMsg = @FieldType(AppMsg, field_name);
    return @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "char", c));
}

/// Build the AppMsg for a SpecialKey into the named field. Returns null
/// for keys that don't map to a single TextField Msg (ctrl_c / ctrl_x /
/// ctrl_v — the host loop handles clipboard at its boundary and then
/// dispatches `replace_selection` via `textFieldReplaceSelection`).
pub fn textFieldSpecial(
    comptime AppMsg: type,
    comptime field_name: []const u8,
    key: SpecialKey,
) ?AppMsg {
    const FieldMsg = @FieldType(AppMsg, field_name);
    const name: ?[]const u8 = switch (key) {
        .backspace => "backspace",
        .delete => "delete",
        .left => "cursor_left",
        .right => "cursor_right",
        .shift_left => "select_left",
        .shift_right => "select_right",
        .home, .ctrl_home => "home",
        .end, .ctrl_end => "end",
        .shift_home, .ctrl_shift_home => "select_home",
        .shift_end, .ctrl_shift_end => "select_end",
        .ctrl_left => "word_left",
        .ctrl_right => "word_right",
        .ctrl_shift_left => "select_word_left",
        .ctrl_shift_right => "select_word_right",
        .ctrl_backspace => "delete_word_left",
        .ctrl_delete => "delete_word_right",
        .ctrl_z => "undo",
        .ctrl_y, .ctrl_shift_z => "redo",
        .ctrl_a => "select_all",
        .escape => "select_none",
        else => null,
    };
    const n = name orelse return null;
    // Keys map to payload-free variants; resolve the name at comptime per call site.
    const info = @typeInfo(FieldMsg).@"union";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (ftype == void and std.mem.eql(u8, fname, n))
            return @unionInit(AppMsg, field_name, @unionInit(FieldMsg, fname, {}));
    }
    return null;
}

/// True if the key requires host-level clipboard interaction (the host
/// reads/writes the OS clipboard and then dispatches a normal Msg).
pub fn keyNeedsClipboard(key: SpecialKey) bool {
    return key == .ctrl_c or key == .ctrl_x or key == .ctrl_v;
}

/// Build the AppMsg for a paste into the named field. The host calls
/// this after `clipboard.read()` returns the bytes to insert.
pub fn textFieldReplaceSelection(
    comptime AppMsg: type,
    comptime field_name: []const u8,
    bytes: []const u8,
) AppMsg {
    const FieldMsg = @FieldType(AppMsg, field_name);
    return @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "replace_selection", bytes));
}

/// The Msg for a clipboard chord on the named field, for an App's
/// `clipboardMsg` hook: Ctrl+V -> `replace_selection(paste)`, Ctrl+X ->
/// `replace_selection("")` (deletes the selection; the copy itself is the
/// App's `clipboardText`), anything else (Ctrl+C included) -> null.
pub fn textFieldClipboardMsg(
    comptime AppMsg: type,
    comptime field_name: []const u8,
    key: SpecialKey,
    paste: []const u8,
) ?AppMsg {
    return switch (key) {
        .ctrl_v => textFieldReplaceSelection(AppMsg, field_name, paste),
        .ctrl_x => textFieldReplaceSelection(AppMsg, field_name, ""),
        else => null,
    };
}

/// What Ctrl+C / Ctrl+X copy from a field `Model` (a `TextField(cap).Model`):
/// its selection, or null when nothing is selected. For the App's
/// `clipboardText` hook; the slice borrows from the Model.
pub fn textFieldCopyText(model: anytype, key: SpecialKey) ?[]const u8 {
    if (key != .ctrl_c and key != .ctrl_x) return null;
    if (!model.hasSelection()) return null;
    return model.selectionText();
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd_mod = @import("cmd.zig");
const component_mod = @import("component.zig");

test "TextField(32) passes validateComponent" {
    component_mod.validateComponent(TextField(32));
}

test "TextField: insert at end" {
    const TF = TextField(32);
    var m: TF.Model = .{};
    TF.update(&m, .{ .char = 'A' });
    TF.update(&m, .{ .char = 'B' });
    TF.update(&m, .{ .char = 'C' });
    try std.testing.expectEqualStrings("ABC", m.content());
    try std.testing.expectEqual(@as(usize, 3), m.cursor);
}

test "TextField: backspace removes char before cursor" {
    const TF = TextField(16);
    var m: TF.Model = .{};
    TF.update(&m, .{ .char = 'A' });
    TF.update(&m, .{ .char = 'B' });
    TF.update(&m, .backspace);
    try std.testing.expectEqualStrings("A", m.content());
}

test "TextField: shift-arrows extend selection, plain arrows collapse" {
    const TF = TextField(16);
    var m: TF.Model = .{};
    for ("Hello") |c| TF.update(&m, .{ .char = c });
    TF.update(&m, .select_left);
    TF.update(&m, .select_left);
    try std.testing.expectEqual(@as(?usize, 5), m.selection_anchor);
    try std.testing.expectEqualStrings("lo", m.selectionText());

    // Plain left collapses selection.
    TF.update(&m, .cursor_left);
    try std.testing.expectEqual(@as(?usize, null), m.selection_anchor);
}

test "TextField: typing with selection active replaces it" {
    const TF = TextField(16);
    var m: TF.Model = .{};
    for ("Hello") |c| TF.update(&m, .{ .char = c });
    TF.update(&m, .select_left);
    TF.update(&m, .select_left);
    TF.update(&m, .{ .char = 'p' });
    try std.testing.expectEqualStrings("Help", m.content());
}

test "TextField: select_all + replace_selection round-trip" {
    const TF = TextField(16);
    var m: TF.Model = .{};
    for ("Hello") |c| TF.update(&m, .{ .char = c });
    TF.update(&m, .select_all);
    TF.update(&m, .{ .replace_selection = "Goodbye" });
    try std.testing.expectEqualStrings("Goodbye", m.content());
    try std.testing.expectEqual(@as(usize, 7), m.cursor);
    try std.testing.expectEqual(@as(?usize, null), m.selection_anchor);
}

test "TextField: capacity overflow drops extra bytes silently" {
    const TF = TextField(3);
    var m: TF.Model = .{};
    TF.update(&m, .{ .char = 'A' });
    TF.update(&m, .{ .char = 'B' });
    TF.update(&m, .{ .char = 'C' });
    TF.update(&m, .{ .char = 'D' }); // dropped
    try std.testing.expectEqualStrings("ABC", m.content());
}

test "TextField composes via Components" {
    const Search = TextField(32);
    const App = component_mod.Components(.{ .search = Search }, null);

    var m: App.Model = .{};
    try std.testing.expectEqual(@as(usize, 0), m.search.len);

    App.update(&m, .{ .search = .{ .char = 'q' } });
    App.update(&m, .{ .search = .{ .char = 'u' } });
    App.update(&m, .{ .search = .{ .char = 'e' } });
    App.update(&m, .{ .search = .{ .char = 'r' } });
    App.update(&m, .{ .search = .{ .char = 'y' } });
    try std.testing.expectEqualStrings("query", m.search.content());
}

test "textFieldChar builds AppMsg{ .field = .{ .char = c } }" {
    const Search = TextField(32);
    const App = component_mod.Components(.{ .search = Search }, null);

    const msg = textFieldChar(App.Msg, "search", 'q');
    try std.testing.expectEqual(@as(u8, 'q'), msg.search.char);
}

test "textFieldSpecial maps SpecialKeys to TextField Msg variants" {
    const Search = TextField(32);
    const App = component_mod.Components(.{ .search = Search }, null);

    const m_bs = textFieldSpecial(App.Msg, "search", .backspace).?;
    try std.testing.expectEqual(Search.Msg.backspace, m_bs.search);

    const m_left = textFieldSpecial(App.Msg, "search", .left).?;
    try std.testing.expectEqual(Search.Msg.cursor_left, m_left.search);

    const m_sleft = textFieldSpecial(App.Msg, "search", .shift_left).?;
    try std.testing.expectEqual(Search.Msg.select_left, m_sleft.search);

    const m_all = textFieldSpecial(App.Msg, "search", .ctrl_a).?;
    try std.testing.expectEqual(Search.Msg.select_all, m_all.search);

    const m_esc = textFieldSpecial(App.Msg, "search", .escape).?;
    try std.testing.expectEqual(Search.Msg.select_none, m_esc.search);

    // Unmapped key → null (host-level handling required).
    try std.testing.expect(textFieldSpecial(App.Msg, "search", .ctrl_c) == null);
}

test "textFieldReplaceSelection builds AppMsg with the bytes" {
    const Search = TextField(32);
    const App = component_mod.Components(.{ .search = Search }, null);

    const msg = textFieldReplaceSelection(App.Msg, "search", "pasted");
    try std.testing.expectEqualStrings("pasted", msg.search.replace_selection);
}

test "keyNeedsClipboard flags exactly ctrl_c / ctrl_x / ctrl_v" {
    try std.testing.expect(keyNeedsClipboard(.ctrl_c));
    try std.testing.expect(keyNeedsClipboard(.ctrl_x));
    try std.testing.expect(keyNeedsClipboard(.ctrl_v));
    try std.testing.expect(!keyNeedsClipboard(.backspace));
    try std.testing.expect(!keyNeedsClipboard(.left));
    try std.testing.expect(!keyNeedsClipboard(.shift_right));
}

test "TextField.view emits text_input with the cb's theme" {
    const testing = std.testing;
    const Search = TextField(32);
    const App = component_mod.Components(.{ .search = Search }, null);

    var cb = cmd_mod.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    const m: Search.Model = .{};
    Search.view(&m, &cb, .{ .focus = App.Msg{ .search = .focus } });

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqual(@as(usize, 0), cb.cmds.items[0].text_input.cursor);
}

test "TextField: UTF-8 typed byte-wise, backspace removes a whole grapheme" {
    const TF = TextField(32);
    var m: TF.Model = .{};
    for ("ae\u{0301}\u{20AC}") |c| TF.update(&m, .{ .char = c });
    try std.testing.expectEqualStrings("ae\u{0301}\u{20AC}", m.content());
    TF.update(&m, .backspace); // euro sign
    TF.update(&m, .backspace); // e + combining acute
    try std.testing.expectEqualStrings("a", m.content());
}

test "TextField: Home/End/Delete and word jumps" {
    const TF = TextField(32);
    var m: TF.Model = .{};
    for ("one two three") |c| TF.update(&m, .{ .char = c });
    TF.update(&m, .home);
    try std.testing.expectEqual(@as(usize, 0), m.cursor);
    TF.update(&m, .delete);
    try std.testing.expectEqualStrings("ne two three", m.content());
    TF.update(&m, .word_right);
    try std.testing.expectEqual(@as(usize, 3), m.cursor);
    TF.update(&m, .delete_word_right);
    try std.testing.expectEqualStrings("ne three", m.content());
    TF.update(&m, .end);
    TF.update(&m, .select_word_left);
    try std.testing.expectEqualStrings("three", m.selectionText());
    TF.update(&m, .delete_word_left);
    try std.testing.expectEqualStrings("ne ", m.content());
    TF.update(&m, .undo);
    try std.testing.expectEqualStrings("ne three", m.content());
    TF.update(&m, .redo);
    try std.testing.expectEqualStrings("ne ", m.content());
}

test "TextField: multi-byte character that does not fit is dropped whole" {
    const TF = TextField(4);
    var m: TF.Model = .{};
    for ("abc\u{00e9}") |c| TF.update(&m, .{ .char = c });
    try std.testing.expectEqualStrings("abc", m.content());
}

test "textFieldSpecial maps the editing chords" {
    const Search = TextField(32);
    const App = component_mod.Components(.{ .search = Search }, null);
    try std.testing.expectEqual(Search.Msg.delete, textFieldSpecial(App.Msg, "search", .delete).?.search);
    try std.testing.expectEqual(Search.Msg.home, textFieldSpecial(App.Msg, "search", .home).?.search);
    try std.testing.expectEqual(Search.Msg.select_end, textFieldSpecial(App.Msg, "search", .shift_end).?.search);
    try std.testing.expectEqual(Search.Msg.word_left, textFieldSpecial(App.Msg, "search", .ctrl_left).?.search);
    try std.testing.expectEqual(Search.Msg.delete_word_left, textFieldSpecial(App.Msg, "search", .ctrl_backspace).?.search);
    try std.testing.expectEqual(Search.Msg.undo, textFieldSpecial(App.Msg, "search", .ctrl_z).?.search);
    try std.testing.expectEqual(Search.Msg.redo, textFieldSpecial(App.Msg, "search", .ctrl_shift_z).?.search);
    try std.testing.expect(textFieldSpecial(App.Msg, "search", .up) == null);
}

test "textFieldClipboardMsg / textFieldCopyText: paste, cut and copy over a field" {
    const TF = TextField(32);
    const App = struct {
        pub const Msg = union(enum) { search: TF.Msg };
    };
    const paste = textFieldClipboardMsg(App.Msg, "search", .ctrl_v, "hi").?;
    try std.testing.expectEqualStrings("hi", paste.search.replace_selection);
    const cut = textFieldClipboardMsg(App.Msg, "search", .ctrl_x, "ignored").?;
    try std.testing.expectEqualStrings("", cut.search.replace_selection);
    try std.testing.expect(textFieldClipboardMsg(App.Msg, "search", .ctrl_c, "") == null);

    var m: TF.Model = .{};
    TF.update(&m, .{ .replace_selection = "hello world" });
    try std.testing.expect(textFieldCopyText(&m, .ctrl_c) == null); // nothing selected
    TF.update(&m, .select_all);
    try std.testing.expectEqualStrings("hello world", textFieldCopyText(&m, .ctrl_c).?);
    try std.testing.expect(textFieldCopyText(&m, .ctrl_v) == null);
    TF.update(&m, cut.search);
    try std.testing.expectEqual(@as(usize, 0), m.len);
}
