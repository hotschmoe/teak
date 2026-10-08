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
        // A disabled input is skipped by Tab traversal, mirroring how
        // hit-test refuses to focus it on click.
        .text_input => |t| !t.disabled,
        .text_area => |t| !t.disabled,
        .push_group,
        .pop_group,
        .push_scroll,
        .pop_scroll,
        .push_overlay,
        .pop_overlay,
        .push_virtual_list,
        .pop_virtual_list,
        .text,
        .rich_text,
        .image,
        .divider,
        .button,
        .checkbox,
        .radio,
        .slider,
        .canvas,
        .scene3d,
        => false,
    };
}

/// Half-open cmd range Tab traversal may visit: the whole buffer, or - when a
/// modal overlay is open - only that overlay's contents (the focus trap of a
/// dialog / menu: Tab never lands on a field hidden behind the backdrop).
/// With several modal overlays the last one (topmost) wins.
fn focusScope(cmds: anytype) struct { lo: usize, hi: usize } {
    var lo: usize = 0;
    var hi: usize = cmds.len;
    var open_at: ?usize = null;
    var depth: usize = 0;
    for (cmds, 0..) |c, i| switch (c) {
        .push_overlay => |o| {
            if (depth == 0) open_at = if (o.modal) i else null;
            depth += 1;
        },
        .pop_overlay => {
            if (depth > 0) depth -= 1;
            if (depth == 0) if (open_at) |start| {
                lo = start;
                hi = i + 1;
                open_at = null;
            };
        },
        else => {},
    };
    // An unclosed modal overlay (malformed buffer) scopes to the buffer end.
    if (open_at) |start| lo = start;
    return .{ .lo = lo, .hi = hi };
}

/// Find the next focusable cmd index strictly after `current`. If
/// `current` is null (or outside the traversal scope), start at the scope's
/// beginning. Wraps at the end of the scope - the whole buffer, or the
/// topmost modal overlay when one is open (see `focusScope`). Returns null
/// only if the scope has no focusable widgets at all.
pub fn nextFocusable(cmds: anytype, current: ?usize) ?usize {
    const n = cmds.len;
    if (n == 0) return null;
    const sc = focusScope(cmds);
    const len = sc.hi - sc.lo;
    if (len == 0) return null;

    const start: usize = if (current) |c|
        (if (c >= sc.lo and c < sc.hi) c + 1 - sc.lo else 0)
    else
        0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const idx = sc.lo + (start + i) % len;
        if (isFocusable(cmds[idx])) return idx;
    }
    return null;
}

/// Find the previous focusable cmd index strictly before `current`. If
/// `current` is null (or outside the traversal scope), start from the
/// scope's last index. Wraps at the start of the scope.
pub fn prevFocusable(cmds: anytype, current: ?usize) ?usize {
    const n = cmds.len;
    if (n == 0) return null;
    const sc = focusScope(cmds);
    const len = sc.hi - sc.lo;
    if (len == 0) return null;

    const start: usize = if (current) |c|
        (if (c >= sc.lo and c < sc.hi) (if (c == sc.lo) len - 1 else c - sc.lo - 1) else len - 1)
    else
        len - 1;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const off = if (start >= i) start - i else start + len - i;
        const idx = sc.lo + off;
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
        .text_area => |t| t.focus_msg,
        .checkbox => |cb| cb.msg,
        .radio => |r| r.msg,
        .slider => |s| s.grab_msg,
        .push_group,
        .pop_group,
        .push_scroll,
        .pop_scroll,
        .push_overlay,
        .pop_overlay,
        .push_virtual_list,
        .pop_virtual_list,
        .text,
        .rich_text,
        .image,
        .divider,
        .canvas,
        .scene3d,
        => null,
    };
}

