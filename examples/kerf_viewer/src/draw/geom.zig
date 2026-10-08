//! Pure 2D geometry for the Kerf drawing pipeline (model space, f64).
//!
//! * `BPt` is a polyline vertex with a DXF-style *bulge* on the segment that
//!   starts at it (`b = tan(theta/4)`, positive = counter-clockwise arc).
//! * `appendFlattened` turns bulge paths into plain polylines with an
//!   *adaptive* tolerance (pass the tolerance in model units; the tessellator
//!   derives it from "0.2 output px").
//! * `pointInLoop` / `distToBulgeSeg` / `bboxOfLoop` work on arcs analytically
//!   (no allocation), for hit testing.
//! * `triangulate` is an ear-clipping triangulator for concave polygons with
//!   optional holes (holes are connected to the outer ring by a visible bridge).
//!
//! Everything here is allocator-passed and free of I/O, so it builds for
//! wasm32-freestanding.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vec2 = struct {
    x: f64,
    y: f64,

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn scale(a: Vec2, s: f64) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn len(a: Vec2) f64 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }
    pub fn cross(a: Vec2, b: Vec2) f64 {
        return a.x * b.y - a.y * b.x;
    }
    pub fn dot(a: Vec2, b: Vec2) f64 {
        return a.x * b.x + a.y * b.y;
    }
};

/// Polyline vertex with the bulge of the segment that STARTS here.
pub const BPt = struct {
    x: f64,
    y: f64,
    b: f64 = 0,

    pub fn v(p: BPt) Vec2 {
        return .{ .x = p.x, .y = p.y };
    }
};

pub const BBox = struct {
    x0: f64 = std.math.inf(f64),
    y0: f64 = std.math.inf(f64),
    x1: f64 = -std.math.inf(f64),
    y1: f64 = -std.math.inf(f64),

    pub const empty: BBox = .{};

    pub fn isEmpty(b: BBox) bool {
        return b.x0 > b.x1 or b.y0 > b.y1;
    }
    pub fn addPoint(b: *BBox, x: f64, y: f64) void {
        if (x < b.x0) b.x0 = x;
        if (y < b.y0) b.y0 = y;
        if (x > b.x1) b.x1 = x;
        if (y > b.y1) b.y1 = y;
    }
    pub fn merge(b: *BBox, o: BBox) void {
        if (o.isEmpty()) return;
        b.addPoint(o.x0, o.y0);
        b.addPoint(o.x1, o.y1);
    }
    pub fn intersects(a: BBox, b: BBox) bool {
        if (a.isEmpty() or b.isEmpty()) return false;
        return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0;
    }
    pub fn contains(b: BBox, x: f64, y: f64) bool {
        return x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1;
    }
    pub fn grow(b: BBox, d: f64) BBox {
        if (b.isEmpty()) return b;
        return .{ .x0 = b.x0 - d, .y0 = b.y0 - d, .x1 = b.x1 + d, .y1 = b.y1 + d };
    }
    pub fn width(b: BBox) f64 {
        return if (b.isEmpty()) 0 else b.x1 - b.x0;
    }
    pub fn height(b: BBox) f64 {
        return if (b.isEmpty()) 0 else b.y1 - b.y0;
    }
};

// ---------------------------------------------------------------------------
// Arcs
// ---------------------------------------------------------------------------

pub const Arc = struct {
    cx: f64,
    cy: f64,
    r: f64,
    /// Angle of the start point (radians, atan2 convention).
    a0: f64,
    /// Signed sweep (radians): positive = counter-clockwise (y up).
    sweep: f64,
};

/// Circle through p0 and p1 described by the DXF bulge `b`. Null when the
/// segment is straight (|b| tiny) or degenerate (p0 == p1).
pub fn arcOf(p0: Vec2, p1: Vec2, b: f64) ?Arc {
    if (@abs(b) < 1e-9) return null;
    const d = p1.sub(p0);
    const c = d.len();
    if (c < 1e-12) return null;
    const mid = Vec2{ .x = (p0.x + p1.x) * 0.5, .y = (p0.y + p1.y) * 0.5 };
    const left = Vec2{ .x = -d.y / c, .y = d.x / c };
    const off = (c * 0.5) * (1 - b * b) / (2 * b);
    const center = mid.add(left.scale(off));
    const r = (c * 0.5) * (1 + b * b) / (2 * @abs(b));
    return .{
        .cx = center.x,
        .cy = center.y,
        .r = r,
        .a0 = std.math.atan2(p0.y - center.y, p0.x - center.x),
        .sweep = 4 * std.math.atan(b),
    };
}

