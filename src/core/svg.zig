//! SVG icons: a small, pure SVG subset rasterized on the CPU into RGBA pixels
//! that the app hands to the GPU as an image resource (HARDLINE §2 hatch 8).
//!
//! Supported: `<svg>` with `viewBox` (else `width` / `height`), `<g>`,
//! `<path>` (every path command: M L H V C S Q T A Z, absolute and relative),
//! `<rect>` (incl. `rx` / `ry`), `<circle>`, `<ellipse>`, `<line>`,
//! `<polyline>`, `<polygon>`. Paint: `fill`, `stroke`, `stroke-width`,
//! `fill-rule` (nonzero / evenodd), `stroke-linecap`, `stroke-linejoin`,
//! `opacity`, `fill-opacity`, `stroke-opacity`, as attributes or inside
//! `style="..."`, inherited through `<g>`; colours `#rgb`, `#rrggbb`,
//! `rgb(r,g,b)`, `none`, a few names and `currentColor` (the caller's
//! `Options.color`, so one monochrome icon set follows the theme); the
//! `transform` attribute (matrix, translate, scale, rotate, skewX, skewY).
//! Ignored: gradients, patterns, masks, clip paths, filters, text, `<use>`,
//! CSS classes, dashes. That covers the common icon sets (Lucide, Feather,
//! Heroicons, Material, Tabler).
//!
//! Rasterization: curves are flattened to a quarter-pixel tolerance; each
//! filled or stroked shape is scan-converted with 8 sub-scanlines per pixel
//! and exact horizontal coverage, under its fill rule, then composited
//! (straight-alpha "over") in document order. Strokes are outlined as
//! segment quads plus joins / caps and filled nonzero, so overlaps never
//! double-blend.
//!
//! Pure: no platform code, no globals; the caller supplies the allocator
//! (scratch only, freed before returning) and owns the pixels. Rasterize in
//! `init` / `update` into Model-owned memory, never in `view`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// What `currentColor` paints (RGBA, 0..1).
    color: [4]f32 = .{ 0, 0, 0, 1 },
};

pub const Error = error{ OutOfMemory, InvalidSvg };

/// Rasterize `source` to a `width` x `height` RGBA8 image (straight alpha,
/// row-major, 4 bytes per pixel) written into `out` (len >= width*height*4).
/// The viewBox is scaled uniformly and centred (`preserveAspectRatio`
/// xMidYMid meet). `scratch` holds the flattened paths while drawing.
pub fn rasterizeInto(scratch: Allocator, source: []const u8, width: u32, height: u32, out: []u8, opts: Options) Error!void {
    const n: usize = @as(usize, width) * height * 4;
    if (out.len < n or width == 0 or height == 0) return error.InvalidSvg;
    @memset(out[0..n], 0);
    var r: Renderer = .{ .a = scratch, .w = width, .h = height, .out = out[0..n], .opts = opts };
    defer r.deinit();
    try r.run(source);
}

/// `rasterizeInto` with a freshly allocated pixel buffer (caller frees).
pub fn rasterize(gpa: Allocator, source: []const u8, width: u32, height: u32, opts: Options) Error![]u8 {
    const out = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(out);
    try rasterizeInto(gpa, source, width, height, out, opts);
    return out;
}

// ── Geometry ───────────────────────────────────────────────────────

const Pt = [2]f32;

/// 2D affine matrix [a b c d e f]: x' = a x + c y + e, y' = b x + d y + f.
const Mat = [6]f32;
const identity: Mat = .{ 1, 0, 0, 1, 0, 0 };

fn mul(m: Mat, n: Mat) Mat {
    // m * n (apply n first, then m).
    return .{
        m[0] * n[0] + m[2] * n[1],
        m[1] * n[0] + m[3] * n[1],
        m[0] * n[2] + m[2] * n[3],
        m[1] * n[2] + m[3] * n[3],
        m[0] * n[4] + m[2] * n[5] + m[4],
        m[1] * n[4] + m[3] * n[5] + m[5],
    };
}

fn apply(m: Mat, p: Pt) Pt {
    return .{ m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5] };
}

fn matScale(m: Mat) f32 {
    return @sqrt(@abs(m[0] * m[3] - m[1] * m[2]));
}

// ── Paint state ────────────────────────────────────────────────────

const Paint = union(enum) { none, current, rgba: [4]f32 };
const FillRule = enum { nonzero, evenodd };
const Cap = enum { butt, round, square };
const Join = enum { miter, round, bevel };

const Style = struct {
    fill: Paint = .{ .rgba = .{ 0, 0, 0, 1 } },
    stroke: Paint = .none,
    stroke_width: f32 = 1,
    fill_rule: FillRule = .nonzero,
    cap: Cap = .butt,
    join: Join = .miter,
    opacity: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    m: Mat = identity,
};

const MAX_DEPTH = 32;

