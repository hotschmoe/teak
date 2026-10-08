//! The run loop's half of declarative resources (HARDLINE §2 hatch 8; the
//! data types are in `core/resources.zig`). `Table` remembers which
//! (kind, key) is on the GPU at which `rev` and under which backend
//! handle; `sync` reconciles it with the App's `resources()` list each
//! frame, and `remap*` turns the app keys in draw records into handles.
//!
//! Orchestration state, like `run`'s title buffer: it holds no application
//! state and the Gpu is duck-typed (`anytype`), so this file imports no
//! backend. Fixed capacity, no allocation.

const std = @import("std");
const builtin = @import("builtin");
const res = @import("core/resources.zig");
const render = @import("render/build.zig");
const scene = @import("core/scene.zig");

pub const Resource = res.Resource;
pub const Kind = res.Kind;

/// Most resources (images + meshes) one app can keep resident at once.
/// Resources past it are not uploaded: `sync` counts them in
/// `Table.dropped` and logs a warning once, and their draws are skipped
/// (the unknown key remaps to the none handle). Raise it here if a real
/// app needs more; entries are 16 bytes.
pub const MAX_RESOURCES: usize = 1024;

const Entry = struct {
    kind: Kind,
    key: u32,
    rev: u32,
    /// Backend handle; 0 when the upload failed (not retried until `rev`
    /// changes, so a bad resource cannot cost an upload attempt per frame).
    handle: u32,
    seen: bool,
};

pub const Table = struct {
    entries: [MAX_RESOURCES]Entry = undefined,
    len: usize = 0,
    /// Resources listed beyond `MAX_RESOURCES` in the latest `sync`.
    dropped: usize = 0,
    warned: bool = false,

    /// Reconcile the GPU with `list`: upload new (kind, key) pairs,
    /// re-upload when `rev` changed, release entries no longer listed.
    /// Returns true when anything was uploaded or released, so the loop
    /// can force a re-stage of draws that reference the affected handles.
    /// Keys must be unique per kind; entries past `MAX_RESOURCES` are
    /// ignored loudly (see `MAX_RESOURCES`).
    pub fn sync(self: *Table, gpu: anytype, list: []const Resource) bool {
        var changed = false;
        self.dropped = 0;
        for (self.entries[0..self.len]) |*e| e.seen = false;

        for (list) |r| {
            if (r.key() == 0) continue;
            if (self.find(r.kind(), r.key())) |e| {
                e.seen = true;
                if (e.rev == r.rev()) continue;
                release(gpu, e.kind, e.handle);
                e.rev = r.rev();
                e.handle = upload(gpu, r);
                changed = true;
            } else if (self.len < MAX_RESOURCES) {
                self.entries[self.len] = .{
                    .kind = r.kind(),
                    .key = r.key(),
                    .rev = r.rev(),
                    .handle = upload(gpu, r),
                    .seen = true,
                };
                self.len += 1;
                changed = true;
            } else {
                self.dropped += 1;
                if (!self.warned) {
                    self.warned = true;
                    // Web entry points route std.log through `platform.logFn` (std_options).
                    std.log.warn("teak: more than {d} resources declared; the extra ones are not uploaded (resources.MAX_RESOURCES)", .{MAX_RESOURCES});
                }
            }
        }

        var i: usize = 0;
        while (i < self.len) {
            const e = self.entries[i];
            if (e.seen) {
                i += 1;
                continue;
            }
            release(gpu, e.kind, e.handle);
            self.len -= 1;
            self.entries[i] = self.entries[self.len];
            changed = true;
        }
        return changed;
    }

    /// Release everything (shutdown).
    pub fn deinit(self: *Table, gpu: anytype) void {
        for (self.entries[0..self.len]) |e| release(gpu, e.kind, e.handle);
        self.len = 0;
    }

    fn find(self: *Table, kind: Kind, key: u32) ?*Entry {
        for (self.entries[0..self.len]) |*e| {
            if (e.kind == kind and e.key == key) return e;
        }
        return null;
    }

    /// Backend handle for an app key; 0 when unknown or its upload failed.
    pub fn handleOf(self: *Table, kind: Kind, key: u32) u32 {
        return if (self.find(kind, key)) |e| e.handle else 0;
    }

    /// Replace the app keys in image draws with backend handles. A key
    /// that is not (or not yet) resident becomes the none handle, so the
    /// Gpu skips the draw.
    pub fn remapImages(self: *Table, draws: []render.ImageDraw) void {
        for (draws) |*d| d.handle = self.handleOf(.image, d.handle);
    }

    /// Same for scene draws: an unknown mesh key draws just the clear colour.
    pub fn remapScenes(self: *Table, draws: []render.SceneDraw) void {
        for (draws) |*d| d.mesh = self.handleOf(.mesh, d.mesh);
    }
};

