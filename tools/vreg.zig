//! vreg: the visual-regression runner. Renders every example's named
//! screenshot states (`zig build shot -- out.png --state <name>` in each
//! `examples/<name>/`), compares them with the goldens in `test/golden/`,
//! and fails when pixels differ by more than the tolerance.
//!
//!   zig build vreg                       # native shots vs test/golden/<example>-<state>.png
//!   zig build vreg -- --update           # rewrite the goldens that differ
//!   zig build vreg -- --web              # web builds (headless Chromium) vs test/golden/web/<example>.png
//!   zig build vreg -- --examples todo,tree --state three_items
//!   zig build vreg -- --tol 8 --budget 100       # per-channel tolerance / max differing pixels
//!
//! A pixel "differs" when any RGB channel is off by more than `--tol`. A
//! shot passes when at most `--budget` pixels differ. On failure the actual
//! image and a diff image (expected, dimmed, with differing pixels in red and
//! within-tolerance noise in dark yellow) are written to `--out`
//! (default `zig-out/vreg`). See docs/features/visual-regression.md.

const std = @import("std");
const teak = @import("teak");

const png = teak.headless;

/// Defaults chosen so a driver/AA difference between GPUs (Mali vs lavapipe)
/// passes while a 1 px layout shift or a missing text row does not; see
/// docs/features/visual-regression.md for the measurements.
pub const default_tol: u8 = 24;
pub const default_budget: u32 = 150;
/// Web shots go through SwiftShader and Chromium's compositor: looser.
pub const default_web_tol: u8 = 32;
pub const default_web_budget: u32 = 600;

/// Examples whose web build is not deterministic (wall-clock driven
/// animation): they have native goldens (fake clock) but no web golden.
pub const web_skip = [_][]const u8{"scene3d"};

pub const Compare = struct {
    width: u32,
    height: u32,
    /// Pixels whose largest RGB channel difference exceeds the tolerance.
    differing: u32 = 0,
    /// Largest RGB channel difference anywhere.
    max_delta: u8 = 0,
    /// Pixels that differ at all (noise included).
    nonzero: u32 = 0,
    /// Bounding box of the differing pixels (inclusive); only valid when `differing > 0`.
    x0: u32 = std.math.maxInt(u32),
    y0: u32 = std.math.maxInt(u32),
    x1: u32 = 0,
    y1: u32 = 0,
    size_mismatch: bool = false,

    pub fn pass(self: Compare, budget: u32) bool {
        return !self.size_mismatch and self.differing <= budget;
    }
};

/// Compare two images of equal size. When `diff` is non-null (RGBA, same size)
/// it receives the diff visualisation.
pub fn compare(expected: png.Image, actual: png.Image, tol: u8, diff: ?[]u8) Compare {
    var r: Compare = .{ .width = actual.width, .height = actual.height };
    if (expected.width != actual.width or expected.height != actual.height) {
        r.size_mismatch = true;
        return r;
    }
    const n = @as(usize, actual.width) * actual.height;
    for (0..n) |i| {
        const e = expected.rgba[i * 4 ..][0..4];
        const a = actual.rgba[i * 4 ..][0..4];
        const d = @max(@abs(@as(i16, e[0]) - a[0]), @abs(@as(i16, e[1]) - a[1]), @abs(@as(i16, e[2]) - a[2]));
        const d8: u8 = @intCast(d);
        r.max_delta = @max(r.max_delta, d8);
        if (d8 != 0) r.nonzero += 1;
        const hit = d8 > tol;
        if (hit) {
            r.differing += 1;
            const x: u32 = @intCast(i % actual.width);
            const y: u32 = @intCast(i / actual.width);
            r.x0 = @min(r.x0, x);
            r.x1 = @max(r.x1, x);
            r.y0 = @min(r.y0, y);
            r.y1 = @max(r.y1, y);
        }
        if (diff) |out| {
            const o = out[i * 4 ..][0..4];
            if (hit) {
                o.* = .{ 255, 0, 0, 255 };
            } else if (d8 != 0) {
                o.* = .{ 110, 100, 0, 255 };
            } else {
                // Dimmed expected so the red stands out.
                const l: u8 = @intCast((@as(u16, e[0]) + e[1] + e[2]) / 3 / 3);
                o.* = .{ l, l, l, 255 };
            }
        }
    }
    return r;
}

