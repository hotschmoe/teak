//! See SRC.md, src/sim/gpu.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const hashing = @import("hash.zig");
const interface = @import("../gpu/context.zig");
const render = @import("../render/build.zig");
const scene = @import("../core/scene.zig");
const Vertex = @import("../render/vertex.zig").Vertex;
const verify = @import("sim.zig").verify;

pub const resources_max = 1024;
const Kind = enum { empty, image, mesh };
const Slot = struct { handle: u32 = 0, kind: Kind = .empty, digest: u64 = 0 };
const Stage = enum { ready, overlay, vertices, text, images };
const Operation = union(enum) {
    resize: [2]u32,
    scale: f32,
    overlay: render.OverlaySplit,
    vertices: u64,
    text: u64,
    images: u64,
    scenes: u64,
    present: interface.ClearColor,
    acquire: struct { kind: Kind, handle: u32, digest: u64 },
    release: struct { kind: Kind, handle: u32 },
};

pub const Gpu = struct {
    live: bool = true,
    failure: ?anyerror = null,
    slots: [resources_max]Slot = @splat(.{}),
    created: u32 = 0,
    released: u32 = 0,
    limits: u32 = 0,
    presents: u64 = 0,
    uploads: u64 = 0,
    stage: Stage = .ready,
    initialized: bool = false,
    split: render.OverlaySplit = .{},
    width: u32 = 1280,
    height: u32 = 800,
    scale: f32 = 1,
    vertices_hash: u64 = 0,
    text_hash: u64 = 0,
    images_hash: u64 = 0,
    scenes_hash: u64 = 0,
    calls: hashing.Hasher = .{},
    image_handles: [resources_max]u32 = @splat(0),
    mesh_handles: [resources_max]u32 = @splat(0),
    image_count: u16 = 0,
    mesh_count: u16 = 0,

    pub fn begin(self: *Gpu) void {
        assert(self.live);
        assert(self.calls.count == 0);
        self.calls = .{};
    }

    fn record(self: *Gpu, value: Operation) void {
        assert(self.live);
        assert(self.calls.count == 0);
        self.calls.add(value) catch |err| {
            self.failure = err;
            self.calls.count = 0;
        };
    }

    fn digest(self: *Gpu, value: anytype) u64 {
        assert(self.live);
        assert(self.calls.count == 0);
        return hashing.hash(value) catch |err| {
            self.failure = err;
            return 0;
        };
    }

    fn require_stage(self: *Gpu, stage: Stage) void {
        assert(self.live);
        assert(self.created >= self.released);
        if (self.stage != stage) self.failure = error.GpuProtocol;
    }

    pub fn resize(self: *Gpu, width: u32, height: u32) void {
        self.require_stage(.ready);
        assert(self.live);
        self.width = width;
        self.height = height;
        self.record(.{ .resize = .{ width, height } });
        assert(self.width == width and self.height == height);
    }

    pub fn setScale(self: *Gpu, scale: f32) void {
        self.require_stage(.ready);
        assert(scale > 0);
        assert(std.math.isFinite(scale));
        self.scale = scale;
        self.record(.{ .scale = scale });
    }

    pub fn setOverlayStart(self: *Gpu, split: render.OverlaySplit) void {
        self.require_stage(.ready);
        assert(self.live);
        self.split = split;
        self.stage = .overlay;
        self.record(.{ .overlay = split });
        assert(self.stage == .overlay);
    }

    pub fn uploadVertices(self: *Gpu, vertices: []const Vertex) void {
        self.require_stage(.overlay);
        assert(self.live);
        if (self.split.verts > vertices.len) self.failure = error.OverlayBounds;
        self.vertices_hash = self.digest(vertices);
        self.record(.{ .vertices = self.vertices_hash });
        self.stage = .vertices;
        self.uploads += 1;
        assert(self.stage == .vertices);
    }

    pub fn uploadText(self: *Gpu, draws: []const interface.TextDraw) void {
        self.require_stage(.vertices);
        assert(self.live);
        if (self.split.text > draws.len) self.failure = error.OverlayBounds;
        self.text_hash = self.digest(draws);
        self.record(.{ .text = self.text_hash });
        self.stage = .text;
        assert(self.stage == .text);
    }

    pub fn uploadImages(self: *Gpu, draws: []const render.ImageDraw) void {
        self.require_stage(.text);
        assert(self.live);
        self.image_count = 0;
        if (self.split.images > draws.len) self.failure = error.OverlayBounds;
        for (draws) |draw| self.remember(.image, draw.handle);
        self.images_hash = self.digest(draws);
        self.record(.{ .images = self.images_hash });
        self.stage = .images;
        assert(self.stage == .images);
    }

    pub fn renderScenes(self: *Gpu, draws: []const scene.SceneDraw, data: scene.SceneData) void {
        self.require_stage(.images);
        assert(self.live);
        self.mesh_count = 0;
        if (self.split.scenes > draws.len) self.failure = error.OverlayBounds;
        for (draws) |draw| {
            self.remember(.mesh, draw.mesh);
            if (@as(u64, draw.item_first) + draw.item_count > data.items.len or
                @as(u64, draw.sprite_first) + draw.sprite_count > data.sprites.len)
                self.failure = error.SceneBounds;
        }
        for (data.items) |item| self.remember(.mesh, item.mesh);
        for (data.sprites) |sprite| self.remember(.image, sprite.image);
        self.scenes_hash = self.digest(.{ draws, data });
        self.record(.{ .scenes = self.scenes_hash });
        self.stage = .ready;
        self.initialized = true;
        assert(self.stage == .ready);
    }

    fn remember(self: *Gpu, kind: Kind, handle: u32) void {
        assert(self.live);
        assert(kind != .empty);
        if (handle == 0) return;
        self.check_handle(kind, handle);
        const count = if (kind == .image) &self.image_count else &self.mesh_count;
        const handles = if (kind == .image) &self.image_handles else &self.mesh_handles;
        if (count.* == resources_max) {
            self.limits += 1;
            self.failure = error.DrawLimit;
            return;
        }
        handles[count.*] = handle;
        count.* += 1;
    }

    pub fn renderFrame(self: *Gpu, clear: interface.ClearColor) void {
        self.require_stage(.ready);
        assert(self.live);
        assert(self.created >= self.released);
        if (!self.initialized) self.failure = error.PresentBeforeUpload;
        if (comptime verify) {
            for (self.image_handles[0..self.image_count]) |h| self.check_handle(.image, h);
            for (self.mesh_handles[0..self.mesh_count]) |h| self.check_handle(.mesh, h);
        }
        self.record(.{ .present = clear });
        self.presents += 1;
    }

    pub fn uploadImage(self: *Gpu, bytes: []const u8, width: u32, height: u32) u32 {
        assert(self.live);
        assert(self.created >= self.released);
        const pixels = @as(u64, width) * height;
        if (pixels > std.math.maxInt(u64) / 4 or pixels * 4 != bytes.len) {
            self.failure = error.ImageBounds;
            return 0;
        }
        return self.acquire(.image, self.digest(.{ width, height, bytes }));
    }

    pub fn uploadMesh(self: *Gpu, mesh: scene.MeshData) u32 {
        assert(self.live);
        assert(self.created >= self.released);
        mesh.validate() catch |err| {
            self.failure = err;
            return 0;
        };
        return self.acquire(.mesh, self.digest(mesh));
    }

    fn acquire(self: *Gpu, kind: Kind, content: u64) u32 {
        assert(self.live);
        assert(kind != .empty);
        if (self.created >= std.math.maxInt(u32) / resources_max - 1) {
            self.limits += 1;
            return 0;
        }
        for (&self.slots, 0..) |*slot, index| {
            if (slot.kind != .empty) continue;
            self.created += 1;
            const handle = self.created * resources_max + @as(u32, @intCast(index));
            slot.* = .{ .handle = handle, .kind = kind, .digest = content };
            self.record(.{ .acquire = .{ .kind = kind, .handle = handle, .digest = content } });
            return handle;
        }
        self.limits += 1;
        return 0;
    }

    fn check_handle(self: *Gpu, kind: Kind, handle: u32) void {
        assert(self.live);
        assert(kind != .empty);
        const slot = self.slots[handle % resources_max];
        if (slot.handle != handle or slot.kind != kind) self.failure = error.ResourceLifetime;
    }

    pub fn releaseImage(self: *Gpu, handle: u32) void {
        assert(self.live);
        assert(self.created >= self.released);
        self.release(.image, handle);
    }

    pub fn releaseMesh(self: *Gpu, handle: u32) void {
        assert(self.live);
        assert(self.created >= self.released);
        self.release(.mesh, handle);
    }

    fn release(self: *Gpu, kind: Kind, handle: u32) void {
        assert(self.live);
        assert(kind != .empty);
        self.check_handle(kind, handle);
        if (self.failure != null) return;
        self.slots[handle % resources_max].kind = .empty;
        self.released += 1;
        self.record(.{ .release = .{ .kind = kind, .handle = handle } });
    }

    pub fn frame_hash(self: *Gpu) hashing.Error!u64 {
        assert(self.live);
        assert(self.calls.count == 0);
        return hashing.hash(.{
            self.calls.finish(), self.vertices_hash, self.text_hash, self.images_hash,
            self.scenes_hash,    self.width,         self.height,    self.scale,
        });
    }

    pub fn deinit(self: *Gpu) void {
        assert(self.live);
        assert(self.created >= self.released);
        if (self.failure == null and self.created != self.released)
            self.failure = error.ResourceLeak;
        if (comptime verify) for (self.slots) |slot| {
            if (self.failure == null and slot.kind != .empty) self.failure = error.ResourceLeak;
        };
        if (self.failure == null and self.stage != .ready) self.failure = error.GpuProtocol;
        self.live = false;
    }
};

comptime {
    interface.validateGpu(Gpu);
}