fn normAngle(a: f64) f64 {
    const tau = 2 * std.math.pi;
    var r = @mod(a, tau);
    if (r < 0) r += tau;
    return r;
}

/// Is the direction `ang` inside the arc's angular span?
pub fn arcContainsAngle(arc: Arc, ang: f64) bool {
    const tau = 2 * std.math.pi;
    if (arc.sweep >= 0) {
        return normAngle(ang - arc.a0) <= arc.sweep;
    } else {
        return normAngle(arc.a0 - ang) <= -arc.sweep;
    }
    _ = tau;
}

/// Number of chords needed so the sagitta error of an arc of radius `r`
/// sweeping `sweep` radians stays below `tol` (same units as r).
pub fn arcSegments(r: f64, sweep: f64, tol: f64) usize {
    const s = @abs(sweep);
    if (!(r > 0) or !(tol > 0)) return 1;
    const ratio = 1 - tol / r;
    if (ratio <= -1) return 1;
    const dmax = 2 * std.math.acos(@max(ratio, -1.0));
    if (!(dmax > 1e-6)) return 512;
    const n: f64 = @ceil(s / dmax);
    if (n < 1) return 1;
    if (n > 512) return 512;
    return @intFromFloat(n);
}

/// Append the vertices of the polyline `pts` (bulges expanded to chords of
/// error <= `tol`) to `out`. For `closed` loops the closing segment (with the
/// last vertex's bulge) is expanded but the first vertex is NOT repeated.
/// For open paths the final vertex is included.
pub fn appendFlattened(out: *std.ArrayList(Vec2), a: Allocator, pts: []const BPt, closed: bool, tol: f64) Allocator.Error!void {
    const n = pts.len;
    if (n == 0) return;
    const nseg = if (closed) n else n - 1;
    var i: usize = 0;
    while (i < nseg) : (i += 1) {
        const p0 = pts[i];
        const p1 = pts[(i + 1) % n];
        try out.append(a, p0.v());
        if (arcOf(p0.v(), p1.v(), p0.b)) |arc| {
            const k = arcSegments(arc.r, arc.sweep, tol);
            var j: usize = 1;
            while (j < k) : (j += 1) {
                const ang = arc.a0 + arc.sweep * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(k));
                try out.append(a, .{ .x = arc.cx + arc.r * @cos(ang), .y = arc.cy + arc.r * @sin(ang) });
            }
        }
    }
    if (!closed) try out.append(a, pts[n - 1].v());
}

// ---------------------------------------------------------------------------
// Distances, bounds
// ---------------------------------------------------------------------------

pub fn distPointSeg(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const l2 = dx * dx + dy * dy;
    var t: f64 = 0;
    if (l2 > 0) t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1);
    const qx = ax + t * dx - px;
    const qy = ay + t * dy - py;
    return @sqrt(qx * qx + qy * qy);
}

/// Distance from a point to the (possibly arc) segment p0->p1 with bulge b.
pub fn distToBulgeSeg(px: f64, py: f64, p0: Vec2, p1: Vec2, b: f64) f64 {
    if (arcOf(p0, p1, b)) |arc| {
        const ang = std.math.atan2(py - arc.cy, px - arc.cx);
        if (arcContainsAngle(arc, ang)) {
            const d = @sqrt((px - arc.cx) * (px - arc.cx) + (py - arc.cy) * (py - arc.cy));
            return @abs(d - arc.r);
        }
        const d0 = @sqrt((px - p0.x) * (px - p0.x) + (py - p0.y) * (py - p0.y));
        const d1 = @sqrt((px - p1.x) * (px - p1.x) + (py - p1.y) * (py - p1.y));
        return @min(d0, d1);
    }
    return distPointSeg(px, py, p0.x, p0.y, p1.x, p1.y);
}

/// Distance from a point to a polyline/loop with bulges.
pub fn distToPath(px: f64, py: f64, pts: []const BPt, closed: bool) f64 {
    const n = pts.len;
    if (n == 0) return std.math.inf(f64);
    if (n == 1) return @sqrt((px - pts[0].x) * (px - pts[0].x) + (py - pts[0].y) * (py - pts[0].y));
    const nseg = if (closed) n else n - 1;
    var best = std.math.inf(f64);
    var i: usize = 0;
    while (i < nseg) : (i += 1) {
        const d = distToBulgeSeg(px, py, pts[i].v(), pts[(i + 1) % n].v(), pts[i].b);
        if (d < best) best = d;
    }
    return best;
}

