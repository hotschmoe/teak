//! Tab strip: a row of tabs where exactly one is selected, with keyboard
//! navigation. Zero new Cmd variants: one `button` per tab, styled so the
//! selected tab merges with the panel below it, followed by a divider.
//!
//! The strip owns only the selection (`selected`) and whether it has keyboard
//! focus (`focused`); the tab labels are the app's (passed to `viewWith`,
//! like Dropdown options) and so is the content below, which the app emits
//! for `model.selected`:
//!
//! ```zig
//! Tabs.viewWith(&m.tabs, cb, &.{ "General", "Network", "About" }, msgs, .{});
//! switch (m.tabs.selected) {
//!     0 => general(m, cb),
//!     1 => network(m, cb),
//!     else => about(cb),
//! }
//! ```
//!
//! Keyboard: clicking a tab focuses the strip; then Left/Right move the
//! selection (wrapping), Home/End jump to the ends. Route keys with
//! `keyMsg` from the app's `keySpecialMsg`; Escape (or clicking elsewhere,
//! per app policy) sends `.blur`.

const std = @import("std");
const cmd = @import("../cmd.zig");
const component = @import("../component.zig");
const keys = @import("../../input/keys.zig");

pub const Move = enum { prev, next, first, last };

pub const Model = struct {
    selected: usize = 0,
    /// The strip has keyboard focus (set by clicking a tab).
    focused: bool = false,
};

pub const Msg = union(enum) {
    /// Select tab `i` and focus the strip (fired by a tab button).
    select: usize,
    /// Move the selection; `count` is the number of tabs (build with `moveMsg`).
    move: struct { move: Move, count: usize },
    /// Give up keyboard focus.
    blur,
};

pub const ViewOpts = struct {
    /// Minimum tab width in px (tabs grow to fit longer labels).
    min_width: f32 = 90,
    height: f32 = 32,
    /// Draw the rule under the strip.
    rule: bool = true,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .select => |i| {
            model.selected = i;
            model.focused = true;
        },
        .move => |mv| {
            if (mv.count == 0) return;
            const cur = @min(model.selected, mv.count - 1);
            model.selected = switch (mv.move) {
                .prev => if (cur == 0) mv.count - 1 else cur - 1,
                .next => (cur + 1) % mv.count,
                .first => 0,
                .last => mv.count - 1,
            };
        },
        .blur => model.focused = false,
    }
}

pub fn moveMsg(move: Move, count: usize) Msg {
    return .{ .move = .{ .move = move, .count = count } };
}

/// The Msg for a key press, or null when the strip is unfocused or the key is
/// not a tab key. Route from `keySpecialMsg`.
pub fn keyMsg(model: *const Model, key: keys.SpecialKey, count: usize) ?Msg {
    if (!model.focused) return null;
    return switch (key) {
        .left => moveMsg(.prev, count),
        .right => moveMsg(.next, count),
        .home => moveMsg(.first, count),
        .end => moveMsg(.last, count),
        .escape => .blur,
        else => null,
    };
}

/// Component-contract view (the strip needs labels; use `viewWith`).
pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
    _ = model;
    _ = cb;
    _ = msgs;
}

/// The strip. `msgs.selectMsg(i)` builds the app Msg for selecting tab `i`
/// (a comptime fn, exactly like `Dropdown.viewWith`).
pub fn viewWith(
    model: *const Model,
    cb: anytype,
    labels: []const []const u8,
    msgs: anytype,
    opts: ViewOpts,
) void {
    const pal = cb.theme.palette;
    const sel = if (labels.len == 0) 0 else @min(model.selected, labels.len - 1);
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 2, .align_cross = .end });
    for (labels, 0..) |label, i| {
        var st = cb.theme.button;
        st.min_width = opts.min_width;
        st.height = opts.height;
        st.label_align = .center;
        st.border_width = 1;
        if (i == sel) {
            st.bg = pal.bg_panel;
            st.hover_bg = pal.bg_panel;
            st.fg = pal.fg;
            st.border = if (model.focused) pal.accent else pal.fg_muted;
        } else {
            st.bg = pal.bg_sunken;
            st.fg = pal.fg_muted;
            st.border = pal.border;
        }
        cb.buttonStyled(msgs.selectMsg(i), label, st);
    }
    cb.popGroup();
    if (opts.rule) cb.divider();
    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text = @import("../text.zig");

const AppMsg = union(enum) { tab: usize };
const App = struct {
    fn pick(i: usize) AppMsg {
        return .{ .tab = i };
    }
    const msgs = .{ .selectMsg = pick };
};

const tab_labels = [_][]const u8{ "General", "Network", "About" };





