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
        .push_grid,
        .pop_group,
        .pop_grid,
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
fn focusScope(cmds: anytype) struct { lo: usize, hi: usize, modal: bool } {
    var lo: usize = 0;
    var hi: usize = cmds.len;
    var modal = false;
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
                modal = true;
                open_at = null;
            };
        },
        else => {},
    };
    // An unclosed modal overlay (malformed buffer) scopes to the buffer end.
    if (open_at) |start| {
        lo = start;
        modal = true;
    }
    return .{ .lo = lo, .hi = hi, .modal = modal };
}

/// The cmd range of the topmost modal overlay (its `push_overlay` .. `pop_overlay`),
/// or null when none is open. Keyboard focus is trapped inside it.
pub fn modalScope(cmds: anytype) ?struct { lo: usize, hi: usize } {
    const sc = focusScope(cmds);
    return if (sc.modal) .{ .lo = sc.lo, .hi = sc.hi } else null;
}

/// Find the next focusable cmd index strictly after `current`. If
/// `current` is null (or outside the traversal scope), start at the scope's
/// beginning. Wraps at the end of the scope - the whole buffer, or the
/// topmost modal overlay when one is open (see `focusScope`). Returns null
/// only if the scope has no focusable widgets at all.
pub fn nextFocusable(cmds: anytype, current: ?usize) ?usize {
    return nextWhere(cmds, current, isFocusable);
}

/// `nextFocusable` over every keyboard-operable leaf (`isNavigable`): enabled
/// buttons, checkboxes, radios, sliders, text inputs and text areas. This is
/// the Tab order of the run loop's keyboard navigation.
pub fn nextNavigable(cmds: anytype, current: ?usize) ?usize {
    return nextWhere(cmds, current, isTabStop);
}

/// `prevFocusable` over every keyboard-operable leaf.
pub fn prevNavigable(cmds: anytype, current: ?usize) ?usize {
    return prevWhere(cmds, current, isTabStop);
}

fn nextWhere(cmds: anytype, current: ?usize, comptime pred: anytype) ?usize {
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
        if (pred(cmds[idx])) return idx;
    }
    return null;
}

/// Find the previous focusable cmd index strictly before `current`. If
/// `current` is null (or outside the traversal scope), start from the
/// scope's last index. Wraps at the start of the scope.
pub fn prevFocusable(cmds: anytype, current: ?usize) ?usize {
    return prevWhere(cmds, current, isFocusable);
}

fn prevWhere(cmds: anytype, current: ?usize, comptime pred: anytype) ?usize {
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
        if (pred(cmds[idx])) return idx;
    }
    return null;
}

/// `isNavigable` minus buttons that opted out of Tab (`ButtonCmd.tab_stop = false`).
pub fn isTabStop(c: anytype) bool {
    return switch (c) {
        .button => |b| !b.disabled and b.tab_stop,
        else => isNavigable(c),
    };
}

/// A cmd the keyboard can operate: everything `isFocusable` accepts plus
/// enabled buttons, checkboxes, radios and sliders.
pub fn isNavigable(c: anytype) bool {
    return switch (c) {
        .button => |b| !b.disabled,
        .checkbox, .radio, .slider => true,
        // A clickable canvas (the toggle switch, plots with a click Msg).
        .canvas => |cv| cv.msg != null,
        else => isFocusable(c),
    };
}

