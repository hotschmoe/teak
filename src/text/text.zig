//! `teak-text`: the shared native text module (face table, shaper, measurer,
//! rasterizer). Imported by the Host (measurement) and the Gpu (rasterization)
//! so layout and rendering cannot disagree on metrics. Every function takes the
//! `TextState` the Host owns and lends to the Gpu; there is no module state.

pub const face = @import("face.zig");
pub const shaper = @import("shaper.zig");
pub const raster = @import("raster.zig");
pub const fallback = @import("fallback.zig");
const measure_mod = @import("measure.zig");
const state_mod = @import("text_state.zig");

pub const TextState = state_mod.TextState;
pub const Limits = state_mod.Limits;
pub const Report = state_mod.Report;
pub const Font = face.Font;
pub const registerFace = face.registerFace;
pub const releaseFaces = face.releaseFaces;
pub const registerFallbackFace = fallback.registerFallbackFace;
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
