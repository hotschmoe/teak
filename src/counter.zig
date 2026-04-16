const std = @import("std");

// ── Counter Component ──────────────────────────────────────────────
//
// Matches the compose.zig component protocol:
//   Model (default-initialisable), Msg (tagged union), update(*Model, Msg),
//   view(Model, cb: anytype, msgs: anytype).
//
// The view receives a `msgs` struct pre-built by the composition layer with
// one AppMsg-typed field per payloadless Msg variant. Components therefore
// remain ignorant of the composed AppMsg shape — they write `msgs.increment`
// and the emitted command carries a correctly-wrapped AppMsg.

pub const Model = struct {
    count: i32 = 0,
};

pub const Msg = union(enum) {
    increment,
    decrement,
    reset,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .reset => model.count = 0,
    }
}

pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });

    const count_str = std.fmt.allocPrint(
        cb.arena.allocator(),
        "Count: {d}",
        .{model.count},
    ) catch unreachable;
    cb.text(count_str);

    cb.pushGroup(.{ .direction = .horizontal, .gap = 8 });
    cb.button(msgs.increment, "+");
    cb.button(msgs.decrement, "-");
    cb.popGroup();

    cb.button(msgs.reset, "Reset");

    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

test "counter update transitions" {
    var m: Model = .{};
    update(&m, .increment);
    update(&m, .increment);
    update(&m, .increment);
    update(&m, .decrement);
    try std.testing.expectEqual(@as(i32, 2), m.count);
    update(&m, .reset);
    try std.testing.expectEqual(@as(i32, 0), m.count);
}

test "counter view emits expected command shape" {
    const testing = std.testing;
    const cmd = @import("cmd.zig");

    // Stand-in AppMsg: same variants as Counter.Msg so msgs can be built trivially.
    const AppMsg = Msg;
    var cb = cmd.CmdBuffer(AppMsg).init(testing.allocator);
    defer cb.deinit();

    const msgs = .{
        .increment = AppMsg.increment,
        .decrement = AppMsg.decrement,
        .reset = AppMsg.reset,
    };

    const m: Model = .{ .count = 7 };
    view(&m, &cb, msgs);

    // push, text, push, btn+, btn-, pop, btn reset, pop = 8 cmds
    try testing.expectEqual(@as(usize, 8), cb.cmds.items.len);
    try testing.expectEqualStrings("Count: 7", cb.cmds.items[1].text.content);
    try testing.expectEqual(AppMsg.increment, cb.cmds.items[3].button.msg);
    try testing.expectEqual(AppMsg.decrement, cb.cmds.items[4].button.msg);
    try testing.expectEqual(AppMsg.reset, cb.cmds.items[6].button.msg);
}