// ── Runner ─────────────────────────────────────────────────────────

const Options = struct {
    update: bool = false,
    web: bool = false,
    zig: []const u8 = "zig",
    node: []const u8 = "node",
    out: []const u8 = "zig-out/vreg",
    golden: []const u8 = "test/golden",
    tol: ?u8 = null,
    budget: ?u32 = null,
    examples: ?[]const u8 = null,
    state: ?[]const u8 = null,
    /// Examples processed concurrently.
    jobs: usize = 4,
};

const Row = struct {
    name: []const u8,
    status: []const u8,
    detail: []const u8,
    ok: bool,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var o: Options = .{};
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--update")) {
            o.update = true;
        } else if (std.mem.eql(u8, a, "--web")) {
            o.web = true;
        } else if (std.mem.eql(u8, a, "--zig")) {
            o.zig = it.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--node")) {
            o.node = it.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--out")) {
            o.out = it.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--golden")) {
            o.golden = it.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--tol")) {
            o.tol = std.fmt.parseInt(u8, it.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, a, "--budget")) {
            o.budget = std.fmt.parseInt(u32, it.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, a, "--examples")) {
            o.examples = it.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--jobs")) {
            o.jobs = @max(1, std.fmt.parseInt(usize, it.next() orelse return usage(), 10) catch return usage());
        } else if (std.mem.eql(u8, a, "--state")) {
            o.state = it.next() orelse return usage();
        } else return usage();
    }
    const tol = o.tol orelse if (o.web) default_web_tol else default_tol;
    const budget = o.budget orelse if (o.web) default_web_budget else default_budget;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, o.out);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const examples = try listExamples(arena, io, o);

    // One worker per example (each `zig build shot` compiles its own exe,
    // which dominates a cold run), `o.jobs` at a time.
    const jobs = try arena.alloc(Job, examples.len);
    for (jobs, examples) |*j, ex| j.* = .{ .ex = ex, .arena = std.heap.ArenaAllocator.init(gpa) };
    defer for (jobs) |*j| j.arena.deinit();
    var start: usize = 0;
    while (start < jobs.len) : (start += o.jobs) {
        var group: std.Io.Group = .init;
        for (jobs[start..@min(jobs.len, start + o.jobs)]) |*j| {
            group.concurrent(io, runExample, .{ j, io, o, tol, budget }) catch runExample(j, io, o, tol, budget);
        }
        try group.await(io);
    }
    var rows: std.ArrayList(Row) = .empty;
    for (jobs) |j| try rows.appendSlice(arena, j.rows.items);

    // Table.
    var w = std.Io.Writer.Allocating.init(arena);
    var name_w: usize = 4;
    for (rows.items) |r| name_w = @max(name_w, r.name.len);
    try w.writer.print("\nvisual regression ({s}, tol {d}, budget {d})\n", .{ if (o.web) "web" else "native", tol, budget });
    try writeRow(&w.writer, name_w, "NAME", "STATUS", "DETAIL");
    var failed: usize = 0;
    for (rows.items) |r| {
        try writeRow(&w.writer, name_w, r.name, r.status, r.detail);
        if (!r.ok) failed += 1;
    }
    try w.writer.print("\n{d} shot(s), {d} failed\n", .{ rows.items.len, failed });
    if (failed > 0 and !o.update) try w.writer.print("diffs: {s}/*.diff.png (actual: *.actual.png); if the change is intended, rerun with --update\n", .{o.out});
    try std.Io.File.stdout().writeStreamingAll(io, w.written());
    if (failed > 0) std.process.exit(1);
}

