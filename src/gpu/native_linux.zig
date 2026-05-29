//! Linux + wgpu-native GPU backend (the Linux stitch).
//!
//! Binds the shared wgpu core (`wgpu_core.zig`) to the Xlib surface
//! (`surface_xlib.zig`) and the stb_truetype glyph rasterizer
//! (`text_stbtt.StbttRasterizer`, the `teak-text` module). The parallel
//! Windows stitch is `native.zig` (HWND surface + GDI rasterizer). The
//! build's `linkNativeWgpu` selects this file for Linux targets and
//! exposes it under the `teak-gpu-native` import.

const teak = @import("teak");
const wgpu_core = @import("wgpu_core.zig");
const surface_xlib = @import("surface_xlib.zig");
const text = @import("teak-text");

pub const Gpu = wgpu_core.Gpu(surface_xlib, text.StbttRasterizer);

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

comptime {
    teak.validateGpu(Gpu);
}