fn upload(gpu: anytype, r: Resource) u32 {
    return switch (r) {
        .mesh => |m| gpu.uploadMesh(m.data),
        .image => |im| gpu.uploadImage(im.rgba, im.width, im.height),
    };
}

fn release(gpu: anytype, kind: Kind, handle: u32) void {
    if (handle == 0) return;
    switch (kind) {
        .mesh => gpu.releaseMesh(handle),
        .image => gpu.releaseImage(handle),
    }
}

/// Hand this frame's image and scene draws to the Gpu: remap resource keys
/// (when the App declares resources), then `uploadImages` and — if the
/// backend has the scene extension — `renderScenes`. Called wherever the
/// loop re-stages draws; `renderScenes` runs even with no scenes so the
/// previous frame's composites are cleared.
pub fn stageDraws(
    gpu: anytype,
    table: ?*Table,
    images: []render.ImageDraw,
    scenes: []render.SceneDraw,
) void {
    if (table) |t| {
        t.remapImages(images);
        t.remapScenes(scenes);
    }
    gpu.uploadImages(images);
    if (comptime @hasDecl(@TypeOf(gpu.*), "renderScenes")) gpu.renderScenes(scenes);
}

// ── Tests ──────────────────────────────────────────────────────────

const StubGpu = struct {
    next: u32 = 1,
    uploads: u32 = 0,
    released: [16]u32 = undefined,
    released_len: usize = 0,
    fail_images: bool = false,

    pub fn uploadMesh(self: *StubGpu, _: scene.MeshData) u32 {
        return self.alloc();
    }
    pub fn uploadImage(self: *StubGpu, _: []const u8, _: u32, _: u32) u32 {
        return if (self.fail_images) 0 else self.alloc();
    }
    pub fn releaseMesh(self: *StubGpu, h: u32) void {
        self.free(h);
    }
    pub fn releaseImage(self: *StubGpu, h: u32) void {
        self.free(h);
    }
    fn alloc(self: *StubGpu) u32 {
        self.uploads += 1;
        defer self.next += 1;
        return self.next;
    }
    fn free(self: *StubGpu, h: u32) void {
        self.released[self.released_len] = h;
        self.released_len += 1;
    }
};

fn img(key: u32, rev: u32) Resource {
    return .{ .image = .{ .key = key, .rev = rev, .width = 1, .height = 1, .rgba = &.{ 1, 2, 3, 4 } } };
}

fn mesh(key: u32, rev: u32) Resource {
    return .{ .mesh = .{ .key = key, .rev = rev, .data = .{} } };
}

test "sync uploads once per (key, rev) and is quiet while nothing changes" {
    var gpu: StubGpu = .{};
    var t: Table = .{};
    const list = [_]Resource{ img(1, 1), mesh(1, 1) };

    try std.testing.expect(t.sync(&gpu, &list));
    try std.testing.expectEqual(@as(u32, 2), gpu.uploads);
    // Same key number, different kinds: independent entries.
    try std.testing.expect(t.handleOf(.image, 1) != t.handleOf(.mesh, 1));

    try std.testing.expect(!t.sync(&gpu, &list));
    try std.testing.expect(!t.sync(&gpu, &list));
    try std.testing.expectEqual(@as(u32, 2), gpu.uploads);
    try std.testing.expectEqual(@as(usize, 0), gpu.released_len);
}

test "a rev bump re-uploads and releases the old handle" {
    var gpu: StubGpu = .{};
    var t: Table = .{};
    _ = t.sync(&gpu, &.{img(7, 1)});
    const first = t.handleOf(.image, 7);

    try std.testing.expect(t.sync(&gpu, &.{img(7, 2)}));
    try std.testing.expectEqual(@as(u32, 2), gpu.uploads);
    try std.testing.expectEqual(@as(usize, 1), gpu.released_len);
    try std.testing.expectEqual(first, gpu.released[0]);
    try std.testing.expect(t.handleOf(.image, 7) != first);
}

