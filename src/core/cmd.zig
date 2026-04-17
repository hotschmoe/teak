const std = @import("std");

// ── Shared (Msg-independent) types ─────────────────────────────────

pub const Direction = enum { vertical, horizontal };

pub const GroupStyle = struct {
    direction: Direction = .vertical,
    padding: f32 = 8,
    gap: f32 = 8,
    /// 0 = intrinsic (measured from children). >0 = flex weight; parent
    /// distributes remaining main-axis space proportionally.
    flex: f32 = 0,
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

pub const TextInputStyle = struct {
    bg: [4]f32 = .{ 0.12, 0.12, 0.14, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    border: [4]f32 = .{ 0.35, 0.35, 0.4, 1.0 },
    focus_border: [4]f32 = .{ 0.3, 0.5, 1.0, 1.0 },
    cursor: [4]f32 = .{ 0.9, 0.9, 1.0, 1.0 },
    corner_radius: f32 = 4,
    /// Text inputs expand along the main axis by default.
    flex: f32 = 1,
    /// Minimum width when flex is 0 or parent has no extra space.
    min_width: f32 = 120,
};

// ── Generic Cmd + CmdBuffer over Msg ───────────────────────────────
//
// Per proto 2 Option A: CmdBuffer is generic over the composed AppMsg.
// Components emit commands using the composed Msg; this keeps routing
// explicit rather than hiding it behind a per-component wrapper.

pub fn ButtonCmd(comptime Msg: type) type {
    return struct {
        msg: Msg,
        label: []const u8,
        style: ButtonStyle = .{},
    };
}

pub fn TextInputCmd(comptime Msg: type) type {
    return struct {
        /// Msg emitted when this input is clicked — the Model uses this to
        /// update its focus field. Keyboard character/key events are handled
        /// at the app level (main loop translates key events into app-level
        /// Msgs, app.update dispatches based on Model.focused).
        focus_msg: Msg,
        content: []const u8,
        cursor: usize,
        style: TextInputStyle = .{},
    };
}

pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        /// Re-expose Msg so that generic helpers can recover it from the Cmd type.
        pub const MsgT = Msg;

        push_group: GroupStyle,
        pop_group,
        text: TextCmd,
        button: ButtonCmd(Msg),
        text_input: TextInputCmd(Msg),
    };
}

pub fn CmdBuffer(comptime Msg: type) type {
    return struct {
        const Self = @This();
        pub const MsgT = Msg;
        pub const CmdT = Cmd(Msg);

        cmds: std.ArrayList(CmdT),
        arena: std.heap.ArenaAllocator,
        backing: std.mem.Allocator,

        pub fn init(backing: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(backing),
                .cmds = .empty,
                .backing = backing,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.cmds.deinit(self.backing);
        }

        pub fn reset(self: *Self) void {
            self.cmds.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
        }

        // ── Convenience emitters ───────────────────────────────────

        pub fn pushGroup(self: *Self, style: GroupStyle) void {
            self.cmds.append(self.backing, .{ .push_group = style }) catch unreachable;
        }

        pub fn popGroup(self: *Self) void {
            self.cmds.append(self.backing, .pop_group) catch unreachable;
        }

        pub fn text(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{ .content = content } }) catch unreachable;
        }

        pub fn button(self: *Self, msg: Msg, label: []const u8) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
            } }) catch unreachable;
        }

        pub fn buttonStyled(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = style,
            } }) catch unreachable;
        }

        pub fn textInput(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
        ) void {
            self.cmds.append(self.backing, .{ .text_input = .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
            } }) catch unreachable;
        }

        pub fn textInputStyled(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
            style: TextInputStyle,
        ) void {
            self.cmds.append(self.backing, .{ .text_input = .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = style,
            } }) catch unreachable;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "CmdBuffer emits correct sequence for simple counter view" {
    const testing = std.testing;

    const Msg = union(enum) {
        inc,
        dec,
        reset,
    };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("Count: 0");
    cb.pushGroup(.{ .direction = .horizontal });
    cb.button(.inc, "+");
    cb.button(.dec, "-");
    cb.popGroup();
    cb.button(.reset, "Reset");
    cb.popGroup();

    try testing.expectEqual(@as(usize, 8), cb.cmds.items.len);
    try testing.expectEqual(.push_group, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqual(Msg.inc, cb.cmds.items[3].button.msg);
    try testing.expectEqual(Msg.reset, cb.cmds.items[6].button.msg);
}

test "CmdBuffer emits text_input command" {
    const testing = std.testing;

    const Msg = union(enum) { focus };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.focus, "hello", 2);

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqualStrings("hello", cb.cmds.items[0].text_input.content);
    try testing.expectEqual(@as(usize, 2), cb.cmds.items[0].text_input.cursor);
    try testing.expectEqual(Msg.focus, cb.cmds.items[0].text_input.focus_msg);
}

test "CmdBuffer reset clears commands" {
    const testing = std.testing;

    const Msg = union(enum) { a };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.text("hello");
    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);

    cb.reset();
    try testing.expectEqual(@as(usize, 0), cb.cmds.items.len);
}

test "Cmd exposes Msg type via MsgT" {
    const Msg = union(enum) { a, b };
    try std.testing.expectEqual(Msg, Cmd(Msg).MsgT);
}
