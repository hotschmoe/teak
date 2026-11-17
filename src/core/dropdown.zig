const std = @import("std");
const cmd = @import("cmd.zig");
const component = @import("component.zig");
const keys = @import("../input/keys.zig");

// Model ownership and command constraints: HARDLINE §1 and §3; see SRC.md.

/// Height of a single open-list option row, in pixels. Matches
/// `LayoutEngine.BUTTON_HEIGHT` (the option buttons are plain buttons, so
/// every row is exactly this tall regardless of label font). Scroll math
/// — viewport sizing, `maxScroll`, and scroll-to-reveal — is expressed in
/// multiples of this constant so it stays in lock-step with the rects the
/// layout pass actually produces.
pub const ITEM_HEIGHT: f32 = 36;

/// Anchor + sizing for the open list overlay.
pub const DropdownViewOpts = struct {
    /// Open the list against the closed button automatically (below its
    /// left edge): the overlay is anchored to the `msgs.toggle` button
    /// (`OverlayStyle.anchor_msg`), resolved by layout in the same frame.
    /// `list_x` / `list_y` are then ignored. Set false to place the list
    /// yourself at window-absolute `list_x` / `list_y`.
    auto_anchor: bool = true,
    /// Which side of the button the list opens on when `auto_anchor`.
    anchor_side: cmd.AnchorSide = .below_start,
    /// Window-absolute top-left of the open list when `auto_anchor` is false.
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
/// options slice.
///
/// **`cap` is documentation only**: it is exposed as `Dropdown(cap).capacity`
/// and has no effect on layout, storage or `update` (the Model holds indices,
/// not options, so its size does not depend on `cap`). Pass the intended
/// maximum option count (e.g. `Dropdown(64)` for a long species list) so call
/// sites stay self-describing; any positive number works.
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
            /// Choose option `i` — fired by an open-list item button. Also
            /// valid while CLOSED (set the selection from code, e.g. loading
            /// a record); it always closes the list and parks the keyboard
            /// highlight on `i`. The index is not range-checked: an `i >=
            /// options.len` shows `PLACEHOLDER`.
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

        /// Key -> Msg while the list is open (null when closed: Enter / Space on the
        /// trigger button is the run loop's keyboard activation). Up / Down / Home / End /
        /// PageUp / PageDown move the highlight, Enter chooses it, Escape closes. The app
        /// calls this from `keySpecialMsg` and wraps the result.
        pub fn keyMsg(model: *const Model, key: keys.SpecialKey, options_len: usize, opts: DropdownViewOpts) ?Msg {
            if (!model.open or options_len == 0) return null;
            return switch (key) {
                .up, .page_up => moveHighlightMsg(.prev, options_len, opts),
                .down, .page_down => moveHighlightMsg(.next, options_len, opts),
                .home => moveHighlightMsg(.first, options_len, opts),
                .end => moveHighlightMsg(.last, options_len, opts),
                .enter => .{ .select = @min(model.highlighted, options_len - 1) },
                .escape => .close,
                else => null,
            };
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
                    .anchor_msg = if (opts.auto_anchor) msgs.toggle else null,
                    .anchor_side = opts.anchor_side,
                    .width = opts.list_width,
                    .height = viewport_h,
                    .modal = true,
                    .backdrop_msg = msgs.close,
                    // The opaque viewport prevents clicks falling through to the backdrop.
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
                cb.pushOverlay(.{
                    .x = opts.list_x,
                    .y = opts.list_y,
                    .anchor_msg = if (opts.auto_anchor) msgs.toggle else null,
                    .anchor_side = opts.anchor_side,
                    .width = opts.list_width,
                    .height = opts.list_max_height,
                    .modal = true,
                    .backdrop_msg = msgs.close,
                    .padding = 0,
                    .gap = 0,
                });
                // Full-width rows keep clicks on options rather than the backdrop.
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
                var style = cb.theme.button;
                style.min_width = row_width;
                // Scroll math counts ITEM_HEIGHT rows whatever the theme's button height is.
                style.height = ITEM_HEIGHT;
                if (i == model.highlighted) {
                    style.bg = cb.theme.button.hover_bg;
                    style.fg = cb.theme.button.hover_fg orelse cb.theme.button.fg;
                }
                cb.buttonStyled(msgs.selectMsg(i), opt, style);
            }
        }
    };
}





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






const layout = @import("../layout/engine.zig");
const hit_test = @import("../input/hit_test.zig");
const text_mod = @import("text.zig");

const long_options = [_][]const u8{
    "o0", "o1", "o2", "o3", "o4", "o5", "o6", "o7", "o8", "o9",
};