const Renderer = struct {
    a: Allocator,
    w: u32,
    h: u32,
    out: []u8,
    opts: Options,
    stack: [MAX_DEPTH]Style = undefined,
    depth: usize = 0,
    /// Flattened subpaths of the current shape, in pixel space.
    pts: std.ArrayList(Pt) = .empty,
    /// End index (exclusive) into `pts` of each subpath, and whether closed.
    subs: std.ArrayList(Sub) = .empty,
    /// Edges of the shape being scan-converted.
    edges: std.ArrayList(Edge) = .empty,
    /// Per-row coverage accumulator.
    cov: std.ArrayList(f32) = .empty,
    xs: std.ArrayList(Cross) = .empty,

    const Sub = struct { end: usize, closed: bool };

    fn deinit(r: *Renderer) void {
        r.pts.deinit(r.a);
        r.subs.deinit(r.a);
        r.edges.deinit(r.a);
        r.cov.deinit(r.a);
        r.xs.deinit(r.a);
    }

    fn top(r: *Renderer) *Style {
        return &r.stack[r.depth];
    }

    fn run(r: *Renderer, src: []const u8) Error!void {
        r.stack[0] = .{};
        r.depth = 0;
        var it: TagIter = .{ .s = src };
        var seen_root = false;
        var skip_depth: usize = 0; // inside <defs> and friends
        while (it.next()) |tag| {
            if (tag.closing) {
                if (skip_depth > 0) {
                    skip_depth -= 1;
                    continue;
                }
                if (std.mem.eql(u8, tag.name, "g") or std.mem.eql(u8, tag.name, "svg") or std.mem.eql(u8, tag.name, "a")) {
                    if (r.depth > 0) r.depth -= 1;
                }
                continue;
            }
            if (skip_depth > 0) {
                if (!tag.self_closing) skip_depth += 1;
                continue;
            }
            const name = tag.name;
            if (std.mem.eql(u8, name, "defs") or std.mem.eql(u8, name, "clipPath") or std.mem.eql(u8, name, "mask") or
                std.mem.eql(u8, name, "linearGradient") or std.mem.eql(u8, name, "radialGradient") or
                std.mem.eql(u8, name, "pattern") or std.mem.eql(u8, name, "symbol") or std.mem.eql(u8, name, "style") or
                std.mem.eql(u8, name, "title") or std.mem.eql(u8, name, "desc") or std.mem.eql(u8, name, "metadata") or
                std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "text"))
            {
                if (!tag.self_closing) skip_depth = 1;
                continue;
            }
            const is_group = std.mem.eql(u8, name, "g") or std.mem.eql(u8, name, "svg") or std.mem.eql(u8, name, "a");
            var st = r.top().*;
            if (std.mem.eql(u8, name, "svg") and !seen_root) {
                seen_root = true;
                st.m = rootMatrix(tag, r.w, r.h);
            }
            applyAttrs(&st, tag);
            if (is_group) {
                if (!tag.self_closing and r.depth + 1 < MAX_DEPTH) {
                    r.depth += 1;
                    r.stack[r.depth] = st;
                }
                continue;
            }
            try r.shape(name, tag, st);
        }
        if (!seen_root) return error.InvalidSvg;
    }

    fn shape(r: *Renderer, name: []const u8, tag: Tag, st: Style) Error!void {
        r.pts.clearRetainingCapacity();
        r.subs.clearRetainingCapacity();
        var b: PathBuilder = .{ .r = r, .m = st.m, .tol = 0.25 };
        const f = struct {
            fn num(t: Tag, key: []const u8) f32 {
                const v = t.attr(key) orelse return 0;
                return parseNumber(std.mem.trim(u8, v, " \t\r\n")) orelse 0;
            }
        }.num;
        if (std.mem.eql(u8, name, "path")) {
            const d = tag.attr("d") orelse return;
            try b.path(d);
        } else if (std.mem.eql(u8, name, "rect")) {
            const x = f(tag, "x");
            const y = f(tag, "y");
            const w = f(tag, "width");
            const h = f(tag, "height");
            if (!(w > 0 and h > 0)) return;
            var rx = f(tag, "rx");
            var ry = f(tag, "ry");
            if (tag.attr("rx") == null) rx = ry;
            if (tag.attr("ry") == null) ry = rx;
            rx = @min(rx, w / 2);
            ry = @min(ry, h / 2);
            if (rx > 0 and ry > 0) {
                try b.moveTo(.{ x + rx, y });
                try b.lineTo(.{ x + w - rx, y });
                try b.arcTo(rx, ry, 0, false, true, .{ x + w, y + ry });
                try b.lineTo(.{ x + w, y + h - ry });
                try b.arcTo(rx, ry, 0, false, true, .{ x + w - rx, y + h });
                try b.lineTo(.{ x + rx, y + h });
                try b.arcTo(rx, ry, 0, false, true, .{ x, y + h - ry });
                try b.lineTo(.{ x, y + ry });
                try b.arcTo(rx, ry, 0, false, true, .{ x + rx, y });
            } else {
                try b.moveTo(.{ x, y });
                try b.lineTo(.{ x + w, y });
                try b.lineTo(.{ x + w, y + h });
                try b.lineTo(.{ x, y + h });
            }
            try b.close();
        } else if (std.mem.eql(u8, name, "circle") or std.mem.eql(u8, name, "ellipse")) {
            const cx = f(tag, "cx");
            const cy = f(tag, "cy");
            const rx = if (name[0] == 'c') f(tag, "r") else f(tag, "rx");
            const ry = if (name[0] == 'c') rx else f(tag, "ry");
            if (!(rx > 0 and ry > 0)) return;
            try b.moveTo(.{ cx + rx, cy });
            try b.arcTo(rx, ry, 0, false, true, .{ cx - rx, cy });
            try b.arcTo(rx, ry, 0, false, true, .{ cx + rx, cy });
            try b.close();
        } else if (std.mem.eql(u8, name, "line")) {
            try b.moveTo(.{ f(tag, "x1"), f(tag, "y1") });
            try b.lineTo(.{ f(tag, "x2"), f(tag, "y2") });
        } else if (std.mem.eql(u8, name, "polyline") or std.mem.eql(u8, name, "polygon")) {
            const list = tag.attr("points") orelse return;
            var nr: NumReader = .{ .s = list };
            var first = true;
            while (nr.number()) |x| {
                const y = nr.number() orelse break;
                if (first) try b.moveTo(.{ x, y }) else try b.lineTo(.{ x, y });
                first = false;
            }
            if (name[4] == 'g') try b.close(); // polygon
        } else return;
        try b.finish();
        if (r.pts.items.len == 0) return;

        const alpha = st.opacity;
        if (r.paintColor(st.fill)) |c| {
            if (std.mem.eql(u8, name, "line") or std.mem.eql(u8, name, "polyline")) {
                // Open shapes still fill (closing implicitly) per SVG.
            }
            try r.fillCurrent(st.fill_rule, c, alpha * st.fill_opacity);
        }
        if (r.paintColor(st.stroke)) |c| {
            const sw = st.stroke_width * matScale(st.m);
            if (sw > 0) try r.strokeCurrent(sw, st.cap, st.join, c, alpha * st.stroke_opacity);
        }
    }

    fn paintColor(r: *const Renderer, p: Paint) ?[4]f32 {
        return switch (p) {
            .none => null,
            .current => r.opts.color,
            .rgba => |c| c,
        };
    }

    // ── Filling ────────────────────────────────────────────────────

    fn fillCurrent(r: *Renderer, rule: FillRule, color: [4]f32, alpha: f32) Error!void {
        r.edges.clearRetainingCapacity();
        var start: usize = 0;
        for (r.subs.items) |sub| {
            const ring = r.pts.items[start..sub.end];
            start = sub.end;
            if (ring.len < 2) continue;
            for (ring, 0..) |p, i| {
                const q = ring[(i + 1) % ring.len];
                try r.addEdge(p, q);
            }
        }
        try r.scan(rule, color, alpha);
    }

    fn addEdge(r: *Renderer, p: Pt, q: Pt) Error!void {
        if (p[1] == q[1]) return;
        if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1]) or !std.math.isFinite(q[0]) or !std.math.isFinite(q[1])) return;
        try r.edges.append(r.a, if (p[1] < q[1]) .{ .x0 = p[0], .y0 = p[1], .x1 = q[0], .y1 = q[1], .dir = 1 } else .{ .x0 = q[0], .y0 = q[1], .x1 = p[0], .y1 = p[1], .dir = -1 });
    }

    /// Scan-convert `edges` under `rule` and composite `color` * coverage.
    fn scan(r: *Renderer, rule: FillRule, color: [4]f32, alpha: f32) Error!void {
        if (r.edges.items.len == 0 or !(alpha > 0)) return;
        var ymin: f32 = std.math.inf(f32);
        var ymax: f32 = -std.math.inf(f32);
        for (r.edges.items) |e| {
            ymin = @min(ymin, e.y0);
            ymax = @max(ymax, e.y1);
        }
        const hf: f32 = @floatFromInt(r.h);
        const wf: f32 = @floatFromInt(r.w);
        const row0: u32 = @intFromFloat(std.math.clamp(@floor(ymin), 0, hf));
        const row1: u32 = @intFromFloat(std.math.clamp(@ceil(ymax), 0, hf));
        try r.cov.resize(r.a, r.w + 1);
        const SS: f32 = 8;
        var row = row0;
        while (row < row1) : (row += 1) {
            @memset(r.cov.items, 0);
            var touched = false;
            for (0..8) |s| {
                const y = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(s)) + 0.5) / SS;
                r.xs.clearRetainingCapacity();
                for (r.edges.items) |e| {
                    if (y < e.y0 or y >= e.y1) continue;
                    const t = (y - e.y0) / (e.y1 - e.y0);
                    try r.xs.append(r.a, .{ .x = e.x0 + (e.x1 - e.x0) * t, .dir = e.dir });
                }
                if (r.xs.items.len < 2) continue;
                std.mem.sort(Cross, r.xs.items, {}, Cross.less);
                var wind: i32 = 0;
                for (r.xs.items, 0..) |c, i| {
                    const was_in = inside(rule, wind);
                    wind += c.dir;
                    const now_in = inside(rule, wind);
                    if (!was_in and now_in) {
                        // Span starts at c.x; find where it ends.
                        var w2 = wind;
                        var j = i + 1;
                        while (j < r.xs.items.len) : (j += 1) {
                            w2 += r.xs.items[j].dir;
                            if (!inside(rule, w2)) break;
                        }
                        if (j < r.xs.items.len) {
                            addSpan(r.cov.items, std.math.clamp(c.x, 0, wf), std.math.clamp(r.xs.items[j].x, 0, wf), 1.0 / SS);
                            touched = true;
                        }
                    }
                }
            }
            if (touched) r.compositeRow(row, color, alpha);
        }
    }

    fn compositeRow(r: *Renderer, row: u32, color: [4]f32, alpha: f32) void {
        // `cov` holds per-pixel coverage as a difference array from addSpan.
        var acc: f32 = 0;
        const base = @as(usize, row) * r.w * 4;
        for (0..r.w) |x| {
            acc += r.cov.items[x];
            const c = std.math.clamp(acc, 0, 1) * alpha * color[3];
            if (c <= 0.0005) continue;
            const px = r.out[base + x * 4 ..][0..4];
            const da = @as(f32, @floatFromInt(px[3])) / 255;
            const oa = c + da * (1 - c);
            inline for (0..3) |k| {
                const dc = @as(f32, @floatFromInt(px[k])) / 255;
                const v = if (oa > 0) (color[k] * c + dc * da * (1 - c)) / oa else color[k];
                px[k] = toByte(v);
            }
            px[3] = toByte(oa);
        }
    }

    // ── Stroking ───────────────────────────────────────────────────

    fn strokeCurrent(r: *Renderer, width: f32, cap: Cap, join: Join, color: [4]f32, alpha: f32) Error!void {
        r.edges.clearRetainingCapacity();
        const hw = width / 2;
        var start: usize = 0;
        for (r.subs.items) |sub| {
            const pl = r.pts.items[start..sub.end];
            start = sub.end;
            if (pl.len < 2) {
                if (pl.len == 1 and cap != .butt) try r.addDot(pl[0], hw, cap);
                continue;
            }
            const n = pl.len;
            const segs = if (sub.closed) n else n - 1;
            for (0..segs) |i| {
                const a = pl[i];
                const b = pl[(i + 1) % n];
                try r.addQuad(a, b, hw);
            }
            // Joins at interior vertices (and all of them for a closed ring).
            const first_join: usize = if (sub.closed) 0 else 1;
            const last_join: usize = if (sub.closed) n else n - 1;
            var k = first_join;
            while (k < last_join) : (k += 1) {
                const p = pl[(k + n - 1) % n];
                const v = pl[k];
                const q = pl[(k + 1) % n];
                try r.addJoin(p, v, q, hw, join);
            }
            if (!sub.closed) {
                try r.addCap(pl[1], pl[0], hw, cap);
                try r.addCap(pl[n - 2], pl[n - 1], hw, cap);
            }
        }
        try r.scan(.nonzero, color, alpha);
    }

    /// A closed ring of points with consistent (counter-clockwise in y-down
    /// terms: positive signed area) orientation, so nonzero unions overlap.
    fn addRing(r: *Renderer, ring: []const Pt) Error!void {
        var area: f32 = 0;
        for (ring, 0..) |p, i| {
            const q = ring[(i + 1) % ring.len];
            area += p[0] * q[1] - q[0] * p[1];
        }
        if (area == 0) return;
        for (ring, 0..) |_, i| {
            const idx = if (area > 0) i else ring.len - 1 - i;
            const nxt = if (area > 0) (i + 1) % ring.len else (ring.len * 2 - 2 - i) % ring.len;
            try r.addEdge(ring[idx], ring[nxt]);
        }
    }

    fn addQuad(r: *Renderer, a: Pt, b: Pt, hw: f32) Error!void {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (!(len > 0)) return;
        const nx = -dy / len * hw;
        const ny = dx / len * hw;
        try r.addRing(&.{ .{ a[0] + nx, a[1] + ny }, .{ b[0] + nx, b[1] + ny }, .{ b[0] - nx, b[1] - ny }, .{ a[0] - nx, a[1] - ny } });
    }

    fn addDot(r: *Renderer, c: Pt, hw: f32, cap: Cap) Error!void {
        if (cap == .square) {
            try r.addRing(&.{ .{ c[0] - hw, c[1] - hw }, .{ c[0] + hw, c[1] - hw }, .{ c[0] + hw, c[1] + hw }, .{ c[0] - hw, c[1] + hw } });
        } else try r.addDisc(c, hw);
    }

    fn addDisc(r: *Renderer, c: Pt, rad: f32) Error!void {
        var buf: [64]Pt = undefined;
        const n: usize = @intFromFloat(std.math.clamp(@ceil(rad * 2), 8, 64));
        for (0..n) |i| {
            const t = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            buf[i] = .{ c[0] + @cos(t) * rad, c[1] + @sin(t) * rad };
        }
        try r.addRing(buf[0..n]);
    }

    /// Cap at end `e` of the segment coming from `from`.
    fn addCap(r: *Renderer, from: Pt, e: Pt, hw: f32, cap: Cap) Error!void {
        switch (cap) {
            .butt => {},
            .round => try r.addDisc(e, hw),
            .square => {
                const dx = e[0] - from[0];
                const dy = e[1] - from[1];
                const len = @sqrt(dx * dx + dy * dy);
                if (!(len > 0)) return;
                const ux = dx / len * hw;
                const uy = dy / len * hw;
                try r.addQuad(e, .{ e[0] + ux, e[1] + uy }, hw);
            },
        }
    }

    fn addJoin(r: *Renderer, p: Pt, v: Pt, q: Pt, hw: f32, join: Join) Error!void {
        if (join == .round) return r.addDisc(v, hw);
        const d1 = norm(.{ v[0] - p[0], v[1] - p[1] }) orelse return;
        const d2 = norm(.{ q[0] - v[0], q[1] - v[1] }) orelse return;
        const crs = d1[0] * d2[1] - d1[1] * d2[0];
        if (@abs(crs) < 1e-6) return; // straight
        // The outer side of the turn.
        const s: f32 = if (crs > 0) -1 else 1;
        const n1: Pt = .{ -d1[1] * hw * s, d1[0] * hw * s };
        const n2: Pt = .{ -d2[1] * hw * s, d2[0] * hw * s };
        const a: Pt = .{ v[0] + n1[0], v[1] + n1[1] };
        const b: Pt = .{ v[0] + n2[0], v[1] + n2[1] };
        if (join == .miter) {
            // Miter tip: along the bisector, length hw / cos(theta / 2); limit 4.
            const bx = n1[0] + n2[0];
            const by = n1[1] + n2[1];
            const bl = @sqrt(bx * bx + by * by);
            if (bl > 1e-6) {
                const cos_half = bl / (2 * hw);
                if (cos_half > 0 and 1 / cos_half <= 4) {
                    const ml = hw / cos_half;
                    const tip: Pt = .{ v[0] + bx / bl * ml, v[1] + by / bl * ml };
                    return r.addRing(&.{ v, a, tip, b });
                }
            }
        }
        try r.addRing(&.{ v, a, b });
    }
};

