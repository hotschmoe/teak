// Retained canvas geometry: applies the canvas transform to world-space
// records (src/render/canvas_geom.zig GeomVertex) and expands strokes.
// Record layout, kinds and the clip rules: SRC.md.

struct Screen {
    screen: vec2f,
    scale: f32,
    pad: f32,
}

struct Draw {
    xf: vec4f,   // sx, sy, tx, ty (tx/ty include the canvas origin)
    clip: vec4f, // logical x, y, w, h
}

struct VsOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
    @location(2) @interpolate(flat) mode: f32, // 0 hard, 1 aa coverage, 2 circle, 3 arc
    @location(3) @interpolate(flat) stroke: vec4f, // circle: stroke rgba. arc: start, sweep, sign sx, sign sy
    @location(4) @interpolate(flat) circ: vec4f, // circle: outer rx, outer ry, border width. arc: rx, ry, half width
}

const TAU: f32 = 6.283185307179586;

@group(0) @binding(0) var<uniform> screen_u: Screen;
@group(0) @binding(1) var<uniform> draw: Draw;

fn to_clip(p: vec2f) -> vec4f {
    let s = max(screen_u.screen, vec2f(1e-6));
    return vec4f((p.x / s.x) * 2.0 - 1.0, 1.0 - (p.y / s.y) * 2.0, 0.0, 1.0);
}

fn pick(c0: vec4f, c1: vec4f, c2: vec4f, c3: vec4f, corner: f32) -> vec4f {
    let i = u32(corner + 0.5);
    if (i == 1u) { return c1; }
    if (i == 2u) { return c2; }
    if (i == 3u) { return c3; }
    return c0;
}

fn out_of(p: vec2f, uv: vec2f, color: vec4f, mode: f32, stroke: vec4f, circ: vec4f) -> VsOut {
    return VsOut(to_clip(p), color, uv, mode, stroke, circ);
}

fn degenerate() -> VsOut {
    // w = 1: a repeated point gives a zero-area quad; w = 0 would be a direction.
    return VsOut(vec4f(0.0, 0.0, 0.0, 1.0), vec4f(0.0), vec2f(0.0), 0.0, vec4f(0.0), vec4f(0.0));
}

// Must match canvas_tess.emitAaSegment (aa) and emitSegmentQuad (hard).
fn expand_segment(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, alpha_in: f32, e0: f32, e1: f32, aa: bool, corner: f32, rgb: vec3f) -> VsOut {
    let d = vec2f(x1 - x0, y1 - y0);
    let len = length(d);
    if (!(len > 0.0)) { return degenerate(); }
    let ux = d.x / len;
    let uy = d.y / len;
    if (aa) {
        let alpha = alpha_in * clamp(thickness, 0.0, 1.0);
        if (!(alpha > 0.0)) { return degenerate(); }
        let hw = max(thickness, 1.0) * 0.5;
        let nx = -uy;
        let ny = ux;
        let hl = (len + e0 + e1) * 0.5;
        let off = (e1 - e0) * 0.5;
        let mx = (x0 + x1) * 0.5 + ux * off;
        let my = (y0 + y1) * 0.5 + uy * off;
        let m = 1.0;
        let au = (hw + m) / hw;
        let av = (hl + m) / hl;
        let ax = ux * (hl + m);
        let ay = uy * (hl + m);
        let bx = nx * (hw + m);
        let by = ny * (hw + m);
        let c0 = vec4f(mx - ax + bx, my - ay + by, au, -av);
        let c1 = vec4f(mx + ax + bx, my + ay + by, au, av);
        let c2 = vec4f(mx + ax - bx, my + ay - by, -au, av);
        let c3 = vec4f(mx - ax - bx, my - ay - by, -au, -av);
        let c = pick(c0, c1, c2, c3, corner);
        return out_of(c.xy, c.zw, vec4f(rgb, alpha), 1.0, vec4f(0.0), vec4f(0.0));
    }
    let sx0 = x0 - ux * e0;
    let sy0 = y0 - uy * e0;
    let sx1 = x1 + ux * e1;
    let sy1 = y1 + uy * e1;
    let half = thickness * 0.5;
    let nx = -uy * half;
    let ny = ux * half;
    let c0 = vec4f(sx0 + nx, sy0 + ny, 0.0, 0.0);
    let c1 = vec4f(sx1 + nx, sy1 + ny, 0.0, 0.0);
    let c2 = vec4f(sx1 - nx, sy1 - ny, 0.0, 0.0);
    let c3 = vec4f(sx0 - nx, sy0 - ny, 0.0, 0.0);
    let c = pick(c0, c1, c2, c3, corner);
    return out_of(c.xy, vec2f(0.0), vec4f(rgb, alpha_in), 0.0, vec4f(0.0), vec4f(0.0));
}

