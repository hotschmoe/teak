//! Tool API for headless runs: script input, run frames, grab pixels, write
//! a PNG. Everything here is duck-typed over the Host / Gpu / Runtime (it
//! imports no backend), so it works with `platform/headless.zig` +
//! `Gpu.initOffscreen`; `teak.linkHeadless` wires those up. See
//! docs/features/headless.md.
//!
//! ```zig
//! var host = try Host.init(gpa, 1280, 800);   // teak-platform-headless
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
const pointer = @import("core/pointer.zig");
const keys = @import("input/keys.zig");
const run_mod = @import("run.zig");

// ── Scripted steps ─────────────────────────────────────────────────

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

// ── One-call screenshot ────────────────────────────────────────────

/// A TTF to register on the headless Host before the first frame
/// (`Host.registerFont`), like a windowed entry's `host.registerFont`.
pub const FontFace = struct {
    family: @import("core/text.zig").FontFamily,
    weight: @import("core/text.zig").FontWeight,
    ttf: []const u8,
};

pub const ShotOptions = struct {
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
    run: run_mod.RunOptions = .{},
    /// Embedded fonts to register on the Host (`@embedFile` slices).
    fonts: []const FontFace = &.{},
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
    var host = try Host.init(gpa, o.width, o.height);
    defer host.deinit();
    for (o.fonts) |f| try host.registerFont(f.family, f.weight, f.ttf);
    var gpu = try Gpu.initOffscreen(o.width, o.height, .{ .msaa = o.msaa, .scale = o.scale });
    defer gpu.deinit();
    var rt = try run_mod.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, o.run);
    defer rt.deinit();

    try play(&rt, &host, o.steps);
    for (0..o.settle) |_| try rt.frame();
    try writeFramePng(&gpu, gpa, path);
}

/// `argv[1]` of a `pub fn main(init: std.process.Init)` program, or
/// `default` when absent: the output path of a `zig build shot -- out.png`.
pub fn pathArg(init: anytype, default: []const u8) []const u8 {
    var it = init.minimal.args.iterate();
    _ = it.next(); // program name
    return it.next() orelse default;
}

// ── Named states + the shot CLI ────────────────────────────────────

/// A named, scripted app state for screenshots (`--state <name>`).
pub const ShotState = struct {
    name: []const u8,
    steps: []const Step,
};

/// The whole `shot_main.zig` for an example: parses
/// `[out.png] [--state <name>] [--list] [--all <dir> --prefix <p>]` from argv, plays that state's
/// script (`o.steps` is ignored; the first of `states` is the default),
/// and writes the PNG. `--list` prints the state names, one per line, on
/// stdout and exits. `--all <dir> --prefix <p>` renders every state to
/// `<dir>/<p>-<state>.actual.png` in one process and prints the names:
/// `tools/vreg` uses it so each example needs a single `zig build` call.
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
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--list")) {
            list = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            all_dir = it.next() orelse return error.MissingAllDir;
        } else if (std.mem.eql(u8, a, "--scale")) {
            opts_base.scale = std.fmt.parseFloat(f32, it.next() orelse return error.MissingScale) catch return error.BadScale;
        } else if (std.mem.eql(u8, a, "--prefix")) {
            prefix = it.next() orelse return error.MissingPrefix;
        } else if (std.mem.eql(u8, a, "--state")) {
            want = it.next() orelse return error.MissingStateName;
        } else path = a;
    }
    if (list) {
        for (states) |st| {
            try std.Io.File.stdout().writeStreamingAll(init.io, st.name);
            try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        }
        return;
    }
    if (all_dir) |dir| {
        for (states) |st| {
            var opts = opts_base;
            opts.steps = st.steps;
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
        try shot(App, Host, Gpu, init.gpa, path, opts);
        std.debug.print("wrote {s} (state {s})\n", .{ path, st.name });
        return;
    };
    std.debug.print("unknown state '{s}'; available:", .{want});
    for (states) |st| std.debug.print(" {s}", .{st.name});
    std.debug.print("\n", .{});
    return error.UnknownState;
}

// ── PNG ────────────────────────────────────────────────────────────

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

    // zlib stream of filtered scanlines.
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

    // Unfilter in place (each row against the previous reconstructed row).
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

// ── Tests ──────────────────────────────────────────────────────────

