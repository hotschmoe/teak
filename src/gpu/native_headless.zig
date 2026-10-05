//! Headless native GPU stitch: the wgpu core with no surface provider and
//! the stb_truetype rasterizer, for `Gpu.initOffscreen` runs (agent
//! screenshots, CI) on a machine without a display. `teak.linkHeadless`
//! exposes it under the import name `teak-gpu-headless`; pair it with
//! `teak-platform-headless` (`platform/headless.zig`).

const teak = @import("teak");
const wgpu_core = @import("wgpu_core.zig");
const text = @import("teak-text");

/// There is no window system: asking for a surface is an error, so only
/// `initOffscreen` (or `initFromDevice(.., null, ..)`) builds this Gpu.
const NoSurface = struct {
    pub const Handle = void;
    pub fn createSurface(_: anytype, _: anytype) !@import("wgpu_c.zig").c.WGPUSurface {
        return error.NoWindowSystem;
    }
};

pub const Gpu = wgpu_core.Gpu(NoSurface, text.StbttRasterizer);

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

comptime {
    teak.validateGpu(Gpu);
}
