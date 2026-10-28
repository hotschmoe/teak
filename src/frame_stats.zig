//! Frame timing and perf counters for the run loop: `FrameStats`, the percentile summary, and the `TEAK_FRAME_STATS` CSV sink
//!
//! Loop-side machinery (like `control.zig`): `Runtime.frame` times its own
//! phases on the loop clock and hands the finished record here. Nothing in
//! this file is read by `update` / `view` / layout / render — the numbers
//! leave the loop only as data (`Runtime.lastFrameStats`, a CSV file, the
//! optional HUD overlay appended after the app's view), so the TEA loop is
//! untouched (HARDLINE §1, §3 "view() reading wall-clock").
//!
//! The file sink compiles out on targets with no host filesystem
//! (wasm/freestanding), exactly like the snapshot sink; the record itself
//! and `summarize` work everywhere.

const std = @import("std");
const builtin = @import("builtin");

/// The target has a host filesystem + environment (not wasm/freestanding).
pub const fs_capable = builtin.os.tag != .freestanding;

/// What one `Runtime.frame` call cost. Plain data; every duration is in
/// milliseconds of the loop clock (a monotonic high-resolution clock on
/// native, `Host.nowMs` — whole milliseconds — on wasm/freestanding).
pub const FrameStats = struct {
    /// 0-based count of `frame` calls that ran (quiet ones included).
    index: u64 = 0,
    /// Present-to-present: time since the previous frame that presented
    /// (`Gpu.renderFrame`). 0 when this frame did not present, or on the
    /// first present. With idle skip on, it includes the time spent idle.
    frame_ms: f32 = 0,
    /// The whole `frame` call (poll through snapshot), excluding the idle
    /// wait `run` does between calls.
    work_ms: f32 = 0,
    /// Input poll + routing + every `update` it dispatched + subscriptions
    /// + effects: everything before the view is built.
    update_ms: f32 = 0,
    /// `view` (plus the inspector / HUD overlay when on).
    view_ms: f32 = 0,
    /// Layout passes.
    layout_ms: f32 = 0,
    /// `buildFrame` + vertex / text / image / scene uploads; 0 when the
    /// frame diff skipped the rebuild.
    build_ms: f32 = 0,
    /// `Gpu.renderFrame` (encode, submit and present; blocks on vsync when
    /// the backend paces).
    gpu_ms: f32 = 0,
    /// Cmds in the frame on screen (app view + any loop overlay).
    cmds: u32 = 0,
    /// Vertices last uploaded.
    vertices: u32 = 0,
    /// The idle skip ran nothing: no view, layout or present (a caret
    /// toggle still presents; see `presented`).
    quiet: bool = false,
    /// `Gpu.renderFrame` ran this frame.
    presented: bool = false,
    /// Vertices were rebuilt and uploaded (false: the frame diff found
    /// nothing changed and only re-presented).
    rebuilt: bool = false,
};

/// `frame_ms` distribution of a run. Percentiles are nearest-rank over the
/// sorted samples (`p50` of 1..100 is 50, `p99` is 99).
pub const Summary = struct {
    count: usize = 0,
    mean_ms: f32 = 0,
    min_ms: f32 = 0,
    p50_ms: f32 = 0,
    p95_ms: f32 = 0,
    p99_ms: f32 = 0,
    max_ms: f32 = 0,
};

/// Nearest-rank percentile `p` (0..100) of ascending `sorted`; 0 if empty.
pub fn percentile(sorted: []const f32, p: f32) f32 {
    if (sorted.len == 0) return 0;
    const n: f32 = @floatFromInt(sorted.len);
    const rank: usize = @intFromFloat(@ceil(std.math.clamp(p, 0, 100) / 100 * n));
    return sorted[std.math.clamp(rank, 1, sorted.len) - 1];
}

/// Summarize `frame_ms` samples. Sorts `samples` in place.
pub fn summarize(samples: []f32) Summary {
    if (samples.len == 0) return .{};
    std.mem.sort(f32, samples, {}, std.sort.asc(f32));
    var sum: f64 = 0;
    for (samples) |s| sum += s;
    return .{
        .count = samples.len,
        .mean_ms = @floatCast(sum / @as(f64, @floatFromInt(samples.len))),
        .min_ms = samples[0],
        .p50_ms = percentile(samples, 50),
        .p95_ms = percentile(samples, 95),
        .p99_ms = percentile(samples, 99),
        .max_ms = samples[samples.len - 1],
    };
}

/// Header row of the CSV sink (one `writeCsvLine` per frame follows).
pub const csv_header = "frame,frame_ms,work_ms,update_ms,view_ms,layout_ms,build_ms,gpu_ms,cmds,vertices,quiet,presented,rebuilt\n";

