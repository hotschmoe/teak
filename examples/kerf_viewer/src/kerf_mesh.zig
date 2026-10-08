//! Loader for Kerf's mesh JSON (`kerf_mesh: "0.1"`, docs/features/scene.md
//! section 7) into per-part meshes for the `viewport3d` path, plus the
//! per-part data the viewer's panel and CPU picking need.
//!
//! One `Loaded` owns everything (a single arena). Each part is its own mesh
//! resource (key = id = `index + 1`); the viewer places them as `Item`s, so
//! selection and hover are item flags / tints, never geometry edits.

const std = @import("std");
const teak = @import("teak");

pub const Vec3 = [3]f32;

pub const Part = struct {
    /// Zero-based position in the file; the viewer's pick/selection id is `index + 1`.
    index: u32,
    src: []const u8,
    /// Optional second-level name (`"part"` in the JSON), empty if absent.
    name: []const u8,
    material: []const u8,
    instance: u32,
    tri_count: u32,
    lo: Vec3,
    hi: Vec3,
    /// Muted display colour (the JSON colour desaturated toward grey).
    color: [4]f32,
    /// Part-local geometry: vertices (muted colour), local indices, edge segments.
    /// Also what CPU picking tests against.
    mesh: teak.MeshData,
    /// Every edge shared by an even number of triangles (`section.isClosed`):
    /// open shells would streak under a stencil-parity cut cap.
    closed: bool,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    parts: []Part,
    lo: Vec3,
    hi: Vec3,
    tri_total: u32,
    /// Inputs for `teak.scene.pick.items`: one item / mesh ref per part,
    /// key and id both `index + 1`.
    pick_items: []teak.scene.pick.Item,
    pick_refs: []teak.scene.pick.MeshRef,
    /// One `.mesh` resource per part, for the App's `resources()` hook.
    resources: []teak.Resource,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn bounds(self: *const Loaded) teak.scene.Bounds {
        return .{ .lo = self.lo, .hi = self.hi };
    }

    /// Part for a 1-based id (0 = none).
    pub fn partById(self: *const Loaded, id: u32) ?*const Part {
        if (id == 0 or id > self.parts.len) return null;
        return &self.parts[id - 1];
    }

    /// Stamp every mesh resource with revision `rev` (bump it when a new
    /// document replaces the keys' content).
    pub fn setRev(self: *Loaded, rev: u32) void {
        for (self.resources) |*r| r.mesh.rev = rev;
    }
};

pub const ParseError = error{ BadJson, NoParts, BadMesh, OutOfMemory };

const JsonPart = struct {
    src: []const u8 = "",
    part: ?[]const u8 = null,
    instance: u32 = 0,
    material: []const u8 = "",
    color: []const u8 = "#B0B0B0",
    positions: []const f32 = &.{},
    normals: []const f32 = &.{},
    indices: []const u32 = &.{},
    edges: []const f32 = &.{},
};
const JsonMesh = struct { kerf_mesh: ?[]const u8 = null, parts: []const JsonPart = &.{} };