const Job = struct {
    ex: []const u8,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
};

fn runExample(j: *Job, io: std.Io, o: Options, tol: u8, budget: u32) void {
    runExampleInner(j, io, o, tol, budget) catch |e| {
        const a = j.arena.allocator();
        j.rows.append(a, .{ .name = j.ex, .status = "ERROR", .detail = @errorName(e), .ok = false }) catch {};
    };
}

fn runExampleInner(j: *Job, io: std.Io, o: Options, tol: u8, budget: u32) !void {
    const arena = j.arena.allocator();
    const ex = j.ex;
    if (o.web) {
        if (for (web_skip) |sk| {
            if (std.mem.eql(u8, sk, ex)) break true;
        } else false) return;
        try webShot(arena, io, o, ex, tol, budget, &j.rows);
        return;
    }
    const states = listStates(arena, io, o, ex) catch |e| {
        try j.rows.append(arena, .{ .name = ex, .status = "ERROR", .detail = @errorName(e), .ok = false });
        return;
    };
    for (states) |st| {
        if (o.state) |want| if (!std.mem.eql(u8, want, st)) continue;
        try nativeShot(arena, io, o, ex, st, tol, budget, &j.rows);
    }
}

fn writeRow(w: *std.Io.Writer, name_w: usize, name: []const u8, status: []const u8, detail: []const u8) !void {
    try w.writeAll(name);
    try w.splatByteAll(' ', name_w + 1 - name.len);
    try w.writeAll(status);
    try w.splatByteAll(' ', 9 -| status.len);
    try w.print("{s}\n", .{detail});
}

fn usage() error{BadArgs} {
    std.debug.print("usage: vreg [--update] [--web] [--examples a,b] [--state name] [--jobs N] [--tol N] [--budget N] [--out dir] [--golden dir] [--zig path] [--node path]\n", .{});
    return error.BadArgs;
}

fn listExamples(arena: std.mem.Allocator, io: std.Io, o: Options) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const shot = try std.fmt.allocPrint(arena, "{s}/src/shot_main.zig", .{e.name});
        dir.access(io, shot, .{}) catch continue;
        if (o.examples) |want| {
            var hit = false;
            var parts = std.mem.splitScalar(u8, want, ',');
            while (parts.next()) |p| if (std.mem.eql(u8, p, e.name)) {
                hit = true;
            };
            if (!hit) continue;
        }
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

fn exampleDir(arena: std.mem.Allocator, ex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "examples/{s}", .{ex});
}

fn listStates(arena: std.mem.Allocator, io: std.Io, o: Options, ex: []const u8) ![]const []const u8 {
    std.debug.print("[vreg] {s}: listing states\n", .{ex});
    const res = try std.process.run(arena, io, .{
        .argv = &.{ o.zig, "build", "shot", "--", "--list" },
        .cwd = .{ .path = try exampleDir(arena, ex) },
    });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("{s}: `zig build shot -- --list` failed:\n{s}\n", .{ ex, res.stderr });
        return error.ListFailed;
    }
    var states: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r\t");
        if (t.len > 0) try states.append(arena, t);
    }
    return states.items;
}

fn nativeShot(arena: std.mem.Allocator, io: std.Io, o: Options, ex: []const u8, state: []const u8, tol: u8, budget: u32, rows: *std.ArrayList(Row)) !void {
    const name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ ex, state });
    const actual_path = try std.fmt.allocPrint(arena, "{s}/{s}.actual.png", .{ o.out, name });
    const golden_path = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ o.golden, name });
    // The shot runs with cwd = the example, so the output path must be absolute.
    const abs_actual = try std.Io.Dir.cwd().realPathFileAlloc(io, o.out, arena);
    const abs_out = try std.fmt.allocPrint(arena, "{s}/{s}.actual.png", .{ abs_actual, name });

    std.debug.print("[vreg] {s}: rendering\n", .{name});
    const res = try std.process.run(arena, io, .{
        .argv = &.{ o.zig, "build", "shot", "--", abs_out, "--state", state },
        .cwd = .{ .path = try exampleDir(arena, ex) },
    });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("{s}: shot failed:\n{s}\n", .{ name, res.stderr });
        try rows.append(arena, .{ .name = name, .status = "ERROR", .detail = "shot step failed (see stderr above)", .ok = false });
        return;
    }
    try judge(arena, io, o, name, actual_path, golden_path, tol, budget, rows);
}

