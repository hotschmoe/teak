const std = @import("std");
const model = @import("model.zig");
const Msg = model.Msg;

// ── Command Types ──────────────────────────────────────────────────

pub const Direction = enum { vertical, horizontal };

pub const GroupStyle = struct {
    direction: Direction = .vertical,
    padding: f32 = 8,
    gap: f32 = 8,
};

pub const TextCmd = struct {
    content: []const u8,
};

pub const ButtonStyle = struct {
    bg: [4]f32 = .{ 0.25, 0.25, 0.25, 1.0 },
    hover_bg: [4]f32 = .{ 0.35, 0.35, 0.35, 1.0 },
    press_bg: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    corner_radius: f32 = 4,
};

pub const ButtonCmd = struct {
    msg: Msg,
    label: []const u8,
    style: ButtonStyle = .{},
};

pub const Cmd = union(enum) {
    push_group: GroupStyle,
    pop_group,
    text: TextCmd,
    button: ButtonCmd,
};

// ── Command Buffer ─────────────────────────────────────────────────

pub const CmdBuffer = struct {
    cmds: std.ArrayList(Cmd),
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) CmdBuffer {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .cmds = .empty,
            .backing = backing,
        };
    }

    pub fn deinit(self: *CmdBuffer) void {
        self.arena.deinit();
        self.cmds.deinit(self.backing);
    }

    pub fn reset(self: *CmdBuffer) void {
        self.cmds.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    // ── Convenience Emitters ───────────────────────────────────────

    pub fn pushGroup(self: *CmdBuffer, style: GroupStyle) void {
        self.cmds.append(self.backing, .{ .push_group = style }) catch unreachable;
    }

    pub fn popGroup(self: *CmdBuffer) void {
        self.cmds.append(self.backing, .pop_group) catch unreachable;
    }

    pub fn text(self: *CmdBuffer, content: []const u8) void {
        self.cmds.append(self.backing, .{ .text = .{ .content = content } }) catch unreachable;
    }

    pub fn button(self: *CmdBuffer, msg: Msg, label: []const u8) void {
        self.cmds.append(self.backing, .{ .button = .{
            .msg = msg,
            .label = label,
        } }) catch unreachable;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "CmdBuffer emits correct command sequence" {
    const testing = std.testing;
    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    const m = model.Model{ .count = 5 };
    model.view(m, &cb);

    const items = cb.cmds.items;
    try testing.expectEqual(@as(usize, 8), items.len);

    try testing.expectEqual(.push_group, std.meta.activeTag(items[0]));
    try testing.expectEqual(.text, std.meta.activeTag(items[1]));
    try testing.expectEqual(.push_group, std.meta.activeTag(items[2]));
    try testing.expectEqual(.button, std.meta.activeTag(items[3]));
    try testing.expectEqual(.button, std.meta.activeTag(items[4]));
    try testing.expectEqual(.pop_group, std.meta.activeTag(items[5]));
    try testing.expectEqual(.button, std.meta.activeTag(items[6]));
    try testing.expectEqual(.pop_group, std.meta.activeTag(items[7]));

    // Verify text content
    try testing.expectEqualStrings("Count: 5", items[1].text.content);

    // Verify button messages
    try testing.expectEqual(Msg.increment, items[3].button.msg);
    try testing.expectEqual(Msg.decrement, items[4].button.msg);
    try testing.expectEqual(Msg.reset, items[6].button.msg);

    // Verify button labels
    try testing.expectEqualStrings("+", items[3].button.label);
    try testing.expectEqualStrings("-", items[4].button.label);
    try testing.expectEqualStrings("Reset", items[6].button.label);
}

test "CmdBuffer reset clears commands" {
    const testing = std.testing;
    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.text("hello");
    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);

    cb.reset();
    try testing.expectEqual(@as(usize, 0), cb.cmds.items.len);
}