/// Buttons of the roving group `idx` belongs to (contiguous `roving != .none` buttons
/// sharing one container): the neighbour `delta` steps away (negative = back), clamped to the
/// group (no wrap); `delta` of `minInt`/`maxInt` jumps to the first / last. Null when `idx` is
/// not a roving button or the group has one member.
pub fn rovingTarget(cmds: anytype, idx: usize, delta: i32) ?usize {
    if (idx >= cmds.len or cmds[idx] != .button or cmds[idx].button.roving == .none) return null;
    var members: [256]usize = undefined;
    var n: usize = 0;
    var self_pos: usize = 0;
    var lo = idx;
    var depth: i32 = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        switch (cmds[i]) {
            .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => depth += 1,
            .push_group, .push_grid, .push_scroll, .push_overlay, .push_virtual_list => {
                if (depth == 0) break;
                depth -= 1;
            },
            .button => |b| if (depth == 0) {
                if (b.roving == .none) break;
                lo = i;
            },
            .radio, .checkbox, .slider, .text_input, .text_area, .canvas => if (depth == 0) break,
            else => {},
        }
    }
    depth = 0;
    i = lo;
    while (i < cmds.len and n < members.len) : (i += 1) {
        switch (cmds[i]) {
            .push_group, .push_grid, .push_scroll, .push_overlay, .push_virtual_list => depth += 1,
            .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => {
                if (depth == 0) break;
                depth -= 1;
            },
            .button => |b| if (depth == 0) {
                if (b.roving == .none) break;
                if (i == idx) self_pos = n;
                members[n] = i;
                n += 1;
            },
            .radio, .checkbox, .slider, .text_input, .text_area, .canvas => if (depth == 0) break,
            else => {},
        }
    }
    if (n < 2) return null;
    const last: i64 = @intCast(n - 1);
    const want: i64 = if (delta == std.math.minInt(i32)) 0 else if (delta == std.math.maxInt(i32)) last else std.math.clamp(@as(i64, @intCast(self_pos)) + delta, 0, last);
    return members[@intCast(want)];
}

/// The next (`forward`) or previous radio of the radio group `idx` belongs to,
/// wrapping inside the group; null when `idx` is not a radio or is alone. A
/// group is the run of radios that share one container (same nesting depth,
/// no other interactive leaf or container boundary in between).
pub fn groupNeighbor(cmds: anytype, idx: usize, forward: bool) ?usize {
    if (idx >= cmds.len or cmds[idx] != .radio) return null;
    var members: [64]usize = undefined;
    var n: usize = 0;
    var self_pos: usize = 0;
    // Scan back to the group's first member.
    var lo = idx;
    var depth: i32 = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        switch (cmds[i]) {
            .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => depth += 1,
            .push_group, .push_grid, .push_scroll, .push_overlay, .push_virtual_list => {
                if (depth == 0) break;
                depth -= 1;
            },
            .radio => if (depth == 0) {
                lo = i;
            },
            .button, .checkbox, .slider, .text_input, .text_area => if (depth == 0) break,
            else => {},
        }
    }
    depth = 0;
    i = lo;
    while (i < cmds.len and n < members.len) : (i += 1) {
        switch (cmds[i]) {
            .push_group, .push_grid, .push_scroll, .push_overlay, .push_virtual_list => depth += 1,
            .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => {
                if (depth == 0) break;
                depth -= 1;
            },
            .radio => if (depth == 0) {
                if (i == idx) self_pos = n;
                members[n] = i;
                n += 1;
            },
            .button, .checkbox, .slider, .text_input, .text_area => if (depth == 0) break,
            else => {},
        }
    }
    if (n < 2) return null;
    return members[if (forward) (self_pos + 1) % n else (self_pos + n - 1) % n];
}

/// True for leaves that own text focus (the app keeps their focus Msg in its
/// Model and typing goes to them); false for the other navigable leaves,
/// whose keyboard focus is the run loop's own.
pub fn isTextLeaf(c: anytype) bool {
    return switch (c) {
        .text_input, .text_area => true,
        else => false,
    };
}

/// The activation/focus Msg an interactive leaf carries, or null for a
/// non-interactive cmd. This is the same leaf set hit-test keys off
/// (`button`, `text_input`, `checkbox`, `radio`, `slider`) — kept in
/// sync so "the Msg this cmd would dispatch" means the same thing to
/// both passes. For a `text_input` that Msg is its `focus_msg`; for a
/// `slider` it's `grab_msg`; for the rest it's `msg`.
pub fn activationMsg(c: anytype) ?@TypeOf(c).MsgT {
    return switch (c) {
        .button => |b| b.msg,
        .text_input => |t| t.focus_msg,
        .text_area => |t| t.focus_msg,
        .checkbox => |cb| cb.msg,
        .radio => |r| r.msg,
        .slider => |s| s.grab_msg,
        .canvas => |cv| cv.msg,
        .push_group,
        .push_grid,
        .pop_group,
        .pop_grid,
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












