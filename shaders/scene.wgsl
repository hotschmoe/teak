// 3D scene shader: flat-shaded lit triangles and camera-facing line quads.
// Uniform layout must match `Globals` in src/gpu/scene_common.zig (208 B).
// Per-item placement comes from the instance stream (`scene_pass.Packed`, 80 B).

struct Globals {
    view_proj: mat4x4f,
    eye: vec4f,
    light_dir: vec4f,   // xyz = direction the light travels; 0 = headlight
    edge_color: vec4f,  // multiplied into every line vertex colour
    viewport: vec4f,    // xy = target size px, z = line width px, w = line depth bias
    clip: vec4f,        // section plane n.xyz, d: fragments with dot(n, p) + d > 0 are cut away
    highlight: vec4f,   // rgb = highlight colour, w = blend amount
    misc: vec4f,        // x = 1 flat material, z = 1 cut enabled, w = device px per logical px
    cam_right: vec4f,   // world-space camera axes (billboards)
    cam_up: vec4f,
};

@group(0) @binding(0) var<uniform> g: Globals;

const AMBIENT: f32 = 0.35;

// ItemFlags bits (see scene_pass.zig).
const FLAG_UNLIT: u32 = 2u;
const FLAG_HIGHLIGHT: u32 = 16u;

fn place(m0: vec4f, m1: vec4f, m2: vec4f, p: vec3f) -> vec3f {
    let h = vec4f(p, 1.0);
    return vec3f(dot(m0, h), dot(m1, h), dot(m2, h));
}

fn cut_away(world: vec3f) -> bool {
    return g.misc.z > 0.5 && dot(g.clip.xyz, world) + g.clip.w > 0.0;
}

// ── Triangles ──────────────────────────────────────────────────────

struct MeshOut {
    @builtin(position) pos: vec4f,
    @location(0) world: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
    @location(3) @interpolate(flat) flags: u32,
};

// Instance stream: rows of the 3x4 transform, tint, (id, flags).
// Normals use the linear part (rotation + uniform scale); `normalize` in
// the fragment stage absorbs the scale.
@vertex
fn vs_mesh(
    @location(0) pos: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
    @location(4) m0: vec4f,
    @location(5) m1: vec4f,
    @location(6) m2: vec4f,
    @location(7) tint: vec4f,
    @location(8) id_flags: vec2u,
) -> MeshOut {
    let world = place(m0, m1, m2, pos);
    let n = vec3f(dot(m0.xyz, normal), dot(m1.xyz, normal), dot(m2.xyz, normal));
    return MeshOut(g.view_proj * vec4f(world, 1.0), world, n, vec4f(color.rgb * tint.rgb, color.a), id_flags.y);
}

@fragment
fn fs_mesh(in: MeshOut) -> @location(0) vec4f {
    if (cut_away(in.world)) { discard; }
    var rgb = in.color.rgb;
    if ((in.flags & FLAG_HIGHLIGHT) != 0u) { rgb = mix(rgb, g.highlight.rgb, g.highlight.w); }
    if (g.misc.x > 0.5 || (in.flags & FLAG_UNLIT) != 0u) { return vec4f(rgb, 1.0); }
    var n = normalize(in.normal);
    let to_eye = g.eye.xyz - in.world;
    // Two-sided: light the side that faces the camera.
    if (dot(n, to_eye) < 0.0) { n = -n; }
    var travel = g.light_dir.xyz;
    if (dot(travel, travel) < 1e-8) { travel = -to_eye; }
    let diffuse = max(dot(n, -normalize(travel)), 0.0);
    return vec4f(rgb * (AMBIENT + (1.0 - AMBIENT) * diffuse), 1.0);
}

// ── Plane layers ───────────────────────────────────────────────────
// Plane-local 2D triangles (the canvas tessellator's output) placed by the
// plane frame in the instance stream; `layer` biases depth so coplanar
// sheets stack deterministically.

struct PlaneOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) world: vec3f,
};

@vertex
fn vs_plane(
    @location(0) xy: vec2f,
    @location(1) color: vec4f,
    @location(4) m0: vec4f,
    @location(5) m1: vec4f,
    @location(6) m2: vec4f,
    @location(7) tint: vec4f,
    @location(8) id_flags: vec2u,
    @location(9) layer: i32,
) -> PlaneOut {
    let world = place(m0, m1, m2, vec3f(xy, 0.0));
    var clip = g.view_proj * vec4f(world, 1.0);
    clip.z = clip.z - f32(layer) * 2e-5 * clip.w;
    return PlaneOut(clip, vec4f(color.rgb, color.a * tint.a), world);
}

@fragment
fn fs_plane(in: PlaneOut) -> @location(0) vec4f {
    if (cut_away(in.world) || in.color.a < 0.02) { discard; }
    return in.color;
}

// ── Sprites ────────────────────────────────────────────────────────
// One instance per sprite, six vertices per quad. `screen_px` camera-facing
// sprites keep a constant pixel size; the others are world-space quads on
// the camera axes (billboard), the camera's right projected on XZ (axis
// locked) or the world XY plane (fixed).

@group(1) @binding(0) var sprite_tex: texture_2d<f32>;
@group(1) @binding(1) var sprite_samp: sampler;

