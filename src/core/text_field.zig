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


const cmd_mod = @import("cmd.zig");
const component_mod = @import("component.zig");


