/// Exact bounding box of a bulge path (arc extremes included).
pub fn bboxOfPath(pts: []const BPt, closed: bool) BBox {
    var bb = BBox.empty;
    const n = pts.len;
    if (n == 0) return bb;
    for (pts) |p| bb.addPoint(p.x, p.y);
    const nseg = if (closed) n else if (n > 0) n - 1 else 0;
    var i: usize = 0;
    while (i < nseg) : (i += 1) {
        if (arcOf(pts[i].v(), pts[(i + 1) % n].v(), pts[i].b)) |arc| {
            const quarter = [4]f64{ 0, std.math.pi * 0.5, std.math.pi, std.math.pi * 1.5 };
            for (quarter) |q| {
                if (arcContainsAngle(arc, q)) bb.addPoint(arc.cx + arc.r * @cos(q), arc.cy + arc.r * @sin(q));
            }
        }
    }
    return bb;
}

// ---------------------------------------------------------------------------
// Polygons
// ---------------------------------------------------------------------------

/// Signed shoelace area (positive = counter-clockwise in a y-up frame).
pub fn polygonArea(pts: []const Vec2) f64 {
    var s: f64 = 0;
    const n = pts.len;
    if (n < 3) return 0;
    var j = n - 1;
    for (pts, 0..) |p, i| {
        s += pts[j].x * p.y - p.x * pts[j].y;
        j = i;
    }
    return s * 0.5;
}

/// Signed area of a bulge loop INCLUDING the circular segments.
pub fn loopArea(pts: []const BPt) f64 {
    const n = pts.len;
    if (n < 3 and !hasBulge(pts)) return 0;
    var s: f64 = 0;
    var j = n - 1;
    for (pts, 0..) |p, i| {
        s += pts[j].x * p.y - p.x * pts[j].y;
        j = i;
    }
    s *= 0.5;
    // circular-segment corrections: segment area = r^2/2 * (theta - sin theta) (signed by bulge)
    for (pts, 0..) |p, i| {
        if (@abs(p.b) < 1e-9) continue;
        const q = pts[(i + 1) % n];
        if (arcOf(p.v(), q.v(), p.b)) |arc| {
            s += 0.5 * arc.r * arc.r * (arc.sweep - @sin(arc.sweep));
        }
    }
    return s;
}

fn hasBulge(pts: []const BPt) bool {
    for (pts) |p| if (@abs(p.b) > 1e-9) return true;
    return false;
}

pub fn reverseVec2(pts: []Vec2) void {
    std.mem.reverse(Vec2, pts);
}

