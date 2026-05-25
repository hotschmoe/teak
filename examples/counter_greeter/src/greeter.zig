const std = @import("std");

// ── Greeter Component ──────────────────────────────────────────────
// Text input + live greeting. All widget state (buffer, length, cursor) is
// explicit on Model — nothing hidden. The text_input command carries only a
// focus_msg; per-key events arrive as component Msgs via the app dispatcher.

pub const MAX_NAME: usize = 63;
const BUFFER_LEN: usize = MAX_NAME + 1;

pub const Model = struct {
    name: [BUFFER_LEN]u8 = [_]u8{0} ** BUFFER_LEN,
    name_len: usize = 0,
    cursor: usize = 0,
    /// Selection anchor. null = no selection (cursor only). When non-null
    /// and != cursor, the range [min(anchor,cursor), max(anchor,cursor))
    /// is selected. Typed chars / backspace replace the selection.
    selection_anchor: ?usize = null,
};

pub const Msg = union(enum) {
    name_char: u8,
    name_backspace,
    name_cursor_left,
    name_cursor_right,
    /// Shift+arrow variants: extend selection rather than collapse.
    name_select_left,
    name_select_right,
    /// Replace current selection (or empty range) with the given bytes.
    /// Used for clipboard paste.
    name_replace_selection: []const u8,
    /// Clear selection without moving cursor.
    name_select_none,
    /// Move cursor + clear selection to byte 0 (select_all uses this then
    /// extends with name_select_to_end).
    name_select_all,
    focus,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .name_char => |c| {
            // Replace any active selection before inserting.
            deleteSelection(model);
            if (model.name_len >= MAX_NAME) return;
            std.mem.copyBackwards(
                u8,
                model.name[model.cursor + 1 .. model.name_len + 1],
                model.name[model.cursor..model.name_len],
            );
            model.name[model.cursor] = c;
            model.name_len += 1;
            model.cursor += 1;
        },
        .name_backspace => {
            if (model.selection_anchor) |_| {
                deleteSelection(model);
                return;
            }
            if (model.cursor == 0) return;
            std.mem.copyForwards(
                u8,
                model.name[model.cursor - 1 .. model.name_len - 1],
                model.name[model.cursor..model.name_len],
            );
            model.name_len -= 1;
            model.cursor -= 1;
        },
        .name_cursor_left => {
            model.selection_anchor = null;
            if (model.cursor > 0) model.cursor -= 1;
        },
        .name_cursor_right => {
            model.selection_anchor = null;
            if (model.cursor < model.name_len) model.cursor += 1;
        },
        .name_select_left => {
            if (model.selection_anchor == null) model.selection_anchor = model.cursor;
            if (model.cursor > 0) model.cursor -= 1;
        },
        .name_select_right => {
            if (model.selection_anchor == null) model.selection_anchor = model.cursor;
            if (model.cursor < model.name_len) model.cursor += 1;
        },
        .name_replace_selection => |bytes| {
            deleteSelection(model);
            // Cap to remaining capacity.
            const room = MAX_NAME - model.name_len;
            const insert = bytes[0..@min(bytes.len, room)];
            if (insert.len == 0) return;
            std.mem.copyBackwards(
                u8,
                model.name[model.cursor + insert.len .. model.name_len + insert.len],
                model.name[model.cursor..model.name_len],
            );
            @memcpy(model.name[model.cursor .. model.cursor + insert.len], insert);
            model.name_len += insert.len;
            model.cursor += insert.len;
        },
        .name_select_none => {
            model.selection_anchor = null;
        },
        .name_select_all => {
            model.selection_anchor = 0;
            model.cursor = model.name_len;
        },
        .focus => {},
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
        model.name[lo .. model.name_len - (hi - lo)],
        model.name[hi..model.name_len],
    );
    model.name_len -= (hi - lo);
    model.cursor = lo;
    model.selection_anchor = null;
}

/// Returns the currently selected text, or "" when there's no selection.
pub fn selectionText(model: *const Model) []const u8 {
    const anchor = model.selection_anchor orelse return "";
    const lo = @min(anchor, model.cursor);
    const hi = @max(anchor, model.cursor);
    if (hi == lo) return "";
    return model.name[lo..hi];
}

pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });

    const name_slice = model.name[0..model.name_len];
    cb.textInputSelected(msgs.focus, name_slice, model.cursor, model.selection_anchor, .{});

    const greeting = std.fmt.allocPrint(
        cb.arena.allocator(),
        "Hello, {s}!",
        .{if (model.name_len > 0) name_slice else "World"},
    ) catch unreachable;
    cb.text(greeting);

    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

test "greeter: insert at end" {
    var m: Model = .{};
    update(&m, .{ .name_char = 'A' });
    update(&m, .{ .name_char = 'B' });
    update(&m, .{ .name_char = 'C' });
    try std.testing.expectEqualStrings("ABC", m.name[0..m.name_len]);
    try std.testing.expectEqual(@as(usize, 3), m.cursor);
}

