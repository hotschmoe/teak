// 3D scene shader: flat-shaded lit triangles and camera-facing line quads.
// Uniform layout must match `Globals` in src/gpu/scene_common.zig (128 B).

struct Globals {
    view_proj: mat4x4f,
    eye: vec4f,
    light_dir: vec4f,   // xyz = direction the light travels; 0 = headlight
    edge_color: vec4f,  // multiplied into every line vertex colour
    viewport: vec4f,    // xy = target size px, z = line width px, w = line depth bias
};

@group(0) @binding(0) var<uniform> g: Globals;

const AMBIENT: f32 = 0.35;

// ── Triangles ──────────────────────────────────────────────────────

struct MeshOut {
    @builtin(position) pos: vec4f,
    @location(0) world: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
};

@vertex
fn vs_mesh(
    @location(0) pos: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
) -> MeshOut {
    return MeshOut(g.view_proj * vec4f(pos, 1.0), pos, normal, color);
}

@fragment
fn fs_mesh(in: MeshOut) -> @location(0) vec4f {
    var n = normalize(in.normal);
    let to_eye = g.eye.xyz - in.world;
    // Two-sided: light the side that faces the camera.
    if (dot(n, to_eye) < 0.0) { n = -n; }
    var travel = g.light_dir.xyz;
    if (dot(travel, travel) < 1e-8) { travel = -to_eye; }
    let diffuse = max(dot(n, -normalize(travel)), 0.0);
    return vec4f(in.color.rgb * (AMBIENT + (1.0 - AMBIENT) * diffuse), 1.0);
}

// ── Lines ──────────────────────────────────────────────────────────
// One instance per segment; six vertices expand it into a quad of
// constant pixel width, extended by half a width at each end so
// polylines join without gaps. Instance attributes are a LineVertex pair.

struct LineOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
};

@vertex
fn vs_line(
    @builtin(vertex_index) vi: u32,
    @location(0) pos_a: vec3f,
    @location(1) col_a: vec4f,
    @location(2) pos_b: vec3f,
    @location(3) col_b: vec4f,
) -> LineOut {
    var end_of = array<u32, 6>(0, 0, 1, 1, 0, 1);
    var side_of = array<f32, 6>(-1, 1, -1, -1, 1, 1);

    var a = g.view_proj * vec4f(pos_a, 1.0);
    var b = g.view_proj * vec4f(pos_b, 1.0);

    // Clip the segment to the near plane (z >= 0) before the perspective
    // divide, so an endpoint behind the camera cannot explode.
    var visible = true;
    if (a.z < 0.0 && b.z < 0.0) {
        visible = false;
    } else if (a.z < 0.0) {
        a = mix(a, b, a.z / (a.z - b.z));
    } else if (b.z < 0.0) {
        b = mix(b, a, b.z / (b.z - a.z));
    }

    let half_size = g.viewport.xy * 0.5;
    let pa = a.xy / a.w * half_size;
    let pb = b.xy / b.w * half_size;
    var dir = pb - pa;
    let len = length(dir);
    if (len < 1e-4) { dir = vec2f(1.0, 0.0); } else { dir = dir / len; }
    let normal = vec2f(-dir.y, dir.x);
    let half_width = g.viewport.z * 0.5;

    var c = a;
    var color = col_a;
    var along = -1.0;
    if (end_of[vi] == 1u) {
        c = b;
        color = col_b;
        along = 1.0;
    }
    let offset_px = normal * side_of[vi] * half_width + dir * along * half_width;
    let ndc_xy = c.xy / c.w + offset_px / half_size;
    let ndc_z = c.z / c.w - g.viewport.w;

    var out: LineOut;
    out.pos = vec4f(ndc_xy * c.w, ndc_z * c.w, c.w);
    if (!visible) { out.pos = vec4f(2.0, 2.0, 2.0, 1.0); }
    out.color = color * g.edge_color;
    return out;
}

@fragment
fn fs_line(in: LineOut) -> @location(0) vec4f {
    return in.color;
}
