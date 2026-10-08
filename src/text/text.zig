//! `teak-text`: the shared native text module (face table, shaper, measurer,
//! rasterizer). Imported by the Host (measurement) and the Gpu (rasterization)
//! so layout and rendering cannot disagree on metrics.

pub const face = @import("face.zig");
pub const shaper = @import("shaper.zig");
pub const raster = @import("raster.zig");
const measure_mod = @import("measure.zig");

pub const Font = face.Font;
pub const registerFace = face.registerFace;
pub const releaseFaces = face.releaseFaces;
pub const faceFor = face.faceFor;
pub const SimpleShaper = shaper;
pub const measure = measure_mod.measure;
pub const width = measure_mod.width;
pub const GlyphBitmap = raster.GlyphBitmap;
pub const StbttRasterizer = raster.StbttRasterizer;

/// True when this build shapes complex scripts with HarfBuzz.
pub const has_harfbuzz = @import("text_options").harfbuzz;

comptime {
    // wasm32-freestanding has no libc: stb gets malloc/libm from this shim.
    if (@import("builtin").os.tag == .freestanding) _ = @import("stb_wasm_shim.zig");
}

test {
    _ = @import("face.zig");
    _ = @import("shaper.zig");
    _ = @import("measure.zig");
    _ = @import("raster.zig");
    if (has_harfbuzz) _ = @import("hb_shaper_test.zig");
}
