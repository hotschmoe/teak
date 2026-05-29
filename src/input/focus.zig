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

/// The activation/focus Msg an interactive leaf carries, or null for a
/// non-interactive cmd. This is the same leaf set hit-test keys off
/// (`button`, `text_input`, `checkbox`, `radio`, `slider`) — kept in
/// sync so "the Msg this cmd would dispatch" means the same thing to
/// both passes. For a `text_input` that Msg is its `focus_msg`; for a
/// `slider` it's `grab_msg`; for the rest it's `msg`.
fn activationMsg(c: anytype) ?@TypeOf(c).MsgT {
    return switch (c) {
        .button => |b| b.msg,
        .text_input => |t| t.focus_msg,
        .checkbox => |cb| cb.msg,
        .radio => |r| r.msg,
        .slider => |s| s.grab_msg,
        else => null,
    };
}

/// Find the cmd index whose interactive leaf carries `msg`, comparing by
/// value (`std.meta.eql`). Returns the first match in buffer order, or
/// null if no interactive leaf emits that Msg this frame.
///
/// This is the stable alternative to "the Nth text_input": the app names
/// a field by the Msg its focus click dispatches (e.g. the value it set
/// `Model.focused` from), and this maps that Msg back to a cmd index
/// regardless of how many widgets sit before it or whether earlier
/// widgets are conditionally emitted. Msgs are data (HARDLINE §3), so
/// keying focus off a Msg value introduces no widget-identity hashing —
/// it's the same value the cmd already carries.
///
/// `msg` is taken as `anytype` so callers pass a plain `Msg` value; it
/// must be the same `Msg` the cmd buffer was built over.
pub fn indexOfFocusMsg(cmds: anytype, msg: anytype) ?usize {
    for (cmds, 0..) |c, i| {
        if (activationMsg(c)) |m| {
            if (std.meta.eql(m, msg)) return i;
        }
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

test "indexOfFocusMsg maps a Msg value back to its cmd index" {
    const testing = std.testing;
    const Msg = union(enum) { focus_name, focus_email, submit };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.text("Name"); // idx 0 — not interactive
    cb.textInput(.focus_name, "", 0); // idx 1
    cb.text("Email"); // idx 2
    cb.textInput(.focus_email, "", 0); // idx 3
    cb.button(.submit, "Save"); // idx 4

    try testing.expectEqual(@as(?usize, 1), indexOfFocusMsg(cb.cmds.items, Msg.focus_name));
    try testing.expectEqual(@as(?usize, 3), indexOfFocusMsg(cb.cmds.items, Msg.focus_email));
    try testing.expectEqual(@as(?usize, 4), indexOfFocusMsg(cb.cmds.items, Msg.submit));
}

test "indexOfFocusMsg is stable when earlier widgets are conditionally dropped" {
    const testing = std.testing;
    const Msg = union(enum) { focus_a, focus_b };

    // Frame 1: both inputs present — focus_b is the 2nd text_input.
    var cb1 = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb1.deinit();
    cb1.textInput(.focus_a, "", 0); // idx 0
    cb1.textInput(.focus_b, "", 0); // idx 1
    try testing.expectEqual(@as(?usize, 1), indexOfFocusMsg(cb1.cmds.items, Msg.focus_b));

    // Frame 2: the first input is conditionally not emitted. Ordinal
    // matching ("2nd text_input") would now point at the wrong widget;
    // indexOfFocusMsg still resolves focus_b correctly to its new index.
    var cb2 = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb2.deinit();
    cb2.textInput(.focus_b, "", 0); // idx 0 now
    try testing.expectEqual(@as(?usize, 0), indexOfFocusMsg(cb2.cmds.items, Msg.focus_b));
    try testing.expectEqual(@as(?usize, null), indexOfFocusMsg(cb2.cmds.items, Msg.focus_a));
}

test "indexOfFocusMsg returns null for a Msg no leaf carries" {
    const testing = std.testing;
    const Msg = union(enum) { focus, other };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.focus, "", 0);
    try testing.expectEqual(@as(?usize, null), indexOfFocusMsg(cb.cmds.items, Msg.other));
}
