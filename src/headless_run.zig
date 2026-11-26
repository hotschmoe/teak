//! Tool API for headless runs: script input, run frames, grab pixels, write
//! a PNG. Everything here is duck-typed over the Host / Gpu / Runtime (it
//! imports no backend), so it works with `platform/headless.zig` +
//! `Gpu.initOffscreen`; `teak.linkHeadless` wires those up. See
//! docs/features/headless.md.
//!
//! ```zig
//! var host = try Host.init(gpa, 1280, 800, .{});   // teak-platform-headless
//! var gpu = try Gpu.initOffscreen(1280, 800, .{ .msaa = true }); // teak-gpu-headless
//! var rt = try teak.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, .{});
//! try teak.headless.play(&rt, &host, &.{
//!     .{ .frames = 2 },
//!     .{ .click = .{ 120, 80 } },
//!     .{ .chars = "hello" },
//!     .{ .frames = 3 },
//! });
//! try teak.headless.writeFramePng(&gpu, gpa, "out.png");
//! ```

const std = @import("std");
const builtin = @import("builtin");
const pointer = @import("core/pointer.zig");
const keys = @import("input/keys.zig");
const snapshot = @import("core/snapshot.zig");
const run_mod = @import("run.zig");

/// One scripted step. Steps that only queue input (`move`, `down`, `up`,
/// `wheel`, `chars`, `key`, `mods`) do not run a frame; `frames` and the
/// compound steps do.
pub const Step = union(enum) {
    /// Run `n` frames (input queued so far is delivered in the first).
    frames: u32,
    /// Queue a pointer move.
    move: [2]f32,
    down: pointer.Button,
    up: pointer.Button,
    /// Queue a wheel scroll (dx, dy); positive dy scrolls content down.
    wheel: [2]f32,
    chars: []const u8,
    key: keys.SpecialKey,
    mods: pointer.Modifiers,
    /// Queue a keyboard shortcut (`InputState.chords`): `.{ .chord = Chord.ctrl(.k) }`.
    chord: keys.Chord,
    /// Move to the point, press and release the left button, with a frame
    /// between each part (hover is established, the press arms, the release
    /// fires the click — the runtime routes against the previous frame).
    click: [2]f32,
    /// Press at `a`, move through `b` in 4 interpolated frames, release at
    /// `b`: a left-button drag.
    drag: [2][2]f32,
};

/// Run `steps` against a Runtime + Host (anything with `frame()` and the
/// scripting `push*` API of `platform/headless.zig`).
pub fn play(rt: anytype, host: anytype, steps: []const Step) !void {
    for (steps) |s| switch (s) {
        .frames => |n| for (0..n) |_| try rt.frame(),
        .move => |p| host.pushMouseMove(p[0], p[1]),
        .down => |b| host.pushMouseDown(b),
        .up => |b| host.pushMouseUp(b),
        .wheel => |w| host.pushWheel(w[0], w[1]),
        .chars => |t| host.pushChars(t),
        .key => |k| host.pushKey(k),
        .mods => |m| host.setModifiers(m),
        .chord => |c| host.pushChord(c),
        .click => |p| {
            host.pushMouseMove(p[0], p[1]);
            try rt.frame();
            host.pushMouseDown(.left);
            try rt.frame();
            host.pushMouseUp(.left);
            try rt.frame();
        },
        .drag => |d| {
            host.pushMouseMove(d[0][0], d[0][1]);
            try rt.frame();
            host.pushMouseDown(.left);
            try rt.frame();
            for (1..5) |i| {
                const t: f32 = @as(f32, @floatFromInt(i)) / 4.0;
                host.pushMouseMove(d[0][0] + (d[1][0] - d[0][0]) * t, d[0][1] + (d[1][1] - d[0][1]) * t);
                try rt.frame();
            }
            host.pushMouseUp(.left);
            try rt.frame();
        },
    };
}

