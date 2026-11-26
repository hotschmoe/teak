//! See SRC.md, src/sim/runner.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const run = @import("../run.zig");
const cmd = @import("../core/cmd.zig");
const input = @import("input.zig");
const workload = @import("workload.zig");
const check = @import("check.zig");
const hashing = @import("hash.zig");
const Gpu = @import("gpu.zig").Gpu;
const verify = @import("sim.zig").verify;

pub const settle_frames = 32;
pub const quiet_deadline = 8;

pub const Counters = struct {
    clicks_dispatched: u64 = 0,
    text_dispatched: u64 = 0,
    tab_moved: u64 = 0,
    drag_started: u64 = 0,
    drag_cancelled_focus_loss: u64 = 0,
    zero_size: u64 = 0,
    scroll_changed: u64 = 0,
    quiet: u64 = 0,
    skipped_unchanged: u64 = 0,
    idle_checked: u64 = 0,
    idle_exempt: u64 = 0,
    idle_grace: u64 = 0,
    effects_issued: u64 = 0,
    effects_unanswered: u64 = 0,
    resources_created: u64 = 0,
    resources_released: u64 = 0,
    limits: u64 = 0,
    unsupported: u64 = 0,
    messages: u64 = 0,
};

pub const Config = struct {
    seed: u64,
    workload_frames: u32,
    frames: []input.Frame,
    fingerprints: []check.Fingerprint,
    progress: *check.Progress,
    replay: bool = false,
    cleanup_model: ?*const fn (*anyopaque) void = null,
};
pub const Report = struct {
    counters: Counters,
    kinds: [workload.weights.len]u64,
    events: [@typeInfo(input.Event).@"union".field_names.len]u64,
    final_hash: u64,
};
const IdleWatch = struct {
    counters: *Counters,
    eligible: u32 = 0,
    settled: bool = false,
};

pub fn simulate(
    comptime App: type,
    comptime Host: type,
    allocator: std.mem.Allocator,
    config: Config,
) !Report {
    assert(config.frames.len == config.fingerprints.len);
    assert(config.frames.len > 0);
    var first: Report = undefined;
    for (0..2) |pass| {
        config.progress.pass = @intCast(pass);
        const report = try run_pass(App, Host, allocator, config);
        if (pass == 0) first = report else {
            config.progress.checker = .determinism;
            const expected = try hashing.hash(first);
            const actual = try hashing.hash(report);
            if (expected != actual) {
                config.progress.expected = expected;
                config.progress.actual = actual;
                return error.DeterminismCounters;
            }
        }
    }
    return first;
}

fn run_pass(
    comptime App: type,
    comptime Host: type,
    allocator: std.mem.Allocator,
    config: Config,
) !Report {
    assert(config.progress.pass <= 1);
    assert(config.frames.len > 0);
    config.progress.frame = 0;
    config.progress.checker = .no_stop;
    if (!config.replay and config.progress.pass == 0) {
        config.frames[0] = .{};
        config.progress.recorded = 1;
    }
    var host = try Host.init();
    var host_live = true;
    defer if (host_live) host.deinit();
    var gpu: Gpu = .{};
    var runtime = try run.Runtime(App, Host, Gpu).init(allocator, &host, &gpu, .{
        .inspect_hotkey = false,
    });
    var runtime_live = true;
    defer {
        if (runtime_live) runtime.deinit();
        if (config.cleanup_model) |cleanup| cleanup(@ptrCast(&runtime.model));
    }
    var scratch = cmd.CmdBuffer(App.Msg).init(allocator);
    defer scratch.deinit();
    var generator: workload.Generator = .{ .state = config.seed };
    var counters: Counters = .{};
    var idle: IdleWatch = .{ .counters = &counters };
    for (0..config.frames.len) |index| {
        config.progress.frame = @intCast(index);
        config.progress.checker = .no_stop;
        const generated = try next_frame(&generator, &runtime, config, @intCast(index));
        host.next = generated;
        gpu.begin();
        const before = observe(&runtime);
        try runtime.frame();
        try check_frame(App, &runtime, &scratch, config.progress);
        try count_frame(&counters, &runtime, before, config.progress);
        try idle_valid(App, &runtime, config, @intCast(index), &idle);
        config.progress.checker = .determinism;
        const fingerprint = try check.fingerprint(&runtime, generated);
        if (config.progress.pass == 0) config.fingerprints[index] = fingerprint else {
            try check.deterministic(config.fingerprints[index], fingerprint, config.progress);
        }
    }
    runtime_live = false;
    host_live = false;
    return finish(&runtime, &generator, &counters, config);
}

fn finish(
    runtime: anytype,
    generator: *const workload.Generator,
    counters: *Counters,
    config: Config,
) !Report {
    assert(runtime.host.live);
    assert(runtime.gpu.live);
    config.progress.checker = .resources;
    runtime.deinit();
    runtime.gpu.deinit();
    runtime.host.deinit();
    if (runtime.gpu.failure) |err| return err;
    if (runtime.host.failure) |err| return err;
    counters.effects_issued = runtime.host.effects_issued;
    counters.effects_unanswered = runtime.host.unanswered;
    counters.resources_created = runtime.gpu.created;
    counters.resources_released = runtime.gpu.released;
    counters.limits = runtime.host.limits + runtime.gpu.limits + generator.limits;
    counters.unsupported = runtime.host.unsupported;
    counters.messages = runtime.dispatch_count;
    counters.clicks_dispatched = runtime.click_dispatches;
    counters.text_dispatched = runtime.text_dispatches;
    counters.tab_moved = runtime.tab_moves;
    return .{
        .counters = counters.*,
        .kinds = generator.counts,
        .events = generator.events,
        .final_hash = try hashing.hash(config.fingerprints),
    };
}