test "encodePng writes a valid PNG: signature, IHDR, CRCs, and decodes back" {
    const gpa = std.testing.allocator;
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 40 }; // 2x2
    const png = try encodePng(gpa, &px, 2, 2);
    defer gpa.free(png);

    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, png[8..12], .big));
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big)); // width
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[20..24], .big)); // height
    try std.testing.expectEqual(@as(u8, 6), png[25]); // RGBA
    var off: usize = 8;
    var saw_end = false;
    while (off < png.len) {
        const len = std.mem.readInt(u32, png[off..][0..4], .big);
        const tag = png[off + 4 ..][0..4];
        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(png[off + 8 ..][0..len]);
        try std.testing.expectEqual(crc.final(), std.mem.readInt(u32, png[off + 8 + len ..][0..4], .big));
        if (std.mem.eql(u8, tag, "IEND")) saw_end = true;
        off += 12 + len;
    }
    try std.testing.expect(saw_end);
    try std.testing.expectEqual(png.len, off);

    const img = try decodePng(gpa, png);
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqualSlices(u8, &px, img.rgba);
}

test "encodePng round-trips noisy and flat images; flat UI-like images compress hard; output is deterministic" {
    const gpa = std.testing.allocator;
    const w = 300;
    const h = 200;
    const px = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(px);

    // Noise exercises every filter choice and multi-block deflate output.
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(px);
    const noisy = try encodePng(gpa, px, w, h);
    defer gpa.free(noisy);
    const back = try decodePng(gpa, noisy);
    defer back.deinit(gpa);
    try std.testing.expectEqualSlices(u8, px, back.rgba);

    // A flat background with a rectangle: the screenshot-like case.
    for (0..h) |y| for (0..w) |x| {
        const inside = x > 40 and x < 200 and y > 30 and y < 90;
        const c: [4]u8 = if (inside) .{ 200, 60, 60, 255 } else .{ 24, 26, 32, 255 };
        @memcpy(px[(y * w + x) * 4 ..][0..4], &c);
    };
    const flat = try encodePng(gpa, px, w, h);
    defer gpa.free(flat);
    try std.testing.expect(flat.len < w * h * 4 / 50);
    const flat2 = try encodePng(gpa, px, w, h);
    defer gpa.free(flat2);
    try std.testing.expectEqualSlices(u8, flat, flat2);
    const back2 = try decodePng(gpa, flat);
    defer back2.deinit(gpa);
    try std.testing.expectEqualSlices(u8, px, back2.rgba);
}

test "encodePng rejects a pixel buffer of the wrong size" {
    try std.testing.expectError(error.BadImageSize, encodePng(std.testing.allocator, &.{ 1, 2, 3 }, 1, 1));
}

test "play drives frames and queues input for a recording host" {
    const Rt = struct {
        frames: u32 = 0,
        fn frame(self: *@This()) !void {
            self.frames += 1;
        }
    };
    const Host = struct {
        log: [16]u8 = undefined,
        n: usize = 0,
        fn note(self: *@This(), c: u8) void {
            self.log[self.n] = c;
            self.n += 1;
        }
        fn pushMouseMove(self: *@This(), _: f32, _: f32) void {
            self.note('m');
        }
        fn pushMouseDown(self: *@This(), _: pointer.Button) void {
            self.note('d');
        }
        fn pushMouseUp(self: *@This(), _: pointer.Button) void {
            self.note('u');
        }
        fn pushWheel(self: *@This(), _: f32, _: f32) void {
            self.note('w');
        }
        fn pushChars(self: *@This(), _: []const u8) void {
            self.note('c');
        }
        fn pushKey(self: *@This(), _: keys.SpecialKey) void {
            self.note('k');
        }
        fn setModifiers(self: *@This(), _: pointer.Modifiers) void {
            self.note('s');
        }
    };
    var rt: Rt = .{};
    var host: Host = .{};
    try play(&rt, &host, &.{
        .{ .frames = 2 },
        .{ .click = .{ 5, 5 } }, // m, frame, d, frame, u, frame
        .{ .chars = "x" },
        .{ .key = .enter },
        .{ .wheel = .{ 0, 3 } },
        .{ .frames = 1 },
    });
    try std.testing.expectEqualStrings("mduckw", host.log[0..host.n]);
    try std.testing.expectEqual(@as(u32, 2 + 3 + 1), rt.frames);

    var rt2: Rt = .{};
    var host2: Host = .{};
    try play(&rt2, &host2, &.{.{ .drag = .{ .{ 0, 0 }, .{ 40, 40 } } }});
    try std.testing.expectEqualStrings("mdmmmmu", host2.log[0..host2.n]);
    try std.testing.expectEqual(@as(u32, 7), rt2.frames);
}
