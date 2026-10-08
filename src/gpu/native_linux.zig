//! Linux + wgpu-native GPU backend (the Linux stitch), for the X11 and Wayland hosts.
//!
//! Binds the shared wgpu core (`wgpu_core.zig`) to the Xlib surface
//! (`surface_linux.zig`) and the stb_truetype glyph rasterizer
//! (`raster.StbttRasterizer`, the `teak-text` module). The parallel
//! Windows stitch is `native.zig` (HWND surface + GDI rasterizer). The
//! build's `linkNativeWgpu` selects this file for Linux targets and
//! exposes it under the `teak-gpu-native` import.

const teak = @import("teak");
const wgpu_core = @import("wgpu_core.zig");
const surface_linux = @import("surface_linux.zig");
const text = @import("teak-text");

pub const Gpu = wgpu_core.Gpu(surface_linux, text.StbttRasterizer);

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

comptime {
    teak.validateGpu(Gpu);
}