fn norm(d: Pt) ?Pt {
    const l = @sqrt(d[0] * d[0] + d[1] * d[1]);
    if (!(l > 0)) return null;
    return .{ d[0] / l, d[1] / l };
}

fn inside(rule: FillRule, wind: i32) bool {
    return switch (rule) {
        .nonzero => wind != 0,
        .evenodd => @mod(wind, 2) != 0,
    };
}

fn toByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v * 255), 0, 255));
}

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i32 };
const Cross = struct {
    x: f32,
    dir: i32,
    fn less(_: void, a: Cross, b: Cross) bool {
        return a.x < b.x;
    }
};

/// Add `w` of coverage over [x0, x1) to a difference array (pixel i holds
/// coverage(i) - coverage(i-1)), with exact fractional ends.
fn addSpan(d: []f32, x0: f32, x1: f32, w: f32) void {
    if (!(x1 > x0)) return;
    const last = d.len - 1; // d has width + 1 entries
    const ia: usize = @intFromFloat(@floor(x0));
    const ib: usize = @intFromFloat(@floor(x1));
    if (ia >= last) return;
    if (ia == ib) {
        const c = (x1 - x0) * w;
        d[ia] += c;
        d[ia + 1] -= c;
        return;
    }
    // First partial pixel.
    const fa = (@as(f32, @floatFromInt(ia + 1)) - x0) * w;
    d[ia] += fa;
    d[ia + 1] += w - fa;
    // Full pixels ia+1 .. ib-1 carry w (started by the line above); end at ib.
    if (ib >= last) return;
    const fb = (x1 - @as(f32, @floatFromInt(ib))) * w;
    d[ib] += fb - w;
    d[ib + 1] -= fb;
}

