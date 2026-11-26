//! See SRC.md, src/sim/workload.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const input = @import("input.zig");
const focus = @import("../input/focus.zig");
const hit_test = @import("../input/hit_test.zig");
const keys = @import("../input/keys.zig");

pub const Kind = enum {
    move,
    click,
    drag,
    wheel,
    tab,
    shift_tab,
    enter,
    escape,
    arrow,
    edit,
    shortcut,
    text_ascii,
    text_multibyte,
    text_rtl,
    text_combining,
    burst,
    idle,
    resize,
    scale,
    focus_loss,
    press,
    release,
    modifiers,
};

pub const Weight = struct { kind: Kind, weight: u16 };
pub const weights = [_]Weight{
    .{ .kind = .move, .weight = 10 },          .{ .kind = .click, .weight = 24 },
    .{ .kind = .drag, .weight = 8 },           .{ .kind = .wheel, .weight = 8 },
    .{ .kind = .tab, .weight = 7 },            .{ .kind = .shift_tab, .weight = 4 },
    .{ .kind = .enter, .weight = 10 },         .{ .kind = .escape, .weight = 3 },
    .{ .kind = .arrow, .weight = 7 },          .{ .kind = .edit, .weight = 5 },
    .{ .kind = .shortcut, .weight = 5 },       .{ .kind = .text_ascii, .weight = 15 },
    .{ .kind = .text_multibyte, .weight = 3 }, .{ .kind = .text_rtl, .weight = 3 },
    .{ .kind = .text_combining, .weight = 3 }, .{ .kind = .burst, .weight = 4 },
    .{ .kind = .idle, .weight = 5 },           .{ .kind = .resize, .weight = 4 },
    .{ .kind = .scale, .weight = 2 },          .{ .kind = .focus_loss, .weight = 2 },
    .{ .kind = .press, .weight = 2 },          .{ .kind = .release, .weight = 2 },
    .{ .kind = .modifiers, .weight = 2 },
};

const Phase = enum { ready, release, drag_move, drag_end, drag_finish, text_release, text_send };
const candidates_max = 2048;
const Candidate = struct { point: [2]f32, index: u32 };

