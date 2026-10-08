//! macOS + wgpu-native (Metal) GPU backend (the macOS stitch).
//!
//! Binds the shared wgpu core (`wgpu_core.zig`) to the Metal-layer surface
//! (`surface_cocoa.zig`) and the stb_truetype glyph rasterizer (the
//! `teak-text` module). The parallel stitches are `native.zig` (Windows) and
//! `native_linux.zig`. The build's `linkNativeWgpu` selects this file for
//! macOS targets and exposes it under the `teak-gpu-native` import.

const teak = @import("teak");
const wgpu_core = @import("wgpu_core.zig");
const surface_cocoa = @import("surface_cocoa.zig");
const text = @import("teak-text");

pub const Gpu = wgpu_core.Gpu(surface_cocoa, text.StbttRasterizer);

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

comptime {
    teak.validateGpu(Gpu);
}
