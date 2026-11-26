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
const live_focus = @import("live_focus.zig");
const recording = @import("recording.zig");

pub const settle_frames = 32;
pub const quiet_deadline = 8;

pub const Counters = struct {
    clicks_dispatched: u64 = 0,
    text_dispatched: u64 = 0,
    tab_moved: u64 = 0,
    mixed_bursts: u64 = 0,
    burst_pointer: u64 = 0,
    burst_keys: u64 = 0,
    burst_text: u64 = 0,
    focus_cycles: u64 = 0,
    focus_set_changed: u64 = 0,
    focus_tabs: u64 = 0,
    focus_pending: u64 = 0,
    file_reads: u64 = 0,
    file_replace: u64 = 0,
    file_atomic: u64 = 0,
    file_append: u64 = 0,
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
    record_check: bool = false,
    record_bytes: []u8,
    record_len: *u32,
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
    config.record_len.* = 0;
    var first: Report = undefined;
    for (0..2) |pass| {
        config.progress.pass = @intCast(pass);
        const report = try run_pass(App, Host, allocator, config);
        if (pass == 0) first = report else if (!config.record_check) {
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
        .snapshot_path = recording.snapshot_path,
        .record_path = recording.recording_path,
        .stats_path = "frame.stats",
    });
    var runtime_live = true;
    defer {
        if (runtime_live) runtime.deinit();
        if (config.cleanup_model) |cleanup| cleanup(@ptrCast(&runtime.model));
    }
    var scratch = cmd.CmdBuffer(App.Msg).init(allocator);
    defer scratch.deinit();
    var state = try drive(App, &runtime, &scratch, config);
    runtime_live = false;
    host_live = false;
    return finish(&runtime, &state.generator, &state.counters, config);
}

const RunState = struct {
    generator: workload.Generator,
    counters: Counters = .{},
    cycle: live_focus.State = .{},
};

fn drive(comptime App: type, runtime: anytype, scratch: anytype, config: Config) !RunState {
    assert(runtime.host.live);
    assert(runtime.gpu.live);
    var state: RunState = .{ .generator = .{ .state = config.seed } };
    var idle: IdleWatch = .{ .counters = &state.counters };
    const source = try record_source(runtime, config);
    defer if (source) |bytes| runtime.gpa.free(bytes);
    var playback: recording.Replay = .{ .bytes = config.record_bytes[0..config.record_len.*] };
    if (source) |bytes| playback.bytes = bytes;
    for (0..config.frames.len) |index| {
        config.progress.frame = @intCast(index);
        config.progress.checker = .no_stop;
        const from_record = config.record_check and config.progress.pass == 1;
        const generated = if (from_record) input.Frame{} else try next_frame(
            &state.generator,
            runtime,
            config,
            @intCast(index),
            &state.cycle,
        );
        if (from_record) runtime.host.recorded_input = try playback.next(@intCast(index));
        runtime.host.next = generated;
        runtime.gpu.begin();
        const before = observe(runtime);
        try runtime.frame();
        if (generated.focus_probe) try state.cycle.observe(runtime, config.progress);
        count_burst(&state.counters, generated);
        try check_frame(App, runtime, scratch, config.progress);
        try count_frame(&state.counters, runtime, before, config.progress);
        try idle_valid(App, runtime, config, @intCast(index), &idle);
        config.progress.checker = if (from_record) .record_replay else .determinism;
        const fingerprint = try check.fingerprint(runtime);
        if (config.progress.pass == 0) config.fingerprints[index] = fingerprint else {
            try check.deterministic(config.fingerprints[index], fingerprint, config.progress);
        }
    }
    state.counters.focus_cycles = state.cycle.completed;
    state.counters.focus_set_changed = state.cycle.changed_set;
    state.counters.focus_tabs = state.cycle.tabs;
    state.counters.focus_pending = @intFromBool(state.cycle.active);
    state.counters.limits += state.cycle.limited;
    return state;
}