struct SpriteOut {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
    @location(2) world: vec3f,
};

@vertex
fn vs_sprite(
    @builtin(vertex_index) vi: u32,
    @location(0) pos_mode: vec4f,
    @location(1) size_anchor: vec4f,
    @location(2) uvr: vec4f,
    @location(3) tint: vec4f,
    @location(4) extra: vec4f,
) -> SpriteOut {
    var corner = array<vec2f, 6>(
        vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
        vec2f(1.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0),
    );
    let c = corner[vi];
    let local = c - size_anchor.zw;          // in units of the size, y up
    let mode = i32(pos_mode.w + 0.5);
    var world = pos_mode.xyz;
    var clip = g.view_proj * vec4f(world, 1.0);
    if (extra.y > 0.5 && mode == 0) {
        let px = local * size_anchor.xy * g.misc.w;
        clip.x = clip.x + px.x * 2.0 / g.viewport.x * clip.w;
        clip.y = clip.y + px.y * 2.0 / g.viewport.y * clip.w;
    } else {
        var right = g.cam_right.xyz;
        var up = g.cam_up.xyz;
        if (mode == 1) { right = normalize(vec3f(right.x, 0.0, right.z)); up = vec3f(0.0, 1.0, 0.0); }
        if (mode == 2) { right = vec3f(1.0, 0.0, 0.0); up = vec3f(0.0, 1.0, 0.0); }
        world = pos_mode.xyz + right * (local.x * size_anchor.x) + up * (local.y * size_anchor.y);
        clip = g.view_proj * vec4f(world, 1.0);
    }
    clip.z = clip.z - extra.x * 2e-5 * clip.w;
    return SpriteOut(clip, mix(uvr.xy, uvr.zw, vec2f(c.x, 1.0 - c.y)), tint, world);
}

@fragment
fn fs_sprite(in: SpriteOut) -> @location(0) vec4f {
    let t = textureSample(sprite_tex, sprite_samp, in.uv) * in.color;
    if (cut_away(in.world) || t.a < 0.01) { discard; }
    return t;
}

// ── Section caps ───────────────────────────────────────────────────
// Stencil parity: the item's faces (cut-away half discarded) are drawn with
// colour writes off and stencil `invert`; a pixel's stencil is then odd iff
// the view ray enters the kept half inside the closed solid. The cap quad on
// the plane is drawn where stencil != 0 (and clears it again).

@fragment
fn fs_stencil(in: MeshOut) -> @location(0) vec4f {
    if (cut_away(in.world)) { discard; }
    return vec4f(0.0);
}

struct CapOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
};

@vertex
fn vs_cap(@location(0) pos: vec3f, @location(1) color: vec4f) -> CapOut {
    return CapOut(g.view_proj * vec4f(pos, 1.0), color);
}

// A drafting-style hatch: diagonal stripes in screen space, slightly darker.
@fragment
fn fs_cap(in: CapOut) -> @location(0) vec4f {
    let t = fract((in.pos.x + in.pos.y) / 7.0);
    let stripe = step(0.8, t);
    return vec4f(mix(in.color.rgb, in.color.rgb * 0.7, stripe), 1.0);
}

// ── Lines ──────────────────────────────────────────────────────────
// One instance per segment; six vertices expand it into a quad of
// constant pixel width, extended by half a width at each end so
// polylines join without gaps. Instance attributes are a LineVertex pair.

struct LineOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) world: vec3f,
};

@vertex
fn vs_line(
    @builtin(vertex_index) vi: u32,
    @location(0) pos_a: vec3f,
    @location(1) col_a: vec4f,
    @location(2) pos_b: vec3f,
    @location(3) col_b: vec4f,
    @location(4) m0: vec4f,
    @location(5) m1: vec4f,
    @location(6) m2: vec4f,
) -> LineOut {
    var end_of = array<u32, 6>(0, 0, 1, 1, 0, 1);
    var side_of = array<f32, 6>(-1, 1, -1, -1, 1, 1);

    // The item's transform arrives through a stride-0 instance stream, so
    // every segment of the item reads the same record.
    let world_a = place(m0, m1, m2, pos_a);
    let world_b = place(m0, m1, m2, pos_b);
    var a = g.view_proj * vec4f(world_a, 1.0);
    var b = g.view_proj * vec4f(world_b, 1.0);

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
    var world = world_a;
    if (end_of[vi] == 1u) {
        c = b;
        color = col_b;
        along = 1.0;
        world = world_b;
    }
    let offset_px = normal * side_of[vi] * half_width + dir * along * half_width;
    let ndc_xy = c.xy / c.w + offset_px / half_size;
    let ndc_z = c.z / c.w - g.viewport.w;

    var out: LineOut;
    out.pos = vec4f(ndc_xy * c.w, ndc_z * c.w, c.w);
    if (!visible) { out.pos = vec4f(2.0, 2.0, 2.0, 1.0); }
    out.color = color * g.edge_color;
    out.world = world;
    return out;
}

@fragment
fn fs_line(in: LineOut) -> @location(0) vec4f {
    if (cut_away(in.world)) { discard; }
    return in.color;
}