/// The activation/focus Msg of the focusable leaf at `index`, or null if
/// that cmd is not an interactive leaf. The inverse of `indexOfFocusMsg`:
/// Tab traversal lands on an index via `nextFocusable`/`prevFocusable`,
/// then asks this for the Msg to dispatch so the app moves its focus
/// field (same Msg a click on that widget would fire).
pub fn focusMsgAt(cmds: anytype, index: usize) ?std.meta.Elem(@TypeOf(cmds)).MsgT {
    if (index >= cmds.len) return null;
    return activationMsg(cmds[index]);
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

test "a modal overlay traps Tab traversal inside itself" {
    const testing = std.testing;
    const Msg = union(enum) { under, in1, in2, close };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.under, "", 0); // idx 0: behind the dialog
    cb.pushOverlay(.{ .modal = true, .backdrop_msg = .close }); // idx 1
    cb.textInput(.in1, "", 0); // idx 2
    cb.button(.close, "OK"); // idx 3
    cb.textInput(.in2, "", 0); // idx 4
    cb.popOverlay(); // idx 5

    // From outside the scope, traversal enters the overlay (never idx 0).
    try testing.expectEqual(@as(?usize, 2), nextFocusable(cb.cmds.items, 0));
    try testing.expectEqual(@as(?usize, 4), prevFocusable(cb.cmds.items, 0));
    try testing.expectEqual(@as(?usize, 4), nextFocusable(cb.cmds.items, 2));
    // ...and wraps inside it rather than escaping to idx 0.
    try testing.expectEqual(@as(?usize, 2), nextFocusable(cb.cmds.items, 4));
    try testing.expectEqual(@as(?usize, 4), prevFocusable(cb.cmds.items, 2));
}

test "a non-modal overlay does not trap traversal" {
    const testing = std.testing;
    const Msg = union(enum) { a, b };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.textInput(.a, "", 0); // idx 0
    cb.pushOverlay(.{}); // tooltip-like
    cb.text("tip");
    cb.popOverlay();
    cb.textInput(.b, "", 0); // idx 4
    try testing.expectEqual(@as(?usize, 4), nextFocusable(cb.cmds.items, 0));
    try testing.expectEqual(@as(?usize, 0), nextFocusable(cb.cmds.items, 4));
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

test "focusMsgAt returns the leaf's focus Msg and round-trips with indexOfFocusMsg" {
    const testing = std.testing;
    const Msg = union(enum) { focus_a, focus_b };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.focus_a, "", 0); // idx 0
    cb.text("between"); // idx 1 — not focusable
    cb.textInput(.focus_b, "", 0); // idx 2

    try testing.expectEqual(@as(?Msg, Msg.focus_a), focusMsgAt(cb.cmds.items, 0));
    try testing.expectEqual(@as(?Msg, Msg.focus_b), focusMsgAt(cb.cmds.items, 2));
    try testing.expectEqual(@as(?Msg, null), focusMsgAt(cb.cmds.items, 1)); // plain text
    try testing.expectEqual(@as(?Msg, null), focusMsgAt(cb.cmds.items, 99)); // out of range

    // Round-trip: index -> msg -> index.
    const idx = indexOfFocusMsg(cb.cmds.items, Msg.focus_b).?;
    try testing.expectEqual(@as(?Msg, Msg.focus_b), focusMsgAt(cb.cmds.items, idx));
}

test "Tab traversal skips a disabled input" {
    const testing = std.testing;
    const Msg = union(enum) { a, b, c };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.a, "", 0); // idx 0 — focusable
    cb.textInputDisabled(.b, "", 0); // idx 1 — disabled, skipped
    cb.textInput(.c, "", 0); // idx 2 — focusable

    // From the first input, next focusable jumps over the disabled one.
    try testing.expectEqual(@as(?usize, 2), nextFocusable(cb.cmds.items, 0));
    // And back-wraps the same way.
    try testing.expectEqual(@as(?usize, 0), prevFocusable(cb.cmds.items, 2));
}

test "text_area is focusable (Tab traversal, focus Msg) unless disabled" {
    const testing = std.testing;
    const Msg = union(enum) { a, b, c };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{});
    cb.textArea(.{ .focus_msg = .a, .id = 1, .content = "" });
    cb.textArea(.{ .focus_msg = .b, .id = 2, .content = "", .disabled = true });
    cb.textInput(.c, "", 0);
    cb.popGroup();
    const cmds = cb.cmds.items;
    try testing.expectEqual(@as(?usize, 1), nextFocusable(cmds, null));
    try testing.expectEqual(@as(?usize, 3), nextFocusable(cmds, 1)); // skips the disabled area
    try testing.expectEqual(@as(?Msg, Msg.a), focusMsgAt(cmds, 1));
    try testing.expectEqual(@as(?usize, 1), indexOfFocusMsg(cmds, Msg.a));
}