test "keys that disappear are released; deinit releases the rest" {
    var gpu: StubGpu = .{};
    var t: Table = .{};
    _ = t.sync(&gpu, &.{ img(1, 1), img(2, 1), mesh(3, 1) });
    const keep = t.handleOf(.mesh, 3);

    try std.testing.expect(t.sync(&gpu, &.{mesh(3, 1)}));
    try std.testing.expectEqual(@as(usize, 2), gpu.released_len);
    try std.testing.expectEqual(@as(u32, 0), t.handleOf(.image, 1));
    try std.testing.expectEqual(keep, t.handleOf(.mesh, 3)); // survivor untouched

    t.deinit(&gpu);
    try std.testing.expectEqual(@as(usize, 3), gpu.released_len);
    try std.testing.expectEqual(@as(usize, 0), t.len);
}

test "failed upload is not retried until rev changes; key 0 is ignored" {
    var gpu: StubGpu = .{ .fail_images = true };
    var t: Table = .{};
    try std.testing.expect(t.sync(&gpu, &.{ img(5, 1), img(0, 1) }));
    try std.testing.expectEqual(@as(u32, 0), t.handleOf(.image, 5));
    try std.testing.expect(!t.sync(&gpu, &.{img(5, 1)})); // no retry spam
    gpu.fail_images = false;
    try std.testing.expect(t.sync(&gpu, &.{img(5, 2)}));
    try std.testing.expect(t.handleOf(.image, 5) != 0);
    try std.testing.expectEqual(@as(usize, 0), gpu.released_len); // handle 0 never "released"
}

test "remap turns keys into handles; unknown keys become none" {
    var gpu: StubGpu = .{};
    var t: Table = .{};
    _ = t.sync(&gpu, &.{ img(10, 1), mesh(20, 1) });

    var images = [_]render.ImageDraw{
        .{ .rect_x = 0, .rect_y = 0, .rect_w = 1, .rect_h = 1, .handle = 10, .tint = .{ 1, 1, 1, 1 }, .clip_x = 0, .clip_y = 0, .clip_w = 1, .clip_h = 1 },
        .{ .rect_x = 0, .rect_y = 0, .rect_w = 1, .rect_h = 1, .handle = 99, .tint = .{ 1, 1, 1, 1 }, .clip_x = 0, .clip_y = 0, .clip_w = 1, .clip_h = 1 },
    };
    t.remapImages(&images);
    try std.testing.expectEqual(t.handleOf(.image, 10), images[0].handle);
    try std.testing.expectEqual(@as(u32, 0), images[1].handle);

    var scenes = [_]render.SceneDraw{
        .{ .mesh = 20, .rect_x = 0, .rect_y = 0, .rect_w = 1, .rect_h = 1, .clip_x = 0, .clip_y = 0, .clip_w = 1, .clip_h = 1 },
        .{ .mesh = 0, .rect_x = 0, .rect_y = 0, .rect_w = 1, .rect_h = 1, .clip_x = 0, .clip_y = 0, .clip_w = 1, .clip_h = 1 },
    };
    t.remapScenes(&scenes);
    try std.testing.expectEqual(t.handleOf(.mesh, 20), scenes[0].mesh);
    try std.testing.expectEqual(@as(u32, 0), scenes[1].mesh);
}

test "table is bounded: overflow entries are dropped loudly (warned), not a crash" {
    // The one-time overflow warning is the behaviour under test; keep it off
    // the test runner's stderr (the runner reports logged output as failure).
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;
    var gpu: StubGpu = .{};
    var t: Table = .{};
    var list: [MAX_RESOURCES + 4]Resource = undefined;
    for (&list, 0..) |*r, i| r.* = img(@intCast(i + 1), 1);
    _ = t.sync(&gpu, &list);
    try std.testing.expect(t.warned);
    try std.testing.expectEqual(MAX_RESOURCES, t.len);
    try std.testing.expectEqual(@as(usize, 4), t.dropped);
    try std.testing.expectEqual(@as(u32, 0), t.handleOf(.image, MAX_RESOURCES + 1));
}
