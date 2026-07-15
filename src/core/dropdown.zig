const std = @import("std");
const cmd = @import("cmd.zig");
const component = @import("component.zig");

// ── Dropdown / Select ────────────────────────────────────────────────
//
// A select widget built ENTIRELY from existing primitives — there is no
// new Cmd variant. The closed state is a single `button`; the open list
// is the same modal-overlay pattern the help dialog uses (pushOverlay +
// modal + backdrop_msg, an inner vertical pushGroup, one button per
// option, popGroup, popOverlay). modal+backdrop_msg gives
// click-outside-to-close for free via the hit-test pass.
//
// Motivation (consumer issue #2): radio rows stop scaling past ~10
// options, and apps need many pickers (species lists, rebar sizes, steel
// sections, code editions, exposure categories). A dropdown collapses an
// arbitrarily long option set to one row when closed.
//
// HARDLINE shape:
//   • The Dropdown owns ONLY transient-free state: `open` + `selected`
//     (an index). All state lives in the composed Model, per §1.
//   • The OPTION LABELS are owned by the app, not the component. They are
//     passed to `viewWith` at call time — exactly how counter_greeter
//     hands a custom msgs struct to greeter.view. The component never
//     stores a slice it didn't allocate.
//   • Cmds carry DATA, never fn-pointers (§3). The `selectMsg` below is a
//     comptime *parameter* to a view helper — it builds a Msg *value* that
//     is stored on the button Cmd. The function itself is never a field on
//     any Cmd, so the data-only invariant holds.
//
// Two view entry points:
//   • `view(model, cb, msgs)` — the canonical 3-arg signature the
//     `validateComponent` contract + the generated composed view require.
//     With no options slice available it can only draw the CLOSED button
//     (labelled PLACEHOLDER). It exists so a Dropdown composes through
//     `Components(.{...})` like any other component.
//   • `viewWith(model, cb, options, msgs, opts)` — the RICHER view the app
//     calls EXPLICITLY (the generated path passes only 3 args and has no
//     slot for `options`/`opts`). This is what apps actually use; it draws
//     the closed button labelled with the real selection and, when open,
//     the overlay list. Same hand-call pattern counter_greeter uses to
//     drive greeter.view with a bespoke msgs struct.

/// Height of a single open-list option row, in pixels. Matches
/// `LayoutEngine.BUTTON_HEIGHT` (the option buttons are plain buttons, so
/// every row is exactly this tall regardless of label font). Scroll math
/// — viewport sizing, `maxScroll`, and scroll-to-reveal — is expressed in
/// multiples of this constant so it stays in lock-step with the rects the
/// layout pass actually produces.
pub const ITEM_HEIGHT: f32 = 36;

/// Anchor + sizing for the open list overlay.
pub const DropdownViewOpts = struct {
    /// Window-absolute top-left where the open list should appear. The app
    /// typically passes the previous frame's rect of the closed button
    /// (its bottom-left), matching the overlay positioning pattern used
    /// elsewhere in the framework.
    list_x: f32 = 0,
    list_y: f32 = 0,
    list_width: f32 = 200,
    /// Forced height of the open list overlay when it does NOT scroll
    /// (i.e. `max_visible == 0`, or the option count fits). This is the
    /// overlay's `height`, which is a forced size — render and hit-test
    /// both clip to it, so option rows past `list_max_height` are
    /// invisible AND unclickable. Set `max_visible` for a taller list
    /// that scrolls its overflow into view instead of clipping it.
    list_max_height: f32 = 320,
    /// Max option rows visible before the open list scrolls. `0` =
    /// unlimited (the pre-scroll behavior: the whole list draws in one
    /// group). When `options.len > max_visible`, the open list is wrapped
    /// in a `push_scroll` whose viewport is `max_visible * ITEM_HEIGHT`
    /// tall and scrolled by `Model.scroll_offset`. Wheel + keyboard
    /// (`scrollByMsg` / `moveHighlightMsg`) drive the offset; the
    /// highlighted row is kept revealed on keyboard moves.
    max_visible: usize = 0,
};

