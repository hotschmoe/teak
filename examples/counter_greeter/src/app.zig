const std = @import("std");
const teak = @import("teak");
const component = teak.component;
const counter = @import("counter.zig");
const greeter = @import("greeter.zig");

// ── Composed Application ───────────────────────────────────────────
//
// Compose counter + greeter into one app via teak.component.Components, plus AppLevel
// state for focus tracking. Keyboard events aren't in AppLevel.Msg — the
// main loop reads Model.focused and translates keys directly into
// component Msgs (e.g. Msg{ .greeter = .{ .name_char = c } }). This keeps
// AppLevel tiny and avoids duplicate enum plumbing.

pub const FocusField = enum { greeter };

const AppLevel = struct {
    focused: ?FocusField = null,
    /// Demo: help modal open/closed state. Driven by AppLevel Msgs so
    /// nothing platform-specific leaks into the component world.
    show_help_modal: bool = false,

    pub const Msg = union(enum) {
        focus_set: FocusField,
        focus_clear,
        help_open,
        help_close,
    };

    // `@This().Msg` disambiguates against the file-scope `pub const Msg`
    // alias below — both are in scope from inside this struct.
    pub fn update(model: anytype, msg: @This().Msg) void {
        switch (msg) {
            .focus_set => |f| model.focused = f,
            .focus_clear => model.focused = null,
            .help_open => model.show_help_modal = true,
            .help_close => model.show_help_modal = false,
        }
    }
};

const Composed = component.Components(.{
    .counter = counter,
    .greeter = greeter,
}, AppLevel);

pub const Model = Composed.Model;
pub const Msg = Composed.Msg;
pub const update = Composed.update;

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });

    // Top toolbar with a Help button — proof that AppLevel state can
    // drive overlay visibility.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 8, .gap = 8 });
    cb.button(Msg{ .help_open = {} }, "Help");
    cb.popGroup();

    // Main row: counter on the left, greeter on the right.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 16, .gap = 16 });

    // Counter: payloadless variants wrap straight into AppMsg.
    counter.view(&m.counter, cb, component.buildMsgs(counter, "counter", Msg));

    // Greeter: wrapped in flex=1 so it claims remaining horizontal space.
    // Its `focus` click routes to AppLevel (focus_set), not Greeter.update —
    // so we hand-build this msgs struct instead of using buildMsgs.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .flex = 1 });
    greeter.view(&m.greeter, cb, .{ .focus = Msg{ .focus_set = .greeter } });
    cb.popGroup();

    cb.popGroup();

    cb.popGroup();

    // Modal overlay rendered last so it's at the top of the buffer;
    // hit-test gives it precedence regardless. The host should set the
    // overlay's width/height to the window size for a true modal
    // backdrop — for now we use a generous 900x500.
    if (m.show_help_modal) {
        cb.pushOverlay(.{
            .x = 0,
            .y = 0,
            .width = 900,
            .height = 500,
            .padding = 0,
            .backdrop = .{ 0, 0, 0, 0.55 },
        });
        // Inner panel: centered card with text + close button.
        cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 12 });
        cb.text("Teak — Functional Gaps demo");
        cb.text("Overlay (this modal), virtual list, image, rich text now live.");
        cb.button(Msg{ .help_close = {} }, "Close");
        cb.popGroup();
        cb.popOverlay();
    }
}

