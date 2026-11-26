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
    assert(progress.checker == .determinism);
    inline for (@typeInfo(Fingerprint).@"struct".field_names, 0..) |name, index| {
        if (@field(expected, name) != @field(actual, name)) {
            progress.index = @intCast(index);
            progress.expected = @field(expected, name);
            progress.actual = @field(actual, name);
            return error.Determinism;
        }
    }
}

pub fn fingerprint(runtime: anytype, generated: anytype) !Fingerprint {
    assert(runtime.host.live);
    assert(runtime.current <= 1);
    return .{
        .model = try hashing.hash(runtime.model),
        .commands = try hashing.hash(runtime.bufs[runtime.current].cmds.items),
        .rects = try hashing.hash(runtime.rects[runtime.current].items),
        .vertices = try hashing.hash(runtime.verts.items),
        .gpu = try runtime.gpu.frame_hash(),
        .input = try hashing.hash(.{ generated.advance_ms, generated.events[0..generated.count] }),
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

fn probe(runtime: anytype, x: f32, y: f32) !void {
    const commands = runtime.bufs[runtime.current].cmds.items;
    const rects = runtime.rects[runtime.current].items;
    assert(commands.len == rects.len);
    assert(std.math.isFinite(x) and std.math.isFinite(y));
    if (hit_test.hitTest(commands, rects, x, y)) |hit| {
        if (hit.index >= rects.len) return error.HitIndex;
        if (!contains(rects[hit.index], x, y)) return error.HitContainment;
    }
}

pub fn hit_valid(runtime: anytype, frame: u32) !void {
    if (comptime !verify) return;
    const rects = runtime.rects[runtime.current].items;
    assert(runtime.current <= 1);
    assert(runtime.host.live);
    try probe(runtime, runtime.host.last.mouse_x, runtime.host.last.mouse_y);
    if (rects.len == 0) return;
    for (0..4) |sample| {
        const rect = rects[(@as(u64, frame) * 7 + sample * 31) % rects.len];
        try probe(runtime, rect.x + rect.w / 2, rect.y + rect.h / 2);
        try probe(runtime, rect.x - 0.125, rect.y + rect.h / 2);
        try probe(runtime, rect.x + rect.w + 0.125, rect.y + rect.h / 2);
        try probe(runtime, rect.x + rect.w / 2, rect.y + rect.h + 0.125);
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

fn navigable(command: anytype, tab_stop: bool) bool {
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
