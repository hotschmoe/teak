//! See SRC.md, src/platform/sim/main.zig.
const std = @import("std");
const teak = @import("teak");
const assert = teak.assert;
const sim = teak.sim;
const build_options = @import("sim-options");
const Host = sim.Host(sim.Metrics(@import("teak-text").Font));

const frames_max = 100000;
const trace_bytes_max = 128 * 1024 * 1024;
const Options = struct {
    app: sim.trace.App = .todo,
    seed: ?u64 = null,
    frames: u32 = 1000,
    seeds: u32 = 1,
    budget_ms: u32 = 0,
    replay: ?[]const u8 = null,
    save: ?[]const u8 = null,
};
const Diagnostics = struct {
    io: std.Io,
    directory: std.Io.Dir,
    header: sim.trace.Header,
    progress: sim.check.Progress = .{},
    frames: []sim.input.Frame,
    bytes: []u8,
};
var diagnostics: ?*Diagnostics = null;
var reporting_panic: bool = false;
pub const panic = std.debug.FullPanic(panic_report);

fn panic_report(message: []const u8, address: ?usize) noreturn {
    if (!reporting_panic) {
        reporting_panic = true;
        if (diagnostics) |state| {
            report_failure(state, message) catch |err|
                std.debug.print("failure artifact error: {s}\n", .{@errorName(err)});
        }
    }
    std.debug.defaultPanic(message, address);
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options = try parse_options(arguments);
    assert(options.frames > 0);
    assert(options.frames <= frames_max);
    const capacity = if (options.replay != null)
        frames_max + sim.runner.settle_frames
    else
        options.frames + sim.runner.settle_frames;
    const frames = try init.gpa.alloc(sim.input.Frame, capacity);
    defer init.gpa.free(frames);
    const fingerprints = try init.gpa.alloc(sim.check.Fingerprint, capacity);
    defer init.gpa.free(fingerprints);
    const bytes = try init.gpa.alloc(u8, trace_bytes_max);
    defer init.gpa.free(bytes);
    var seed_bytes: [8]u8 = undefined;
    var seed = options.seed orelse block: {
        init.io.random(&seed_bytes);
        break :block std.mem.readInt(u64, &seed_bytes, .little);
    };
    var state: Diagnostics = .{
        .io = init.io,
        .directory = std.Io.Dir.cwd(),
        .frames = frames,
        .bytes = bytes,
        .header = .{
            .app = options.app,
            .seed = seed,
            .commit = build_options.commit,
            .workload_frames = options.frames,
        },
    };
    var count = capacity;
    if (options.replay) |path| {
        const loaded = try load_trace(init, path, &state);
        state.header = loaded.header;
        std.debug.print("REPLAY app={s} seed={d} trace_commit={s} build_commit={s}\n", .{
            @tagName(loaded.header.app), loaded.header.seed, loaded.header.commit,
            build_options.commit,
        });
        state.progress.recorded = loaded.count;
        count = loaded.count;
        options.app = loaded.header.app;
        options.frames = loaded.header.workload_frames;
        seed = loaded.header.seed;
    }
    diagnostics = &state;
    defer diagnostics = null;
    try run_seeds(init, options, &state, fingerprints[0..count], seed);
}

fn parse_options(arguments: []const []const u8) !Options {
    assert(arguments.len > 0);
    var result: Options = .{};
    var index: u32 = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 == arguments.len) return error.MissingArgument;
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--app")) {
            result.app = std.meta.stringToEnum(sim.trace.App, value) orelse
                return error.UnknownApp;
        } else if (std.mem.eql(u8, flag, "--seed")) {
            result.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, flag, "--frames")) {
            result.frames = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--seeds")) {
            result.seeds = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--budget-ms")) {
            result.budget_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--replay")) {
            result.replay = value;
        } else if (std.mem.eql(u8, flag, "--save")) {
            result.save = value;
        } else return error.UnknownArgument;
    }
    if (result.frames == 0 or result.frames > frames_max or result.seeds == 0)
        return error.ArgumentRange;
    assert(index >= arguments.len);
    return result;
}

fn load_trace(
    init: std.process.Init,
    path: []const u8,
    state: *Diagnostics,
) !sim.trace.Loaded {
    assert(state.frames.len > 0);
    assert(state.bytes.len == trace_bytes_max);
    const bytes = try state.directory.readFileAlloc(
        init.io,
        path,
        init.arena.allocator(),
        .limited(trace_bytes_max),
    );
    const loaded = try sim.trace.read(init.arena.allocator(), bytes, state.frames);
    return .{ .header = loaded.header, .count = loaded.count };
}

fn run_seeds(
    init: std.process.Init,
    options: Options,
    state: *Diagnostics,
    fingerprints: []sim.check.Fingerprint,
    seed_start: u64,
) !void {
    assert(fingerprints.len > 0);
    assert(options.seeds > 0);
    const start = clock_ns(state);
    for (0..options.seeds) |offset| {
        const seed = seed_start +% offset;
        state.header.seed = seed;
        state.header.commit = build_options.commit;
        const recorded = state.progress.recorded;
        state.progress = .{ .recorded = if (options.replay != null) recorded else 0 };
        const config: sim.runner.Config = .{
            .seed = seed,
            .workload_frames = options.frames,
            .frames = state.frames[0..fingerprints.len],
            .fingerprints = fingerprints,
            .progress = &state.progress,
            .replay = options.replay != null,
        };
        const began = clock_ns(state);
        const report = dispatch(init.gpa, options.app, config) catch |err| {
            try report_failure(state, @errorName(err));
            return err;
        };
        const duration = clock_ns(state) - began;
        print_report(options.app, seed, report, fingerprints.len, duration);
        if (options.save) |path| try save_trace(state, path);
        const elapsed = clock_ns(state) - start;
        if (options.budget_ms > 0 and elapsed >= @as(i128, options.budget_ms) * 1000000)
            break;
    }
}