// Liang-Barsky against the draw clip, matching canvas_tess.clipSegment.
struct ClipSeg {
    a: vec2f,
    b: vec2f,
    t0: f32,
    t1: f32,
    ok: bool,
}

fn clip_edge(t0_in: f32, t1_in: f32, pk: f32, qk: f32) -> vec3f {
    var t0 = t0_in;
    var t1 = t1_in;
    if (pk == 0.0) {
        if (qk < 0.0) { return vec3f(t0, t1, 0.0); }
        return vec3f(t0, t1, 1.0);
    }
    let t = qk / pk;
    if (pk < 0.0) {
        if (t > t1) { return vec3f(t0, t1, 0.0); }
        if (t > t0) { t0 = t; }
    } else {
        if (t < t0) { return vec3f(t0, t1, 0.0); }
        if (t < t1) { t1 = t; }
    }
    return vec3f(t0, t1, 1.0);
}

fn clip_seg(a: vec2f, b: vec2f, clip: vec4f) -> ClipSeg {
    let d = b - a;
    let xmin = clip.x;
    let xmax = clip.x + clip.z;
    let ymin = clip.y;
    let ymax = clip.y + clip.w;
    let p = vec4f(-d.x, d.x, -d.y, d.y);
    let q = vec4f(a.x - xmin, xmax - a.x, a.y - ymin, ymax - a.y);
    var t0 = 0.0;
    var t1 = 1.0;
    var e = clip_edge(t0, t1, p.x, q.x);
    if (e.z < 0.5) { return ClipSeg(a, b, 0.0, 1.0, false); }
    t0 = e.x; t1 = e.y;
    e = clip_edge(t0, t1, p.y, q.y);
    if (e.z < 0.5) { return ClipSeg(a, b, 0.0, 1.0, false); }
    t0 = e.x; t1 = e.y;
    e = clip_edge(t0, t1, p.z, q.z);
    if (e.z < 0.5) { return ClipSeg(a, b, 0.0, 1.0, false); }
    t0 = e.x; t1 = e.y;
    e = clip_edge(t0, t1, p.w, q.w);
    if (e.z < 0.5) { return ClipSeg(a, b, 0.0, 1.0, false); }
    t0 = e.x; t1 = e.y;
    return ClipSeg(a + d * t0, a + d * t1, t0, t1, true);
}

// As canvas_tess.strokeSegment: a trimmed antialiased end extends thickness/2+1 past the rect.
fn expand_clipped(a: vec2f, b: vec2f, thickness: f32, alpha_in: f32, e0: f32, e1: f32, aa: bool, corner: f32, rgb: vec3f, clip: vec4f) -> VsOut {
    let s = clip_seg(a, b, clip);
    if (!s.ok) { return degenerate(); }
    var ee0 = e0;
    var ee1 = e1;
    if (aa) {
        let cap = thickness * 0.5 + 1.0;
        if (s.t0 > 0.0) { ee0 = cap; }
        if (s.t1 < 1.0) { ee1 = cap; }
    }
    return expand_segment(s.a.x, s.a.y, s.b.x, s.b.y, thickness, alpha_in, ee0, ee1, aa, corner, rgb);
}

fn sd_ellipse(p: vec2f, ab: vec2f) -> f32 {
    // Exact for a circle; otherwise Inigo Quilez's ellipse approximation.
    if (abs(ab.x - ab.y) < 1e-4) {
        return length(p) - ab.x;
    }
    let pabs = abs(p);
    let k0 = length(pabs / ab);
    let k1 = length(pabs / (ab * ab));
    return k0 * (k0 - 1.0) / max(k1, 1e-6);
}

