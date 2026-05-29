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

/// Anchor + sizing for the open list overlay.
pub const DropdownViewOpts = struct {
    /// Window-absolute top-left where the open list should appear. The app
    /// typically passes the previous frame's rect of the closed button
    /// (its bottom-left), matching the overlay positioning pattern used
    /// elsewhere in the framework.
    list_x: f32 = 0,
    list_y: f32 = 0,
    list_width: f32 = 200,
    /// Advisory cap on the open list's height before it would overflow.
    /// v1 does NOT clip or scroll: a very long list simply draws past this
    /// height. A scroll wrapper around the option group is a follow-up.
    list_max_height: f32 = 320,
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
        };

        pub const Msg = union(enum) {
            /// Open/close the list — fired by the closed-state button.
            toggle,
            /// Close without changing the selection — fired by the modal
            /// backdrop (click-outside).
            close,
            /// Choose option `i` — fired by an open-list item button.
            select: usize,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .toggle => model.open = !model.open,
                .close => model.open = false,
                .select => |i| {
                    model.selected = i;
                    model.open = false;
                },
            }
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

            // Open list: the modal-overlay pattern (see help dialog in
            // counter_greeter). modal + backdrop_msg => click-outside closes.
            cb.pushOverlay(.{
                .x = opts.list_x,
                .y = opts.list_y,
                .width = opts.list_width,
                .height = opts.list_max_height,
                .modal = true,
                .backdrop_msg = msgs.close,
                .padding = 4,
                .gap = 2,
            });
            cb.pushGroup(.{
                .direction = .vertical,
                .bg = cb.theme.panel_bg,
                .gap = 2,
            });
            for (options, 0..) |opt, i| {
                cb.button(msgs.selectMsg(i), opt);
            }
            cb.popGroup();
            cb.popOverlay();
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