fn clock_ns(state: *Diagnostics) i128 {
    assert(state.frames.len > 0);
    assert(state.bytes.len == trace_bytes_max);
    return std.Io.Clock.awake.now(state.io).nanoseconds;
}

fn dispatch(
    allocator: std.mem.Allocator,
    app: sim.trace.App,
    config: sim.runner.Config,
) !sim.runner.Report {
    assert(config.frames.len > 0);
    assert(config.progress.pass == 0);
    return switch (app) {
        .todo => sim.runner.simulate(@import("todo"), Host, allocator, config),
        .probe => sim.runner.simulate(sim.probe, Host, allocator, config),
        .counter_greeter => sim.runner.simulate(
            @import("counter_greeter"),
            Host,
            allocator,
            config,
        ),
        .tree => sim.runner.simulate(@import("tree"), Host, allocator, config),
        .gallery => sim.runner.simulate(@import("gallery"), Host, allocator, config),
        .notes => sim.runner.simulate(@import("notes"), Host, allocator, config),
        .tables => block: {
            var tables_config = config;
            tables_config.cleanup_model = cleanup_tables;
            break :block sim.runner.simulate(@import("tables"), Host, allocator, tables_config);
        },
    };
}

fn cleanup_tables(context: *anyopaque) void {
    const model: *@import("tables").Model = @ptrCast(@alignCast(context));
    assert(@intFromPtr(model.table) != @intFromPtr(model.list));
    assert(@intFromPtr(model.list) != @intFromPtr(model.tree));
    std.heap.page_allocator.destroy(model.table);
    std.heap.page_allocator.destroy(model.list);
    std.heap.page_allocator.destroy(model.tree);
}

fn print_report(
    app: sim.trace.App,
    seed: u64,
    report: sim.runner.Report,
    frames: usize,
    duration: i128,
) void {
    assert(frames > 0);
    assert(duration >= 0);
    const seconds = @as(f64, @floatFromInt(@max(duration, 1))) / 1.0e9;
    const fps = @as(f64, @floatFromInt(frames * 2)) / seconds;
    std.debug.print("PASS app={s} seed={d} commit={s} frames={d} passes=2 " ++
        "fps={d:.0} hash={x}\n", .{
        @tagName(app), seed, build_options.commit, frames, fps, report.final_hash,
    });
    for (sim.workload.weights, report.kinds) |weight, count|
        std.debug.print(" kind.{s}={d}", .{ @tagName(weight.kind), count });
    std.debug.print("\n", .{});
    inline for (@typeInfo(sim.input.Event).@"union".field_names, 0..) |name, index|
        std.debug.print(" event.{s}={d}", .{ name, report.events[index] });
    std.debug.print("\n", .{});
    inline for (@typeInfo(sim.runner.Counters).@"struct".field_names) |name|
        std.debug.print(" {s}={d}", .{ name, @field(report.counters, name) });
    std.debug.print("\n", .{});
}

fn save_trace(state: *Diagnostics, path: []const u8) !void {
    assert(state.progress.recorded <= state.frames.len);
    assert(state.bytes.len == trace_bytes_max);
    var writer: std.Io.Writer = .fixed(state.bytes);
    try sim.trace.write(&writer, state.header, state.frames[0..state.progress.recorded]);
    try state.directory.writeFile(state.io, .{ .sub_path = path, .data = writer.buffered() });
}

fn report_failure(state: *Diagnostics, message: []const u8) !void {
    assert(state.progress.recorded <= state.frames.len);
    assert(state.header.workload_frames > 0);
    assert(state.progress.pass <= 1);
    assert(state.progress.frame < state.frames.len);
    std.debug.print("FAIL app={s} seed={d} frame={d} pass={d} checker={s} " ++
        "commit={s} error={s}\n", .{
        @tagName(state.header.app), state.header.seed,                state.progress.frame,
        state.progress.pass,        @tagName(state.progress.checker), build_options.commit,
        message,
    });
    if (state.progress.checker == .layout)
        std.debug.print("index={d} values={any}\n", .{
            state.progress.index, state.progress.values,
        });
    if (state.progress.checker == .determinism)
        std.debug.print("component={d} expected={x} actual={x}\n", .{
            state.progress.index, state.progress.expected, state.progress.actual,
        });
    try state.directory.createDirPath(state.io, "zig-out/sim");
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, "zig-out/sim/{s}-{d}.jsonl", .{
        @tagName(state.header.app), state.header.seed,
    });
    state.progress.recorded = @min(state.progress.recorded, state.progress.frame + 1);
    try save_trace(state, path);
    std.debug.print("replay: zig build sim -- --replay {s}\n", .{path});
}
