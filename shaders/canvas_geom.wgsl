// Retained canvas geometry. Vertices are world-space records
// (src/render/canvas_geom.zig GeomVertex); this shader applies the canvas
// transform and expands antialiased strokes. Coverage matches shaders/quad.wgsl
// so a retained draw stays within the immediate path's pixel tolerance.
//
// Ten vec2 attributes (8-byte aligned, stride 80):
//   0 kind,corner  1 ax,ay  2 bx,by  3 cx,cy  4 dx,dy
//   5 r,g  6 b,a  7 sr,sg  8 sb,sa  9 e0,e1
//
// Kinds: 0 world segment, 1 fill triangle, 2 SDF circle, 3 AA fringe,
// 4 marker, 5 screen-px segment. Quads use corners 0,1,2,0,2,3.
//
// Painter's order is the pass's: retained draws sit with image / scene
// composites, above the canvas's own immediate primitives.

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
    @location(2) @interpolate(flat) mode: f32, // 0 hard, 1 aa coverage, 2 circle
    @location(3) @interpolate(flat) stroke: vec4f,
    @location(4) @interpolate(flat) circ: vec4f, // outer rx, outer ry, border width, unused
}

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
    return VsOut(vec4f(0.0), vec4f(0.0), vec2f(0.0), 0.0, vec4f(0.0), vec4f(0.0));
}

// shadeSegment / emitAaSegment, and the hard quad (emitSegmentQuad).
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

fn sd_ellipse(p: vec2f, ab: vec2f) -> f32 {
    // A circle (rx == ry) is length(p) - r, matching sd_round_box of a disc.
    // Otherwise Inigo Quilez's ellipse approximation.
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
        let ed = p1 - p0;
        let len = length(ed);
        if (!(len > 0.0)) { return degenerate(); }
        // World shoelace sign in c.x; screen area flips with sx*sy.
        let s = c.x * sign(xf.x) * sign(xf.y);
        let n = vec2f(ed.y / len * s, -ed.x / len * s);
        let c0 = vec4f(p0, vec2f(1.0, 0.0));
        let c1 = vec4f(p1, vec2f(1.0, 0.0));
        let c2 = vec4f(p1 + n, vec2f(2.0, 0.0));
        let c3 = vec4f(p0 + n, vec2f(2.0, 0.0));
        let q = pick(c0, c1, c2, c3, corner);
        return out_of(q.xy, q.zw, rgba, 1.0, zero4, zero4);
    }

    if (kind == 5u) {
        let sgx = sign(xf.x);
        let sgy = sign(xf.y);
        let cxs = xf.z + a.x * xf.x;
        let cys = xf.w + a.y * xf.y;
        return expand_segment(
            cxs + b.x * sgx, cys + b.y * sgy,
            cxs + c.x * sgx, cys + c.y * sgy,
            d.x, rgba.a, e.x, e.y, d.y > 0.5, corner, rgba.rgb,
        );
    }

    if (kind == 0u) {
        return expand_segment(
            xf.z + a.x * xf.x, xf.w + a.y * xf.y,
            xf.z + b.x * xf.x, xf.w + b.y * xf.y,
            c.x, rgba.a, e.x, e.y, c.y > 0.5, corner, rgba.rgb,
        );
    }

    return degenerate();
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4f {
    // Derivatives before any discard (uniform control flow). uv is in
    // logical pixels, so fw is logical pixels per device pixel.
    let fw = max(max(fwidth(in.uv.x), fwidth(in.uv.y)), 1e-4);
    let gx = max(length(vec2f(dpdx(in.uv.x), dpdy(in.uv.x))), 1e-6);
    let gy = max(length(vec2f(dpdx(in.uv.y), dpdy(in.uv.y))), 1e-6);

    let lp = in.pos.xy / max(screen_u.scale, 1e-6);
    let clip = draw.clip;
    // The immediate path clips a stroke's centerline, then pushes a trimmed
    // cap outside the rect by thickness/2+1 and grows the antialias quad by
    // another pixel. Those solids are not scissored, so the bulge is in the
    // picture. Two logical pixels covers that cap for the strokes this
    // pipeline is checked against (thickness up to 1.5).
    let pad = 2.0;
    if (lp.x < clip.x - pad || lp.y < clip.y - pad || lp.x >= clip.x + clip.z + pad || lp.y >= clip.y + clip.w + pad) {
        discard;
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