pub fn writeCsvLine(w: *std.Io.Writer, s: FrameStats) std.Io.Writer.Error!void {
    try w.print("{d},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d},{d},{d},{d},{d}\n", .{
        s.index,                 s.frame_ms,  s.work_ms,             s.update_ms,
        s.view_ms,               s.layout_ms, s.build_ms,            s.gpu_ms,
        s.cmds,                  s.vertices,  @intFromBool(s.quiet), @intFromBool(s.presented),
        @intFromBool(s.rebuilt),
    });
}

/// Mean of each phase over the presented frames of a run.
pub const PhaseMeans = struct {
    work_ms: f32 = 0,
    update_ms: f32 = 0,
    view_ms: f32 = 0,
    layout_ms: f32 = 0,
    build_ms: f32 = 0,
    gpu_ms: f32 = 0,
};

/// The human-readable end-of-run report.
pub fn writeSummary(w: *std.Io.Writer, frames: u64, s: Summary, m: PhaseMeans) std.Io.Writer.Error!void {
    try w.print("teak frame stats: {d} frames, {d} frame_ms samples\n", .{ frames, s.count });
    try w.print("frame_ms  mean {d:.3}  min {d:.3}  p50 {d:.3}  p95 {d:.3}  p99 {d:.3}  max {d:.3}\n", .{ s.mean_ms, s.min_ms, s.p50_ms, s.p95_ms, s.p99_ms, s.max_ms });
    try w.print("mean ms   work {d:.3}  update {d:.3}  view {d:.3}  layout {d:.3}  build {d:.3}  gpu {d:.3}\n", .{ m.work_ms, m.update_ms, m.view_ms, m.layout_ms, m.build_ms, m.gpu_ms });
}

/// Owned dupe of environment variable `name` if set and non-empty. Read
/// through the globally-available `Io` handle (no libc), like the snapshot
/// sink's `TEAK_SNAPSHOT`. Always null on wasm/freestanding.
pub fn envVar(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (comptime !fs_capable) return null;
    const threaded = std.Options.debug_threaded_io orelse return null;
    var map = threaded.environ.process_environ.createMap(gpa) catch return null;
    defer map.deinit();
    const v = map.get(name) orelse return null;
    if (v.len == 0) return null;
    return gpa.dupe(u8, v) catch null;
}

/// `name` as a flag: unset -> null, "0" -> false, anything else -> true.
pub fn envFlag(gpa: std.mem.Allocator, name: []const u8) ?bool {
    const v = envVar(gpa, name) orelse return null;
    defer gpa.free(v);
    return !std.mem.eql(u8, v, "0");
}

/// `name` as an unsigned integer; unset or unparsable -> null.
pub fn envInt(gpa: std.mem.Allocator, name: []const u8) ?u64 {
    const v = envVar(gpa, name) orelse return null;
    defer gpa.free(v);
    return std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch null;
}