fn record_source(runtime: anytype, config: Config) !?[]u8 {
    assert(runtime.host.live);
    assert(config.progress.pass <= 1);
    if (!config.record_check or config.progress.pass == 0) return null;
    const files = runtime.host.files();
    try files.write(
        files.ctx,
        recording.recording_path,
        config.record_bytes[0..config.record_len.*],
        .replace,
    );
    return try files.read(
        files.ctx,
        runtime.gpa,
        recording.recording_path,
        @import("files.zig").file_bytes_max,
    );
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
    errdefer if (runtime.gpu.live) runtime.gpu.deinit();
    errdefer if (runtime.host.live) runtime.host.deinit();
    try copy_record(runtime, config);
    runtime.gpu.deinit();
    runtime.host.deinit();
    if (runtime.gpu.failure) |err| return err;
    if (runtime.host.failure) |err| return err;
    counters.effects_issued = runtime.host.effects_issued;
    counters.effects_unanswered = runtime.host.unanswered;
    counters.resources_created = runtime.gpu.created;
    counters.resources_released = runtime.gpu.released;
    counters.limits += runtime.host.limits + runtime.gpu.limits + generator.limits;
    counters.unsupported = runtime.host.unsupported;
    counters.messages = runtime.dispatch_count;
    counters.clicks_dispatched = runtime.click_dispatches;
    counters.text_dispatched = runtime.text_dispatches;
    counters.tab_moved = runtime.tab_moves;
    counters.file_reads = runtime.host.file_table.reads;
    counters.file_replace = runtime.host.file_table.writes[0];
    counters.file_atomic = runtime.host.file_table.writes[1];
    counters.file_append = runtime.host.file_table.writes[2];
    counters.limits += runtime.host.file_table.limits;
    return .{
        .counters = counters.*,
        .kinds = generator.counts,
        .events = generator.events,
        .final_hash = try hashing.hash(config.fingerprints),
    };
}

fn copy_record(runtime: anytype, config: Config) !void {
    assert(runtime.host.live);
    assert(config.record_bytes.len >= @import("files.zig").file_bytes_max);
    const bytes = runtime.host.file_table.get(recording.recording_path) orelse
        return error.RecordingMissing;
    if (config.progress.pass == 0) {
        @memcpy(config.record_bytes[0..bytes.len], bytes);
        config.record_len.* = @intCast(bytes.len);
    }
}

fn next_frame(
    generator: *workload.Generator,
    runtime: anytype,
    config: Config,
    index: u32,
    cycle: *live_focus.State,
) !input.Frame {
    assert(index < config.frames.len);
    assert(config.workload_frames > 0);
    if (config.replay) {
        if (config.frames[index].focus_probe and !try cycle.prepare(runtime, true))
            return error.LiveFocusReplay;
        return config.frames[index];
    }
    const eligible = index % 32 == 1 and generator.phase == .ready;
    const probing = index < config.workload_frames and try cycle.prepare(runtime, eligible);
    const generated: input.Frame = if (probing)
        live_focus.tab_frame()
    else if (index < config.workload_frames)
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

fn count_burst(counters: *Counters, frame: input.Frame) void {
    assert(frame.count <= input.events_max);
    assert(frame.advance_ms <= 300000);
    if (frame.count < 12) return;
    var pointer_count: u32 = 0;
    var keys_count: u32 = 0;
    var text_count: u32 = 0;
    for (frame.events[0..frame.count]) |event| switch (event) {
        .move, .down, .up, .wheel => pointer_count += 1,
        .key => keys_count += 1,
        .text => text_count += 1,
        .modifiers, .shortcut, .resize, .scale, .focus_loss => {},
    };
    if (pointer_count == 0 or keys_count == 0 or text_count == 0) return;
    counters.mixed_bursts += 1;
    counters.burst_pointer += pointer_count;
    counters.burst_keys += keys_count;
    counters.burst_text += text_count;
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
    try check.hit_valid(runtime, progress);
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
