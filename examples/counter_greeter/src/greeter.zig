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
};

pub const Msg = union(enum) {
    name_char: u8,
    name_backspace,
    name_cursor_left,
    name_cursor_right,
    focus,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .name_char => |c| {
            if (model.name_len >= MAX_NAME) return;
            // Shift [cursor..name_len) right by one, then write c at cursor.
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
            if (model.cursor > 0) model.cursor -= 1;
        },
        .name_cursor_right => {
            if (model.cursor < model.name_len) model.cursor += 1;
        },
        .focus => {},
    }
}

pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });

    const name_slice = model.name[0..model.name_len];
    cb.textInput(msgs.focus, name_slice, model.cursor);

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
