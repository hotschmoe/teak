//! Backend-neutral plan of what a scene slot draws: the packed per-instance
//! records, the runs of items that share a mesh (one instanced draw each),
//! and the content hash that decides whether the slot must be re-rendered.
//! Pure functions over `teak` data; `wgpu_scene.zig` and `web_scene.zig`
//! only translate the plan into API calls, so native and web agree by
//! construction. See docs/features/scene.md section 4.3.

const std = @import("std");
const teak = @import("teak");

const SceneDraw = teak.SceneDraw;
const Item = teak.SceneItem;

/// One instance as the vertex stage reads it (`shaders/scene.wgsl`
/// `@location(4..8)`): three rows of the 3x4 transform, tint, id and flags.
pub const Packed = extern struct {
    m0: [4]f32,
    m1: [4]f32,
    m2: [4]f32,
    tint: [4]f32,
    id: u32,
    /// `ItemFlags` bits: 0 hidden, 1 unlit, 2 no_edges, 3 no_pick, 4 highlight.
    flags: u32,
    _pad: [2]u32 = .{ 0, 0 },
};

pub const flag_unlit: u32 = 1 << 1;
pub const flag_no_edges: u32 = 1 << 2;
pub const flag_highlight: u32 = 1 << 4;

/// Items `first .. first + count` of `Plan.insts` all use backend mesh `mesh`.
pub const Run = struct { mesh: u32, first: u32, count: u32 };

pub fn pack(it: Item) Packed {
    const t = it.transform;
    return .{
        .m0 = .{ t[0], t[1], t[2], t[3] },
        .m1 = .{ t[4], t[5], t[6], t[7] },
        .m2 = .{ t[8], t[9], t[10], t[11] },
        .tint = it.tint,
        .id = it.id,
        .flags = @as(u8, @bitCast(it.flags)),
    };
}

pub const Plan = struct {
    insts: std.ArrayList(Packed) = .empty,
    runs: std.ArrayList(Run) = .empty,
    scratch: std.ArrayList(Keyed) = .empty,

    const Keyed = struct { mesh: u32, idx: u32 };

    pub fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        self.insts.deinit(gpa);
        self.runs.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    /// Rebuild the plan for `draw`. `items` is the scene's own slice
    /// (`scene_common.itemsOf`), keys already remapped to backend handles;
    /// `ctx.hasMesh(handle)` says whether a handle is resident. A scene with
    /// no items draws `draw.mesh` once, untransformed (the legacy
    /// `scene3d`). Hidden items and unknown meshes are dropped; the rest are
    /// ordered by mesh handle (ties keep their input order), so repeated
    /// parts collapse into one instanced draw.
    pub fn build(self: *Plan, gpa: std.mem.Allocator, draw: SceneDraw, items: []const Item, ctx: anytype) std.mem.Allocator.Error!void {
        self.insts.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();

        if (draw.item_count == 0 and items.len == 0) {
            if (draw.mesh != 0 and ctx.hasMesh(draw.mesh)) {
                try self.insts.append(gpa, pack(.{ .mesh = draw.mesh }));
                try self.runs.append(gpa, .{ .mesh = draw.mesh, .first = 0, .count = 1 });
            }
            return;
        }
        for (items, 0..) |it, i| {
            if (it.flags.hidden or it.mesh == 0 or !ctx.hasMesh(it.mesh)) continue;
            try self.scratch.append(gpa, .{ .mesh = it.mesh, .idx = @intCast(i) });
        }
        std.mem.sortUnstable(Keyed, self.scratch.items, {}, struct {
            fn less(_: void, a: Keyed, b: Keyed) bool {
                return if (a.mesh != b.mesh) a.mesh < b.mesh else a.idx < b.idx;
            }
        }.less);
        for (self.scratch.items) |k| {
            const pos: u32 = @intCast(self.insts.items.len);
            try self.insts.append(gpa, pack(items[k.idx]));
            if (self.runs.items.len > 0 and self.runs.items[self.runs.items.len - 1].mesh == k.mesh) {
                self.runs.items[self.runs.items.len - 1].count += 1;
            } else {
                try self.runs.append(gpa, .{ .mesh = k.mesh, .first = pos, .count = 1 });
            }
        }
    }

    /// Hash of everything the plan contributes to the picture: the packed
    /// instances, the run structure and each run's mesh version
    /// (`ctx.meshVersion(handle)`), so a re-upload into a reused slot
    /// re-renders.
    pub fn contentHash(self: *const Plan, ctx: anytype) u64 {
        var h = std.hash.Wyhash.init(0x5ce9e);
        h.update(std.mem.sliceAsBytes(self.insts.items));
        for (self.runs.items) |r| {
            h.update(std.mem.asBytes(&r));
            const v: u32 = ctx.meshVersion(r.mesh);
            h.update(std.mem.asBytes(&v));
        }
        return h.final();
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const TestCtx = struct {
    pub fn hasMesh(_: TestCtx, h: u32) bool {
        return h != 99;
    }
    pub fn meshVersion(_: TestCtx, h: u32) u32 {
        return h * 10;
    }
};

fn draw0() SceneDraw {
    return .{ .mesh = 0, .rect_x = 0, .rect_y = 0, .rect_w = 1, .rect_h = 1, .clip_x = 0, .clip_y = 0, .clip_w = 1, .clip_h = 1 };
}

test "Packed is the 80-byte instance record" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Packed));
}