/// Parse a `mesh.json` document. All output lives in the returned arena.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Loaded {
    var parsed = std.json.parseFromSlice(JsonMesh, gpa, bytes, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadJson,
    };
    defer parsed.deinit();
    const jp = parsed.value.parts;
    if (jp.len == 0) return error.NoParts;

    var out: Loaded = undefined;
    out.arena = std.heap.ArenaAllocator.init(gpa);
    errdefer out.arena.deinit();
    const a = out.arena.allocator();

    for (jp) |p| {
        if (p.positions.len == 0 or p.positions.len % 3 != 0) return error.BadMesh;
        if (p.indices.len % 3 != 0) return error.BadMesh;
        for (p.indices) |i| if (i >= p.positions.len / 3) return error.BadMesh;
    }

    out.parts = try a.alloc(Part, jp.len);
    out.resources = try a.alloc(teak.Resource, jp.len);
    out.pick_items = try a.alloc(teak.scene.pick.Item, jp.len);
    out.pick_refs = try a.alloc(teak.scene.pick.MeshRef, jp.len);

    var lo: Vec3 = @splat(std.math.inf(f32));
    var hi: Vec3 = @splat(-std.math.inf(f32));
    var tris: u32 = 0;
    for (jp, 0..) |p, pi| {
        const n = p.positions.len / 3;
        const color = muted(parseHexColor(p.color));
        const verts = try a.alloc(teak.MeshVertex, n);
        var plo: Vec3 = @splat(std.math.inf(f32));
        var phi: Vec3 = @splat(-std.math.inf(f32));
        for (verts, 0..) |*v, k| {
            const pos = Vec3{ p.positions[3 * k], p.positions[3 * k + 1], p.positions[3 * k + 2] };
            v.* = .{ .pos = pos, .normal = .{ 0, 1, 0 }, .color = color };
            plo = teak.scene.mat.minV(plo, pos);
            phi = teak.scene.mat.maxV(phi, pos);
        }
        if (p.normals.len == p.positions.len) {
            for (verts, 0..) |*v, k| v.normal = teak.scene.mat.normalizeOr(.{ p.normals[3 * k], p.normals[3 * k + 1], p.normals[3 * k + 2] }, .{ 0, 1, 0 });
        } else {
            computeNormals(verts, p.indices);
        }
        const indices = try a.dupe(u32, p.indices);
        const nl = p.edges.len / 3 / 2 * 2;
        const lines = try a.alloc(teak.LineVertex, nl);
        for (lines, 0..) |*l, k| l.* = .{
            .pos = .{ p.edges[3 * k], p.edges[3 * k + 1], p.edges[3 * k + 2] },
            .color = .{ 0.10, 0.10, 0.10, 1 },
        };
        const mesh = teak.MeshData{ .vertices = verts, .indices = indices, .lines = lines };
        const key: u32 = @intCast(pi + 1);
        out.parts[pi] = .{
            .index = @intCast(pi),
            .src = try a.dupe(u8, p.src),
            .name = try a.dupe(u8, p.part orelse ""),
            .material = try a.dupe(u8, p.material),
            .instance = p.instance,
            .tri_count = @intCast(indices.len / 3),
            .lo = plo,
            .hi = phi,
            .color = color,
            .mesh = mesh,
            .closed = teak.scene.section.isClosed(gpa, .{ .vertices = verts, .indices = indices }) catch false,
        };
        out.resources[pi] = .{ .mesh = .{ .key = key, .rev = 1, .data = mesh } };
        out.pick_items[pi] = .{ .mesh = key, .id = key };
        out.pick_refs[pi] = .{ .key = key, .mesh = mesh, .bounds = .{ .lo = plo, .hi = phi } };
        lo = teak.scene.mat.minV(lo, plo);
        hi = teak.scene.mat.maxV(hi, phi);
        tris += @intCast(indices.len / 3);
    }
    out.lo = lo;
    out.hi = hi;
    out.tri_total = tris;
    return out;
}

/// Area-weighted smooth normals from the triangles (used only when the file
/// carries none).
fn computeNormals(verts: []teak.MeshVertex, indices: []const u32) void {
    const m = teak.scene.mat;
    for (verts) |*v| v.normal = .{ 0, 0, 0 };
    var t: usize = 0;
    while (t + 2 < indices.len) : (t += 3) {
        const a = verts[indices[t]].pos;
        const b = verts[indices[t + 1]].pos;
        const c = verts[indices[t + 2]].pos;
        const n = m.cross(m.sub(b, a), m.sub(c, a));
        for (indices[t..][0..3]) |i| verts[i].normal = m.add(verts[i].normal, n);
    }
    for (verts) |*v| v.normal = m.normalizeOr(v.normal, .{ 0, 1, 0 });
}

pub fn parseHexColor(s: []const u8) [4]f32 {
    var rgb: [3]f32 = .{ 0.69, 0.69, 0.69 };
    if (s.len == 7 and s[0] == '#') {
        for (0..3) |i| {
            const v = std.fmt.parseInt(u8, s[1 + 2 * i ..][0..2], 16) catch return .{ 0.69, 0.69, 0.69, 1 };
            rgb[i] = @as(f32, @floatFromInt(v)) / 255.0;
        }
    }
    return .{ rgb[0], rgb[1], rgb[2], 1 };
}

/// Kerf's `muted()`: pull colours toward grey so the ink edges carry the drawing.
pub fn muted(c: [4]f32) [4]f32 {
    const luma = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
    const k: f32 = 0.62;
    return .{ luma + (c[0] - luma) * k, luma + (c[1] - luma) * k, luma + (c[2] - luma) * k, 1 };
}

pub fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, 1 };
}

