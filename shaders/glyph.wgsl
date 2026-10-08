// Instanced glyph quads sampled from an R8 coverage atlas page.
// One instance = one glyph (see GlyphInstance in src/gpu/glyph_atlas.zig).
// Positions are physical (device) pixels; `screen` is the LOGICAL size and
// `scale` device px per logical px, so the clip-space divisor is screen*scale.

struct Uniforms {
    screen_size: vec2f,
    scale: f32,
    text_gamma: f32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var atlas: texture_2d<f32>;

struct VOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) @interpolate(flat) origin: vec2u,
    @location(2) local: vec2f,
    @location(3) @interpolate(flat) clip_min: vec2f,
    @location(4) @interpolate(flat) clip_max: vec2f,
    @location(5) @interpolate(flat) clipped: u32,
};

const corners = array<vec2f, 6>(
    vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
    vec2f(1.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0),
);

@vertex
fn vs_main(
    @builtin(vertex_index) vi: u32,
    @location(0) pos: vec2f,
    @location(1) size: vec2u,
    @location(2) uv: vec2u,
    @location(3) color: vec4f,
    @location(4) clip_xy: vec2i,
    @location(5) clip_wh: vec2u,
    @location(6) flags: u32,
) -> VOut {
    let c = corners[vi];
    let px = pos + c * vec2f(size);
    let device = u.screen_size * u.scale;
    let clip = vec2f(px.x / device.x * 2.0 - 1.0, 1.0 - px.y / device.y * 2.0);
    var o: VOut;
    o.pos = vec4f(clip, 0.0, 1.0);
    o.color = color;
    o.origin = uv;
    o.local = c * vec2f(size);
    o.clip_min = vec2f(clip_xy);
    o.clip_max = vec2f(clip_xy) + vec2f(clip_wh);
    o.clipped = select(0u, 1u, clip_wh.x != 0u || clip_wh.y != 0u);
    return o;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4f {
    if (in.clipped != 0u) {
        let p = in.pos.xy;
        if (p.x < in.clip_min.x || p.y < in.clip_min.y || p.x >= in.clip_max.x || p.y >= in.clip_max.y) {
            discard;
        }
    }
    // The quad is pixel-aligned, so `local` hits texel centres: exact fetch, no filtering.
    let texel = vec2i(in.origin) + vec2i(floor(in.local));
    let cov = textureLoad(atlas, texel, 0).r;
    return vec4f(in.color.rgb, in.color.a * pow(cov, u.text_gamma));
}