/// A face to register on the Host before the first frame (`Host.registerFont`).
/// `bytes` must outlive the shot.
pub const ShotFont = struct {
    family: @import("core/text.zig").FontFamily,
    weight: @import("core/text.zig").FontWeight,
    bytes: []const u8,
};

pub const ShotOptions = struct {
    /// Faces registered before the run starts.
    fonts: []const ShotFont = &.{},
    width: u32 = 1280,
    height: u32 = 800,
    /// 4x MSAA of the UI pass (as a windowed app would run it).
    msaa: bool = true,
    /// Device pixels per logical pixel: the PNG is `width * scale` by
    /// `height * scale` and text is rasterized at that size (HiDPI).
    scale: f32 = 1,
    /// Input script; see `Step`.
    steps: []const Step = &.{},
    /// Extra frames after the script so animations / one-frame input
    /// latency settle before the capture.
    settle: u32 = 3,
    run: run_mod.Options = .{},
};

/// Run `App` headlessly: build the Host and offscreen Gpu, play the
/// script, capture the last frame to `path` as a PNG. `Host` is
/// `teak-platform-headless`'s `Host`, `Gpu` is `teak-gpu-headless`'s `Gpu`.
pub fn shot(
    comptime App: type,
    comptime Host: type,
    comptime Gpu: type,
    gpa: std.mem.Allocator,
    path: []const u8,
    o: ShotOptions,
) !void {
    var host = try Host.init(gpa, o.width, o.height, o.run);
    defer host.deinit();
    for (o.fonts) |f| try host.registerFont(f.family, f.weight, f.bytes);
    var gpu = try Gpu.initOffscreen(o.width, o.height, .{
        .msaa = o.msaa,
        .scale = envScale(o.scale, o.run.scale),
        .gpu_fallback = o.run.gpu_fallback,
    });
    defer gpu.deinit();
    var rt = try run_mod.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, o.run);
    defer rt.deinit();

    try play(&rt, &host, o.steps);
    for (0..o.settle) |_| try rt.frame();
    try writeFramePng(&gpu, gpa, path);
}

/// What an idle run did: of `frames` input-free frames after the script and
/// the settle frames, how many did real work (`busy`: not the loop's quiet
/// skip) and how many presented (caret blink redraws present but stay quiet).
pub const IdleReport = struct {
    frames: u32,
    busy: u32,
    presented: u32,
    /// Quiet frames that still presented (caret blinks).
    blinks: u32 = 0,
    /// Index (0-based, within the idle window) of the first busy frame.
    first_busy: ?u32 = null,
    /// A busy frame came after a quiet one (something woke the loop up again).
    rewoke: bool = false,
    /// The last frame of the window was busy.
    busy_at_end: bool = false,
    /// Process memory at the end of the window, with the Gpu alive. Linux only; 0 elsewhere.
    rss_bytes: u64 = 0,
    /// Private resident plus swapped pages (`RssAnon + VmSwap`).
    committed_bytes: u64 = 0,

    /// The UI went quiet within the window and stayed quiet: a finite
    /// transition (a sliding popover) passes, a never-ending animation or a
    /// self-sustaining Msg does not.
    pub fn settled(r: IdleReport) bool {
        return !r.busy_at_end and !r.rewoke;
    }

    /// No frame did work and every present was a caret blink; stricter than `settled`.
    pub fn fullyQuiet(r: IdleReport) bool {
        return r.busy == 0 and r.presented == r.blinks;
    }
};

const ProcessMemory = struct {
    rss_bytes: u64 = 0,
    committed_bytes: u64 = 0,
};