/// Root transform: viewBox -> pixel box, uniform scale, centred.
fn rootMatrix(tag: Tag, w: u32, h: u32) Mat {
    var vb: [4]f32 = .{ 0, 0, 0, 0 };
    if (tag.attr("viewBox")) |v| {
        var nr: NumReader = .{ .s = v };
        for (&vb) |*x| x.* = nr.number() orelse 0;
    }
    if (!(vb[2] > 0 and vb[3] > 0)) {
        vb = .{ 0, 0, parseLength(tag.attr("width")) orelse @floatFromInt(w), parseLength(tag.attr("height")) orelse @floatFromInt(h) };
    }
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const s = @min(wf / vb[2], hf / vb[3]);
    const ox = (wf - vb[2] * s) / 2 - vb[0] * s;
    const oy = (hf - vb[3] * s) / 2 - vb[1] * s;
    return .{ s, 0, 0, s, ox, oy };
}

fn parseLength(v: ?[]const u8) ?f32 {
    const s = v orelse return null;
    var nr: NumReader = .{ .s = s };
    return nr.number();
}

// ── Attributes / style ─────────────────────────────────────────────

fn applyAttrs(st: *Style, tag: Tag) void {
    var it = tag.attrs();
    while (it.next()) |kv| applyProp(st, kv.k, kv.v);
    if (tag.attr("style")) |css| {
        var decls = std.mem.tokenizeScalar(u8, css, ';');
        while (decls.next()) |decl| {
            const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
            applyProp(st, std.mem.trim(u8, decl[0..colon], " \t\r\n"), std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n"));
        }
    }
}

fn applyProp(st: *Style, k: []const u8, v_raw: []const u8) void {
    const v = std.mem.trim(u8, v_raw, " \t\r\n");
    const eq = std.mem.eql;
    if (eq(u8, k, "fill")) {
        if (parsePaint(v)) |p| st.fill = p;
    } else if (eq(u8, k, "stroke")) {
        if (parsePaint(v)) |p| st.stroke = p;
    } else if (eq(u8, k, "stroke-width")) {
        if (parseLength(v)) |x| st.stroke_width = @max(x, 0);
    } else if (eq(u8, k, "fill-rule")) {
        st.fill_rule = if (eq(u8, v, "evenodd")) .evenodd else .nonzero;
    } else if (eq(u8, k, "stroke-linecap")) {
        st.cap = if (eq(u8, v, "round")) .round else if (eq(u8, v, "square")) .square else .butt;
    } else if (eq(u8, k, "stroke-linejoin")) {
        st.join = if (eq(u8, v, "round")) .round else if (eq(u8, v, "bevel")) .bevel else .miter;
    } else if (eq(u8, k, "opacity")) {
        if (parseNumber(v)) |x| st.opacity *= std.math.clamp(x, 0, 1);
    } else if (eq(u8, k, "fill-opacity")) {
        if (parseNumber(v)) |x| st.fill_opacity = std.math.clamp(x, 0, 1);
    } else if (eq(u8, k, "stroke-opacity")) {
        if (parseNumber(v)) |x| st.stroke_opacity = std.math.clamp(x, 0, 1);
    } else if (eq(u8, k, "transform")) {
        st.m = mul(st.m, parseTransform(v));
    }
}

fn parsePaint(v: []const u8) ?Paint {
    const eq = std.mem.eql;
    if (v.len == 0) return null;
    if (eq(u8, v, "none") or eq(u8, v, "transparent")) return .none;
    if (eq(u8, v, "currentColor")) return .current;
    if (std.mem.startsWith(u8, v, "url(")) return null; // gradients: unsupported, keep inherited
    if (v[0] == '#') {
        const hex = v[1..];
        if (hex.len == 3 or hex.len == 6) {
            var c: [3]f32 = undefined;
            for (0..3) |i| {
                const s = if (hex.len == 3) &[2]u8{ hex[i], hex[i] } else hex[i * 2 ..][0..2];
                const b = std.fmt.parseInt(u8, s, 16) catch return null;
                c[i] = @as(f32, @floatFromInt(b)) / 255;
            }
            return .{ .rgba = .{ c[0], c[1], c[2], 1 } };
        }
        return null;
    }
    if (std.mem.startsWith(u8, v, "rgb")) {
        const open = std.mem.indexOfScalar(u8, v, '(') orelse return null;
        var nr: NumReader = .{ .s = v[open + 1 ..] };
        var c: [3]f32 = undefined;
        for (&c) |*x| x.* = std.math.clamp((nr.number() orelse return null) / 255, 0, 1);
        return .{ .rgba = .{ c[0], c[1], c[2], 1 } };
    }
    const names = [_]struct { []const u8, [3]f32 }{
        .{ "black", .{ 0, 0, 0 } },      .{ "white", .{ 1, 1, 1 } },
        .{ "red", .{ 1, 0, 0 } },        .{ "green", .{ 0, 0.5, 0 } },
        .{ "blue", .{ 0, 0, 1 } },       .{ "gray", .{ 0.5, 0.5, 0.5 } },
        .{ "grey", .{ 0.5, 0.5, 0.5 } }, .{ "yellow", .{ 1, 1, 0 } },
        .{ "orange", .{ 1, 0.647, 0 } },
    };
    for (names) |nm| if (eq(u8, v, nm[0])) return .{ .rgba = .{ nm[1][0], nm[1][1], nm[1][2], 1 } };
    return null;
}

fn parseTransform(v: []const u8) Mat {
    var m = identity;
    var rest = v;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t\r\n,");
        const open = std.mem.indexOfScalar(u8, rest, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, rest, open, ')') orelse break;
        const name = std.mem.trim(u8, rest[0..open], " \t\r\n,");
        var nr: NumReader = .{ .s = rest[open + 1 .. close] };
        var a: [6]f32 = .{ 0, 0, 0, 0, 0, 0 };
        var n: usize = 0;
        while (n < 6) : (n += 1) a[n] = nr.number() orelse break;
        const eq = std.mem.eql;
        const t: Mat = if (eq(u8, name, "matrix") and n == 6)
            a
        else if (eq(u8, name, "translate"))
            .{ 1, 0, 0, 1, a[0], if (n > 1) a[1] else 0 }
        else if (eq(u8, name, "scale"))
            .{ a[0], 0, 0, if (n > 1) a[1] else a[0], 0, 0 }
        else if (eq(u8, name, "rotate")) blk: {
            const rad = a[0] * std.math.pi / 180;
            const c = @cos(rad);
            const s = @sin(rad);
            const rot: Mat = .{ c, s, -s, c, 0, 0 };
            if (n >= 3) break :blk mul(mul(.{ 1, 0, 0, 1, a[1], a[2] }, rot), .{ 1, 0, 0, 1, -a[1], -a[2] });
            break :blk rot;
        } else if (eq(u8, name, "skewX"))
            .{ 1, 0, @tan(a[0] * std.math.pi / 180), 1, 0, 0 }
        else if (eq(u8, name, "skewY"))
            .{ 1, @tan(a[0] * std.math.pi / 180), 0, 1, 0, 0 }
        else
            identity;
        m = mul(m, t);
        rest = rest[close + 1 ..];
    }
    return m;
}