/// Even-odd crossing test on a plain polygon.
pub fn pointInPolygon(pts: []const Vec2, x: f64, y: f64) bool {
    var inside = false;
    const n = pts.len;
    if (n < 3) return false;
    var j = n - 1;
    for (pts, 0..) |p, i| {
        const q = pts[j];
        if ((p.y > y) != (q.y > y)) {
            const xi = (q.x - p.x) * (y - p.y) / (q.y - p.y) + p.x;
            if (x < xi) inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Point-in-loop for a closed loop whose segments may be arcs. No
/// allocation: tests the chord polygon, then toggles for every circular
/// segment (region between chord and arc) that contains the point.
/// Valid for simple (non self-intersecting) loops.
pub fn pointInLoop(pts: []const BPt, x: f64, y: f64) bool {
    const n = pts.len;
    if (n < 2) return false; // two bulged vertices = a full circle (engine emits rebar dots this way)
    var inside = false;
    var j = n - 1;
    for (pts, 0..) |p, i| {
        const q = pts[j];
        if ((p.y > y) != (q.y > y)) {
            const xi = (q.x - p.x) * (y - p.y) / (q.y - p.y) + p.x;
            if (x < xi) inside = !inside;
        }
        j = i;
    }
    for (pts, 0..) |p, i| {
        if (@abs(p.b) < 1e-9) continue;
        const q = pts[(i + 1) % n];
        const arc = arcOf(p.v(), q.v(), p.b) orelse continue;
        const dx = x - arc.cx;
        const dy = y - arc.cy;
        if (dx * dx + dy * dy > arc.r * arc.r) continue;
        // side of the chord: bulge > 0 => arc lies to the RIGHT of p0->p1 (cross < 0)
        const cr = (q.x - p.x) * (y - p.y) - (q.y - p.y) * (x - p.x);
        // exactly on the chord: count it for one direction only (so a 2-vertex circle has an inside centre)
        const cdx = q.x - p.x;
        const cdy = q.y - p.y;
        const on_chord = cr == 0 and (cdx > 0 or (cdx == 0 and cdy > 0));
        if ((p.b > 0 and (cr < 0 or on_chord)) or (p.b < 0 and (cr > 0 or on_chord))) inside = !inside;
    }
    return inside;
}

/// Even-odd over several loops (loop 0 outer, rest holes, or any nesting).
pub fn pointInLoopsEvenOdd(loops: []const []const BPt, x: f64, y: f64) bool {
    var inside = false;
    for (loops) |l| if (pointInLoop(l, x, y)) {
        inside = !inside;
    };
    return inside;
}

// ---------------------------------------------------------------------------
// Triangulation (ear clipping with hole bridging)
// ---------------------------------------------------------------------------

/// Triangles as a flat list: every 3 consecutive points form a triangle.
pub const TriList = std.ArrayList(Vec2);

fn cross3(a: Vec2, b: Vec2, c: Vec2) f64 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

fn segsProperlyCross(a: Vec2, b: Vec2, c: Vec2, d: Vec2) bool {
    const d1 = cross3(a, b, c);
    const d2 = cross3(a, b, d);
    const d3 = cross3(c, d, a);
    const d4 = cross3(c, d, b);
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0));
}

fn veq(a: Vec2, b: Vec2) bool {
    return a.x == b.x and a.y == b.y;
}

/// Triangulate polygon `outer` minus `holes` (loops of plain points; any
/// orientation). Appends triangles (CCW in a y-up frame) to `out`.
/// Degenerate input (fewer than 3 points, zero area) produces nothing.
/// Not a constrained-Delaunay: just robust, O(n^2).
pub fn triangulate(a: Allocator, outer: []const Vec2, holes: []const []const Vec2, out: *TriList) Allocator.Error!void {
    if (outer.len < 3) return;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    // Normalize orientation: outer CCW, holes CW.
    var ring: std.ArrayList(Vec2) = .empty;
    try ring.appendSlice(ar, outer);
    if (polygonArea(ring.items) < 0) std.mem.reverse(Vec2, ring.items);

    const HoleRec = struct { pts: []Vec2, minx: f64, start: usize };
    var hs: std.ArrayList(HoleRec) = .empty;
    for (holes) |h| {
        if (h.len < 3) continue;
        const hp = try ar.dupe(Vec2, h);
        if (polygonArea(hp) > 0) std.mem.reverse(Vec2, hp);
        var mi: usize = 0;
        for (hp, 0..) |p, i| {
            if (p.x < hp[mi].x or (p.x == hp[mi].x and p.y < hp[mi].y)) mi = i;
        }
        try hs.append(ar, .{ .pts = hp, .minx = hp[mi].x, .start = mi });
    }
    // Process holes by decreasing x (rightmost first) so bridges don't cross later holes.
    std.mem.sort(HoleRec, hs.items, {}, struct {
        fn lt(_: void, p: HoleRec, q: HoleRec) bool {
            return p.minx > q.minx;
        }
    }.lt);

    var hi: usize = 0;
    while (hi < hs.items.len) : (hi += 1) {
        const h = hs.items[hi];
        const hv = h.pts[h.start];
        // candidate ring vertices by distance
        const idx = try ar.alloc(usize, ring.items.len);
        for (idx, 0..) |*q, i| q.* = i;
        const Ctx = struct { ring: []const Vec2, hv: Vec2 };
        const ctx = Ctx{ .ring = ring.items, .hv = hv };
        std.mem.sort(usize, idx, ctx, struct {
            fn lt(c: Ctx, p: usize, q: usize) bool {
                const dp = c.ring[p].sub(c.hv);
                const dq = c.ring[q].sub(c.hv);
                const lp = dp.x * dp.x + dp.y * dp.y;
                const lq = dq.x * dq.x + dq.y * dq.y;
                if (lp != lq) return lp < lq;
                return p < q;
            }
        }.lt);
        var found: ?usize = null;
        for (idx) |vi| {
            const rv = ring.items[vi];
            if (bridgeVisible(ring.items, hs.items[hi..], hv, rv, vi)) {
                found = vi;
                break;
            }
        }
        const vi = found orelse idx[0];
        // Build merged ring: ring[0..=vi], hole from start around back to start, ring[vi] again, ring[vi+1..]
        var merged: std.ArrayList(Vec2) = .empty;
        try merged.appendSlice(ar, ring.items[0 .. vi + 1]);
        var k: usize = 0;
        while (k <= h.pts.len) : (k += 1) {
            try merged.append(ar, h.pts[(h.start + k) % h.pts.len]);
        }
        try merged.append(ar, ring.items[vi]);
        try merged.appendSlice(ar, ring.items[vi + 1 ..]);
        ring = merged;
    }
    try earClip(a, ar, ring.items, out);
}

fn bridgeVisible(ring: []const Vec2, rest_holes: anytype, hv: Vec2, rv: Vec2, vi: usize) bool {
    // segment hv->rv must not properly cross ring edges or other holes' edges
    const n = ring.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = ring[i];
        const q = ring[(i + 1) % n];
        if (segsProperlyCross(hv, rv, p, q)) return false;
    }
    _ = vi;
    for (rest_holes) |h| {
        const m = h.pts.len;
        var k: usize = 0;
        while (k < m) : (k += 1) {
            if (segsProperlyCross(hv, rv, h.pts[k], h.pts[(k + 1) % m])) return false;
        }
    }
    // midpoint must be inside the ring (outer minus bridged holes)
    const mid = Vec2{ .x = (hv.x + rv.x) * 0.5, .y = (hv.y + rv.y) * 0.5 };
    if (!pointInPolygon(ring, mid.x, mid.y)) {
        // ring includes bridges (zero-width), even-odd still right
        return false;
    }
    return true;
}