fn statusKb(text: []const u8, name: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        const rest = std.mem.trim(u8, line[name.len..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        return std.fmt.parseInt(u64, rest[0..end], 10) catch 0;
    }
    return 0;
}

fn readProcessMemory() ProcessMemory {
    if (comptime builtin.os.tag != .linux) return .{};
    const io = std.Options.debug_io;
    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return .{};
    defer file.close(io);
    var scratch: [16384]u8 = undefined;
    // procfs reports size 0, so only a streaming read returns the contents.
    var reader = file.readerStreaming(io, &.{});
    const n = reader.interface.readSliceShort(&scratch) catch return .{};
    const text = scratch[0..n];
    return .{
        .rss_bytes = statusKb(text, "VmRSS:") * 1024,
        .committed_bytes = (statusKb(text, "RssAnon:") + statusKb(text, "VmSwap:")) * 1024,
    };
}

/// The idle gate (#141): play `o.steps`, settle, then run `frames` frames
/// with no input and report how many still did work. A healthy UI goes
/// quiet and stays quiet (`IdleReport.settled`); a busy tail or a re-wake is
/// a Msg, sub or animation that keeps the loop awake (an indeterminate
/// progress bar legitimately does). Uses the
/// same Host / Gpu as `shot`; no PNG is written.
pub fn idleCheck(
    comptime App: type,
    comptime Host: type,
    comptime Gpu: type,
    gpa: std.mem.Allocator,
    o: ShotOptions,
    frames: u32,
) !IdleReport {
    var host = try Host.init(gpa, o.width, o.height, o.run);
    defer host.deinit();
    for (o.fonts) |f| try host.registerFont(f.family, f.weight, f.bytes);
    var gpu = try Gpu.initOffscreen(o.width, o.height, .{
        .msaa = o.msaa,
        .scale = envScale(o.scale, o.run.scale),
        .gpu_fallback = o.run.gpu_fallback,
    });
    defer gpu.deinit();
    var rt = try run_mod.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, o.run);
    defer rt.deinit();
    try play(&rt, &host, o.steps);
    for (0..o.settle) |_| try rt.frame();
    var r: IdleReport = .{ .frames = frames, .busy = 0, .presented = 0 };
    var seen_quiet = false;
    for (0..frames) |i| {
        try rt.frame();
        const s = rt.lastFrameStats();
        if (!s.quiet) {
            if (r.first_busy == null) r.first_busy = @intCast(i);
            r.busy += 1;
            if (seen_quiet) r.rewoke = true;
        } else seen_quiet = true;
        if (s.presented) r.presented += 1;
        if (s.quiet and s.presented) r.blinks += 1;
        if (i + 1 == frames) r.busy_at_end = !s.quiet;
    }
    const mem = readProcessMemory();
    r.rss_bytes = mem.rss_bytes;
    r.committed_bytes = mem.committed_bytes;
    return r;
}

/// One scripted click: frames from the event that changed the view to the
/// frame that presented it. The designed budget is 1 (docs/features/headless.md).
pub const LatencyReport = struct {
    /// 0 when `unstable` or `unchanged`.
    frames: u32 = 0,
    /// The view kept changing with no further input, so a click cannot be timed.
    unstable: bool = false,
    /// The click did not change the cmd buffer (miss, or a no-op control).
    unchanged: bool = false,
    x: f32 = 0,
    y: f32 = 0,

    pub fn pass(r: LatencyReport, budget: u32) bool {
        return !r.unstable and !r.unchanged and r.frames == budget;
    }
};

fn cmdFingerprint(gpa: std.mem.Allocator, rt: anytype) !u64 {
    const cur = rt.current;
    var buf = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer buf.deinit();
    try snapshot.write(&buf.writer, rt.bufs[cur].cmds.items, rt.rects[cur].items, .{});
    return std.hash.Wyhash.hash(0, buf.written());
}