test "legacy scene: one identity instance of draw.mesh; unknown mesh draws nothing" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    var d = draw0();
    d.mesh = 3;
    try plan.build(gpa, d, &.{}, TestCtx{});
    try std.testing.expectEqual(@as(usize, 1), plan.insts.items.len);
    try std.testing.expectEqual(@as(f32, 1), plan.insts.items[0].m0[0]);
    try std.testing.expectEqual(@as(f32, 1), plan.insts.items[0].m2[2]);
    try std.testing.expectEqual(@as(u32, 3), plan.runs.items[0].mesh);
    d.mesh = 99;
    try plan.build(gpa, d, &.{}, TestCtx{});
    try std.testing.expectEqual(@as(usize, 0), plan.runs.items.len);
}

test "items are grouped by mesh in a stable order; hidden and unknown are dropped" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    const items = [_]Item{
        .{ .mesh = 5, .id = 1 },
        .{ .mesh = 2, .id = 2 },
        .{ .mesh = 5, .id = 3, .tint = .{ 1, 0, 0, 1 } },
        .{ .mesh = 99, .id = 4 }, // not resident
        .{ .mesh = 2, .id = 5, .flags = .{ .hidden = true } },
        .{ .mesh = 0, .id = 6 }, // none
        .{ .mesh = 2, .id = 7, .flags = .{ .highlight = true, .no_edges = true } },
    };
    var d = draw0();
    d.item_count = items.len;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expectEqual(@as(usize, 2), plan.runs.items.len);
    try std.testing.expectEqual(Run{ .mesh = 2, .first = 0, .count = 2 }, plan.runs.items[0]);
    try std.testing.expectEqual(Run{ .mesh = 5, .first = 2, .count = 2 }, plan.runs.items[1]);
    const ids = [_]u32{ 2, 7, 1, 3 };
    for (ids, plan.insts.items) |want, got| try std.testing.expectEqual(want, got.id);
    try std.testing.expect(plan.insts.items[1].flags & flag_highlight != 0);
    try std.testing.expect(plan.insts.items[1].flags & flag_no_edges != 0);
    try std.testing.expectEqual(@as(f32, 1), plan.insts.items[3].tint[0]);
    try std.testing.expectEqual(@as(f32, 0), plan.insts.items[3].tint[1]);
}

test "transform rows are packed row-major with the translation in .w" {
    const p = pack(.{ .mesh = 1, .transform = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } });
    try std.testing.expectEqual([4]f32{ 1, 2, 3, 4 }, p.m0);
    try std.testing.expectEqual([4]f32{ 5, 6, 7, 8 }, p.m1);
    try std.testing.expectEqual([4]f32{ 9, 10, 11, 12 }, p.m2);
}

test "contentHash reacts to tint, transform, flags, order and mesh version" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    var items = [_]Item{ .{ .mesh = 1, .id = 1 }, .{ .mesh = 2, .id = 2 } };
    var d = draw0();
    d.item_count = 2;
    try plan.build(gpa, d, &items, TestCtx{});
    const base = plan.contentHash(TestCtx{});
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expectEqual(base, plan.contentHash(TestCtx{}));

    items[0].tint[1] = 0.5;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expect(base != plan.contentHash(TestCtx{}));
    items[0].tint[1] = 1;
    items[1].transform[3] = 4;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expect(base != plan.contentHash(TestCtx{}));
    items[1].transform[3] = 0;
    items[1].flags.highlight = true;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expect(base != plan.contentHash(TestCtx{}));

    const Other = struct {
        pub fn hasMesh(_: @This(), _: u32) bool {
            return true;
        }
        pub fn meshVersion(_: @This(), h: u32) u32 {
            return h * 10 + 1;
        }
    };
    items[1].flags.highlight = false;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expectEqual(base, plan.contentHash(TestCtx{}));
    try std.testing.expect(base != plan.contentHash(Other{}));
}