fn pointInTriInclusive(a: Vec2, b: Vec2, c: Vec2, p: Vec2) bool {
    return (c.x - p.x) * (a.y - p.y) - (a.x - p.x) * (c.y - p.y) >= 0 and
        (a.x - p.x) * (b.y - p.y) - (b.x - p.x) * (a.y - p.y) >= 0 and
        (b.x - p.x) * (c.y - p.y) - (c.x - p.x) * (b.y - p.y) >= 0;
}

/// Ear clipping on a (CCW, possibly bridged / degenerate) ring.
fn earClip(a: Allocator, ar: Allocator, ring: []const Vec2, out: *TriList) Allocator.Error!void {
    const n0 = ring.len;
    if (n0 < 3) return;
    const prev = try ar.alloc(u32, n0);
    const next = try ar.alloc(u32, n0);
    const alive = try ar.alloc(bool, n0);
    for (0..n0) |i| {
        prev[i] = @intCast((i + n0 - 1) % n0);
        next[i] = @intCast((i + 1) % n0);
        alive[i] = true;
    }
    var count: usize = n0;
    try out.ensureUnusedCapacity(a, (n0 - 2) * 3);

    var cur: u32 = 0;
    var stall: usize = 0;
    while (count > 3) {
        const pv = prev[cur];
        const nx = next[cur];
        const pa = ring[pv];
        const pb = ring[cur];
        const pc = ring[nx];
        // drop duplicates / collinear spikes
        const ar2 = cross3(pa, pb, pc);
        if (veq(pa, pb) or veq(pb, pc) or ar2 == 0) {
            // remove cur
            next[pv] = nx;
            prev[nx] = pv;
            alive[cur] = false;
            count -= 1;
            cur = pv;
            stall = 0;
            continue;
        }
        var ear = ar2 > 0;
        if (ear) {
            var p = next[nx];
            while (p != pv) : (p = next[p]) {
                const q = ring[p];
                if (veq(q, pa)) continue;
                if (pointInTriInclusive(pa, pb, pc, q) and cross3(ring[prev[p]], q, ring[next[p]]) <= 0) {
                    ear = false;
                    break;
                }
            }
        }
        if (ear) {
            out.appendAssumeCapacity(pa);
            out.appendAssumeCapacity(pb);
            out.appendAssumeCapacity(pc);
            next[pv] = nx;
            prev[nx] = pv;
            alive[cur] = false;
            count -= 1;
            cur = nx;
            stall = 0;
            continue;
        }
        cur = nx;
        stall += 1;
        if (stall > count) {
            // No ear found (self-touching / numerically odd ring): clip the most convex vertex.
            var best: u32 = cur;
            var best_area: f64 = -std.math.inf(f64);
            var p = cur;
            var steps: usize = 0;
            while (steps < count) : (steps += 1) {
                const ca = cross3(ring[prev[p]], ring[p], ring[next[p]]);
                if (ca > best_area) {
                    best_area = ca;
                    best = p;
                }
                p = next[p];
            }
            const bp = prev[best];
            const bn = next[best];
            if (best_area > 0) {
                out.appendAssumeCapacity(ring[bp]);
                out.appendAssumeCapacity(ring[best]);
                out.appendAssumeCapacity(ring[bn]);
            }
            next[bp] = bn;
            prev[bn] = bp;
            alive[best] = false;
            count -= 1;
            cur = bn;
            stall = 0;
        }
    }
    if (count == 3) {
        const pv = prev[cur];
        const nx = next[cur];
        if (cross3(ring[pv], ring[cur], ring[nx]) > 0) {
            out.appendAssumeCapacity(ring[pv]);
            out.appendAssumeCapacity(ring[cur]);
            out.appendAssumeCapacity(ring[nx]);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn triAreaSum(tris: []const Vec2) f64 {
    var s: f64 = 0;
    var i: usize = 0;
    while (i + 2 < tris.len) : (i += 3) s += cross3(tris[i], tris[i + 1], tris[i + 2]) * 0.5;
    return s;
}

test "arcOf: semicircle bulge 1 from (0,0) to (2,0) is CCW below the chord" {
    const arc = arcOf(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, 1).?;
    try testing.expectApproxEqAbs(@as(f64, 1), arc.r, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), arc.cx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), arc.cy, 1e-12);
    try testing.expectApproxEqAbs(std.math.pi, arc.sweep, 1e-12);
    // midpoint of the arc must be (1,-1): positive bulge bulges to the right of travel
    const mid = arc.a0 + arc.sweep * 0.5;
    try testing.expectApproxEqAbs(@as(f64, 1), arc.cx + arc.r * @cos(mid), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1), arc.cy + arc.r * @sin(mid), 1e-9);
}