/// Move to `(x, y)`, wait for two identical frames, click, and count frames
/// until a changed view is presented. `host` needs `pushMouseMove` /
/// `pushMouseDown` / `pushMouseUp`.
pub fn latencyAfterClick(rt: anytype, host: anytype, gpa: std.mem.Allocator, x: f32, y: f32) !LatencyReport {
    var r: LatencyReport = .{ .x = x, .y = y };
    host.pushMouseMove(x, y);
    try rt.frame();
    var prev = try cmdFingerprint(gpa, rt);
    var stable = false;
    for (0..4) |_| {
        try rt.frame();
        const h = try cmdFingerprint(gpa, rt);
        if (h == prev) {
            stable = true;
            break;
        }
        prev = h;
    }
    if (!stable) {
        r.unstable = true;
        return r;
    }
    const base = prev;

    host.pushMouseDown(.left);
    try rt.frame();
    const after_down = try cmdFingerprint(gpa, rt);
    if (after_down != base and rt.lastFrameStats().presented) {
        r.frames = 1;
        host.pushMouseUp(.left);
        try rt.frame();
        return r;
    }

    host.pushMouseUp(.left);
    for (0..8) |i| {
        try rt.frame();
        const h = try cmdFingerprint(gpa, rt);
        if (h != base and rt.lastFrameStats().presented) {
            r.frames = @intCast(i + 1);
            return r;
        }
    }
    r.unchanged = true;
    return r;
}

/// Play `o.steps`, settle, then `latencyAfterClick`. Same Host / Gpu as
/// `idleCheck`; no PNG is written.
pub fn latencyCheck(
    comptime App: type,
    comptime Host: type,
    comptime Gpu: type,
    gpa: std.mem.Allocator,
    o: ShotOptions,
    x: f32,
    y: f32,
) !LatencyReport {
    var host = try Host.init(gpa, o.width, o.height, o.run);
    defer host.deinit();
    for (o.fonts) |f| try host.registerFont(f.family, f.weight, f.bytes);
    var gpu = try Gpu.initOffscreen(o.width, o.height, .{
        .msaa = o.msaa,
        .scale = envScale(o.scale, o.run.scale),
        .gpu_fallback = o.run.gpu_fallback,
    });
    defer gpu.deinit();
    var rt = try run_mod.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, o.run);
    defer rt.deinit();
    try play(&rt, &host, o.steps);
    for (0..o.settle) |_| try rt.frame();
    return latencyAfterClick(&rt, &host, gpa, x, y);
}

fn parsePair(s: []const u8) ?[2]f32 {
    const c = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const x = std.fmt.parseFloat(f32, s[0..c]) catch return null;
    const y = std.fmt.parseFloat(f32, s[c + 1 ..]) catch return null;
    return .{ x, y };
}

/// Headless scale parsing retains the [0.25, 16] range.
pub fn envScale(default: f32, value: ?[]const u8) f32 {
    const parsed = std.fmt.parseFloat(f32, value orelse return default) catch return default;
    return if (parsed >= 0.25 and parsed <= 16) parsed else default;
}

pub const ServeOptions = struct {
    width: u32 = 1280,
    height: u32 = 800,
    msaa: bool = true,
    /// Real milliseconds slept between frames, so an idle headless app does
    /// not spin a core. The Host clock stays fake (16 ms per frame).
    frame_sleep_ms: u32 = 4,
    run: run_mod.Options = .{},
};

/// Run `App` headlessly until the Host closes (the control channel's `quit`
/// command, or never): the "launch me for an agent" entry point. Pair it with
/// `TEAK_CONTROL=<socket>` and `tools/teak-drive`. See
/// docs/features/agent-driver.md.
pub fn serve(
    comptime App: type,
    comptime Host: type,
    comptime Gpu: type,
    gpa: std.mem.Allocator,
    o: ServeOptions,
) !void {
    var host = try Host.init(gpa, o.width, o.height, o.run);
    defer host.deinit();
    var gpu = try Gpu.initOffscreen(o.width, o.height, .{
        .msaa = o.msaa,
        .gpu_fallback = o.run.gpu_fallback,
    });
    defer gpu.deinit();
    var rt = try run_mod.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, o.run);
    defer rt.deinit();
    while (!host.shouldClose()) {
        try rt.frame();
        if (o.frame_sleep_ms > 0) {
            std.Io.sleep(std.Options.debug_io, .fromMilliseconds(o.frame_sleep_ms), .awake) catch {};
        }
    }
}

