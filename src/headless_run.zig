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
    run: run_mod.RunOptions = .{},
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
    for (o.fonts) |f| try host.registerFont(f.family, f.weight, f.bytes);
    var gpu = try Gpu.initOffscreen(o.width, o.height, .{ .msaa = o.msaa, .scale = o.scale });
    defer gpu.deinit();
    var rt = try run_mod.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, o.run);
    defer rt.deinit();

    try play(&rt, &host, o.steps);
    for (0..o.settle) |_| try rt.frame();
    try writeFramePng(&gpu, gpa, path);
}

pub const ServeOptions = struct {
    width: u32 = 1280,
    height: u32 = 800,
    msaa: bool = true,
    /// Real milliseconds slept between frames, so an idle headless app does
    /// not spin a core. The Host clock stays fake (16 ms per frame).
    frame_sleep_ms: u32 = 4,
    /// `control_path` / `record_path` / `replay_path` / `inspect` here are
    /// overridden by `TEAK_CONTROL` / `TEAK_RECORD` / `TEAK_REPLAY` /
    /// `TEAK_INSPECT`.
    run: run_mod.RunOptions = .{},
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
    var host = try Host.init(gpa, o.width, o.height);
    defer host.deinit();
    var gpu = try Gpu.initOffscreen(o.width, o.height, .{ .msaa = o.msaa });
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

/// `argv[1]` of a `pub fn main(init: std.process.Init)` program, or
/// `default` when absent: the output path of a `zig build shot -- out.png`.
pub fn pathArg(init: anytype, default: []const u8) []const u8 {
    // `toSlice` (not `iterate`) so this also works on Windows.
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return default;
    return if (args.len > 1) args[1] else default;
}

// ── PNG ────────────────────────────────────────────────────────────

/// Encode tightly packed RGBA8 as a PNG (8-bit RGBA, no interlace). The
/// zlib stream uses stored (uncompressed) blocks: dependency-free and
/// instant, at the cost of ~raw size (1280x800 -> 4 MB). Caller frees.
pub fn encodePng(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    if (rgba.len != @as(usize, width) * height * 4) return error.BadImageSize;
    const row = @as(usize, width) * 4;

    // Raw scanlines, each prefixed with filter byte 0.
    const raw_len = (row + 1) * height;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    for (0..height) |y| {
        raw[y * (row + 1)] = 0;
        @memcpy(raw[y * (row + 1) + 1 ..][0..row], rgba[y * row ..][0..row]);
    }

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

    // zlib: header, stored blocks of <= 65535 bytes, adler32.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var pos: usize = 0;
    while (pos < raw.len or pos == 0) {
        const n = @min(raw.len - pos, 65535);
        const final: u8 = if (pos + n >= raw.len) 1 else 0;
        var hdr: [5]u8 = undefined;
        hdr[0] = final;
        std.mem.writeInt(u16, hdr[1..3], @intCast(n), .little);
        std.mem.writeInt(u16, hdr[3..5], @intCast(~@as(u16, @intCast(n))), .little);
        try z.appendSlice(gpa, &hdr);
        try z.appendSlice(gpa, raw[pos..][0..n]);
        pos += n;
        if (final == 1) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler);
    try appendChunk(gpa, &out, "IDAT", z.items);

    try appendChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
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

test "encodePng writes a valid PNG: signature, IHDR, one IDAT, IEND, CRCs" {
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
    // Verify every chunk's CRC and find the IDAT payload.
    var off: usize = 8;
    var idat: []const u8 = "";
    var saw_end = false;
    while (off < png.len) {
        const len = std.mem.readInt(u32, png[off..][0..4], .big);
        const tag = png[off + 4 ..][0..4];
        const data = png[off + 8 ..][0..len];
        var crc = std.hash.Crc32.init();
        crc.update(tag);
        crc.update(data);
        try std.testing.expectEqual(crc.final(), std.mem.readInt(u32, png[off + 8 + len ..][0..4], .big));
        if (std.mem.eql(u8, tag, "IDAT")) idat = data;
        if (std.mem.eql(u8, tag, "IEND")) saw_end = true;
        off += 12 + len;
    }
    try std.testing.expect(saw_end);
    try std.testing.expectEqual(png.len, off);

    // Inflate the zlib stream and compare with the scanlines.
    var in: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    var raw: [2 * (2 * 4 + 1)]u8 = undefined;
    try decomp.reader.readSliceAll(&raw);
    try std.testing.expectEqual(@as(u8, 0), raw[0]);
    try std.testing.expectEqualSlices(u8, px[0..8], raw[1..9]);
    try std.testing.expectEqual(@as(u8, 0), raw[9]);
    try std.testing.expectEqualSlices(u8, px[8..16], raw[10..18]);
}

test "encodePng splits big images into stored blocks and keeps adler/crc valid" {
    const gpa = std.testing.allocator;
    const w = 300;
    const h = 100; // 300*100*4 + 100 > 65535: needs several stored blocks
    const px = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(px);
    for (px, 0..) |*b, i| b.* = @truncate(i *% 7);
    const png = try encodePng(gpa, px, w, h);
    defer gpa.free(png);

    var off: usize = 8;
    var idat: []const u8 = "";
    while (off < png.len) {
        const len = std.mem.readInt(u32, png[off..][0..4], .big);
        if (std.mem.eql(u8, png[off + 4 ..][0..4], "IDAT")) idat = png[off + 8 ..][0..len];
        off += 12 + len;
    }
    var in: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const raw = try gpa.alloc(u8, (w * 4 + 1) * h);
    defer gpa.free(raw);
    try decomp.reader.readSliceAll(raw);
    for (0..h) |y| {
        try std.testing.expectEqual(@as(u8, 0), raw[y * (w * 4 + 1)]);
        try std.testing.expectEqualSlices(u8, px[y * w * 4 ..][0 .. w * 4], raw[y * (w * 4 + 1) + 1 ..][0 .. w * 4]);
    }
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