test "arcOf: negative bulge bulges to the left" {
    const arc = arcOf(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, -1).?;
    const mid = arc.a0 + arc.sweep * 0.5;
    try testing.expectApproxEqAbs(@as(f64, 1), arc.cy + arc.r * @sin(mid), 1e-9);
}

test "arcOf: quarter circle and major arc radii" {
    const q = arcOf(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, @tan(std.math.pi / 8.0)).?;
    try testing.expectApproxEqAbs(@as(f64, 1), q.r, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), q.cx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), q.cy, 1e-12);
    // 270 degree arc: bulge = tan(270/4 deg)
    const m = arcOf(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = -1 }, @tan(std.math.degreesToRadians(67.5))).?;
    try testing.expectApproxEqAbs(@as(f64, 1), m.r, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), m.cx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), m.cy, 1e-12);
}

test "arcSegments adaptive: finer tolerance, more chords" {
    const n1 = arcSegments(10, std.math.pi, 0.1);
    const n2 = arcSegments(10, std.math.pi, 0.001);
    try testing.expect(n2 > n1);
    try testing.expect(n1 >= 4);
    try testing.expectEqual(@as(usize, 1), arcSegments(0.001, std.math.pi, 0.1));
}

test "appendFlattened stays within tolerance of the circle" {
    const a = testing.allocator;
    var out: std.ArrayList(Vec2) = .empty;
    defer out.deinit(a);
    const pts = [_]BPt{ .{ .x = 10, .y = 0, .b = 1 }, .{ .x = -10, .y = 0, .b = 1 } };
    try appendFlattened(&out, a, &pts, true, 0.01);
    try testing.expect(out.items.len > 20);
    for (out.items) |p| try testing.expectApproxEqAbs(@as(f64, 10), @sqrt(p.x * p.x + p.y * p.y), 1e-9);
    // area ~ circle area, pi * 100
    try testing.expectApproxEqRel(std.math.pi * 100.0, @abs(polygonArea(out.items)), 0.01);
}

test "appendFlattened open path includes last point; closed does not repeat first" {
    const a = testing.allocator;
    var out: std.ArrayList(Vec2) = .empty;
    defer out.deinit(a);
    const pts = [_]BPt{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 } };
    try appendFlattened(&out, a, &pts, false, 0.1);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    out.clearRetainingCapacity();
    try appendFlattened(&out, a, &pts, true, 0.1);
    try testing.expectEqual(@as(usize, 3), out.items.len);
}