fn webShot(arena: std.mem.Allocator, io: std.Io, o: Options, ex: []const u8, tol: u8, budget: u32, rows: *std.ArrayList(Row)) !void {
    const dir = try exampleDir(arena, ex);
    const name = try std.fmt.allocPrint(arena, "web/{s}", .{ex});
    const actual_path = try std.fmt.allocPrint(arena, "{s}/web-{s}.actual.png", .{ o.out, ex });
    const golden_path = try std.fmt.allocPrint(arena, "{s}/web/{s}.png", .{ o.golden, ex });

    const build = try std.process.run(arena, io, .{ .argv = &.{ o.zig, "build", "web" }, .cwd = .{ .path = dir } });
    if (build.term != .exited or build.term.exited != 0) {
        std.debug.print("{s}: `zig build web` failed:\n{s}\n", .{ ex, build.stderr });
        try rows.append(arena, .{ .name = name, .status = "ERROR", .detail = "web build failed", .ok = false });
        return;
    }
    const dist = try std.fmt.allocPrint(arena, "{s}/dist", .{dir});
    const shot = try std.process.run(arena, io, .{
        .argv = &.{ o.node, "tools/webshot.mjs", dist, actual_path, "--wait-ms", "4000" },
    });
    if (shot.term != .exited or shot.term.exited != 0) {
        std.debug.print("{s}: webshot failed:\n{s}\n{s}\n", .{ ex, shot.stdout, shot.stderr });
        try rows.append(arena, .{ .name = name, .status = "ERROR", .detail = "webshot failed (page error / blank canvas / no browser)", .ok = false });
        return;
    }
    try judge(arena, io, o, name, actual_path, golden_path, tol, budget, rows);
}

/// Compare `actual_path` with `golden_path`; record a table row; write
/// the diff image on failure; with `--update` rewrite the golden.
fn judge(arena: std.mem.Allocator, io: std.Io, o: Options, name: []const u8, actual_path: []const u8, golden_path: []const u8, tol: u8, budget: u32, rows: *std.ArrayList(Row)) !void {
    const cwd = std.Io.Dir.cwd();
    const actual_bytes = try cwd.readFileAlloc(io, actual_path, arena, .limited(256 << 20));
    const actual = try png.decodePng(arena, actual_bytes);

    const golden_bytes = cwd.readFileAlloc(io, golden_path, arena, .limited(256 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            if (o.update) {
                try writeGolden(io, golden_path, actual_bytes);
                try rows.append(arena, .{ .name = name, .status = "NEW", .detail = try std.fmt.allocPrint(arena, "wrote {s}", .{golden_path}), .ok = true });
            } else {
                try rows.append(arena, .{ .name = name, .status = "MISSING", .detail = try std.fmt.allocPrint(arena, "no golden {s}; run with --update", .{golden_path}), .ok = false });
            }
            return;
        },
        else => return e,
    };
    const expected = try png.decodePng(arena, golden_bytes);

    const diff_buf = try arena.alloc(u8, actual.rgba.len);
    const c = compare(expected, actual, tol, if (expected.width == actual.width and expected.height == actual.height) diff_buf else null);

    if (c.size_mismatch) {
        try rows.append(arena, .{ .name = name, .status = "FAIL", .detail = try std.fmt.allocPrint(arena, "size {d}x{d} vs golden {d}x{d}", .{ actual.width, actual.height, expected.width, expected.height }), .ok = false });
        if (o.update) {
            try writeGolden(io, golden_path, actual_bytes);
            rows.items[rows.items.len - 1] = .{ .name = name, .status = "UPDATED", .detail = "size changed", .ok = true };
        }
        return;
    }
    const bbox = if (c.differing > 0) try std.fmt.allocPrint(arena, " bbox x {d}..{d} y {d}..{d}", .{ c.x0, c.x1, c.y0, c.y1 }) else "";
    const detail = try std.fmt.allocPrint(arena, "{d} px > tol (budget {d}), {d} px noisy, max delta {d}{s}", .{ c.differing, budget, c.nonzero, c.max_delta, bbox });
    if (c.pass(budget)) {
        try rows.append(arena, .{ .name = name, .status = "ok", .detail = detail, .ok = true });
        return;
    }
    if (o.update) {
        try writeGolden(io, golden_path, actual_bytes);
        try rows.append(arena, .{ .name = name, .status = "UPDATED", .detail = detail, .ok = true });
        return;
    }
    const diff_path = try std.fmt.allocPrint(arena, "{s}/{s}.diff.png", .{ o.out, std.mem.replaceOwned(u8, arena, name, "/", "-") catch name });
    const diff_png = try png.encodePng(arena, diff_buf, actual.width, actual.height);
    try cwd.writeFile(io, .{ .sub_path = diff_path, .data = diff_png });
    try rows.append(arena, .{ .name = name, .status = "FAIL", .detail = detail, .ok = false });
}

