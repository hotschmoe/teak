struct VertexOutput {
    @builtin(position) pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
};

struct Uniforms {
    screen_size: vec2f,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(0) @binding(1) var tex: texture_2d<f32>;
@group(0) @binding(2) var samp: sampler;

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
    return VertexOutput(vec4f(clip, 0.0, 1.0), color, uv);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // Texture is BGRA-with-alpha-as-coverage. Sample alpha, modulate
    // the quad color by it. RGB channels of the texture are ignored
    // because the rasterizer stamps full-intensity RGB everywhere and
    // puts the grayscale coverage in alpha.
    let t = textureSample(tex, samp, in.uv);
    return vec4f(in.color.rgb, in.color.a * t.a);
}