/// Format inches as feet-inches with eighths: `7'-1 1/4"`, `3 1/2"`, `0"`.
pub fn fmtFtIn(arena: std.mem.Allocator, inches: f32) []const u8 {
    const neg = inches < 0;
    const eighths: u32 = @intFromFloat(@round(@abs(inches) * 8));
    const ft = eighths / (8 * 12);
    const in_e = eighths % (8 * 12);
    const whole = in_e / 8;
    const frac = in_e % 8;
    const sign: []const u8 = if (neg and eighths != 0) "-" else "";
    var frac_buf: [8]u8 = undefined;
    const frac_s: []const u8 = if (frac == 0) "" else blk: {
        const g = std.math.gcd(frac, 8);
        break :blk std.fmt.bufPrint(&frac_buf, " {d}/{d}", .{ frac / g, 8 / g }) catch "";
    };
    if (ft > 0) {
        if (whole == 0 and frac == 0) return std.fmt.allocPrint(arena, "{s}{d}'-0\"", .{ sign, ft }) catch "?";
        return std.fmt.allocPrint(arena, "{s}{d}'-{d}{s}\"", .{ sign, ft, whole, frac_s }) catch "?";
    }
    if (whole == 0 and frac != 0) return std.fmt.allocPrint(arena, "{s}{s}\"", .{ sign, std.mem.trimStart(u8, frac_s, " ") }) catch "?";
    return std.fmt.allocPrint(arena, "{s}{d}{s}\"", .{ sign, whole, frac_s }) catch "?";
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

pub const small_fixture = @embedFile("fixtures/flush-psl-2x6.json");
pub const large_fixture = @embedFile("fixtures/palmer-sd1-like.json");

test "parse: flush-psl-2x6 fixture" {
    var l = try parse(testing.allocator, small_fixture);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 10), l.parts.len);
    try testing.expectEqual(@as(u32, 120), l.tri_total);
    try testing.expectEqualStrings("bottom_plate", l.parts[0].src);
    try testing.expectEqual(@as(u32, 1), l.parts[3].instance);
    try testing.expect(l.lo[0] < l.hi[0] and l.lo[1] < l.hi[1] and l.lo[2] < l.hi[2]);
    // every part is a valid mesh whose bounds contain its vertices, with a resource keyed index + 1
    for (l.parts, l.resources) |p, r| {
        try p.mesh.validate();
        for (p.mesh.vertices) |v| for (0..3) |k| try testing.expect(v.pos[k] >= p.lo[k] and v.pos[k] <= p.hi[k]);
        try testing.expectEqual(p.index + 1, r.mesh.key);
    }
    l.setRev(7);
    try testing.expectEqual(@as(u32, 7), l.resources[3].mesh.rev);
}

test "parse: palmer fixture has named parts and edges; only the dowel and wedge shank are open shells" {
    var l = try parse(testing.allocator, large_fixture);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 24), l.parts.len);
    try testing.expectEqualStrings("footing", l.parts[0].name);
    try testing.expect(l.parts[0].mesh.lines.len > 0 and l.parts[0].mesh.lines.len % 2 == 0);
    for (l.parts, 0..) |p, i| try testing.expectEqual(i != 5 and i != 9, p.closed);
}

test "parse: errors" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "{nope"));
    try testing.expectError(error.NoParts, parse(testing.allocator, "{\"kerf_mesh\":\"0.1\",\"parts\":[]}"));
    try testing.expectError(error.BadMesh, parse(testing.allocator, "{\"parts\":[{\"positions\":[0,0,0,1,0,0,0,1,0],\"indices\":[0,1,5]}]}"));
}

test "missing normals are computed" {
    var l = try parse(testing.allocator, "{\"parts\":[{\"src\":\"tri\",\"positions\":[0,0,0,1,0,0,0,1,0],\"indices\":[0,1,2]}]}");
    defer l.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1), l.parts[0].mesh.vertices[0].normal[2], 1e-6);
    try testing.expectEqual(@as(usize, 0), l.parts[0].mesh.lines.len);
}

test "fmtFtIn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("7'-1 1/4\"", fmtFtIn(a, 85.25));
    try testing.expectEqualStrings("4'-0\"", fmtFtIn(a, 48));
    try testing.expectEqualStrings("1 1/2\"", fmtFtIn(a, 1.5));
    try testing.expectEqualStrings("0\"", fmtFtIn(a, 0));
    try testing.expectEqualStrings("-3'-4\"", fmtFtIn(a, -40));
    try testing.expectEqualStrings("1/4\"", fmtFtIn(a, 0.25));
}