/// Sequential view of argv without the program name.
const ArgIter = struct {
    items: []const [:0]const u8,
    i: usize = 1,

    fn next(self: *ArgIter) ?[:0]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

/// `argv[1]` of a `pub fn main(init: std.process.Init)` program, or
/// `default` when absent: the output path of a `zig build shot -- out.png`.
pub fn pathArg(init: anytype, default: []const u8) []const u8 {
    // `toSlice` (not `iterate`) so this also works on Windows.
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return default;
    return if (args.len > 1) args[1] else default;
}

/// A named, scripted app state for screenshots (`--state <name>`).
pub const ShotState = struct {
    name: []const u8,
    steps: []const Step,
    /// Overrides `ShotOptions.msaa` for this state (null = keep it).
    msaa: ?bool = null,
};

/// True when `args` asks a shot binary for a measurement instead of a PNG
/// (`--gates-json`, `--idle-check` or `--latency-check`), for a `main` that
/// only hands measurements to `shotCli`.
pub fn requestsGate(args: []const [:0]const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--gates-json") or std.mem.eql(u8, a, "--idle-check") or
            std.mem.eql(u8, a, "--latency-check"))
            return true;
    }
    return false;
}

/// The whole `shot_main.zig` for an example: parses
/// `[out.png] [--state <name>] [--list] [--all <dir> --prefix <p>]` from argv, plays that state's
/// script (`o.steps` is ignored; the first of `states` is the default),
/// and writes the PNG. `--list` prints the state names, one per line, on
/// stdout and exits. `--all <dir> --prefix <p>` renders every state to
/// `<dir>/<p>-<state>.actual.png` in one process and prints the names:
/// `tools/vreg` uses it so each example needs a single `zig build` call.
/// `--gates-json` prints one JSON object of measurements (idle per state,
/// optional latency, memory of the first state) for `tools/ci_gates.zig`.
pub fn shotCli(
    comptime App: type,
    comptime Host: type,
    comptime Gpu: type,
    init: anytype,
    default_path: []const u8,
    o: ShotOptions,
    states: []const ShotState,
) !void {
    std.debug.assert(states.len > 0);
    var path: []const u8 = default_path;
    var want: []const u8 = states[0].name;
    var list = false;
    var all_dir: ?[]const u8 = null;
    var opts_base = o;
    var prefix: []const u8 = "shot";
    var idle_frames: ?u32 = null;
    var gates = false;
    var gate_frames: u32 = 125;
    var state_set = false;
    var lat_xy: ?[2]f32 = null;
    var lat_state: ?[]const u8 = null;
    // `toSlice` (not `iterate`, a compile error on Windows).
    var it: ArgIter = .{ .items = try init.minimal.args.toSlice(init.arena.allocator()) };
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--list")) {
            list = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            all_dir = it.next() orelse return error.MissingAllDir;
        } else if (std.mem.eql(u8, a, "--scale")) {
            opts_base.scale = std.fmt.parseFloat(f32, it.next() orelse return error.MissingScale) catch return error.BadScale;
        } else if (std.mem.eql(u8, a, "--prefix")) {
            prefix = it.next() orelse return error.MissingPrefix;
        } else if (std.mem.eql(u8, a, "--idle-check")) {
            idle_frames = std.fmt.parseInt(u32, it.next() orelse return error.MissingIdleFrames, 10) catch return error.BadIdleFrames;
        } else if (std.mem.eql(u8, a, "--gates-json")) {
            gates = true;
        } else if (std.mem.eql(u8, a, "--idle-frames")) {
            gate_frames = std.fmt.parseInt(u32, it.next() orelse return error.MissingIdleFrames, 10) catch return error.BadIdleFrames;
        } else if (std.mem.eql(u8, a, "--latency-check")) {
            lat_xy = parsePair(it.next() orelse return error.MissingLatency) orelse return error.BadLatency;
            gates = true;
        } else if (std.mem.eql(u8, a, "--latency-state")) {
            lat_state = it.next() orelse return error.MissingStateName;
        } else if (std.mem.eql(u8, a, "--plain")) {
            want = "plain"; // alias of `--state plain`
            state_set = true;
        } else if (std.mem.eql(u8, a, "--state")) {
            want = it.next() orelse return error.MissingStateName;
            state_set = true;
        } else path = a;
    }
    if (list) {
        for (states) |st| {
            try std.Io.File.stdout().writeStreamingAll(init.io, st.name);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        }
        return;
    }
    if (gates) {
        if (!state_set) want = "*";
        try writeGatesJson(App, Host, Gpu, init, opts_base, states, want, gate_frames, lat_xy, lat_state);
        return;
    }
    if (idle_frames) |n| {
        var any_busy = false;
        for (states) |st| {
            if (!std.mem.eql(u8, want, "*") and !std.mem.eql(u8, st.name, want)) continue;
            var opts = opts_base;
            opts.steps = st.steps;
            const r = try idleCheck(App, Host, Gpu, init.gpa, opts, n);
            std.debug.print("idle {s}: {d}/{d} frames busy, {d} presented{s}\n", .{ st.name, r.busy, r.frames, r.presented, if (r.settled()) "" else " (NOT IDLE)" });
            if (!r.settled()) any_busy = true;
        }
        if (any_busy) return error.NotIdle;
        return;
    }
    if (all_dir) |dir| {
        for (states) |st| {
            var opts = opts_base;
            opts.steps = st.steps;
            if (st.msaa) |ms| opts.msaa = ms;
            const out = try std.fmt.allocPrint(init.gpa, "{s}/{s}-{s}.actual.png", .{ dir, prefix, st.name });
            defer init.gpa.free(out);
            try shot(App, Host, Gpu, init.gpa, out, opts);
            try std.Io.File.stdout().writeStreamingAll(init.io, st.name);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        }
        return;
    }
    for (states) |st| if (std.mem.eql(u8, st.name, want)) {
        var opts = opts_base;
        opts.steps = st.steps;
        if (st.msaa) |ms| opts.msaa = ms;
        try shot(App, Host, Gpu, init.gpa, path, opts);
        std.debug.print("wrote {s} (state {s})\n", .{ path, st.name });
        return;
    };
    std.debug.print("unknown state '{s}'; available:", .{want});
    for (states) |st| std.debug.print(" {s}", .{st.name});
    std.debug.print("\n", .{});
    return error.UnknownState;
}