/// Placeholder shown when there is no valid selection (empty options or a
/// `selected` index that is out of range).
pub const PLACEHOLDER = "Select\u{2026}";

/// A dropdown/select holding `selected` as an index into the app-owned
/// options slice. `cap` documents the intended maximum option count for
/// the call site; it is not enforced on the slice (the app owns the
/// options) but keeps the type self-describing alongside its siblings
/// (e.g. `Dropdown(64)` for a long species list).
pub fn Dropdown(comptime cap: usize) type {
    return struct {
        /// Documented intended option capacity. Not a hard limit on the
        /// slice the app passes; kept for self-documentation at call sites.
        pub const capacity = cap;

        pub const Model = struct {
            /// Whether the option list is currently shown.
            open: bool = false,
            /// Index into the options slice the app passes to `viewWith`.
            selected: usize = 0,
            /// Vertical scroll offset (px) of the open list. Only
            /// meaningful when the list scrolls (`options.len >
            /// opts.max_visible`). All widget scroll state lives here on
            /// Model per HARDLINE §1 — it is mutated ONLY through
            /// `.scroll_by` / `.highlight` in `update`, and clamped for
            /// display in `viewWith`.
            scroll_offset: f32 = 0,
            /// Keyboard-highlighted option index (the arrow-key cursor).
            /// Rendered with a highlight background; `.select` /click
            /// commits it. Reset to `selected` when the list opens.
            highlighted: usize = 0,
        };

        /// Direction of a keyboard highlight move.
        pub const Move = enum { prev, next, first, last };

        /// Payload for `.scroll_by`: a wheel delta plus the maximum valid
        /// offset (so `update` can clamp without knowing the option
        /// count). Build it with `scrollByMsg`.
        pub const ScrollBy = struct {
            delta: f32,
            max: f32,
        };

        /// Payload for `.highlight`: which way to move the keyboard cursor
        /// plus the geometry `update` needs to clamp + scroll-to-reveal
        /// (the option count and the viewport row cap). Build it with
        /// `moveHighlightMsg`.
        pub const HighlightMove = struct {
            move: Move,
            /// `options.len` — upper clamp for `.next` / `.last`.
            count: usize,
            /// `opts.max_visible` — viewport rows for scroll-to-reveal
            /// (`0` = the list does not scroll, so reveal is a no-op).
            max_visible: usize,
        };

        pub const Msg = union(enum) {
            /// Open/close the list — fired by the closed-state button.
            toggle,
            /// Close without changing the selection — fired by the modal
            /// backdrop (click-outside).
            close,
            /// Choose option `i` — fired by an open-list item button.
            select: usize,
            /// Wheel the open list. Build with `scrollByMsg` so `.max` is
            /// filled from the option count.
            scroll_by: ScrollBy,
            /// Move the keyboard highlight, keeping it revealed. Build with
            /// `moveHighlightMsg`.
            highlight: HighlightMove,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .toggle => {
                    model.open = !model.open;
                    // Opening parks the keyboard cursor on the current
                    // selection. Reveal is deferred to the first keyboard
                    // move (`.toggle` carries no viewport geometry); the
                    // display clamp in `viewWith` keeps the offset valid.
                    if (model.open) model.highlighted = model.selected;
                },
                .close => model.open = false,
                .select => |i| {
                    model.selected = i;
                    model.highlighted = i;
                    model.open = false;
                },
                .scroll_by => |s| {
                    model.scroll_offset = std.math.clamp(
                        model.scroll_offset + s.delta,
                        0,
                        @max(0, s.max),
                    );
                },
                .highlight => |h| {
                    model.highlighted = moveIndex(model.highlighted, h.move, h.count);
                    model.scroll_offset = revealOffset(
                        model.scroll_offset,
                        model.highlighted,
                        h.max_visible,
                    );
                },
            }
        }

        // ── Scroll helpers (pure) ──────────────────────────────────────

        /// New highlight index after `move`, clamped to `[0, count)`.
        fn moveIndex(cur: usize, move: Move, count: usize) usize {
            if (count == 0) return 0;
            // Clamp a stale / out-of-range cursor into `[0, count)` before
            // moving, so a shrunken option list can't leave `.prev` one past
            // the (now smaller) end — which would blow `revealOffset` past
            // `maxScroll`.
            const c = @min(cur, count - 1);
            return switch (move) {
                .prev => if (c == 0) 0 else c - 1,
                .next => if (c + 1 >= count) count - 1 else c + 1,
                .first => 0,
                .last => count - 1,
            };
        }

        /// The largest valid scroll offset for `options_len` rows given a
        /// `max_visible`-row viewport. `0` when the list doesn't scroll.
        pub fn maxScroll(options_len: usize, max_visible: usize) f32 {
            if (max_visible == 0 or options_len <= max_visible) return 0;
            return @as(f32, @floatFromInt(options_len - max_visible)) * ITEM_HEIGHT;
        }

        /// Smallest adjustment to `scroll` that brings row `i` fully inside
        /// a `max_visible`-row viewport. Self-bounding: for any in-range
        /// `i` the result stays within `[0, maxScroll]`, so scroll-to-
        /// reveal never needs the option count.
        fn revealOffset(scroll: f32, i: usize, max_visible: usize) f32 {
            if (max_visible == 0) return scroll;
            const viewport = @as(f32, @floatFromInt(max_visible)) * ITEM_HEIGHT;
            const top = @as(f32, @floatFromInt(i)) * ITEM_HEIGHT;
            const bottom = top + ITEM_HEIGHT;
            var new = scroll;
            if (top < new) new = top;
            if (bottom > new + viewport) new = bottom - viewport;
            return @max(0, new);
        }

        /// True when the open list scrolls for this option count + opts.
        pub fn scrolls(options_len: usize, opts: DropdownViewOpts) bool {
            return opts.max_visible > 0 and options_len > opts.max_visible;
        }

        /// Build a `.scroll_by` Msg for a wheel delta. The app calls this
        /// from its `wheelMsg` hook (it owns the options slice, so it can
        /// pass `options.len`) and wraps the result into its AppMsg, the
        /// same way it wraps `selectMsg`.
        pub fn scrollByMsg(delta: f32, options_len: usize, opts: DropdownViewOpts) Msg {
            return .{ .scroll_by = .{
                .delta = delta,
                .max = maxScroll(options_len, opts.max_visible),
            } };
        }

        /// Build a `.highlight` Msg for a keyboard move. The app calls this
        /// from its `keySpecialMsg` hook and wraps the result into AppMsg.
        pub fn moveHighlightMsg(move: Move, options_len: usize, opts: DropdownViewOpts) Msg {
            return .{ .highlight = .{
                .move = move,
                .count = options_len,
                .max_visible = opts.max_visible,
            } };
        }

        /// Canonical 3-arg view satisfying the component contract + the
        /// generated composed view. Without an options slice it can only
        /// draw the CLOSED button (labelled PLACEHOLDER, firing toggle).
        /// Apps that want the real options + open list call `viewWith`.
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            _ = model;
            cb.button(msgs.toggle, PLACEHOLDER);
        }

        /// EXPLICIT view — called by the app, not by the generated composed
        /// view (which lacks a slot for `options`/`opts`).
        ///
        /// `msgs` is a struct carrying the composed AppMsg wiring:
        ///   • `.toggle`  — AppMsg fired by the closed button.
        ///   • `.close`   — AppMsg fired by the modal backdrop.
        ///   • `.selectMsg` — a COMPTIME `fn(usize) AppMsg` the app supplies
        ///     to build the per-index select message, e.g.
        ///       `fn pick(i: usize) AppMsg {
        ///            return .{ .picker = .{ .select = i } };
        ///        }`
        ///     The fn produces a Msg *value* stored on the button Cmd; it is
        ///     never stored on a Cmd itself, so Cmds stay pure data.
        ///
        /// CLOSED: emits exactly one button labelled with the current
        /// selection (or PLACEHOLDER when empty / out of range).
        /// OPEN: also emits the overlay list described above.
        pub fn viewWith(
            model: *const Model,
            cb: anytype,
            options: []const []const u8,
            msgs: anytype,
            opts: DropdownViewOpts,
        ) void {
            // Closed-state button: always present. Label is the selected
            // option, guarded for empty / out-of-range slices.
            const label: []const u8 = if (model.selected < options.len)
                options[model.selected]
            else
                PLACEHOLDER;
            cb.button(msgs.toggle, label);

            if (!model.open) return;

            if (scrolls(options.len, opts)) {
                // Scrolling list: the option buttons live inside a
                // push_scroll nested in the modal overlay. push_scroll
                // works unchanged inside push_overlay — layout gives the
                // scroll a normal child cursor, and hit-test/render keep
                // an independent clip stack intersected with the overlay
                // clip, so rows past the viewport are clipped in both
                // passes. No new mechanism, just the existing scroll +
                // overlay hatches composed.
                const viewport_h = @as(f32, @floatFromInt(opts.max_visible)) * ITEM_HEIGHT;
                const scroll_y = std.math.clamp(
                    model.scroll_offset,
                    0,
                    maxScroll(options.len, opts.max_visible),
                );
                cb.pushOverlay(.{
                    .x = opts.list_x,
                    .y = opts.list_y,
                    .width = opts.list_width,
                    .height = viewport_h,
                    .modal = true,
                    .backdrop_msg = msgs.close,
                    // Fill the whole viewport rect so the scrolled list is
                    // opaque — otherwise a click landing in the (transparent)
                    // dead zone right of a short row would fall through to the
                    // modal backdrop and close instead of select.
                    .backdrop = cb.theme.panel_bg,
                    .padding = 0,
                    .gap = 0,
                });
                cb.pushScroll(.{
                    .direction = .vertical,
                    .width = opts.list_width,
                    .height = viewport_h,
                    .padding = 0,
                    .gap = 0,
                    .scroll_y = scroll_y,
                });
                emitOptions(model, cb, options, msgs, opts.list_width);
                cb.popScroll();
                cb.popOverlay();
            } else {
                // Non-scrolling list: the modal-overlay pattern (see help
                // dialog in counter_greeter). modal + backdrop_msg =>
                // click-outside closes.
                cb.pushOverlay(.{
                    .x = opts.list_x,
                    .y = opts.list_y,
                    .width = opts.list_width,
                    .height = opts.list_max_height,
                    .modal = true,
                    .backdrop_msg = msgs.close,
                    .padding = 0,
                    .gap = 0,
                });
                // Zero padding/gap on the panel so each option row can span
                // the full list width — a click anywhere across a row (not
                // just over the label text) lands on the option button, never
                // on the modal backdrop behind it.
                cb.pushGroup(.{
                    .direction = .vertical,
                    .bg = cb.theme.panel_bg,
                    .padding = 0,
                    .gap = 0,
                });
                emitOptions(model, cb, options, msgs, opts.list_width);
                cb.popGroup();
                cb.popOverlay();
            }
        }

        /// Emit one button per option, giving the keyboard-highlighted row
        /// a distinct background so the arrow-key cursor is visible. The
        /// highlight is presentation derived from `model.highlighted` — the
        /// button still carries `selectMsg(i)`, so hit-test resolves to the
        /// true option index regardless of scroll offset or highlight.
        fn emitOptions(
            model: *const Model,
            cb: anytype,
            options: []const []const u8,
            msgs: anytype,
            row_width: f32,
        ) void {
            for (options, 0..) |opt, i| {
                // Force every row to the full list width so the whole row is
                // a clickable target (see `ButtonStyle.min_width`).
                var style = cb.theme.button;
                style.min_width = row_width;
                if (i == model.highlighted) style.bg = cb.theme.button.hover_bg;
                cb.buttonStyled(msgs.selectMsg(i), opt, style);
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "validateComponent: Dropdown satisfies the component contract" {
    component.validateComponent(Dropdown(8));
}

test "update: toggle / close / select transitions" {
    const D = Dropdown(8);
    var model: D.Model = .{};

    // toggle opens, toggle again closes.
    D.update(&model, .toggle);
    try std.testing.expect(model.open);
    D.update(&model, .toggle);
    try std.testing.expect(!model.open);

    // select sets the index AND closes (even from open).
    D.update(&model, .toggle);
    try std.testing.expect(model.open);
    D.update(&model, .{ .select = 3 });
    try std.testing.expectEqual(@as(usize, 3), model.selected);
    try std.testing.expect(!model.open);

    // close closes without touching selection.
    D.update(&model, .toggle);
    D.update(&model, .close);
    try std.testing.expect(!model.open);
    try std.testing.expectEqual(@as(usize, 3), model.selected);
}

// A tiny AppMsg used to exercise the explicit view + selectMsg convention.
const TestApp = struct {
    pub const Msg = union(enum) {
        toggle,
        close,
        select: usize,
    };
    fn pick(i: usize) Msg {
        return .{ .select = i };
    }
    const msgs = .{
        .toggle = Msg.toggle,
        .close = Msg.close,
        .selectMsg = pick,
    };
};

const test_options = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta" };

test "viewWith (closed): one button labelled with the selection, no overlay" {
    const testing = std.testing;
    const D = Dropdown(8);

    var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
    defer cb.deinit();

    var model: D.Model = .{ .selected = 2 }; // "Gamma"
    D.viewWith(&model, &cb, &test_options, TestApp.msgs, .{});

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    try testing.expect(cb.cmds.items[0] == .button);
    try testing.expectEqualStrings("Gamma", cb.cmds.items[0].button.label);
    try testing.expectEqual(TestApp.Msg.toggle, cb.cmds.items[0].button.msg);
}

test "viewWith (open): button + overlay list with per-option select msgs" {
    const testing = std.testing;
    const D = Dropdown(8);

    var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
    defer cb.deinit();

    var model: D.Model = .{ .open = true, .selected = 0 };
    D.viewWith(&model, &cb, &test_options, TestApp.msgs, .{ .list_x = 10, .list_y = 40 });

    const items = cb.cmds.items;
    // 1 closed button + push_overlay + push_group + 4 option buttons
    //   + pop_group + pop_overlay = 9 cmds.
    try testing.expectEqual(@as(usize, 9), items.len);

    // [0] closed button.
    try testing.expect(items[0] == .button);
    try testing.expectEqual(TestApp.Msg.toggle, items[0].button.msg);

    // [1] overlay: modal, backdrop fires the close msg. The push_overlay
    // payload IS the OverlayStyle (no `.style` wrapper).
    try testing.expect(items[1] == .push_overlay);
    try testing.expect(items[1].push_overlay.modal);
    try testing.expectEqual(
        @as(?TestApp.Msg, TestApp.Msg.close),
        items[1].push_overlay.backdrop_msg,
    );

    // [2] inner group.
    try testing.expect(items[2] == .push_group);

    // [3..7) one option button each, carrying selectMsg(i).
    inline for (0..4) |i| {
        const c = items[3 + i];
        try testing.expect(c == .button);
        try testing.expectEqualStrings(test_options[i], c.button.label);
        try testing.expectEqual(TestApp.pick(i), c.button.msg);
    }

    // [7] pop_group, [8] pop_overlay.
    try testing.expect(items[7] == .pop_group);
    try testing.expect(items[8] == .pop_overlay);
}

test "compose: Dropdown routes through Components and select closes" {
    const App = component.Components(.{ .picker = Dropdown(8) }, null);

    var model: App.Model = .{};
    // Open it first so we can prove select also closes via the composed path.
    App.update(&model, .{ .picker = .toggle });
    try std.testing.expect(model.picker.open);

    App.update(&model, .{ .picker = .{ .select = 2 } });
    try std.testing.expectEqual(@as(usize, 2), model.picker.selected);
    try std.testing.expect(!model.picker.open);

    // Explicitly view through the composed AppMsg, hand-building msgs the
    // way counter_greeter hand-builds greeter's — including a selectMsg
    // closure that wraps the local Dropdown.Msg into the composed AppMsg.
    const testing = std.testing;
    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    const Picker = Dropdown(8);
    const pick = struct {
        fn f(i: usize) App.Msg {
            return .{ .picker = .{ .select = i } };
        }
    }.f;
    const composed_msgs = .{
        .toggle = App.Msg{ .picker = .toggle },
        .close = App.Msg{ .picker = .close },
        .selectMsg = pick,
    };

    model.picker.open = true;
    Picker.viewWith(&model.picker, &cb, &test_options, composed_msgs, .{});

    // Closed button carries the composed toggle; an option button carries
    // the composed select.
    try testing.expectEqual(App.Msg{ .picker = .toggle }, cb.cmds.items[0].button.msg);
    try testing.expectEqual(App.Msg{ .picker = .{ .select = 1 } }, cb.cmds.items[4].button.msg);
}

// ── Scrolling open list ─────────────────────────────────────────────

const layout = @import("../layout/engine.zig");
const hit_test = @import("../input/hit_test.zig");
const text_mod = @import("text.zig");

const long_options = [_][]const u8{
    "o0", "o1", "o2", "o3", "o4", "o5", "o6", "o7", "o8", "o9",
};

test "viewWith (scrolling): long list wraps options in a push_scroll" {
    const testing = std.testing;
    const D = Dropdown(64);

    var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
    defer cb.deinit();

    var model: D.Model = .{ .open = true, .selected = 0 };
    D.viewWith(&model, &cb, &long_options, TestApp.msgs, .{
        .list_x = 10,
        .list_y = 40,
        .list_width = 200,
        .max_visible = 4,
    });

    const items = cb.cmds.items;
    // closed button + push_overlay + push_scroll + 10 buttons + pop_scroll
    //   + pop_overlay = 15.
    try testing.expectEqual(@as(usize, 15), items.len);
    try testing.expect(items[1] == .push_overlay);
    try testing.expect(items[2] == .push_scroll);
    // Viewport height = max_visible * ITEM_HEIGHT.
    try testing.expectEqual(@as(f32, 4 * ITEM_HEIGHT), items[2].push_scroll.height);
    try testing.expectEqual(@as(f32, 4 * ITEM_HEIGHT), items[1].push_overlay.height);
    try testing.expect(items[13] == .pop_scroll);
    try testing.expect(items[14] == .pop_overlay);
    // Each option still carries its own select msg.
    inline for (0..10) |i| {
        try testing.expect(items[3 + i] == .button);
        try testing.expectEqual(TestApp.pick(i), items[3 + i].button.msg);
    }
}

test "viewWith (short list): does not scroll even with max_visible set" {
    const testing = std.testing;
    const D = Dropdown(64);

    var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
    defer cb.deinit();

    var model: D.Model = .{ .open = true, .selected = 0 };
    // 4 options, room for 8 → the non-scroll group path.
    D.viewWith(&model, &cb, &test_options, TestApp.msgs, .{ .max_visible = 8 });

    const items = cb.cmds.items;
    try testing.expectEqual(@as(usize, 9), items.len);
    try testing.expect(items[2] == .push_group);
    for (items) |c| try testing.expect(c != .push_scroll);
}

test "scroll math: maxScroll + scroll_by clamps to [0, max]" {
    const testing = std.testing;
    const D = Dropdown(64);
    const opts: DropdownViewOpts = .{ .max_visible = 4 };

    // 10 rows, 4 visible → 6 rows of overflow.
    try testing.expectEqual(@as(f32, 6 * ITEM_HEIGHT), D.maxScroll(10, 4));
    // Short list never scrolls.
    try testing.expectEqual(@as(f32, 0), D.maxScroll(3, 4));
    try testing.expectEqual(@as(f32, 0), D.maxScroll(10, 0));

    var model: D.Model = .{ .open = true };
    // Wheel far past the end clamps to maxScroll.
    D.update(&model, D.scrollByMsg(10_000, long_options.len, opts));
    try testing.expectEqual(@as(f32, 6 * ITEM_HEIGHT), model.scroll_offset);
    // Wheel far past the start clamps to 0.
    D.update(&model, D.scrollByMsg(-10_000, long_options.len, opts));
    try testing.expectEqual(@as(f32, 0), model.scroll_offset);
}

test "scroll-to-reveal: keyboard moves keep the highlighted row visible" {
    const testing = std.testing;
    const D = Dropdown(64);
    const opts: DropdownViewOpts = .{ .max_visible = 4 };

    var model: D.Model = .{ .open = true };
    try testing.expectEqual(@as(usize, 0), model.highlighted);

    // Jump to the last row: viewport must scroll so row 9 is at the bottom.
    D.update(&model, D.moveHighlightMsg(.last, long_options.len, opts));
    try testing.expectEqual(@as(usize, 9), model.highlighted);
    // bottom(=10*ITEM_HEIGHT) - viewport(=4*ITEM_HEIGHT) = 6*ITEM_HEIGHT.
    try testing.expectEqual(@as(f32, 6 * ITEM_HEIGHT), model.scroll_offset);

    // Back to the first row: scroll snaps to the top.
    D.update(&model, D.moveHighlightMsg(.first, long_options.len, opts));
    try testing.expectEqual(@as(usize, 0), model.highlighted);
    try testing.expectEqual(@as(f32, 0), model.scroll_offset);

    // Step down past the viewport bottom (rows 0..3 fit; row 4 needs a nudge).
    inline for (0..4) |_| {
        D.update(&model, D.moveHighlightMsg(.next, long_options.len, opts));
    }
    try testing.expectEqual(@as(usize, 4), model.highlighted);
    // Row 4 bottom (5*ITEM_HEIGHT) - viewport (4*ITEM_HEIGHT) = 1 row.
    try testing.expectEqual(@as(f32, ITEM_HEIGHT), model.scroll_offset);

    // `.next` at the end saturates (no runaway index).
    D.update(&model, D.moveHighlightMsg(.last, long_options.len, opts));
    D.update(&model, D.moveHighlightMsg(.next, long_options.len, opts));
    try testing.expectEqual(@as(usize, 9), model.highlighted);
}

test "hit-test lands on the correct option while the list is scrolled" {
    const testing = std.testing;
    const D = Dropdown(64);
    const opts: DropdownViewOpts = .{
        .list_x = 10,
        .list_y = 40,
        .list_width = 200,
        .max_visible = 4,
    };

    var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
    defer cb.deinit();

    // Scrolled to the bottom: rows 6..9 are the visible window.
    var model: D.Model = .{ .open = true, .selected = 0, .highlighted = 0 };
    model.scroll_offset = D.maxScroll(long_options.len, opts.max_visible); // 216

    // A root container so positionPass has a parent for the closed button
    // (apps always call viewWith inside their own root group).
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    D.viewWith(&model, &cb, &long_options, TestApp.msgs, opts);
    cb.popGroup();

    const items = cb.cmds.items;
    var rects: [32]layout.Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..items.len], items, 800, 600, text_mod.monoMeasurer());

    // Viewport spans y ∈ [40, 184]; with scroll 216, row i sits at
    // y = 40 - 216 + i*36, so the first visible row is 6 (y ∈ [40, 76]).
    const hit_top = hit_test.hitTest(items, rects[0..items.len], 15, 45);
    try testing.expect(hit_top != null);
    try testing.expectEqual(@as(?TestApp.Msg, TestApp.Msg{ .select = 6 }), hit_top.?.msg);

    // A point deeper in the viewport lands on a later row (row 8, y ∈ [112,148]).
    const hit_mid = hit_test.hitTest(items, rects[0..items.len], 15, 120);
    try testing.expectEqual(@as(?TestApp.Msg, TestApp.Msg{ .select = 8 }), hit_mid.?.msg);

    // A far-right click on a visible row (list spans x ∈ [10, 210]) still lands
    // on the option button — rows are full-width, so there is no transparent
    // dead zone that would fall through to the modal backdrop (F4).
    const hit_right = hit_test.hitTest(items, rects[0..items.len], 195, 45);
    try testing.expectEqual(@as(?TestApp.Msg, TestApp.Msg{ .select = 6 }), hit_right.?.msg);

    // A point above the viewport (over the closed button row, y=40 boundary
    // handled) that maps to a row scrolled out of view is clipped — a
    // click just below the viewport bottom hits nothing selectable.
    const hit_below = hit_test.hitTest(items, rects[0..items.len], 15, 300);
    // 300 is outside the overlay entirely → no overlay hit; base layer has
    // only the closed button near the top, so this misses it too.
    try testing.expect(hit_below == null or hit_below.?.msg == null or
        std.meta.activeTag(hit_below.?.msg.?) != .select);
}

