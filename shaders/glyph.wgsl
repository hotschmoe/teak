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
@group(0) @binding(2) var samp: sampler;

struct VOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) @interpolate(flat) origin: vec2u,
    @location(2) local: vec2f,
    @location(3) @interpolate(flat) clip_min: vec2f,
    @location(4) @interpolate(flat) clip_max: vec2f,
    @location(5) @interpolate(flat) clipped: u32,
    @location(6) @interpolate(flat) mode: u32,
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
    // flags: bits 0-1 mode (0 = coverage bitmap, 1 = signed distance field),
    // bits 16-31 quad scale in 1/256 units (SDF glyphs are drawn at any size).
    let mode = flags & 3u;
    let k = select(1.0, f32(flags >> 16u) / 256.0, mode == 1u);
    let px = pos + c * vec2f(size) * k;
    let device = u.screen_size * u.scale;
    let clip = vec2f(px.x / device.x * 2.0 - 1.0, 1.0 - px.y / device.y * 2.0);
    var o: VOut;
    o.pos = vec4f(clip, 0.0, 1.0);
    o.color = color;
    o.origin = uv;
    o.local = c * vec2f(size);
    o.clip_min = vec2f(clip_xy);
    o.clip_max = vec2f(clip_xy) + vec2f(clip_wh);
    o.mode = mode;
    o.clipped = select(0u, 1u, clip_wh.x != 0u || clip_wh.y != 0u);
    return o;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4f {
    // Both samples are taken before any discard (derivatives need uniform control flow).
    // Coverage bitmaps: the quad is pixel-aligned, so `local` hits texel centres: exact fetch.
    let texel = vec2i(in.origin) + vec2i(floor(in.local));
    let cov_bitmap = textureLoad(atlas, texel, 0).r;
    // Distance fields: bilinear sample, then a one-pixel-wide smoothstep around the edge value,
    // sized by the screen-space derivative so the edge stays crisp at any scale.
    let uv = (vec2f(in.origin) + in.local) / vec2f(textureDimensions(atlas));
    let d = textureSample(atlas, samp, uv).r;
    let w = max(fwidth(d) * 0.7, 0.0005);
    let cov_sdf = smoothstep(0.502 - w, 0.502 + w, d);
    if (in.clipped != 0u) {
        let p = in.pos.xy;
        if (p.x < in.clip_min.x || p.y < in.clip_min.y || p.x >= in.clip_max.x || p.y >= in.clip_max.y) {
            discard;
        }
    }
    let cov = select(cov_bitmap, cov_sdf, in.mode == 1u);
    let a = select(pow(cov, u.text_gamma), cov, u.text_gamma == 1.0);
    return vec4f(in.color.rgb, in.color.a * a);
}