@vertex
fn vs_main(
    @location(0) kind_corner: vec2f,
    @location(1) a: vec2f,
    @location(2) b: vec2f,
    @location(3) c: vec2f,
    @location(4) d: vec2f,
    @location(5) rg: vec2f,
    @location(6) ba: vec2f,
    @location(7) srg: vec2f,
    @location(8) sba: vec2f,
    @location(9) e: vec2f,
) -> VsOut {
    let kind = u32(kind_corner.x + 0.5);
    let corner = kind_corner.y;
    let xf = draw.xf;
    let rgba = vec4f(rg, ba);
    let srgba = vec4f(srg, sba);
    let zero4 = vec4f(0.0);

    if (kind == 1u) {
        let p = vec2f(xf.z + a.x * xf.x, xf.w + a.y * xf.y);
        return out_of(p, vec2f(0.0), rgba, 0.0, zero4, zero4);
    }

    if (kind == 4u) {
        let ctr = vec2f(xf.z + a.x * xf.x, xf.w + a.y * xf.y);
        let half = b.x * 0.5;
        if (!(half > 0.0)) { return degenerate(); }
        let c0 = vec4f(ctr.x - half, ctr.y - half, 0.0, 0.0);
        let c1 = vec4f(ctr.x + half, ctr.y - half, 0.0, 0.0);
        let c2 = vec4f(ctr.x + half, ctr.y + half, 0.0, 0.0);
        let c3 = vec4f(ctr.x - half, ctr.y + half, 0.0, 0.0);
        let q = pick(c0, c1, c2, c3, corner);
        return out_of(q.xy, vec2f(0.0), rgba, 0.0, zero4, zero4);
    }

    if (kind == 2u) {
        let ctr = vec2f(xf.z + a.x * xf.x, xf.w + a.y * xf.y);
        let screen_r = b.y > 0.5;
        let rx = select(b.x * abs(xf.x), c.x, screen_r);
        let ry = select(b.x * abs(xf.y), c.x, screen_r);
        let has_fill = d.x > 0.5;
        let has_stroke = d.y > 0.5;
        let grow = select(0.0, c.y * 0.5, has_stroke);
        let ox = max(rx + grow, 0.0);
        let oy = max(ry + grow, 0.0);
        let bw = select(0.0, min(c.y, min(ox, oy)), has_stroke);
        let pad = 1.5;
        let x0 = ctr.x - ox - pad;
        let y0 = ctr.y - oy - pad;
        let x1 = ctr.x + ox + pad;
        let y1 = ctr.y + oy + pad;
        let c0 = vec4f(x0, y0, x0 - ctr.x, y0 - ctr.y);
        let c1 = vec4f(x1, y0, x1 - ctr.x, y0 - ctr.y);
        let c2 = vec4f(x1, y1, x1 - ctr.x, y1 - ctr.y);
        let c3 = vec4f(x0, y1, x0 - ctr.x, y1 - ctr.y);
        let q = pick(c0, c1, c2, c3, corner);
        var fill = rgba;
        var stroke = srgba;
        if (!has_fill) { fill.a = 0.0; }
        if (!has_stroke) { stroke.a = 0.0; }
        return out_of(q.xy, q.zw, fill, 2.0, stroke, vec4f(ox, oy, bw, 0.0));
    }

    if (kind == 3u) {
        let p0 = vec2f(xf.z + a.x * xf.x, xf.w + a.y * xf.y);
        let p1 = vec2f(xf.z + b.x * xf.x, xf.w + b.y * xf.y);
        let clipped = clip_seg(p0, p1, draw.clip);
        if (!clipped.ok) { return degenerate(); }
        let ed = clipped.b - clipped.a;
        let len = length(ed);
        if (!(len > 0.0)) { return degenerate(); }
        // c.x is the world shoelace sign; the screen winding flips with sx*sy.
        let s = c.x * sign(xf.x) * sign(xf.y);
        let n = vec2f(ed.y / len * s, -ed.x / len * s);
        let c0 = vec4f(clipped.a, vec2f(1.0, 0.0));
        let c1 = vec4f(clipped.b, vec2f(1.0, 0.0));
        let c2 = vec4f(clipped.b + n, vec2f(2.0, 0.0));
        let c3 = vec4f(clipped.a + n, vec2f(2.0, 0.0));
        let q = pick(c0, c1, c2, c3, corner);
        return out_of(q.xy, q.zw, rgba, 1.0, zero4, zero4);
    }

    if (kind == 5u) {
        let sgx = sign(xf.x);
        let sgy = sign(xf.y);
        let cxs = xf.z + a.x * xf.x;
        let cys = xf.w + a.y * xf.y;
        return expand_clipped(
            vec2f(cxs + b.x * sgx, cys + b.y * sgy),
            vec2f(cxs + c.x * sgx, cys + c.y * sgy),
            d.x, rgba.a, e.x, e.y, d.y > 0.5, corner, rgba.rgb, draw.clip,
        );
    }

    if (kind == 6u) {
        let ctr = vec2f(xf.z + a.x * xf.x, xf.w + a.y * xf.y);
        let rx = b.x * abs(xf.x);
        let ry = b.x * abs(xf.y);
        let aa = d.x > 0.5;
        let hw = select(b.y, max(b.y, 1.0), aa) * 0.5;
        let alpha = select(rgba.a, rgba.a * clamp(b.y, 0.0, 1.0), aa);
        if (!(rx > 0.0 && ry > 0.0 && hw > 0.0 && alpha > 0.0)) { return degenerate(); }
        let ext = vec2f(rx, ry) + hw + 1.5;
        let c0 = vec4f(ctr - ext, -ext);
        let c1 = vec4f(ctr.x + ext.x, ctr.y - ext.y, ext.x, -ext.y);
        let c2 = vec4f(ctr + ext, ext);
        let c3 = vec4f(ctr.x - ext.x, ctr.y + ext.y, -ext.x, ext.y);
        let q = pick(c0, c1, c2, c3, corner);
        return out_of(q.xy, q.zw, vec4f(rgba.rgb, alpha), 3.0, vec4f(c, sign(xf.x), sign(xf.y)), vec4f(rx, ry, hw, 0.0));
    }

    if (kind == 0u) {
        return expand_clipped(
            vec2f(xf.z + a.x * xf.x, xf.w + a.y * xf.y),
            vec2f(xf.z + b.x * xf.x, xf.w + b.y * xf.y),
            c.x, rgba.a, e.x, e.y, c.y > 0.5, corner, rgba.rgb, draw.clip,
        );
    }

    return degenerate();
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4f {
    // Derivatives must precede any discard (uniform control flow).
    let fw = max(max(fwidth(in.uv.x), fwidth(in.uv.y)), 1e-4);
    let gx = max(length(vec2f(dpdx(in.uv.x), dpdy(in.uv.x))), 1e-6);
    let gy = max(length(vec2f(dpdx(in.uv.y), dpdy(in.uv.y))), 1e-6);

    let lp = in.pos.xy / max(screen_u.scale, 1e-6);
    let clip = draw.clip;
    // Antialiased strokes and fringes keep a 3px bulge past the rect, as the unscissored immediate path does.
    let bulge = (in.mode > 0.5) && (in.mode < 1.5);
    let pad = select(0.0, 3.0, bulge);
    if (lp.x < clip.x - pad || lp.y < clip.y - pad || lp.x >= clip.x + clip.z + pad || lp.y >= clip.y + clip.w + pad) {
        discard;
    }

    if (in.mode > 2.5) {
        let ab = max(in.circ.xy, vec2f(1e-4));
        // Hard arcs get the same coverage ramp: a per-pixel step would alias where MSAA smooths hard quads.
        var cov = clamp((in.circ.z - abs(sd_ellipse(in.uv, ab))) / fw + 0.5, 0.0, 1.0);
        let span = abs(in.stroke.y);
        if (span < TAU - 1e-4) {
            // Angles are in world orientation: undo the axis signs before atan2.
            let q = in.uv * in.stroke.zw / ab;
            let turn = (atan2(q.y, q.x) - in.stroke.x) * sign(in.stroke.y);
            let along = turn - TAU * floor(turn / TAU);
            let past = select(min(along - span, TAU - along), -min(along, span - along), along <= span) * length(in.uv);
            cov *= clamp(0.5 - past / fw, 0.0, 1.0);
        }
        let alpha = in.color.a * cov;
        if (alpha <= 0.0) { discard; }
        return vec4f(in.color.rgb, alpha);
    }

    if (in.mode > 1.5) {
        let ab = max(in.circ.xy, vec2f(1e-4));
        let dist = sd_ellipse(in.uv, ab);
        let cov = clamp(0.5 - dist / fw, 0.0, 1.0);
        var inner = 1.0;
        if (in.circ.z > 0.0) {
            inner = clamp(0.5 - (dist + in.circ.z) / fw, 0.0, 1.0);
        }
        let pf = vec4f(in.color.rgb * in.color.a, in.color.a);
        let pb = vec4f(in.stroke.rgb * in.stroke.a, in.stroke.a);
        let pm = (pf * inner + pb * (1.0 - inner)) * cov;
        if (pm.a <= 0.0) { discard; }
        return vec4f(pm.rgb / pm.a, pm.a);
    }

    if (in.mode > 0.5) {
        let cov = clamp((1.0 - abs(in.uv.x)) / gx + 0.5, 0.0, 1.0) * clamp((1.0 - abs(in.uv.y)) / gy + 0.5, 0.0, 1.0);
        let alpha = in.color.a * cov;
        if (alpha <= 0.0) { discard; }
        return vec4f(in.color.rgb, alpha);
    }

    if (in.color.a <= 0.0) { discard; }
    return in.color;
}
