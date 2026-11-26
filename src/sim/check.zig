//! See SRC.md, src/sim/check.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const hashing = @import("hash.zig");
const focus = @import("../input/focus.zig");
const hit_test = @import("../input/hit_test.zig");
const layout = @import("../layout/engine.zig");
const scroll = @import("../layout/scroll_extent.zig");
const cmd = @import("../core/cmd.zig");
const wrap = @import("../core/text_wrap.zig");
const verify = @import("sim.zig").verify;

pub const Checker = enum {
    no_stop,
    determinism,
    view_purity,
    resources,
    idle,
    layout,
    hit_test,
    focus,
    record_replay,
};
pub const Progress = struct {
    frame: u32 = 0,
    recorded: u32 = 0,
    pass: u8 = 0,
    checker: Checker = .no_stop,
    index: u32 = 0,
    values: [4]f32 = @splat(0),
    expected: u64 = 0,
    actual: u64 = 0,
};
pub const Fingerprint = struct {
    model: u64,
    commands: u64,
    rects: u64,
    vertices: u64,
    gpu: u64,
    input: u64,
};

pub fn deterministic(expected: Fingerprint, actual: Fingerprint, progress: *Progress) !void {
    if (comptime !verify) return;
    assert(progress.pass <= 1);
    assert(progress.checker == .determinism or progress.checker == .record_replay);
    inline for (@typeInfo(Fingerprint).@"struct".field_names, 0..) |name, index| {
        if (@field(expected, name) != @field(actual, name)) {
            progress.index = @intCast(index);
            progress.expected = @field(expected, name);
            progress.actual = @field(actual, name);
            return error.Determinism;
        }
    }
}

pub fn fingerprint(runtime: anytype) !Fingerprint {
    assert(runtime.host.live);
    assert(runtime.current <= 1);
    return .{
        .model = try hashing.hash(runtime.model),
        .commands = try hashing.hash(runtime.bufs[runtime.current].cmds.items),
        .rects = try hashing.hash(runtime.rects[runtime.current].items),
        .vertices = try hashing.hash(runtime.verts.items),
        .gpu = try runtime.gpu.frame_hash(),
        .input = try hashing.hash(.{
            runtime.host.last, runtime.host.clock_ms, runtime.host.scale,
        }),
    };
}

pub fn view_purity(comptime App: type, runtime: anytype, scratch: anytype) !void {
    if (comptime !verify) return;
    assert(runtime.host.live);
    assert(runtime.current <= 1);
    const before = try hashing.hash(runtime.model);
    scratch.reset();
    if (@hasDecl(App, "themeFor")) scratch.theme = App.themeFor(&runtime.model);
    App.view(&runtime.model, scratch);
    if (cmd.validateBalance(scratch.cmds.items) != null) return error.ViewBalance;
    const first = try hashing.hash(.{ scratch.theme, scratch.cmds.items });
    if (before != try hashing.hash(runtime.model)) return error.ViewMutation;
    scratch.reset();
    if (@hasDecl(App, "themeFor")) scratch.theme = App.themeFor(&runtime.model);
    App.view(&runtime.model, scratch);
    const second = try hashing.hash(.{ scratch.theme, scratch.cmds.items });
    if (first != second or before != try hashing.hash(runtime.model)) return error.ViewPurity;
}

pub fn layout_valid(runtime: anytype, progress: *Progress) !void {
    if (comptime !verify) return;
    const commands = runtime.bufs[runtime.current].cmds.items;
    const rects = runtime.rects[runtime.current].items;
    assert(runtime.current <= 1);
    assert(commands.len == rects.len);
    for (rects, 0..) |rect, index| {
        if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
            !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or
            rect.w < 0 or rect.h < 0)
        {
            progress.index = @intCast(index);
            progress.values = .{ rect.x, rect.y, rect.w, rect.h };
            return error.LayoutRect;
        }
    }
    for (commands, 0..) |command, index| switch (command) {
        .push_scroll => |style| {
            progress.index = @intCast(index);
            progress.values = .{ style.scroll_x, style.scroll_y, rects[index].w, rects[index].h };
            if (!std.math.isFinite(style.scroll_x) or !std.math.isFinite(style.scroll_y) or
                style.scroll_x < 0 or style.scroll_y < 0) return error.ScrollRange;
            if (runtime.layout_dirty) continue;
            const extent = scroll.scrollExtent(commands, rects, index);
            if (style.scroll_x > @max(0, extent.content_w - extent.viewport_w) + 0.02 or
                style.scroll_y > @max(0, extent.content_h - extent.viewport_h) + 0.02)
                return error.ScrollRange;
        },
        .text_area => |area| {
            progress.index = @intCast(index);
            progress.values = .{ area.scroll_x, area.scroll_y, rects[index].w, rects[index].h };
            try text_scroll_valid(runtime, area, rects[index]);
        },
        .push_group,
        .pop_group,
        .push_grid,
        .pop_grid,
        .pop_scroll,
        .push_overlay,
        .pop_overlay,
        .push_virtual_list,
        .pop_virtual_list,
        .text,
        .rich_text,
        .image,
        .divider,
        .button,
        .text_input,
        .checkbox,
        .radio,
        .slider,
        .canvas,
        .scene3d,
        => {},
    };
}

