// Instanced glyph quads sampled from an R8 coverage atlas page.
// One instance = one glyph (see GlyphInstance in src/gpu/glyph_atlas.zig).
// The instance is read as raw 32-bit words (Float32x2, Uint32x2, Uint32,
// Uint32x2, Uint32) and unpacked here: zunk's vertex formats are 32-bit only,
// and the same shader then serves the native and web backends.
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
    @location(1) size_uv: vec2u,    // w | h << 16, u | v << 16
    @location(2) color_rgba: u32,   // r | g << 8 | b << 16 | a << 24
    @location(3) clip_words: vec2u, // x | y << 16 (i16 each), w | h << 16
    @location(4) flags: u32,
) -> VOut {
    let size = vec2u(size_uv.x & 0xffffu, size_uv.x >> 16u);
    let uv = vec2u(size_uv.y & 0xffffu, size_uv.y >> 16u);
    let color = unpack4x8unorm(color_rgba);
    let clip_xy = vec2i(bitcast<i32>(clip_words.x << 16u) >> 16u, bitcast<i32>(clip_words.x) >> 16u);
    let clip_wh = vec2u(clip_words.y & 0xffffu, clip_words.y >> 16u);
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
    let a = select(pow(cov, u.text_gamma), cov, u.text_gamma == 1.0);
    return vec4f(in.color.rgb, in.color.a * a);
}