test "highlight move clamps a stale out-of-range cursor (F8)" {
    const testing = std.testing;
    const D = Dropdown(8);

    // A highlight left over from a longer list (99) with only 5 options now.
    // moveIndex must clamp to `count-1` (4) BEFORE moving, so `.prev` yields 3
    // — not 98, which would push revealOffset past maxScroll.
    var model: D.Model = .{ .open = true, .highlighted = 99, .scroll_offset = 0 };
    D.update(&model, .{ .highlight = .{ .move = .prev, .count = 5, .max_visible = 0 } });
    try testing.expectEqual(@as(usize, 3), model.highlighted);
    // With max_visible = 0 (no scrolling) the offset stays put and valid.
    try testing.expectEqual(@as(f32, 0), model.scroll_offset);

    // `.next` from the same stale cursor saturates at the clamped end.
    model.highlighted = 99;
    D.update(&model, .{ .highlight = .{ .move = .next, .count = 5, .max_visible = 0 } });
    try testing.expectEqual(@as(usize, 4), model.highlighted);
}

test "hit-test: full-width option row is clickable edge to edge (F4)" {
    const testing = std.testing;
    const D = Dropdown(8);
    const opts: DropdownViewOpts = .{ .list_x = 0, .list_y = 40, .list_width = 200 };

    var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
    defer cb.deinit();

    var model: D.Model = .{ .open = true, .selected = 0 };
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    D.viewWith(&model, &cb, &test_options, TestApp.msgs, opts);
    cb.popGroup();

    const items = cb.cmds.items;
    var rects: [32]layout.Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..items.len], items, 800, 600, text_mod.monoMeasurer());

    // Row 0 of the (non-scrolling) open list spans y ∈ [40, 76). A click near
    // the right edge (x = 150) — well past the short "Alpha" label — must land
    // on the option button, NOT the modal backdrop (which fires .close). This
    // is the exact probe from the finding: (150,50) → .select, not .close.
    const hit = hit_test.hitTest(items, rects[0..items.len], 150, 50);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?TestApp.Msg, TestApp.Msg{ .select = 0 }), hit.?.msg);
}

test "viewWith: empty / out-of-range selection shows placeholder, no crash" {
    const testing = std.testing;
    const D = Dropdown(8);

    // Empty options.
    {
        var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
        defer cb.deinit();
        var model: D.Model = .{ .selected = 0 };
        const empty: []const []const u8 = &.{};
        D.viewWith(&model, &cb, empty, TestApp.msgs, .{});
        try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
        try testing.expectEqualStrings(PLACEHOLDER, cb.cmds.items[0].button.label);
    }

    // Out-of-range selected index.
    {
        var cb = cmd.CmdBuffer(TestApp.Msg).init(testing.allocator);
        defer cb.deinit();
        var model: D.Model = .{ .selected = 99 };
        D.viewWith(&model, &cb, &test_options, TestApp.msgs, .{});
        try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
        try testing.expectEqualStrings(PLACEHOLDER, cb.cmds.items[0].button.label);
    }
}
