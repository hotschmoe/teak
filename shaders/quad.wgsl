// Solid quads, plus signed-distance rounded rects (per-corner radii, inside
// border stroke, gradient fill, soft drop shadow) in the same stream so
// painter's order holds. Plain solids have color.a >= 0 and return their
// vertex colour untouched. An SDF quad is tagged color.a = -1; its `r` is the
// vertex index of a 6-vertex "header" whose r g b a u v fields hold the
// 36-float record (layout: src/render/sdf.zig `rec`), read back through the
// vertex buffer bound as read-only storage. uv is the pixel offset from the
// rect centre (the SDF coordinate).

struct VertexOutput {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
    @location(2) @interpolate(flat) sdf: f32,
};

struct Uniforms {
    screen_size: vec2f,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var<storage, read> vdata: array<f32>;

@vertex
fn vs_main(
    @location(0) pos: vec2f,
    @location(1) color: vec4f,
    @location(2) uv: vec2f,
) -> VertexOutput {
    let clip = vec2f(
        (pos.x / uniforms.screen_size.x) * 2.0 - 1.0,
        1.0 - (pos.y / uniforms.screen_size.y) * 2.0,
    );
    return VertexOutput(vec4f(clip, 0.0, 1.0), color, uv, select(-1.0, color.r, color.a < -0.5));
}

// Record float `k` of the header starting at vertex `h` (8 floats per
// vertex; r g b a u v are floats 2..7 of each of the six header vertices).
fn rec(h: u32, k: u32) -> f32 {
    return vdata[(h + k / 6u) * 8u + 2u + k % 6u];
}

fn rec4(h: u32, k: u32) -> vec4f {
    return vec4f(rec(h, k), rec(h, k + 1u), rec(h, k + 2u), rec(h, k + 3u));
}

// Signed distance to a rounded box centred at the origin. r = (br, tr, bl, tl)
// so (x>0, y>0) picks r.x; y grows downward.
fn sd_round_box(p: vec2f, b: vec2f, r4: vec4f) -> f32 {
    let r2 = select(r4.zw, r4.xy, p.x > 0.0);
    let r = select(r2.y, r2.x, p.y > 0.0);
    let q = abs(p) - b + vec2f(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2f(0.0))) - r;
}

// erf via the Abramowitz-Stegun-style closed form (max error ~1e-4).
fn erf_approx(x: f32) -> f32 {
    let a = 0.147;
    let x2 = x * x;
    let t = x2 * (1.2732395 + a * x2) / (1.0 + a * x2);
    return sign(x) * sqrt(max(1.0 - exp(-t), 0.0));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // Derivatives before any branch (uniform control flow): logical pixels
    // per device pixel, so antialiasing is one device pixel at any DPR.
    let fw = max(max(fwidth(in.uv.x), fwidth(in.uv.y)), 1e-4);
    if (in.sdf < 0.0) {
        return in.color;
    }
    let h = u32(in.sdf);
    let p = in.uv;
    let half_size = vec2f(rec(h, 0u), rec(h, 1u));
    let rad = vec4f(rec(h, 4u), rec(h, 3u), rec(h, 5u), rec(h, 2u));
    let bw = rec(h, 6u);
    let bcol = rec4(h, 7u);
    let f0 = rec4(h, 11u);
    let f1 = rec4(h, 15u);
    let gk = rec(h, 19u);
    let gdir = vec2f(rec(h, 20u), rec(h, 21u));

    var fill = f0;
    if (gk > 0.5) {
        var t = 0.0;
        if (gk < 1.5) {
            let ext = abs(gdir.x) * half_size.x + abs(gdir.y) * half_size.y;
            t = clamp(0.5 + dot(p, gdir) / (2.0 * max(ext, 1e-4)), 0.0, 1.0);
        } else {
            t = clamp(length(p / max(half_size, vec2f(1e-4))), 0.0, 1.0);
        }
        fill = mix(f0, f1, t);
    }

    let d = sd_round_box(p, half_size, rad);
    let cov = clamp(0.5 - d / fw, 0.0, 1.0);
    // 1 inside the inner edge of the border stroke, 0 on the stroke.
    var inner = 1.0;
    if (bw > 0.0) {
        inner = clamp(0.5 - (d + bw) / fw, 0.0, 1.0);
    }
    let pf = vec4f(fill.rgb * fill.a, fill.a);
    let pb = vec4f(bcol.rgb * bcol.a, bcol.a);
    var pm = (pf * inner + pb * (1.0 - inner)) * cov;

    if (rec(h, 30u) > 0.5) {
        let scol = rec4(h, 22u);
        let sigma = max(rec(h, 26u), 0.5 * fw);
        let spread = rec(h, 27u);
        let off = vec2f(rec(h, 28u), rec(h, 29u));
        let ds = sd_round_box(p - off, max(half_size + vec2f(spread), vec2f(0.0)), max(rad + vec4f(spread), vec4f(0.0)));
        // Gaussian-blurred edge, drawn outside the rect only (CSS box-shadow).
        let sa = scol.a * (0.5 - 0.5 * erf_approx(ds / (sigma * 1.41421356))) * (1.0 - cov);
        pm = pm + vec4f(scol.rgb * sa, sa) * (1.0 - pm.a);
    }
    if (pm.a <= 0.0) {
        discard;
    }
    var out = vec4f(pm.rgb / pm.a, pm.a);
    // Soft shadows and gradients span many nearly equal levels; a sub-level
    // blue-noise-ish dither (interleaved gradient noise) hides the 8-bit
    // banding that would otherwise show as contour lines.
    let n = (fract(52.9829189 * fract(dot(in.pos.xy, vec2f(0.06711056, 0.00583715)))) - 0.5) / 255.0;
    if (gk > 0.5) {
        out = vec4f(out.rgb + vec3f(n), out.a);
    }
    if (rec(h, 30u) > 0.5 && out.a < 0.995) {
        out.a = clamp(out.a + n, 0.0, 1.0);
    }
    return out;
}