test "loopArea includes circular segments" {
    // Semicircle loop: two vertices bulge 1 -> full circle of radius 1
    const full = [_]BPt{ .{ .x = 1, .y = 0, .b = 1 }, .{ .x = -1, .y = 0, .b = 1 } };
    try testing.expectApproxEqAbs(std.math.pi, loopArea(&full), 1e-9);
    // Rectangle
    const rect = [_]BPt{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 2 }, .{ .x = 0, .y = 2 } };
    try testing.expectApproxEqAbs(@as(f64, 8), loopArea(&rect), 1e-12);
}

test "pointInLoop with arcs: rounded notch and bulge" {
    // Square 0..4 with a CCW outward semicircle bulge on the right edge? Edge (4,0)->(4,4) going up:
    // bulge < 0 bulges LEFT (inward), bulge > 0 bulges RIGHT (outward).
    const out_b = [_]BPt{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0, .b = 1 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    try testing.expect(pointInLoop(&out_b, 2, 2));
    try testing.expect(pointInLoop(&out_b, 5.5, 2)); // inside the outward semicircle (center (4,2), r 2)
    try testing.expect(!pointInLoop(&out_b, 6.5, 2));
    try testing.expect(!pointInLoop(&out_b, 5.9, 3.9));
    const in_b = [_]BPt{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0, .b = -1 }, .{ .x = 4, .y = 4 }, .{ .x = 0, .y = 4 } };
    try testing.expect(!pointInLoop(&in_b, 3, 2)); // carved out
    try testing.expect(pointInLoop(&in_b, 1, 2));
    try testing.expect(!pointInLoop(&in_b, 3.8, 3.9)); // inside the carved circle (center (4,2), r 2)
    try testing.expect(pointInLoop(&in_b, 1.9, 2));
}

test "pointInLoop: full circle as two bulge vertices" {
    const circ = [_]BPt{ .{ .x = 1, .y = 0, .b = 1 }, .{ .x = -1, .y = 0, .b = 1 } };
    // two bulged vertices = full circle
    try testing.expect(pointInLoop(&circ, 0, 0)); // exactly on both chords
    try testing.expect(pointInLoop(&circ, 0, 0.99));
    try testing.expect(pointInLoop(&circ, 0, -0.99));
    try testing.expect(!pointInLoop(&circ, 1.01, 0));
    const c4 = [_]BPt{
        .{ .x = 1, .y = 0, .b = @tan(std.math.pi / 8.0) },
        .{ .x = 0, .y = 1, .b = @tan(std.math.pi / 8.0) },
        .{ .x = -1, .y = 0, .b = @tan(std.math.pi / 8.0) },
        .{ .x = 0, .y = -1, .b = @tan(std.math.pi / 8.0) },
    };
    try testing.expect(pointInLoop(&c4, 0.0, 0.0));
    try testing.expect(pointInLoop(&c4, 0.69, 0.69));
    try testing.expect(!pointInLoop(&c4, 0.75, 0.75));
    try testing.expect(!pointInLoop(&c4, 1.01, 0));
}

test "distToPath: line and arc" {
    const pl = [_]BPt{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } };
    try testing.expectApproxEqAbs(@as(f64, 3), distToPath(5, 3, &pl, false), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5), distToPath(-3, 4, &pl, false), 1e-12);
    const arcp = [_]BPt{ .{ .x = 0, .y = 0, .b = 1 }, .{ .x = 2, .y = 0 } };
    // arc is lower semicircle of radius 1 centered (1,0)
    try testing.expectApproxEqAbs(@as(f64, 0.5), distToPath(1, -1.5, &arcp, false), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), distToPath(1, -0.5, &arcp, false), 1e-9);
    // above the chord the arc is not there: nearest is an endpoint
    try testing.expectApproxEqAbs(@sqrt(2.0), distToPath(1, 1, &arcp, false), 1e-9);
}

test "bboxOfPath includes arc extremes" {
    const arcp = [_]BPt{ .{ .x = 0, .y = 0, .b = 1 }, .{ .x = 2, .y = 0 } };
    const bb = bboxOfPath(&arcp, false);
    try testing.expectApproxEqAbs(@as(f64, -1), bb.y0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), bb.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), bb.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2), bb.x1, 1e-9);
}

test "polygonArea orientation" {
    const ccw = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } };
    try testing.expectApproxEqAbs(@as(f64, 1), polygonArea(&ccw), 1e-12);
    var cw = ccw;
    reverseVec2(&cw);
    try testing.expectApproxEqAbs(@as(f64, -1), polygonArea(&cw), 1e-12);
}