const GateRow = struct {
    name: []const u8,
    r: IdleReport,
};

fn writeGatesJson(
    comptime App: type,
    comptime Host: type,
    comptime Gpu: type,
    init: anytype,
    opts_base: ShotOptions,
    states: []const ShotState,
    want: []const u8,
    gate_frames: u32,
    lat_xy: ?[2]f32,
    lat_state: ?[]const u8,
) !void {
    var rows: std.ArrayList(GateRow) = .empty;
    defer rows.deinit(init.gpa);
    var mem: ProcessMemory = .{};
    for (states) |st| {
        if (!std.mem.eql(u8, want, "*") and !std.mem.eql(u8, st.name, want)) continue;
        var opts = opts_base;
        opts.steps = st.steps;
        if (st.msaa) |ms| opts.msaa = ms;
        const r = try idleCheck(App, Host, Gpu, init.gpa, opts, gate_frames);
        if (rows.items.len == 0) mem = .{ .rss_bytes = r.rss_bytes, .committed_bytes = r.committed_bytes };
        try rows.append(init.gpa, .{ .name = st.name, .r = r });
    }

    var lat: ?LatencyReport = null;
    var lat_name: []const u8 = "";
    if (lat_xy) |xy| {
        lat_name = lat_state orelse if (!std.mem.eql(u8, want, "*")) want else states[0].name;
        var found = false;
        for (states) |st| if (std.mem.eql(u8, st.name, lat_name)) {
            var opts = opts_base;
            opts.steps = st.steps;
            if (st.msaa) |ms| opts.msaa = ms;
            lat = try latencyCheck(App, Host, Gpu, init.gpa, opts, xy[0], xy[1]);
            found = true;
            break;
        };
        if (!found) return error.UnknownState;
    }

    var aw: std.Io.Writer.Allocating = .init(init.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"idle_frames\": {d},\n", .{gate_frames});
    try w.print("  \"memory\": {{\"rss_bytes\": {d}, \"committed_bytes\": {d}}},\n  \"states\": [\n", .{ mem.rss_bytes, mem.committed_bytes });
    for (rows.items, 0..) |row, i| {
        const r = row.r;
        try w.writeAll("    {\"name\": ");
        try std.json.Stringify.encodeJsonString(row.name, .{}, w);
        try w.print(", \"frames\": {d}, \"busy\": {d}, \"presented\": {d}, \"blinks\": {d}, \"settled\": {s}, \"fully_quiet\": {s}, \"rewoke\": {s}, \"busy_at_end\": {s}, \"first_busy\": ", .{
            r.frames,
            r.busy,
            r.presented,
            r.blinks,
            if (r.settled()) "true" else "false",
            if (r.fullyQuiet()) "true" else "false",
            if (r.rewoke) "true" else "false",
            if (r.busy_at_end) "true" else "false",
        });
        if (r.first_busy) |b| try w.print("{d}", .{b}) else try w.writeAll("null");
        try w.writeAll(if (i + 1 == rows.items.len) "}\n" else "},\n");
    }
    try w.writeAll("  ],\n  \"latency\": ");
    if (lat) |r| {
        try w.print("{{\"frames\": {d}, \"unstable\": {s}, \"unchanged\": {s}, \"x\": {d}, \"y\": {d}, \"state\": ", .{
            r.frames,
            if (r.unstable) "true" else "false",
            if (r.unchanged) "true" else "false",
            r.x,
            r.y,
        });
        try std.json.Stringify.encodeJsonString(lat_name, .{}, w);
        try w.writeAll("}\n");
    } else try w.writeAll("null\n");
    try w.writeAll("}\n");
    try std.Io.File.stdout().writeStreamingAll(init.io, aw.written());
}

