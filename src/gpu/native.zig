//! Win32 + wgpu-native GPU backend (the Windows stitch).
//!
//! Binds the shared wgpu core (`wgpu_core.zig`) to the Win32 HWND surface
//! (`surface_win32.zig`) and the GDI glyph rasterizer (`raster_gdi.zig`).
//! Linux uses the parallel `native_linux.zig` stitch (Xlib surface +
//! stb_truetype rasterizer). The build's `linkNativeWgpu` picks the right
//! stitch by target OS and exposes it under the `teak-gpu-native` import.
//!
//! Consumer responsibility: add wgpu-native as a dependency and wire the
//! include + library paths (handled by `teak.linkNativeWgpu`). Teak's
//! library build never links wgpu.

const teak = @import("teak");
const wgpu_core = @import("wgpu_core.zig");
const surface_win32 = @import("surface_win32.zig");
const raster_gdi = @import("raster_gdi.zig");

pub const Gpu = wgpu_core.Gpu(surface_win32, raster_gdi.GdiRasterizer);

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

comptime {
    teak.validateGpu(Gpu);
}
