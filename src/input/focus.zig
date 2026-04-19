//! Focus traversal helpers: walk `[]Cmd` to find the next/previous
//! focusable widget. Framework-level primitive; the app decides how to
//! translate a resulting cmd index into its own `Model.focused` field.
//!
//! A Cmd is "focusable" if it accepts keyboard input. For now only
//! `text_input` qualifies; expand the predicate when more widgets
//! become keyboard-operable.

const std = @import("std");

fn isFocusable(c: anytype) bool {
    return switch (c) {
        .text_input => true,
        else => false,
    };
}

/// Find the next focusable cmd index strictly after `current`. If
/// `current` is null, start from index 0. Wraps to 0 at the end.
/// Returns null only if the buffer has no focusable widgets at all.
pub fn nextFocusable(cmds: anytype, current: ?usize) ?usize {
    const n = cmds.len;
    if (n == 0) return null;

    const start: usize = if (current) |c| (c + 1) % n else 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (start + i) % n;
        if (isFocusable(cmds[idx])) return idx;
    }
    return null;
}

/// Find the previous focusable cmd index strictly before `current`. If
/// `current` is null, start from the last index. Wraps to the end at 0.
pub fn prevFocusable(cmds: anytype, current: ?usize) ?usize {
    const n = cmds.len;
    if (n == 0) return null;

    const start: usize = if (current) |c|
        if (c == 0) n - 1 else c - 1
    else
        n - 1;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = if (start >= i) start - i else start + n - i;
        if (isFocusable(cmds[idx])) return idx;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd_mod = @import("../core/cmd.zig");

test "nextFocusable wraps forward" {
    const testing = std.testing;
    const Msg = union(enum) { a, b };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.text("hello");
    cb.textInput(.a, "", 0); // idx 1
    cb.button(.a, "btn");
    cb.textInput(.b, "", 0); // idx 3

    try testing.expectEqual(@as(?usize, 1), nextFocusable(cb.cmds.items, null));
    try testing.expectEqual(@as(?usize, 3), nextFocusable(cb.cmds.items, 1));
    try testing.expectEqual(@as(?usize, 1), nextFocusable(cb.cmds.items, 3)); // wrap
}

test "prevFocusable wraps backward" {
    const testing = std.testing;
    const Msg = union(enum) { a, b };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.a, "", 0); // idx 0
    cb.text("mid");
    cb.textInput(.b, "", 0); // idx 2

    try testing.expectEqual(@as(?usize, 2), prevFocusable(cb.cmds.items, null));
    try testing.expectEqual(@as(?usize, 0), prevFocusable(cb.cmds.items, 2));
    try testing.expectEqual(@as(?usize, 2), prevFocusable(cb.cmds.items, 0)); // wrap
}

test "nextFocusable with a single focusable wraps back to itself" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.a, "", 0); // idx 0 — only focusable

    // Advance from the only focusable. `next` is strict-after, so it
    // must wrap and land back on 0.
    try testing.expectEqual(@as(?usize, 0), nextFocusable(cb.cmds.items, 0));
    try testing.expectEqual(@as(?usize, 0), prevFocusable(cb.cmds.items, 0));
}

test "nextFocusable returns null when no focusables" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.text("only text");
    cb.button(.a, "btn");

    try testing.expectEqual(@as(?usize, null), nextFocusable(cb.cmds.items, null));
    try testing.expectEqual(@as(?usize, null), prevFocusable(cb.cmds.items, null));
}