/// Encode tightly packed RGBA8 as a PNG (8-bit RGBA, no interlace). Each
/// scanline picks the PNG filter (none / sub / up / average / paeth) with
/// the smallest sum of absolute residuals, and the filtered stream is
/// deflate-compressed (`std.compress.flate`, default level), so UI
/// screenshots shrink from ~4 MB raw to tens of KB. Deterministic: the
/// same pixels always produce the same bytes. Caller frees.
pub fn encodePng(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    if (rgba.len != @as(usize, width) * height * 4) return error.BadImageSize;
    const row = @as(usize, width) * 4;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type: RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &out, "IHDR", &ihdr);

    var z = try std.Io.Writer.Allocating.initCapacity(gpa, 1 << 16);
    defer z.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var comp = try std.compress.flate.Compress.init(&z.writer, window, .zlib, .default);

    const cand = try gpa.alloc(u8, 5 * row);
    defer gpa.free(cand);
    const zero_row = try gpa.alloc(u8, row);
    defer gpa.free(zero_row);
    @memset(zero_row, 0);
    for (0..height) |y| {
        const cur = rgba[y * row ..][0..row];
        const prev: []const u8 = if (y == 0) zero_row else rgba[(y - 1) * row ..][0..row];
        var best: usize = 0;
        var best_cost: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            const dst = cand[f * row ..][0..row];
            var cost: u64 = 0;
            for (0..row) |i| {
                const a: u8 = if (i >= 4) cur[i - 4] else 0;
                const b: u8 = prev[i];
                const c: u8 = if (i >= 4) prev[i - 4] else 0;
                const pred: u8 = switch (f) {
                    0 => 0,
                    1 => a,
                    2 => b,
                    3 => @intCast((@as(u16, a) + b) / 2),
                    else => paeth(a, b, c),
                };
                const r = cur[i] -% pred;
                dst[i] = r;
                const sr: i8 = @bitCast(r);
                cost += @abs(@as(i16, sr));
            }
            if (cost < best_cost) {
                best_cost = cost;
                best = f;
            }
        }
        try comp.writer.writeByte(@intCast(best));
        try comp.writer.writeAll(cand[best * row ..][0..row]);
    }
    try comp.finish();
    try appendChunk(gpa, &out, "IDAT", z.written());

    try appendChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn appendChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(gpa, &c);
}