fn writeGolden(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}

// ── Tests ──────────────────────────────────────────────────────────

fn solid(gpa: std.mem.Allocator, w: u32, h: u32, c: [4]u8) !png.Image {
    const buf = try gpa.alloc(u8, w * h * 4);
    for (0..w * h) |i| @memcpy(buf[i * 4 ..][0..4], &c);
    return .{ .width = w, .height = h, .rgba = buf };
}

test "compare: identical images pass, noise within tolerance is not counted, real changes are" {
    const gpa = std.testing.allocator;
    const a = try solid(gpa, 20, 10, .{ 10, 10, 10, 255 });
    defer a.deinit(gpa);
    const b = try solid(gpa, 20, 10, .{ 10, 10, 10, 255 });
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0), compare(a, b, 8, null).differing);

    // 5 px of +6 noise: within tol 8, counted as noisy only.
    for (0..5) |i| b.rgba[i * 4] += 6;
    var r = compare(a, b, 8, null);
    try std.testing.expectEqual(@as(u32, 0), r.differing);
    try std.testing.expectEqual(@as(u32, 5), r.nonzero);
    try std.testing.expect(r.pass(0));

    // 3 px of +60: over tol.
    for (10..13) |i| b.rgba[i * 4 + 1] += 60;
    r = compare(a, b, 8, null);
    try std.testing.expectEqual(@as(u32, 3), r.differing);
    try std.testing.expectEqual(@as(u8, 60), r.max_delta);
    try std.testing.expect(!r.pass(2) and r.pass(3));
    try std.testing.expectEqual(@as(u32, 10), r.x0);
    try std.testing.expectEqual(@as(u32, 12), r.x1);
}

test "compare: size mismatch fails; diff image marks the changed pixels red" {
    const gpa = std.testing.allocator;
    const a = try solid(gpa, 4, 4, .{ 30, 30, 30, 255 });
    defer a.deinit(gpa);
    const small = try solid(gpa, 4, 3, .{ 30, 30, 30, 255 });
    defer small.deinit(gpa);
    try std.testing.expect(!compare(a, small, 8, null).pass(1000));

    const b = try solid(gpa, 4, 4, .{ 30, 30, 30, 255 });
    defer b.deinit(gpa);
    b.rgba[5 * 4] = 200;
    const diff = try gpa.alloc(u8, 4 * 4 * 4);
    defer gpa.free(diff);
    _ = compare(a, b, 8, diff);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, diff[5 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 10, 10, 255 }, diff[0..4]);
}
