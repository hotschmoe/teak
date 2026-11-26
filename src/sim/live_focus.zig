//! See SRC.md, src/sim/live_focus.zig.
const assert = @import("../assert.zig").assert;
const focus = @import("../input/focus.zig");
const cmd = @import("../core/cmd.zig");
const hashing = @import("hash.zig");
const input = @import("input.zig");
const check = @import("check.zig");

pub const stops_max = 2048;
pub const State = struct {
    signature: u64 = 0,
    count: u32 = 0,
    start: ?u32 = null,
    steps: u32 = 0,
    visited: [stops_max]bool = @splat(false),
    active: bool = false,
    completed: u64 = 0,
    changed_set: u64 = 0,
    limited: u64 = 0,
    tabs: u64 = 0,

    pub fn prepare(self: *State, runtime: anytype, eligible: bool) !bool {
        assert(runtime.host.next.count == 0);
        assert(runtime.host.live);
        if (self.active) return true;
        if (!eligible or runtime.layout_dirty or runtime.host.queue.buttons.any()) return false;
        const set = try inventory(runtime);
        if (set.count < 2) return false;
        if (set.count > stops_max) {
            self.limited += 1;
            return false;
        }
        self.signature = set.signature;
        self.count = set.count;
        self.start = current(runtime);
        if (self.start) |index| {
            const commands = runtime.bufs[runtime.current].cmds.items;
            const scope = focus.modalScope(commands);
            const inside = if (scope) |s| index >= s.lo and index < s.hi else true;
            if (!inside or !check.navigable(commands[index], true)) self.start = null;
        }
        self.steps = 0;
        @memset(&self.visited, false);
        self.active = true;
        return true;
    }

    pub fn observe(self: *State, runtime: anytype, progress: *check.Progress) !void {
        assert(self.active);
        assert(self.count >= 2 and self.count <= stops_max);
        progress.checker = .focus;
        self.tabs += 1;
        const set = try inventory(runtime);
        if (self.signature != set.signature or self.count != set.count) {
            self.changed_set += 1;
            self.active = false;
            return;
        }
        const index = current(runtime) orelse return error.LiveFocusMissing;
        if (self.start == null) {
            self.start = index;
            return;
        }
        const ordinal = try rank(runtime, index);
        assert(ordinal < self.count);
        if (self.visited[ordinal]) return error.LiveFocusDuplicate;
        self.visited[ordinal] = true;
        self.steps += 1;
        assert(self.steps <= self.count);
        if (self.steps != self.count) return;
        if (index != self.start) return error.LiveFocusReturn;
        for (self.visited[0..self.count]) |seen| if (!seen) return error.LiveFocusSkipped;
        self.completed += 1;
        self.active = false;
    }
};

fn current(runtime: anytype) ?u32 {
    assert(runtime.current <= 1);
    assert(runtime.ts.focus_index == null or runtime.ts.nav_index == null);
    const index = runtime.ts.nav_index orelse runtime.ts.focus_index;
    return if (index) |i| @intCast(i) else null;
}

fn inventory(runtime: anytype) !struct { signature: u64, count: u32 } {
    const commands = runtime.bufs[runtime.current].cmds.items;
    const scope = focus.modalScope(commands);
    const low = if (scope) |s| s.lo else 0;
    const high = if (scope) |s| s.hi else commands.len;
    assert(low <= high);
    assert(high <= commands.len);
    var hasher: hashing.Hasher = .{};
    var count: u32 = 0;
    for (low..high) |index| {
        if (!check.navigable(commands[index], true)) continue;
        try hasher.add(.{ index, cmd.leafMsg(commands[index]) });
        count += 1;
    }
    return .{ .signature = hasher.finish(), .count = count };
}

fn rank(runtime: anytype, target: u32) !u32 {
    const commands = runtime.bufs[runtime.current].cmds.items;
    const scope = focus.modalScope(commands);
    const low = if (scope) |s| s.lo else 0;
    const high = if (scope) |s| s.hi else commands.len;
    assert(target < commands.len);
    assert(low <= high and high <= commands.len);
    var ordinal: u32 = 0;
    for (low..high) |index| {
        if (!check.navigable(commands[index], true)) continue;
        if (index == target) return ordinal;
        ordinal += 1;
    }
    return error.LiveFocusOutsideScope;
}

pub fn tab_frame() input.Frame {
    var frame: input.Frame = .{ .advance_ms = 0, .focus_probe = true };
    frame.events[0] = .{ .key = .tab };
    frame.count = 1;
    return frame;
}
