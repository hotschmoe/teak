const std = @import("std");
const cmd = @import("cmd.zig");
const CmdBuffer = cmd.CmdBuffer;

// ── Application Types ──────────────────────────────────────────────

pub const Msg = union(enum) {
    increment,
    decrement,
    reset,
};

pub const Model = struct {
    count: i32 = 0,
};

// ── State Transition ───────────────────────────────────────────────

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .reset => model.count = 0,
    }
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(model: Model, cb: *CmdBuffer) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 20, .gap = 12 });

    const count_str = std.fmt.allocPrint(
        cb.arena.allocator(),
        "Count: {d}",
        .{model.count},
    ) catch unreachable;
    cb.text(count_str);

    cb.pushGroup(.{ .direction = .horizontal, .gap = 8 });
    cb.button(.increment, "+");
    cb.button(.decrement, "-");
    cb.popGroup();

    cb.button(.reset, "Reset");

    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

test "update increment" {
    var m = Model{};
    update(&m, .increment);
    try std.testing.expectEqual(@as(i32, 1), m.count);
    update(&m, .increment);
    try std.testing.expectEqual(@as(i32, 2), m.count);
}

test "update decrement" {
    var m = Model{};
    update(&m, .decrement);
    try std.testing.expectEqual(@as(i32, -1), m.count);
}

test "update reset" {
    var m = Model{ .count = 42 };
    update(&m, .reset);
    try std.testing.expectEqual(@as(i32, 0), m.count);
}

test "update sequence" {
    var m = Model{};
    update(&m, .increment);
    update(&m, .increment);
    update(&m, .increment);
    update(&m, .decrement);
    try std.testing.expectEqual(@as(i32, 2), m.count);
    update(&m, .reset);
    try std.testing.expectEqual(@as(i32, 0), m.count);
}