// ── Path building / flattening ─────────────────────────────────────

const PathBuilder = struct {
    r: *Renderer,
    m: Mat,
    tol: f32,
    cur: Pt = .{ 0, 0 },
    start: Pt = .{ 0, 0 },
    open: bool = false,
    /// Last control point (for S / T reflection) and which kind set it.
    last_ctrl: Pt = .{ 0, 0 },
    last_kind: u8 = 0,

    fn emit(b: *PathBuilder, p: Pt) Error!void {
        try b.r.pts.append(b.r.a, apply(b.m, p));
    }

    fn endSub(b: *PathBuilder, closed: bool) Error!void {
        if (!b.open) return;
        try b.r.subs.append(b.r.a, .{ .end = b.r.pts.items.len, .closed = closed });
        b.open = false;
    }

    fn moveTo(b: *PathBuilder, p: Pt) Error!void {
        try b.endSub(false);
        b.cur = p;
        b.start = p;
        b.open = true;
        try b.emit(p);
    }

    fn ensureOpen(b: *PathBuilder) Error!void {
        if (!b.open) {
            b.open = true;
            b.start = b.cur;
            try b.emit(b.cur);
        }
    }

    fn lineTo(b: *PathBuilder, p: Pt) Error!void {
        try b.ensureOpen();
        b.cur = p;
        try b.emit(p);
    }

    fn close(b: *PathBuilder) Error!void {
        if (!b.open) return;
        try b.endSub(true);
        b.cur = b.start;
    }

    fn finish(b: *PathBuilder) Error!void {
        try b.endSub(false);
    }

    /// Segments for a curve whose control polygon spans `len` user units.
    fn steps(b: *const PathBuilder, len: f32) usize {
        const px = len * matScale(b.m);
        const n = @ceil(@sqrt(px / b.tol) * 0.75);
        return @intFromFloat(std.math.clamp(n, 1, 256));
    }

    fn cubicTo(b: *PathBuilder, c1: Pt, c2: Pt, p: Pt) Error!void {
        try b.ensureOpen();
        const p0 = b.cur;
        const n = b.steps(dist(p0, c1) + dist(c1, c2) + dist(c2, p));
        for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const u = 1 - t;
            try b.emit(.{
                u * u * u * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p[0],
                u * u * u * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p[1],
            });
        }
        b.cur = p;
    }

    fn quadTo(b: *PathBuilder, c: Pt, p: Pt) Error!void {
        try b.ensureOpen();
        const p0 = b.cur;
        const n = b.steps(dist(p0, c) + dist(c, p));
        for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const u = 1 - t;
            try b.emit(.{ u * u * p0[0] + 2 * u * t * c[0] + t * t * p[0], u * u * p0[1] + 2 * u * t * c[1] + t * t * p[1] });
        }
        b.cur = p;
    }

    /// SVG elliptical arc (endpoint parameterization, F.6.5 of the spec).
    fn arcTo(b: *PathBuilder, rx_in: f32, ry_in: f32, phi_deg: f32, large: bool, sweep: bool, p: Pt) Error!void {
        try b.ensureOpen();
        const p0 = b.cur;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (rx == 0 or ry == 0 or (p0[0] == p[0] and p0[1] == p[1])) return b.lineTo(p);
        const phi = phi_deg * std.math.pi / 180;
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx = (p0[0] - p[0]) / 2;
        const dy = (p0[1] - p[1]) / 2;
        const x1 = cp * dx + sp * dy;
        const y1 = -sp * dx + cp * dy;
        const lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lam > 1) {
            const s = @sqrt(lam);
            rx *= s;
            ry *= s;
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var co = if (den > 0) @sqrt(@max(num / den, 0)) else 0;
        if (large == sweep) co = -co;
        const cxp = co * rx * y1 / ry;
        const cyp = -co * ry * x1 / rx;
        const cx = cp * cxp - sp * cyp + (p0[0] + p[0]) / 2;
        const cy = sp * cxp + cp * cyp + (p0[1] + p[1]) / 2;
        const t1 = std.math.atan2((y1 - cyp) / ry, (x1 - cxp) / rx);
        var dt = std.math.atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx) - t1;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        const n = b.steps(@abs(dt) * @max(rx, ry) * 2);
        for (1..n + 1) |i| {
            const t = t1 + dt * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const ex = rx * @cos(t);
            const ey = ry * @sin(t);
            try b.emit(if (i == n) p else .{ cp * ex - sp * ey + cx, sp * ex + cp * ey + cy });
        }
        b.cur = p;
    }

    fn path(b: *PathBuilder, d: []const u8) Error!void {
        var nr: NumReader = .{ .s = d };
        var cmd: u8 = 0;
        while (true) {
            nr.skipSep();
            if (nr.i >= nr.s.len) break;
            const ch = nr.s[nr.i];
            if (std.ascii.isAlphabetic(ch)) {
                cmd = ch;
                nr.i += 1;
                if (cmd == 'Z' or cmd == 'z') {
                    try b.close();
                    b.last_kind = 0;
                    continue;
                }
            } else if (cmd == 0) return error.InvalidSvg;
            const rel = std.ascii.isLower(cmd);
            const o: Pt = if (rel) b.cur else .{ 0, 0 };
            switch (std.ascii.toUpper(cmd)) {
                'M' => {
                    const x = nr.number() orelse break;
                    const y = nr.number() orelse break;
                    try b.moveTo(.{ o[0] + x, o[1] + y });
                    cmd = if (rel) 'l' else 'L'; // implicit lineto after the first pair
                    b.last_kind = 0;
                },
                'L' => {
                    const x = nr.number() orelse break;
                    const y = nr.number() orelse break;
                    try b.lineTo(.{ o[0] + x, o[1] + y });
                    b.last_kind = 0;
                },
                'H' => {
                    const x = nr.number() orelse break;
                    try b.lineTo(.{ o[0] + x, b.cur[1] });
                    b.last_kind = 0;
                },
                'V' => {
                    const y = nr.number() orelse break;
                    try b.lineTo(.{ b.cur[0], (if (rel) b.cur[1] else 0) + y });
                    b.last_kind = 0;
                },
                'C', 'S' => {
                    var c1: Pt = undefined;
                    if (std.ascii.toUpper(cmd) == 'C') {
                        const x1 = nr.number() orelse break;
                        const y1 = nr.number() orelse break;
                        c1 = .{ o[0] + x1, o[1] + y1 };
                    } else {
                        c1 = if (b.last_kind == 'C') .{ 2 * b.cur[0] - b.last_ctrl[0], 2 * b.cur[1] - b.last_ctrl[1] } else b.cur;
                    }
                    const x2 = nr.number() orelse break;
                    const y2 = nr.number() orelse break;
                    const x = nr.number() orelse break;
                    const y = nr.number() orelse break;
                    const c2: Pt = .{ o[0] + x2, o[1] + y2 };
                    try b.cubicTo(c1, c2, .{ o[0] + x, o[1] + y });
                    b.last_ctrl = c2;
                    b.last_kind = 'C';
                },
                'Q', 'T' => {
                    var c: Pt = undefined;
                    if (std.ascii.toUpper(cmd) == 'Q') {
                        const x1 = nr.number() orelse break;
                        const y1 = nr.number() orelse break;
                        c = .{ o[0] + x1, o[1] + y1 };
                    } else {
                        c = if (b.last_kind == 'Q') .{ 2 * b.cur[0] - b.last_ctrl[0], 2 * b.cur[1] - b.last_ctrl[1] } else b.cur;
                    }
                    const x = nr.number() orelse break;
                    const y = nr.number() orelse break;
                    try b.quadTo(c, .{ o[0] + x, o[1] + y });
                    b.last_ctrl = c;
                    b.last_kind = 'Q';
                },
                'A' => {
                    const rx = nr.number() orelse break;
                    const ry = nr.number() orelse break;
                    const phi = nr.number() orelse break;
                    const large = nr.flag() orelse break;
                    const sw = nr.flag() orelse break;
                    const x = nr.number() orelse break;
                    const y = nr.number() orelse break;
                    try b.arcTo(rx, ry, phi, large, sw, .{ o[0] + x, o[1] + y });
                    b.last_kind = 0;
                },
                else => return error.InvalidSvg,
            }
        }
    }
};