/// CSV sink: one line per frame to `<path>`, then the summary to stderr and
/// `<path>.summary.txt` at `deinit`. Lines are buffered and flushed every
/// 16 KiB so a frame rarely touches the disk. A write failure disables the
/// sink after one warning; it never crashes the app.
pub const Sink = struct {
    enabled: bool = false,
    gpa: std.mem.Allocator = undefined,
    path: []u8 = &.{},
    file: if (fs_capable) std.Io.File else void = undefined,
    buf: std.Io.Writer.Allocating = undefined,
    /// Every presented frame's `frame_ms` (first present excluded).
    samples: std.ArrayList(f32) = .empty,
    sums: PhaseMeans = .{},
    presented: u64 = 0,
    frames: u64 = 0,

    const flush_at = 16 * 1024;

    /// Open `path` (env `TEAK_FRAME_STATS` wins over `opt_path`). Any
    /// failure yields a disabled sink.
    pub fn init(gpa: std.mem.Allocator, opt_path: ?[]const u8) Sink {
        if (comptime !fs_capable) return .{};
        const env = envVar(gpa, "TEAK_FRAME_STATS");
        const path = env orelse (gpa.dupe(u8, opt_path orelse return .{}) catch return .{});
        if (path.len == 0) {
            gpa.free(path);
            return .{};
        }
        const io = std.Options.debug_io;
        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
            std.log.warn("teak: frame stats disabled — could not create \"{s}\"", .{path});
            gpa.free(path);
            return .{};
        };
        var s: Sink = .{ .enabled = true, .gpa = gpa, .path = path, .file = file, .buf = .init(gpa) };
        s.buf.writer.writeAll(csv_header) catch s.fail();
        return s;
    }

    pub fn record(self: *Sink, s: FrameStats) void {
        if (comptime !fs_capable) return;
        if (!self.enabled) return;
        self.frames += 1;
        if (s.presented) {
            self.presented += 1;
            self.sums.work_ms += s.work_ms;
            self.sums.update_ms += s.update_ms;
            self.sums.view_ms += s.view_ms;
            self.sums.layout_ms += s.layout_ms;
            self.sums.build_ms += s.build_ms;
            self.sums.gpu_ms += s.gpu_ms;
            if (s.frame_ms > 0) self.samples.append(self.gpa, s.frame_ms) catch {};
        }
        writeCsvLine(&self.buf.writer, s) catch return self.fail();
        if (self.buf.written().len >= flush_at) self.flush();
    }

    fn flush(self: *Sink) void {
        if (comptime !fs_capable) return;
        if (!self.enabled) return;
        self.file.writeStreamingAll(std.Options.debug_io, self.buf.written()) catch return self.fail();
        self.buf.clearRetainingCapacity();
    }

    fn fail(self: *Sink) void {
        if (!self.enabled) return;
        self.enabled = false;
        std.log.warn("teak: frame stats disabled — could not write \"{s}\"", .{self.path});
    }

    /// The phase means over the presented frames so far.
    pub fn means(self: *const Sink) PhaseMeans {
        if (self.presented == 0) return .{};
        const n: f32 = @floatFromInt(self.presented);
        const t = self.sums;
        return .{
            .work_ms = t.work_ms / n,
            .update_ms = t.update_ms / n,
            .view_ms = t.view_ms / n,
            .layout_ms = t.layout_ms / n,
            .build_ms = t.build_ms / n,
            .gpu_ms = t.gpu_ms / n,
        };
    }

    /// Flush the CSV, write the summary (stderr + `<path>.summary.txt`),
    /// close the file.
    pub fn deinit(self: *Sink) void {
        if (comptime !fs_capable) return;
        if (self.path.len == 0) return;
        const io = std.Options.debug_io;
        if (self.enabled) {
            self.flush();
            const summary = summarize(self.samples.items);
            self.buf.clearRetainingCapacity();
            writeSummary(&self.buf.writer, self.frames, summary, self.means()) catch {};
            if (!builtin.is_test) std.debug.print("{s}", .{self.buf.written()});
            if (std.fmt.allocPrint(self.gpa, "{s}.summary.txt", .{self.path})) |sp| {
                defer self.gpa.free(sp);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sp, .data = self.buf.written() }) catch {};
            } else |_| {}
        }
        self.file.close(io);
        self.buf.deinit();
        self.samples.deinit(self.gpa);
        self.gpa.free(self.path);
        self.* = .{};
    }
};

test "percentile is nearest-rank and summarize sorts and reports the distribution" {
    var xs: [100]f32 = undefined;
    // 100 down to 1, so summarize has to sort.
    for (&xs, 0..) |*x, i| x.* = @floatFromInt(100 - i);
    const s = summarize(&xs);
    try std.testing.expectEqual(@as(usize, 100), s.count);
    try std.testing.expectEqual(@as(f32, 1), s.min_ms);
    try std.testing.expectEqual(@as(f32, 50), s.p50_ms);
    try std.testing.expectEqual(@as(f32, 95), s.p95_ms);
    try std.testing.expectEqual(@as(f32, 99), s.p99_ms);
    try std.testing.expectEqual(@as(f32, 100), s.max_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 50.5), s.mean_ms, 1e-4);

    var one = [_]f32{7};
    const s1 = summarize(&one);
    try std.testing.expectEqual(@as(f32, 7), s1.p50_ms);
    try std.testing.expectEqual(@as(f32, 7), s1.p99_ms);
    try std.testing.expectEqual(Summary{}, summarize(&.{}));
    // A tail outlier shows up in p99 / max but not p50.
    var tail = [_]f32{ 16, 16, 16, 16, 16, 16, 16, 16, 16, 40 };
    const st = summarize(&tail);
    try std.testing.expectEqual(@as(f32, 16), st.p50_ms);
    try std.testing.expectEqual(@as(f32, 40), st.p99_ms);
}

test "writeCsvLine matches the header's column count" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeCsvLine(&w, .{ .index = 3, .frame_ms = 16.5, .cmds = 10, .presented = true });
    const line = w.buffered();
    try std.testing.expectEqual(std.mem.count(u8, csv_header, ","), std.mem.count(u8, line, ","));
    try std.testing.expect(std.mem.startsWith(u8, line, "3,16.500,"));
}