/// Translate a character typed while a text input is focused into the
/// correct component Msg. Returns null if nothing is focused, which means
/// the main loop should drop the key event.
pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    const f = m.focused orelse return null;
    return switch (f) {
        .greeter => Msg{ .greeter = .{ .name_char = c } },
    };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    const f = m.focused orelse return null;
    return switch (f) {
        .greeter => switch (key) {
            .backspace => Msg{ .greeter = .name_backspace },
            .left => Msg{ .greeter = .name_cursor_left },
            .right => Msg{ .greeter = .name_cursor_right },
            else => null,
        },
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "app: composed Model carries both components + focus" {
    const m: Model = .{};
    try std.testing.expectEqual(@as(i32, 0), m.counter.count);
    try std.testing.expectEqual(@as(usize, 0), m.greeter.name_len);
    try std.testing.expectEqual(@as(?FocusField, null), m.focused);
}

test "app: counter messages route to counter" {
    var m: Model = .{};
    update(&m, .{ .counter = .increment });
    update(&m, .{ .counter = .increment });
    update(&m, .{ .counter = .increment });
    try std.testing.expectEqual(@as(i32, 3), m.counter.count);

    update(&m, .{ .counter = .reset });
    try std.testing.expectEqual(@as(i32, 0), m.counter.count);
}

test "app: greeter messages route to greeter" {
    var m: Model = .{};
    update(&m, .{ .greeter = .{ .name_char = 'H' } });
    update(&m, .{ .greeter = .{ .name_char = 'i' } });
    try std.testing.expectEqualStrings("Hi", m.greeter.name[0..m.greeter.name_len]);

    update(&m, .{ .greeter = .name_backspace });
    try std.testing.expectEqualStrings("H", m.greeter.name[0..m.greeter.name_len]);
}

test "app: focus_set routes to AppLevel.update" {
    var m: Model = .{};
    try std.testing.expectEqual(@as(?FocusField, null), m.focused);

    update(&m, .{ .focus_set = .greeter });
    try std.testing.expectEqual(@as(?FocusField, .greeter), m.focused);

    update(&m, .focus_clear);
    try std.testing.expectEqual(@as(?FocusField, null), m.focused);
}

test "app: keyCharMsg produces greeter char when focused" {
    var m: Model = .{};
    try std.testing.expectEqual(@as(?Msg, null), keyCharMsg(&m, 'A'));

    m.focused = .greeter;
    const maybe_msg = keyCharMsg(&m, 'A');
    try std.testing.expect(maybe_msg != null);
    try std.testing.expectEqual(@as(u8, 'A'), maybe_msg.?.greeter.name_char);
}

test "app: view emits expected root structure" {
    const testing = std.testing;
    const cmd = teak.cmd;

    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    var m: Model = .{};
    update(&m, .{ .counter = .increment });
    update(&m, .{ .greeter = .{ .name_char = 'X' } });
    view(&m, &cb);

    // Root push: the top-level vertical wrapper (toolbar + main row).
    try testing.expectEqual(.push_group, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqual(cmd.Direction.vertical, cb.cmds.items[0].push_group.direction);

    // Last cmd is the root pop. With the modal closed, that's the
    // outer pop_group; with the modal open, it'd be a pop_overlay.
    const last = cb.cmds.items.len - 1;
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[last]));
}

test "app: opening help modal appends an overlay region" {
    const testing = std.testing;

    var cb = teak.cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    var m: Model = .{};
    update(&m, .help_open);
    try testing.expect(m.show_help_modal);
    view(&m, &cb);

    // Buffer should now contain a push_overlay and a pop_overlay.
    var saw_push_overlay = false;
    var saw_pop_overlay = false;
    var saw_close_button = false;
    for (cb.cmds.items) |c| {
        switch (c) {
            .push_overlay => saw_push_overlay = true,
            .pop_overlay => saw_pop_overlay = true,
            .button => |b| if (std.meta.eql(b.msg, Msg.help_close)) {
                saw_close_button = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_push_overlay);
    try testing.expect(saw_pop_overlay);
    try testing.expect(saw_close_button);

    // Close it again — overlay region must disappear.
    update(&m, .help_close);
    cb.reset();
    view(&m, &cb);
    for (cb.cmds.items) |c| {
        try testing.expect(std.meta.activeTag(c) != .push_overlay);
    }
}

test "app: text_input click focus_msg is AppLevel.focus_set" {
    const testing = std.testing;
    const cmd = teak.cmd;

    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    const m: Model = .{};
    view(&m, &cb);

    // Find the text_input command and verify its focus_msg is
    // Msg{ .focus_set = .greeter }.
    var found = false;
    for (cb.cmds.items) |c| {
        if (c == .text_input) {
            try testing.expectEqual(Msg{ .focus_set = .greeter }, c.text_input.focus_msg);
            found = true;
        }
    }
    try testing.expect(found);
}

test "app: compose end-to-end — click + key produces updated greeting" {
    const testing = std.testing;
    const cmd = teak.cmd;
    const layout = teak.layout;
    const hit_test = teak.hit_test;

    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    var m: Model = .{};
    view(&m, &cb);

    var rects: [64]layout.Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, teak.monoMeasurer());

    // Find and click the text input
    var ti_idx: ?usize = null;
    for (cb.cmds.items, 0..) |c, i| if (c == .text_input) {
        ti_idx = i;
    };
    try testing.expect(ti_idx != null);

    const r = rects[ti_idx.?];
    const hit = hit_test.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], r.x + 5, r.y + 5);
    try testing.expect(hit != null);
    update(&m, hit.?.msg);
    try testing.expectEqual(@as(?FocusField, .greeter), m.focused);

    // Type "Hi"
    for ([_]u8{ 'H', 'i' }) |ch| {
        const key_msg = keyCharMsg(&m, ch);
        try testing.expect(key_msg != null);
        update(&m, key_msg.?);
    }
    try testing.expectEqualStrings("Hi", m.greeter.name[0..m.greeter.name_len]);

    // Rebuild view and confirm the greeting updated.
    cb.reset();
    view(&m, &cb);
    var saw_greeting = false;
    for (cb.cmds.items) |c| {
        if (c == .text) {
            if (std.mem.eql(u8, c.text.content, "Hello, Hi!")) saw_greeting = true;
        }
    }
    try testing.expect(saw_greeting);
}