/// A decoded image: tightly packed RGBA8 (top-down).
pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
    }
};

/// Decode a PNG: 8-bit RGB or RGBA, non-interlaced, any scanline filter
/// (so both teak's own `encodePng` output and browser screenshots work).
/// RGB gets alpha 255. Caller frees with `Image.deinit`.
pub fn decodePng(gpa: std.mem.Allocator, png: []const u8) !Image {
    if (png.len < 8 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return error.NotAPng;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var off: usize = 8;
    while (off + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[off..][0..4], .big);
        if (off + 12 + len > png.len) return error.TruncatedPng;
        const tag = png[off + 4 ..][0..4];
        const data = png[off + 8 ..][0..len];
        if (std.mem.eql(u8, tag, "IHDR")) {
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[12] != 0) return error.UnsupportedPng; // 8-bit, no interlace
            channels = switch (data[9]) {
                2 => 3,
                6 => 4,
                else => return error.UnsupportedPng,
            };
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, tag, "IEND")) break;
        off += 12 + len;
    }
    if (channels == 0) return error.NotAPng;

    const stride = @as(usize, width) * channels;
    const raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    var in: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    try decomp.reader.readSliceAll(raw);

    for (0..height) |y| {
        const f = raw[y * (stride + 1)];
        const cur = raw[y * (stride + 1) + 1 ..][0..stride];
        const prev: ?[]const u8 = if (y == 0) null else raw[(y - 1) * (stride + 1) + 1 ..][0..stride];
        for (0..stride) |i| {
            const a: u8 = if (i >= channels) cur[i - channels] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (i >= channels and prev != null) prev.?[i - channels] else 0;
            const pred: u8 = switch (f) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                4 => paeth(a, b, c),
                else => return error.BadPngFilter,
            };
            cur[i] +%= pred;
        }
    }

    const rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(rgba);
    for (0..height) |y| {
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..width) |x| {
            const d = rgba[(y * width + x) * 4 ..][0..4];
            @memcpy(d[0..3], src[x * channels ..][0..3]);
            d[3] = if (channels == 4) src[x * channels + 3] else 255;
        }
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

/// Write RGBA8 pixels to `path` (relative to the cwd) as a PNG.
pub fn writePng(gpa: std.mem.Allocator, path: []const u8, rgba: []const u8, width: u32, height: u32) !void {
    const png = try encodePng(gpa, rgba, width, height);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = png });
}

/// Read back the Gpu's last offscreen frame (`Gpu.readFrame`) and write it
/// to `path` as a PNG.
pub fn writeFramePng(gpu: anytype, gpa: std.mem.Allocator, path: []const u8) !void {
    const rgba = try gpu.readFrame(gpa);
    defer gpa.free(rgba);
    try writePng(gpa, path, rgba, gpu.width, gpu.height);
}