fn dist(a: Pt, b: Pt) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return @sqrt(dx * dx + dy * dy);
}

/// Numbers in SVG syntax: optional sign, digits, '.', exponent; separated
/// by whitespace and / or commas, or by nothing ("1-2", "0.5.5").
const NumReader = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSep(r: *NumReader) void {
        while (r.i < r.s.len and (std.ascii.isWhitespace(r.s[r.i]) or r.s[r.i] == ',')) r.i += 1;
    }

    fn number(r: *NumReader) ?f32 {
        r.skipSep();
        const st = r.i;
        var j = r.i;
        if (j < r.s.len and (r.s[j] == '-' or r.s[j] == '+')) j += 1;
        var dot = false;
        var digits = false;
        while (j < r.s.len) : (j += 1) {
            const c = r.s[j];
            if (std.ascii.isDigit(c)) {
                digits = true;
            } else if (c == '.' and !dot) {
                dot = true;
            } else break;
        }
        if (!digits) return null;
        if (j < r.s.len and (r.s[j] == 'e' or r.s[j] == 'E')) {
            var k = j + 1;
            if (k < r.s.len and (r.s[k] == '-' or r.s[k] == '+')) k += 1;
            if (k < r.s.len and std.ascii.isDigit(r.s[k])) {
                while (k < r.s.len and std.ascii.isDigit(r.s[k])) k += 1;
                j = k;
            }
        }
        r.i = j;
        return std.fmt.parseFloat(f32, r.s[st..j]) catch null;
    }

    /// Arc flags may be written without separators ("a1 1 0 011 1").
    fn flag(r: *NumReader) ?bool {
        r.skipSep();
        if (r.i >= r.s.len) return null;
        const c = r.s[r.i];
        if (c != '0' and c != '1') return null;
        r.i += 1;
        return c == '1';
    }
};