fn text_scroll_valid(runtime: anytype, area: anytype, rect: layout.Rect) !void {
    assert(rect.w >= 0);
    assert(rect.h >= 0);
    if (!std.math.isFinite(area.scroll_x) or !std.math.isFinite(area.scroll_y) or
        area.scroll_x < 0 or area.scroll_y < 0) return error.TextScrollRange;
    if (runtime.layout_dirty) return;
    const inner = layout.textAreaInner(rect, area);
    const width = layout.textAreaWrapWidth(inner, area);
    const mode = if (area.wrap == .ellipsis) .none else area.wrap;
    const measured = wrap.measureWrapped(area.content, area.font, width, mode, 0, runtime.measurer);
    if (area.scroll_x > @max(0, measured.w + 2 - inner.w) + 0.02 or
        area.scroll_y > @max(0, measured.h - inner.h) + 0.02) return error.TextScrollRange;
}

fn contains(rect: layout.Rect, x: f32, y: f32) bool {
    assert(std.math.isFinite(x));
    assert(std.math.isFinite(y));
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn probe(runtime: anytype, point: [2]f32, progress: *Progress) !void {
    const x = point[0];
    const y = point[1];
    const commands = runtime.bufs[runtime.current].cmds.items;
    const rects = runtime.rects[runtime.current].items;
    assert(commands.len == rects.len);
    assert(std.math.isFinite(x) and std.math.isFinite(y));
    const actual = hit_test.hitTest(commands, rects, x, y);
    progress.values = .{ x, y, -1, -1 };
    if (actual) |hit| {
        progress.index = @intCast(hit.index);
        progress.values[3] = @floatFromInt(hit.index);
        if (hit.index >= rects.len) return error.HitIndex;
        if (!contains(rects[hit.index], x, y)) return error.HitContainment;
    }
    const expected = oracle(commands, rects, .{ x, y });
    const expected_index: f32 = if (expected) |h| @floatFromInt(h.index) else -1;
    const actual_index: f32 = if (actual) |h| @floatFromInt(h.index) else -1;
    progress.values = .{ x, y, expected_index, actual_index };
    if (try hashing.hash(expected) != try hashing.hash(actual)) return error.HitOracle;
}

fn OracleHit(comptime Commands: type) type {
    return hit_test.HitResult(std.meta.Elem(Commands).MsgT);
}

fn oracle(
    commands: anytype,
    rects: []const layout.Rect,
    point: [2]f32,
) ?OracleHit(@TypeOf(commands)) {
    assert(commands.len == rects.len);
    assert(std.math.isFinite(point[0]) and std.math.isFinite(point[1]));
    var base: ?OracleHit(@TypeOf(commands)) = null;
    for (0..commands.len) |offset| {
        const index = commands.len - offset - 1;
        const command = commands[index];
        const modal = command == .push_overlay and command.push_overlay.modal;
        if (!modal and !interactive(command)) continue;
        if (!contains(rects[index], point[0], point[1])) continue;
        const ancestry = ancestors(commands, rects, index, point);
        if (!ancestry.visible) continue;
        const hit: OracleHit(@TypeOf(commands)) = .{
            .index = index,
            .msg = if (modal) command.push_overlay.backdrop_msg else cmd.leafMsg(command),
        };
        if (modal or ancestry.overlay) return hit;
        if (base == null) base = hit;
    }
    return base;
}

const Ancestry = struct { visible: bool = true, overlay: bool = false };
const ClipBounds = struct {
    lower: [2]f32 = .{ -1e9, -1e9 },
    upper: [2]f32 = .{ 1e9, 1e9 },

    fn add_rect(self: *ClipBounds, rect: layout.Rect) void {
        assert(rect.w >= 0);
        assert(rect.h >= 0);
        self.lower = .{ @max(self.lower[0], rect.x), @max(self.lower[1], rect.y) };
        self.upper = .{
            @min(self.upper[0], rect.x + rect.w),
            @min(self.upper[1], rect.y + rect.h),
        };
    }

    fn includes(self: *const ClipBounds, point: [2]f32) bool {
        return self.lower[0] < self.upper[0] and self.lower[1] < self.upper[1] and
            point[0] >= self.lower[0] and point[0] <= self.upper[0] and
            point[1] >= self.lower[1] and point[1] <= self.upper[1];
    }
};

fn ancestors(commands: anytype, rects: []const layout.Rect, index: usize, point: [2]f32) Ancestry {
    assert(index < commands.len);
    assert(commands.len == rects.len);
    var result: Ancestry = .{};
    var clip: ClipBounds = .{};
    var closed: u32 = 0;
    for (0..index) |offset| {
        const parent = index - offset - 1;
        switch (commands[parent]) {
            .pop_scroll, .pop_overlay => closed += 1,
            .push_scroll, .push_overlay => {
                if (closed > 0) {
                    closed -= 1;
                    continue;
                }
                clip.add_rect(rects[parent]);
                if (commands[parent] == .push_overlay) result.overlay = true;
            },
            .push_group,
            .pop_group,
            .push_grid,
            .pop_grid,
            .push_virtual_list,
            .pop_virtual_list,
            .text,
            .rich_text,
            .image,
            .divider,
            .button,
            .text_input,
            .text_area,
            .checkbox,
            .radio,
            .slider,
            .canvas,
            .scene3d,
            => {},
        }
    }
    result.visible = clip.includes(point);
    return result;
}

fn interactive(command: anytype) bool {
    return switch (command) {
        .button => |b| !b.disabled,
        .text_input => |t| !t.disabled,
        .text_area => |t| !t.disabled,
        .checkbox, .radio, .slider => true,
        .canvas => |c| c.pointer or c.msg != null,
        .scene3d => |c| c.pointer or c.msg != null,
        .push_group,
        .pop_group,
        .push_grid,
        .pop_grid,
        .push_scroll,
        .pop_scroll,
        .push_overlay,
        .pop_overlay,
        .push_virtual_list,
        .pop_virtual_list,
        .text,
        .rich_text,
        .image,
        .divider,
        => false,
    };
}

pub fn hit_valid(runtime: anytype, progress: *Progress) !void {
    if (comptime !verify) return;
    const rects = runtime.rects[runtime.current].items;
    assert(runtime.current <= 1);
    assert(runtime.host.live);
    try probe(runtime, .{ runtime.host.last.mouse_x, runtime.host.last.mouse_y }, progress);
    if (rects.len == 0) return;
    for (0..4) |sample| {
        const rect = rects[(@as(u64, progress.frame) * 7 + sample * 31) % rects.len];
        try probe(runtime, .{ rect.x + rect.w / 2, rect.y + rect.h / 2 }, progress);
        try probe(runtime, .{ rect.x - 0.125, rect.y + rect.h / 2 }, progress);
        try probe(runtime, .{ rect.x + rect.w + 0.125, rect.y + rect.h / 2 }, progress);
        try probe(runtime, .{ rect.x + rect.w / 2, rect.y + rect.h + 0.125 }, progress);
    }
}

pub fn focus_valid(runtime: anytype) !void {
    if (comptime !verify) return;
    const commands = runtime.bufs[runtime.current].cmds.items;
    assert(runtime.current <= 1);
    assert(commands.len == runtime.rects[runtime.current].items.len);
    for ([_]?usize{ runtime.ts.focus_index, runtime.ts.nav_index }) |focused| {
        if (focused) |index| {
            if (index >= commands.len or !navigable(commands[index], false))
                return error.FocusIndex;
        }
    }
    const scope = focus.modalScope(commands);
    const low = if (scope) |s| s.lo else 0;
    const high = if (scope) |s| s.hi else commands.len;
    var previous: ?usize = null;
    var last: ?usize = null;
    var first: ?usize = null;
    for (low..high) |index| {
        if (!navigable(commands[index], true)) continue;
        if (focus.nextNavigable(commands, previous) != index) return error.FocusCycle;
        if (previous) |p| {
            if (focus.prevNavigable(commands, index) != p) return error.FocusCycle;
        }
        if (first == null) first = index;
        previous = index;
        last = index;
    }
    if (focus.nextNavigable(commands, last) != first or
        focus.prevNavigable(commands, first) != last) return error.FocusCycle;
}

pub fn navigable(command: anytype, tab_stop: bool) bool {
    assert(@sizeOf(@TypeOf(command)) > 0);
    assert(@typeInfo(@TypeOf(command)) == .@"union");
    return switch (command) {
        .button => |b| !b.disabled and (!tab_stop or b.tab_stop),
        .text_input => |t| !t.disabled,
        .text_area => |t| !t.disabled,
        .checkbox, .radio, .slider => true,
        .canvas => |c| c.msg != null,
        .push_group,
        .pop_group,
        .push_grid,
        .pop_grid,
        .push_scroll,
        .pop_scroll,
        .push_overlay,
        .pop_overlay,
        .push_virtual_list,
        .pop_virtual_list,
        .text,
        .rich_text,
        .image,
        .divider,
        .scene3d,
        => false,
    };
}