pub const Generator = struct {
    state: u64,
    phase: Phase = .ready,
    point: [2]f32 = .{ 0, 0 },
    cancel_drag: bool = false,
    pending_text: u8 = 0,
    limits: u64 = 0,
    visits: [candidates_max]u16 = @splat(0),
    counts: [weights.len]u64 = @splat(0),
    events: [@typeInfo(input.Event).@"union".field_names.len]u64 = @splat(0),

    pub fn draw(self: *Generator, bound: u32) u32 {
        assert(bound > 0);
        self.state +%= 0x9e3779b97f4a7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        value ^= value >> 31;
        const result: u32 = @intCast(value % bound);
        assert(result < bound);
        return result;
    }

    fn choose(self: *Generator) Kind {
        var total: u32 = 0;
        for (weights) |entry| total += entry.weight;
        assert(total > 0);
        var choice = self.draw(total);
        for (weights) |entry| {
            assert(entry.weight > 0);
            if (choice < entry.weight) {
                self.counts[@backingInt(entry.kind)] += 1;
                return entry.kind;
            }
            choice -= entry.weight;
        }
        @panic("weight table invariant");
    }

    pub fn next(self: *Generator, runtime: anytype) !input.Frame {
        assert(runtime.host.live);
        var frame: input.Frame = .{};
        if (self.phase != .ready) {
            try self.continue_gesture(&frame);
        } else {
            const kind = self.choose();
            try self.generate(&frame, kind, runtime);
        }
        for (frame.events[0..frame.count]) |event|
            self.events[@backingInt(std.meta.activeTag(event))] += 1;
        assert(frame.count <= input.events_max);
        return frame;
    }

    fn continue_gesture(self: *Generator, frame: *input.Frame) !void {
        assert(self.phase != .ready);
        assert(frame.count == 0);
        switch (self.phase) {
            .release => {
                try frame.push(.{ .up = .left });
                self.phase = .ready;
            },
            .drag_move => {
                try frame.push(.{ .move = .{ self.point[0] + 18, self.point[1] + 9 } });
                self.phase = .drag_end;
            },
            .drag_end => {
                try frame.push(.{ .move = .{ self.point[0] + 28, self.point[1] + 40 } });
                self.phase = .drag_finish;
            },
            .drag_finish => {
                try frame.push(if (self.cancel_drag) .focus_loss else .{ .up = .left });
                self.phase = .ready;
            },
            .text_release => {
                try frame.push(.{ .up = .left });
                self.phase = .text_send;
            },
            .text_send => {
                try frame.push(.{ .text = self.pending_text });
                self.phase = .ready;
            },
            .ready => @panic("gesture invariant"),
        }
    }

    fn generate(self: *Generator, frame: *input.Frame, kind: Kind, runtime: anytype) !void {
        assert(frame.count == 0);
        assert(self.phase == .ready);
        switch (kind) {
            .move => try frame.push(.{ .move = self.target(runtime, .move) }),
            .click, .drag => {
                self.point = self.target(runtime, kind);
                try frame.push(.{ .move = self.point });
                try frame.push(.{ .down = .left });
                self.cancel_drag = self.draw(2) == 0;
                self.phase = if (kind == .click) .release else .drag_move;
            },
            .wheel => {
                try frame.push(.{ .move = self.target(runtime, .wheel) });
                const delta = @as(f32, @floatFromInt(self.draw(1000))) - 300;
                try frame.push(.{ .wheel = .{ 0, delta } });
            },
            .tab => try frame.push(.{ .key = .tab }),
            .shift_tab => try frame.push(.{ .key = .shift_tab }),
            .enter => try frame.push(.{ .key = .enter }),
            .escape => try frame.push(.{ .key = .escape }),
            .arrow => {
                const choices = [_]keys.SpecialKey{
                    .left,      .right,      .up,      .down,      .shift_left, .shift_right,
                    .ctrl_left, .ctrl_right, .page_up, .page_down,
                };
                try frame.push(.{ .key = choices[self.draw(choices.len)] });
            },
            .edit => {
                const choices = [_]keys.SpecialKey{ .backspace, .delete, .home, .end };
                try frame.push(.{ .key = choices[self.draw(choices.len)] });
            },
            .shortcut => try self.shortcut(frame),
            .text_ascii => try self.type_text(frame, runtime, @intCast(self.draw(2))),
            .text_multibyte => try self.type_text(frame, runtime, 2),
            .text_rtl => try self.type_text(frame, runtime, 3),
            .text_combining => try self.type_text(frame, runtime, 4),
            .burst => {
                const count = 12 + self.draw(28);
                for (0..count) |_| try frame.push(.{ .key = .tab });
            },
            .idle => frame.advance_ms = 1 + self.draw(300000),
            .resize => {
                const sizes = [_][2]u32{
                    .{ 0, 0 },      .{ 1, 1 },       .{ 24, 12 }, .{ 320, 240 },
                    .{ 1280, 800 }, .{ 1600, 1000 },
                };
                try frame.push(.{ .resize = sizes[self.draw(sizes.len)] });
            },
            .scale => try frame.push(.{ .scale = 0.5 + @as(f32, @floatFromInt(self.draw(6))) / 2 }),
            .focus_loss => try frame.push(.focus_loss),
            .press, .release => try self.raw_button(frame, kind),
            .modifiers => {
                const bits: u8 = @intCast(self.draw(16));
                try frame.push(.{ .modifiers = @bitCast(bits) });
            },
        }
    }

    fn raw_button(self: *Generator, frame: *input.Frame, kind: Kind) !void {
        assert(kind == .press or kind == .release);
        assert(frame.count == 0);
        const choices = [_]@import("../core/pointer.zig").Button{
            .left, .left, .left, .middle, .right,
        };
        const button = choices[self.draw(choices.len)];
        try frame.push(if (kind == .press) .{ .down = button } else .{ .up = button });
    }

    fn type_text(self: *Generator, frame: *input.Frame, runtime: anytype, sample: u8) !void {
        assert(sample < input.text_samples.len);
        assert(self.phase == .ready);
        const commands = runtime.bufs[runtime.current].cmds.items;
        const rects = runtime.rects[runtime.current].items;
        const point = self.target(runtime, .text_ascii);
        if (hit_test.hitTest(commands, rects, point[0], point[1])) |hit| {
            if (focus.isTextLeaf(commands[hit.index])) {
                try frame.push(.{ .move = point });
                try frame.push(.{ .down = .left });
                self.pending_text = sample;
                self.phase = .text_release;
                return;
            }
        }
        try frame.push(.{ .text = sample });
    }

    fn shortcut(self: *Generator, frame: *input.Frame) !void {
        assert(frame.count == 0);
        const choices = [_]keys.Key{ .a, .c, .x, .v, .z, .y, .up, .down, .s, .k };
        const chord: keys.Chord = .{
            .key = choices[self.draw(choices.len)],
            .mod = self.draw(4) != 0,
            .alt = self.draw(4) == 0,
            .shift = self.draw(4) == 0,
        };
        try frame.push(.{ .modifiers = .{
            .ctrl = chord.mod,
            .alt = chord.alt,
            .shift = chord.shift,
        } });
        try frame.push(.{ .shortcut = chord });
        if (chord.special()) |key| try frame.push(.{ .key = key });
        try frame.push(.{ .modifiers = .{} });
        assert(frame.count <= 4);
    }

    fn target(self: *Generator, runtime: anytype, kind: Kind) [2]f32 {
        assert(runtime.current <= 1);
        const commands = runtime.bufs[runtime.current].cmds.items;
        const rects = runtime.rects[runtime.current].items;
        assert(commands.len == rects.len);
        var candidates: [candidates_max]Candidate = undefined;
        var count: u32 = 0;
        for (commands, rects, 0..) |command, rect, index| {
            if (count == candidates.len) {
                self.limits += 1;
                break;
            }
            if (index >= candidates_max) {
                self.limits += 1;
                continue;
            }
            if (rect.w <= 0 or rect.h <= 0) continue;
            const point: [2]f32 = if (kind == .drag)
                .{ rect.x + @min(10, rect.w / 2), rect.y + @min(6, rect.h / 2) }
            else
                .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
            if (point[0] < 0 or point[1] < 0 or
                point[0] >= @as(f32, @floatFromInt(runtime.host.width)) or
                point[1] >= @as(f32, @floatFromInt(runtime.host.height))) continue;
            const hit = hit_test.hitTest(commands, rects, point[0], point[1]);
            const suitable = switch (kind) {
                .drag => command == .push_group and command.push_group.drag_id != 0 and
                    hit == null,
                .wheel => command == .push_scroll or command == .text_area,
                .text_ascii => focus.isTextLeaf(command) and hit != null and
                    hit.?.index == index,
                else => focus.isNavigable(command) and hit != null and hit.?.index == index,
            };
            if (!suitable) continue;
            candidates[count] = .{ .point = point, .index = @intCast(index) };
            count += 1;
        }
        if (count > 0 and self.draw(10) != 0)
            return self.pick(candidates[0..count], kind);
        return .{
            @as(f32, @floatFromInt(self.draw(runtime.host.width + 200))) - 100,
            @as(f32, @floatFromInt(self.draw(runtime.host.height + 200))) - 100,
        };
    }

    fn pick(self: *Generator, candidates: []const Candidate, kind: Kind) [2]f32 {
        assert(candidates.len > 0);
        assert(candidates.len <= candidates_max);
        var best = candidates[self.draw(@intCast(candidates.len))];
        if (kind == .click and self.draw(4) != 0) {
            for (candidates) |candidate| {
                if (self.visits[candidate.index] < self.visits[best.index]) best = candidate;
            }
        }
        if (kind == .click) self.visits[best.index] +|= 1;
        return best.point;
    }
};
