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
            /// Single character typed.
            char: u8,
            /// Backspace pressed. Deletes the selection if any, else one
            /// byte before the cursor.
            backspace,
            /// Left arrow (collapses selection if any).
            cursor_left,
            /// Right arrow.
            cursor_right,
            /// Shift+left (extends selection).
            select_left,
            /// Shift+right.
            select_right,
            /// Ctrl+A. Selects everything, cursor at the end.
            select_all,
            /// Escape. Clears selection without moving the cursor.
            select_none,
            /// Replace the selected range (or the empty range at the
            /// cursor) with the supplied bytes. Used by paste at the
            /// host boundary.
            replace_selection: []const u8,
        };

        pub const Model = struct {
            buffer: [capacity]u8 = [_]u8{0} ** capacity,
            len: usize = 0,
            cursor: usize = 0,
            /// null = no selection. When set and != cursor, the range
            /// [min(anchor, cursor), max(anchor, cursor)) is selected.
            selection_anchor: ?usize = null,

            /// Slice of the current content (no null terminator).
            pub fn content(self: *const @This()) []const u8 {
                return self.buffer[0..self.len];
            }

            /// Slice of the currently selected bytes, or "" if no selection.
            pub fn selectionText(self: *const @This()) []const u8 {
                const anchor = self.selection_anchor orelse return "";
                const lo = @min(anchor, self.cursor);
                const hi = @max(anchor, self.cursor);
                if (hi == lo) return "";
                return self.buffer[lo..hi];
            }

            pub fn hasSelection(self: *const @This()) bool {
                const anchor = self.selection_anchor orelse return false;
                return anchor != self.cursor;
            }
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .focus => {},
                .char => |c| {
                    deleteSelection(model);
                    if (model.len >= capacity) return;
                    std.mem.copyBackwards(
                        u8,
                        model.buffer[model.cursor + 1 .. model.len + 1],
                        model.buffer[model.cursor..model.len],
                    );
                    model.buffer[model.cursor] = c;
                    model.len += 1;
                    model.cursor += 1;
                },
                .backspace => {
                    if (model.selection_anchor != null) {
                        deleteSelection(model);
                        return;
                    }
                    if (model.cursor == 0) return;
                    std.mem.copyForwards(
                        u8,
                        model.buffer[model.cursor - 1 .. model.len - 1],
                        model.buffer[model.cursor..model.len],
                    );
                    model.len -= 1;
                    model.cursor -= 1;
                },
                .cursor_left => {
                    model.selection_anchor = null;
                    if (model.cursor > 0) model.cursor -= 1;
                },
                .cursor_right => {
                    model.selection_anchor = null;
                    if (model.cursor < model.len) model.cursor += 1;
                },
                .select_left => {
                    if (model.selection_anchor == null) model.selection_anchor = model.cursor;
                    if (model.cursor > 0) model.cursor -= 1;
                },
                .select_right => {
                    if (model.selection_anchor == null) model.selection_anchor = model.cursor;
                    if (model.cursor < model.len) model.cursor += 1;
                },
                .select_all => {
                    model.selection_anchor = 0;
                    model.cursor = model.len;
                },
                .select_none => {
                    model.selection_anchor = null;
                },
                .replace_selection => |bytes| {
                    deleteSelection(model);
                    const room = capacity - model.len;
                    const insert = bytes[0..@min(bytes.len, room)];
                    if (insert.len == 0) return;
                    std.mem.copyBackwards(
                        u8,
                        model.buffer[model.cursor + insert.len .. model.len + insert.len],
                        model.buffer[model.cursor..model.len],
                    );
                    @memcpy(model.buffer[model.cursor .. model.cursor + insert.len], insert);
                    model.len += insert.len;
                    model.cursor += insert.len;
                },
            }
        }

        fn deleteSelection(model: *Model) void {
            const anchor = model.selection_anchor orelse return;
            const lo = @min(anchor, model.cursor);
            const hi = @max(anchor, model.cursor);
            if (hi == lo) {
                model.selection_anchor = null;
                return;
            }
            std.mem.copyForwards(
                u8,
                model.buffer[lo .. model.len - (hi - lo)],
                model.buffer[hi..model.len],
            );
            model.len -= (hi - lo);
            model.cursor = lo;
            model.selection_anchor = null;
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
    return switch (key) {
        .backspace => @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "backspace", {})),
        .left => @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "cursor_left", {})),
        .right => @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "cursor_right", {})),
        .shift_left => @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "select_left", {})),
        .shift_right => @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "select_right", {})),
        .ctrl_a => @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "select_all", {})),
        .escape => @unionInit(AppMsg, field_name, @unionInit(FieldMsg, "select_none", {})),
        else => null,
    };
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