test "pointInPolygon concave" {
    const l = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 4 }, .{ .x = 0, .y = 4 } };
    try testing.expect(pointInPolygon(&l, 0.5, 3));
    try testing.expect(pointInPolygon(&l, 3, 0.5));
    try testing.expect(!pointInPolygon(&l, 3, 3));
}

test "triangulate: convex, concave, area preserved" {
    const a = testing.allocator;
    var out: TriList = .empty;
    defer out.deinit(a);
    const l = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 4 }, .{ .x = 0, .y = 4 } };
    try triangulate(a, &l, &.{}, &out);
    try testing.expectEqual(@as(usize, 4 * 3), out.items.len);
    try testing.expectApproxEqAbs(@as(f64, 7), triAreaSum(out.items), 1e-9);
    // CW input gets normalized
    out.clearRetainingCapacity();
    var cw = l;
    reverseVec2(&cw);
    try triangulate(a, &cw, &.{}, &out);
    try testing.expectApproxEqAbs(@as(f64, 7), triAreaSum(out.items), 1e-9);
}

test "triangulate: square with square hole" {
    const a = testing.allocator;
    var out: TriList = .empty;
    defer out.deinit(a);
    const outer = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    const hole = [_]Vec2{ .{ .x = 4, .y = 4 }, .{ .x = 6, .y = 4 }, .{ .x = 6, .y = 6 }, .{ .x = 4, .y = 6 } };
    const holes = [_][]const Vec2{&hole};
    try triangulate(a, &outer, &holes, &out);
    try testing.expectApproxEqAbs(@as(f64, 96), triAreaSum(out.items), 1e-9);
    // no triangle centroid inside the hole
    var i: usize = 0;
    while (i < out.items.len) : (i += 3) {
        const cx = (out.items[i].x + out.items[i + 1].x + out.items[i + 2].x) / 3;
        const cy = (out.items[i].y + out.items[i + 1].y + out.items[i + 2].y) / 3;
        try testing.expect(!(cx > 4 and cx < 6 and cy > 4 and cy < 6));
    }
}

test "triangulate: two holes, one touching region of the other side" {
    const a = testing.allocator;
    var out: TriList = .empty;
    defer out.deinit(a);
    const outer = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 }, .{ .x = 0, .y = 10 } };
    const h1 = [_]Vec2{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 8 }, .{ .x = 2, .y = 8 } };
    const h2 = [_]Vec2{ .{ .x = 10, .y = 3 }, .{ .x = 16, .y = 3 }, .{ .x = 16, .y = 7 }, .{ .x = 10, .y = 7 } };
    const holes = [_][]const Vec2{ &h1, &h2 };
    try triangulate(a, &outer, &holes, &out);
    try testing.expectApproxEqAbs(@as(f64, 200 - 24 - 24), triAreaSum(out.items), 1e-6);
}

test "triangulate: circle-ish polygon from flattened arcs" {
    const a = testing.allocator;
    var flat: std.ArrayList(Vec2) = .empty;
    defer flat.deinit(a);
    const c4 = [_]BPt{
        .{ .x = 1, .y = 0, .b = @tan(std.math.pi / 8.0) },
        .{ .x = 0, .y = 1, .b = @tan(std.math.pi / 8.0) },
        .{ .x = -1, .y = 0, .b = @tan(std.math.pi / 8.0) },
        .{ .x = 0, .y = -1, .b = @tan(std.math.pi / 8.0) },
    };
    try appendFlattened(&flat, a, &c4, true, 0.001);
    var out: TriList = .empty;
    defer out.deinit(a);
    try triangulate(a, flat.items, &.{}, &out);
    try testing.expectApproxEqRel(std.math.pi, triAreaSum(out.items), 0.01);
}

test "triangulate: degenerate input yields nothing and does not hang" {
    const a = testing.allocator;
    var out: TriList = .empty;
    defer out.deinit(a);
    const line = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 } };
    try triangulate(a, &line, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    const dup = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } };
    try triangulate(a, &dup, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "BBox ops" {
    var b = BBox.empty;
    try testing.expect(b.isEmpty());
    b.addPoint(1, 2);
    b.addPoint(-1, 5);
    try testing.expectEqual(@as(f64, 2), b.width());
    try testing.expect(b.contains(0, 3));
    try testing.expect(b.intersects(.{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 3 }));
    try testing.expect(!b.intersects(.{ .x0 = 5, .y0 = 0, .x1 = 6, .y1 = 3 }));
}
