// Infinite ground grid for 3D scenes: a fullscreen triangle whose fragment
// shader ray-intersects a world plane, derives anti-aliased line coverage
// from screen-space derivatives (minor / major spacing, two axis lines) and
// writes the plane's depth so meshes and edges occlude it.
// Uniform layout must match `GridUniform` in src/gpu/scene_pass.zig (256 B).

struct GridU {
    view_proj: mat4x4f,
    inv_view_proj: mat4x4f,
    eye: vec4f,
    minor: vec4f,
    major: vec4f,
    axis_a: vec4f,      // colour of the line v = 0 (along the u axis)
    axis_b: vec4f,      // colour of the line u = 0 (along the v axis)
    params: vec4f,      // x spacing, y major_every, z fade distance, w plane offset
    plane: vec4f,       // x plane id (0 xz, 1 xy, 2 yz), y axis line px, zw target size px
    extra: vec4f,       // x view-space distance of the far plane, y 1 for a perspective camera
};

@group(0) @binding(0) var<uniform> u: GridU;

@vertex
fn vs_grid(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
    var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    return vec4f(p[vi], 0.0, 1.0);
}

struct FragOut {
    @location(0) color: vec4f,
    @builtin(frag_depth) depth: f32,
};

fn unproject(ndc: vec3f) -> vec3f {
    let h = u.inv_view_proj * vec4f(ndc, 1.0);
    return h.xyz / h.w;
}

// Anti-aliased coverage of the lines of a grid with cell size `s`, and how
// visible that level is (it fades out as cells shrink below a few pixels).
fn grid_level(c: vec2f, fw: vec2f, s: f32) -> vec2f {
    let x = c / s;
    let g = abs(fract(x - 0.5) - 0.5) / max(fw / s, vec2f(1e-6));
    let cov = 1.0 - min(min(g.x, g.y), 1.0);
    let cell_px = s / max(max(fw.x, fw.y), 1e-9);
    return vec2f(cov, smoothstep(2.0, 8.0, cell_px));
}

@fragment
fn fs_grid(@builtin(position) frag: vec4f) -> FragOut {
    let ndc = vec2f(frag.x / u.plane.z * 2.0 - 1.0, 1.0 - frag.y / u.plane.w * 2.0);
    let a = unproject(vec3f(ndc, 0.0));
    let b = unproject(vec3f(ndc, 1.0));
    let d = b - a;

    var n = 1;
    var ua = 0;
    var va = 2;
    let pid = i32(u.plane.x);
    if (pid == 1) { n = 2; ua = 0; va = 1; }
    if (pid == 2) { n = 0; ua = 1; va = 2; }

    var dv = d;
    var av = a;
    let dn = dv[n];
    var t = -1.0;
    if (abs(dn) > 1e-12) { t = (u.params.w - av[n]) / dn; }
    let p = a + d * t;
    var pv = p;
    let c = vec2f(pv[ua], pv[va]);
    // Derivatives are taken before any early-out (uniform control flow).
    let fw = max(fwidth(c), vec2f(1e-9));

    let clip = u.view_proj * vec4f(p, 1.0);
    let depth = clip.z / clip.w;

    let spacing = max(u.params.x, 1e-6);
    let minor = grid_level(c, fw, spacing);
    let major = grid_level(c, fw, spacing * max(u.params.y, 1.0));
    let axis_w = max(u.plane.y, 1.0) * 0.5;
    let cov_a = 1.0 - min(abs(c.y) / (fw.y * axis_w), 1.0); // line v = 0
    let cov_b = 1.0 - min(abs(c.x) / (fw.x * axis_w), 1.0); // line u = 0

    var col = vec4f(u.minor.rgb, u.minor.a * minor.x * minor.y);
    let ma = u.major.a * major.x * major.y;
    col = vec4f(mix(col.rgb, u.major.rgb, ma / max(ma + col.a, 1e-5)), max(col.a, ma));
    let aa = u.axis_a.a * cov_a;
    col = vec4f(mix(col.rgb, u.axis_a.rgb, aa / max(aa + col.a, 1e-5)), max(col.a, aa));
    let ab = u.axis_b.a * cov_b;
    col = vec4f(mix(col.rgb, u.axis_b.rgb, ab / max(ab + col.a, 1e-5)), max(col.a, ab));

    let dist = length(p - u.eye.xyz);
    var fade = 1.0 - smoothstep(0.5 * u.params.z, u.params.z, dist);
    // Dissolve before the far plane so the grid never ends in a hard edge.
    var depth_frac = depth;
    if (u.extra.y > 0.5) { depth_frac = clip.w / max(u.extra.x, 1e-9); }
    fade = fade * (1.0 - smoothstep(0.8, 0.99, depth_frac));
    col.a = col.a * fade;

    if (abs(dn) <= 1e-12 || depth < 0.0 || depth > 1.0 || col.a < 0.003) { discard; }

    var out: FragOut;
    out.color = col;
    out.depth = min(depth + 1e-5, 1.0);
    return out;
}