fn next_frame(
    generator: *workload.Generator,
    runtime: anytype,
    config: Config,
    index: u32,
) !input.Frame {
    assert(index < config.frames.len);
    assert(config.workload_frames > 0);
    if (config.replay) return config.frames[index];
    const generated: input.Frame = if (index < config.workload_frames)
        try generator.next(runtime)
    else if (index == config.workload_frames) block: {
        var frame: input.Frame = .{ .advance_ms = 16 };
        try frame.push(.focus_loss);
        break :block frame;
    } else .{ .advance_ms = 16 };
    if (config.progress.pass == 0) {
        config.frames[index] = generated;
        config.progress.recorded = index + 1;
    }
    return generated;
}

fn check_frame(
    comptime App: type,
    runtime: anytype,
    scratch: anytype,
    progress: *check.Progress,
) !void {
    if (comptime !verify) @compileError("simulation requires verification");
    assert(runtime.host.live);
    assert(runtime.gpu.live);
    progress.checker = .resources;
    if (runtime.gpu.failure) |err| return err;
    if (runtime.host.failure) |err| return err;
    progress.checker = .view_purity;
    try check.view_purity(App, runtime, scratch);
    progress.checker = .layout;
    try check.layout_valid(runtime, progress);
    progress.checker = .hit_test;
    try check.hit_valid(runtime, progress.frame);
    progress.checker = .focus;
    try check.focus_valid(runtime);
}

const Observation = struct {
    dispatched: u64,
    scroll_hash: u64,
    drag_active: bool,
};

fn observe(runtime: anytype) Observation {
    const commands = runtime.bufs[runtime.current].cmds.items;
    const rects = runtime.rects[runtime.current].items;
    assert(commands.len == rects.len);
    assert(runtime.host.live);
    return .{
        .dispatched = runtime.dispatch_count,
        .scroll_hash = scroll_hash(commands),
        .drag_active = runtime.drag.phase == .active,
    };
}

fn scroll_hash(commands: anytype) u64 {
    var hasher: hashing.Hasher = .{};
    assert(hasher.count == 0);
    for (commands) |command| switch (command) {
        .push_scroll => |s| {
            if (s.scroll_x == 0 and s.scroll_y == 0) continue;
            hasher.word(@as(u32, @bitCast(s.scroll_x)));
            hasher.word(@as(u32, @bitCast(s.scroll_y)));
        },
        .text_area => |s| {
            if (s.scroll_x == 0 and s.scroll_y == 0) continue;
            hasher.word(@as(u32, @bitCast(s.scroll_x)));
            hasher.word(@as(u32, @bitCast(s.scroll_y)));
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
    assert(hasher.count == 0);
    return hasher.finish();
}

fn count_frame(
    counters: *Counters,
    runtime: anytype,
    before: Observation,
    progress: *check.Progress,
) !void {
    const last = runtime.host.last;
    const commands = runtime.bufs[runtime.current].cmds.items;
    assert(runtime.current <= 1);
    assert(runtime.host.live);
    if (comptime verify) {
        progress.checker = .idle;
        if (runtime.quiet and runtime.dispatch_count != before.dispatched)
            return error.QuietAfterDispatch;
    }
    if (!before.drag_active and runtime.drag.phase == .active) counters.drag_started += 1;
    if (before.drag_active and last.focus_lost and runtime.drag.phase == .idle)
        counters.drag_cancelled_focus_loss += 1;
    if (last.width == 0 or last.height == 0) counters.zero_size += 1;
    if (scroll_hash(commands) != before.scroll_hash) counters.scroll_changed += 1;
    if (runtime.quiet) counters.quiet += 1;
    if (!runtime.quiet and !runtime.stats.rebuilt) counters.skipped_unchanged += 1;
}

fn idle_valid(
    comptime App: type,
    runtime: anytype,
    config: Config,
    index: u32,
    state: *IdleWatch,
) !void {
    if (comptime !verify) return;
    assert(index < config.frames.len);
    assert(config.workload_frames > 0);
    if (index <= config.workload_frames) return;
    config.progress.checker = .idle;
    const subscribed = if (@hasDecl(App, "subscribe"))
        App.subscribe(&runtime.model).len > 0
    else
        false;
    var effects = false;
    if (@hasDecl(App, "effects")) for (App.effects(&runtime.model)) |effect| {
        if (effect.wantsResult() or !runtime.issued.contains(effect.id())) effects = true;
    };
    if (subscribed or effects) {
        state.eligible = 0;
        state.settled = false;
        state.counters.idle_exempt += 1;
        return;
    }
    state.eligible += 1;
    if (!runtime.quiet) {
        if (state.settled or state.eligible >= quiet_deadline) return error.Idle;
        state.counters.idle_grace += 1;
        return;
    }
    state.settled = true;
    state.counters.idle_checked += 1;
}
