const std = @import("std");

// ── Counter Component ──────────────────────────────────────────────
// Implements the component protocol (see src/core/component.zig): Model, Msg, update, view.
// The msgs parameter carries AppMsg-typed values pre-wrapped by the
// composition layer so this component stays ignorant of the composed shape.

/// Rolling window of recent count values, for the Stats-window chart.
pub const HISTORY_CAP = 32;

pub const Model = struct {
    count: i32 = 0,
    /// Recent count values, oldest first. `history[0..history_len]` is the
    /// live window; once full it slides (drop-oldest). Plain Model state,
    /// mutated only in `update` — the chart in `app.statsView` reads it.
    history: [HISTORY_CAP]f32 = [_]f32{0} ** HISTORY_CAP,
    history_len: usize = 0,
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
    recordHistory(model);
}

/// Append the current count to the rolling history window, sliding the
/// window when it is full. Pure Model mutation — no allocation.
fn recordHistory(model: *Model) void {
    const v: f32 = @floatFromInt(model.count);
    if (model.history_len < HISTORY_CAP) {
        model.history[model.history_len] = v;
        model.history_len += 1;
    } else {
        var i: usize = 1;
        while (i < HISTORY_CAP) : (i += 1) model.history[i - 1] = model.history[i];
        model.history[HISTORY_CAP - 1] = v;
    }
}

/// Live history window (oldest first).
pub fn history(model: *const Model) []const f32 {
    return model.history[0..model.history_len];
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
    const cmd = @import("teak").cmd;

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