fn parseNumber(s: []const u8) ?f32 {
    var nr: NumReader = .{ .s = s };
    return nr.number();
}

// ── A tiny tag scanner (enough XML for icon files) ─────────────────

const Tag = struct {
    name: []const u8,
    body: []const u8, // the attribute text
    closing: bool,
    self_closing: bool,

    const KV = struct { k: []const u8, v: []const u8 };

    const AttrIter = struct {
        s: []const u8,
        i: usize = 0,
        fn next(it: *AttrIter) ?KV {
            while (true) {
                while (it.i < it.s.len and std.ascii.isWhitespace(it.s[it.i])) it.i += 1;
                if (it.i >= it.s.len) return null;
                const ks = it.i;
                while (it.i < it.s.len and it.s[it.i] != '=' and !std.ascii.isWhitespace(it.s[it.i])) it.i += 1;
                const k = it.s[ks..it.i];
                while (it.i < it.s.len and std.ascii.isWhitespace(it.s[it.i])) it.i += 1;
                if (it.i >= it.s.len or it.s[it.i] != '=') {
                    if (k.len == 0) it.i += 1;
                    continue; // valueless attribute
                }
                it.i += 1;
                while (it.i < it.s.len and std.ascii.isWhitespace(it.s[it.i])) it.i += 1;
                if (it.i >= it.s.len) return null;
                const q = it.s[it.i];
                if (q == '"' or q == '\'') {
                    const vs = it.i + 1;
                    const ve = std.mem.indexOfScalarPos(u8, it.s, vs, q) orelse it.s.len;
                    it.i = @min(ve + 1, it.s.len);
                    return .{ .k = k, .v = it.s[vs..ve] };
                }
                const vs = it.i;
                while (it.i < it.s.len and !std.ascii.isWhitespace(it.s[it.i])) it.i += 1;
                return .{ .k = k, .v = it.s[vs..it.i] };
            }
        }
    };

    fn attrs(t: Tag) AttrIter {
        return .{ .s = t.body };
    }

    fn attr(t: Tag, key: []const u8) ?[]const u8 {
        var it = t.attrs();
        while (it.next()) |kv| if (std.mem.eql(u8, kv.k, key)) return kv.v;
        return null;
    }
};

const TagIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *TagIter) ?Tag {
        while (true) {
            const lt = std.mem.indexOfScalarPos(u8, it.s, it.i, '<') orelse return null;
            if (std.mem.startsWith(u8, it.s[lt..], "<!--")) {
                const e = std.mem.indexOfPos(u8, it.s, lt, "-->") orelse return null;
                it.i = e + 3;
                continue;
            }
            if (std.mem.startsWith(u8, it.s[lt..], "<![CDATA[")) {
                const e = std.mem.indexOfPos(u8, it.s, lt, "]]>") orelse return null;
                it.i = e + 3;
                continue;
            }
            // Find the closing '>' outside quotes.
            var j = lt + 1;
            var q: u8 = 0;
            while (j < it.s.len) : (j += 1) {
                const c = it.s[j];
                if (q != 0) {
                    if (c == q) q = 0;
                } else if (c == '"' or c == '\'') {
                    q = c;
                } else if (c == '>') break;
            }
            if (j >= it.s.len) return null;
            it.i = j + 1;
            var inner = it.s[lt + 1 .. j];
            if (inner.len == 0 or inner[0] == '?' or inner[0] == '!') continue;
            const closing = inner[0] == '/';
            if (closing) inner = inner[1..];
            const self_closing = inner.len > 0 and inner[inner.len - 1] == '/';
            if (self_closing) inner = inner[0 .. inner.len - 1];
            var ne: usize = 0;
            while (ne < inner.len and !std.ascii.isWhitespace(inner[ne])) ne += 1;
            var name = inner[0..ne];
            if (std.mem.indexOfScalar(u8, name, ':')) |c| name = name[c + 1 ..]; // svg:path
            return .{ .name = name, .body = inner[ne..], .closing = closing, .self_closing = self_closing };
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn pixelAt(img: []const u8, w: u32, x: u32, y: u32) [4]u8 {
    return img[(y * w + x) * 4 ..][0..4].*;
}

test "filled square covers exactly its pixels" {
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect x="2" y="2" width="6" height="6" fill="#ff0000"/></svg>
    ;
    const img = try rasterize(testing.allocator, src, 10, 10, .{});
    defer testing.allocator.free(img);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixelAt(img, 10, 4, 4));
    try testing.expectEqual(@as(u8, 0), pixelAt(img, 10, 1, 1)[3]);
    try testing.expectEqual(@as(u8, 255), pixelAt(img, 10, 2, 2)[3]);
    try testing.expectEqual(@as(u8, 0), pixelAt(img, 10, 8, 8)[3]);
}

test "viewBox scales; half-covered pixels get half alpha" {
    const src =
        \\<svg viewBox="0 0 4 4"><rect x="0" y="0" width="1" height="4" fill="black"/></svg>
    ;
    // 4 units -> 6 px: the rect is 1.5 px wide.
    const img = try rasterize(testing.allocator, src, 6, 6, .{});
    defer testing.allocator.free(img);
    try testing.expectEqual(@as(u8, 255), pixelAt(img, 6, 0, 3)[3]);
    try testing.expect(@abs(@as(i32, pixelAt(img, 6, 1, 3)[3]) - 128) <= 2);
    try testing.expectEqual(@as(u8, 0), pixelAt(img, 6, 2, 3)[3]);
}

test "evenodd punches a hole, nonzero does not" {
    const ring = "M1 1H9V9H1Z M3 3H7V7H3Z";
    var buf: [256]u8 = undefined;
    const eo = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 10 10\"><path fill-rule=\"evenodd\" d=\"{s}\"/></svg>", .{ring});
    const a = try rasterize(testing.allocator, eo, 10, 10, .{});
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(u8, 0), pixelAt(a, 10, 5, 5)[3]);
    try testing.expectEqual(@as(u8, 255), pixelAt(a, 10, 2, 5)[3]);
    var buf2: [256]u8 = undefined;
    const nz = try std.fmt.bufPrint(&buf2, "<svg viewBox=\"0 0 10 10\"><path d=\"{s}\"/></svg>", .{ring});
    const b = try rasterize(testing.allocator, nz, 10, 10, .{});
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(u8, 255), pixelAt(b, 10, 5, 5)[3]);
}

test "currentColor stroke, round caps, curves and arcs (a Lucide-style icon)" {
    // Lucide "circle-check": a circle outline and a check mark.
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"
        \\  stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        \\  <circle cx="12" cy="12" r="10"/>
        \\  <path d="m9 12 2 2 4-4"/>
        \\</svg>
    ;
    const img = try rasterize(testing.allocator, src, 24, 24, .{ .color = .{ 0, 0.5, 1, 1 } });
    defer testing.allocator.free(img);
    // On the ring (radius 10 at the top: y = 2), off it at the centre's
    // left (x = 5, inside the ring, away from the check).
    try testing.expect(pixelAt(img, 24, 12, 2)[3] > 200);
    try testing.expectEqual(@as(u8, 0), pixelAt(img, 24, 5, 12)[3]);
    try testing.expectEqual(@as(u8, 128), pixelAt(img, 24, 12, 2)[1]);
    // On the check stroke, between (9, 12) and its corner (11, 14).
    try testing.expect(pixelAt(img, 24, 10, 13)[3] > 200);
}

test "transforms, groups, style attribute, relative commands" {
    const src =
        \\<svg viewBox="0 0 20 20"><g transform="translate(10 0)" style="fill:#00ff00">
        \\  <path d="m0 0 h5 v5 h-5 z"/></g>
        \\  <rect transform="scale(2)" x="0" y="5" width="2" height="2" fill="rgb(0,0,255)"/>
        \\</svg>
    ;
    const img = try rasterize(testing.allocator, src, 20, 20, .{});
    defer testing.allocator.free(img);
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixelAt(img, 20, 12, 2));
    try testing.expectEqual(@as(u8, 0), pixelAt(img, 20, 2, 2)[3]);
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixelAt(img, 20, 2, 12));
}

test "defs, comments and unsupported elements are skipped; garbage is rejected" {
    const src =
        \\<?xml version="1.0"?><!-- icon --><svg viewBox="0 0 4 4"><defs><rect width="4" height="4"/></defs>
        \\<title>t</title><text>x</text></svg>
    ;
    const img = try rasterize(testing.allocator, src, 4, 4, .{});
    defer testing.allocator.free(img);
    for (0..16) |i| try testing.expectEqual(@as(u8, 0), img[i * 4 + 3]);
    try testing.expectError(error.InvalidSvg, rasterize(testing.allocator, "not svg", 4, 4, .{}));
}

test "number reader: packed numbers, exponents, arc flags" {
    var nr: NumReader = .{ .s = "1-2.5.5e1,3" };
    try testing.expectEqual(@as(f32, 1), nr.number().?);
    try testing.expectEqual(@as(f32, -2.5), nr.number().?);
    try testing.expectEqual(@as(f32, 5), nr.number().?);
    try testing.expectEqual(@as(f32, 3), nr.number().?);
    var fr: NumReader = .{ .s = "011" };
    try testing.expect(!fr.flag().?);
    try testing.expect(fr.flag().?);
    try testing.expect(fr.flag().?);
}