test "greeter: backspace removes char before cursor" {
    var m: Model = .{};
    update(&m, .{ .name_char = 'A' });
    update(&m, .{ .name_char = 'B' });
    update(&m, .name_backspace);
    try std.testing.expectEqualStrings("A", m.name[0..m.name_len]);
    try std.testing.expectEqual(@as(usize, 1), m.cursor);
}

test "greeter: backspace at cursor 0 is no-op" {
    var m: Model = .{};
    update(&m, .name_backspace);
    try std.testing.expectEqual(@as(usize, 0), m.name_len);
    try std.testing.expectEqual(@as(usize, 0), m.cursor);
}

test "greeter: insert in middle" {
    var m: Model = .{};
    update(&m, .{ .name_char = 'A' });
    update(&m, .{ .name_char = 'C' });
    update(&m, .name_cursor_left);
    update(&m, .{ .name_char = 'B' });
    try std.testing.expectEqualStrings("ABC", m.name[0..m.name_len]);
    try std.testing.expectEqual(@as(usize, 2), m.cursor);
}

test "greeter: cursor bounds" {
    var m: Model = .{};
    update(&m, .name_cursor_left); // no-op at 0
    try std.testing.expectEqual(@as(usize, 0), m.cursor);
    update(&m, .{ .name_char = 'A' });
    update(&m, .name_cursor_right); // no-op at end
    try std.testing.expectEqual(@as(usize, 1), m.cursor);
}

test "greeter: view emits text_input + greeting" {
    const testing = std.testing;
    const cmd = @import("teak").cmd;

    const AppMsg = Msg;
    var cb = cmd.CmdBuffer(AppMsg).init(testing.allocator);
    defer cb.deinit();

    var m: Model = .{};
    update(&m, .{ .name_char = 'A' });
    update(&m, .{ .name_char = 'B' });

    const msgs = .{ .focus = AppMsg.focus };
    view(&m, &cb, msgs);

    // push, text_input, text, pop = 4 cmds
    try testing.expectEqual(@as(usize, 4), cb.cmds.items.len);
    try testing.expectEqualStrings("AB", cb.cmds.items[1].text_input.content);
    try testing.expectEqual(@as(usize, 2), cb.cmds.items[1].text_input.cursor);
    try testing.expectEqualStrings("Hello, AB!", cb.cmds.items[2].text.content);
}

test "greeter: shift-arrow extends selection" {
    var m: Model = .{};
    update(&m, .{ .name_char = 'H' });
    update(&m, .{ .name_char = 'e' });
    update(&m, .{ .name_char = 'l' });
    update(&m, .{ .name_char = 'l' });
    update(&m, .{ .name_char = 'o' });
    // Cursor at 5, no anchor. Shift+left twice → anchor=5, cursor=3.
    update(&m, .name_select_left);
    update(&m, .name_select_left);
    try std.testing.expectEqual(@as(?usize, 5), m.selection_anchor);
    try std.testing.expectEqual(@as(usize, 3), m.cursor);
    try std.testing.expectEqualStrings("lo", selectionText(&m));
}

test "greeter: typing while selection active replaces it" {
    var m: Model = .{};
    for ("Hello") |c| update(&m, .{ .name_char = c });
    update(&m, .name_select_left);
    update(&m, .name_select_left); // select "lo"
    update(&m, .{ .name_char = 'p' });
    try std.testing.expectEqualStrings("Help", m.name[0..m.name_len]);
    try std.testing.expectEqual(@as(?usize, null), m.selection_anchor);
}

test "greeter: backspace with selection deletes selection, not just one char" {
    var m: Model = .{};
    for ("Hello") |c| update(&m, .{ .name_char = c });
    update(&m, .name_select_left);
    update(&m, .name_select_left);
    update(&m, .name_select_left);
    update(&m, .name_select_left); // select "ello"
    update(&m, .name_backspace);
    try std.testing.expectEqualStrings("H", m.name[0..m.name_len]);
    try std.testing.expectEqual(@as(usize, 1), m.cursor);
}

test "greeter: name_replace_selection (paste) replaces selection range" {
    var m: Model = .{};
    for ("Hello") |c| update(&m, .{ .name_char = c });
    update(&m, .name_select_left);
    update(&m, .name_select_left); // select "lo"
    update(&m, .{ .name_replace_selection = "p!" });
    try std.testing.expectEqualStrings("Help!", m.name[0..m.name_len]);
    try std.testing.expectEqual(@as(usize, 5), m.cursor);
}

test "greeter: select_all sets anchor=0, cursor=len" {
    var m: Model = .{};
    for ("Hello") |c| update(&m, .{ .name_char = c });
    update(&m, .name_select_all);
    try std.testing.expectEqual(@as(?usize, 0), m.selection_anchor);
    try std.testing.expectEqual(@as(usize, 5), m.cursor);
}

test "greeter: empty name shows Hello, World!" {
    const testing = std.testing;
    const cmd = @import("teak").cmd;

    const AppMsg = Msg;
    var cb = cmd.CmdBuffer(AppMsg).init(testing.allocator);
    defer cb.deinit();

    const msgs = .{ .focus = AppMsg.focus };
    const empty: Model = .{};
    view(&empty, &cb, msgs);

    try testing.expectEqualStrings("Hello, World!", cb.cmds.items[2].text.content);
}
