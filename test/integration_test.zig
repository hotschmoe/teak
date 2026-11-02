//! Framework-wide integration tests. Complements the per-module tests
//! colocated with each source file by driving the full
//! update → view → layout → hit-test → render pipeline end-to-end.
//!
//! Also compiled under `zig build test-wasm` against
//! `wasm32-freestanding` as a canary: if the framework core picks up a
//! posix-only std dep, this file fails to build for wasm before it
//! reaches production. See `tasks-wasm.md` §1 and `docs/HARDLINE.md` §5
//! drift-audit checklist.

const std = @import("std");
const builtin = @import("builtin");
const teak = @import("teak");

// ── A minimal composed app used by the round-trip test ────────────

const Counter = struct {
    pub const Model = struct { count: i32 = 0 };
    pub const Msg = union(enum) { inc, reset };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .inc => m.count += 1,
            .reset => m.count = 0,
        }
    }
    pub fn view(m: *const Model, cb: anytype, msgs: anytype) void {
        _ = m;
        cb.pushGroup(.{ .direction = .horizontal, .padding = 8, .gap = 8 });
        cb.button(msgs.inc, "+");
        cb.button(msgs.reset, "R");
        cb.popGroup();
    }
};

const App = teak.component.Components(.{ .counter = Counter }, null);

// ── Round-trip: click flows through all five passes ───────────────


// ── Virtual list: visible window holds work bounded ──────────────



// ── WASM canary: pipeline compiles without posix ─────────────────

/// Exported so `wasm32-freestanding -fno-entry -rdynamic` keeps the
/// pipeline alive at link time. Not meaningful to call at runtime;
/// compile-success is the signal.
export fn teak_wasm_probe() u32 {
    const Msg = union(enum) { ping };

    var heap_buf: [1 << 18]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const gpa = fba.allocator();

    var cb = teak.CmdBuffer(Msg).init(gpa);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("hello");
    cb.button(.ping, "+");
    cb.textInput(.ping, "world", 5);
    cb.checkbox(.ping, true, "ok");
    cb.radio(.ping, false, "pick");
    cb.slider(.ping, 0.42);
    cb.divider();
    cb.pushScroll(.{ .width = 100, .height = 100 });
    cb.button(.ping, "inside");
    cb.popScroll();
    cb.popGroup();

    var rects: [32]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, teak.monoMeasurer());

    _ = teak.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 10, 10);

    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(gpa);
    var text_draws: std.ArrayList(teak.TextDraw) = .empty;
    defer text_draws.deinit(gpa);
    var image_draws: std.ArrayList(teak.ImageDraw) = .empty;
    defer image_draws.deinit(gpa);
    teak.buildVertices(&verts, &text_draws, &image_draws, gpa, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, teak.monoMeasurer());

    return @intCast(verts.items.len);
}

/// Log policy of the wasm canary root. The default `std.log` sink drags in
/// `std.Io.Threaded`, which does not compile on wasm32-freestanding, so a web
/// entry point must declare a logFn (`platform.logFn`, i.e. `zunk.web.logFn`).
/// The framework itself logs (e.g. the resource-table overflow warning);
/// `teak_wasm_log_probe` below keeps those call sites in the canary so a
/// log path that only compiles natively fails `zig build test-wasm`.
pub const std_options: std.Options = if (builtin.target.cpu.arch == .wasm32)
    .{ .logFn = canaryLog }
else
    .{};

fn canaryLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

const LogProbeGpu = struct {
    pub fn uploadImage(_: *LogProbeGpu, _: []const u8, _: u32, _: u32) u32 {
        return 1;
    }
    pub fn uploadMesh(_: *LogProbeGpu, _: teak.MeshData) u32 {
        return 1;
    }
    pub fn releaseImage(_: *LogProbeGpu, _: u32) void {}
    pub fn releaseMesh(_: *LogProbeGpu, _: u32) void {}
    pub fn uploadCanvasGeometry(_: *LogProbeGpu, _: anytype, _: bool) u32 {
        return 1;
    }
    pub fn releaseCanvasGeometry(_: *LogProbeGpu, _: u32) void {}
};

/// Overflows the resource table so its `std.log.warn` is compiled and run
/// through the root's logFn.
export fn teak_wasm_log_probe() u32 {
    var gpu: LogProbeGpu = .{};
    var table: teak.ResourceTable = .{};
    var list: [200]teak.Resource = undefined;
    for (&list, 0..) |*r, i| r.* = .{ .image = .{ .key = @intCast(i + 1), .rev = 1, .rgba = &.{}, .width = 0, .height = 0 } };
    _ = table.sync(&gpu, &list);
    return @intCast(table.len);
}

// On native, drive teak_wasm_probe via a test so `zig build test`
// exercises the same surface the wasm canary covers.
