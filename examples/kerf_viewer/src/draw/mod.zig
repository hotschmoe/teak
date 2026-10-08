//! Kerf drawing pipeline (ported from the archived Kerf teak app): IR parser,
//! stroke font, tessellator, pick. Pure Zig; feeds a teak canvas triangle batch.
pub const ir = @import("ir.zig");
pub const geom = @import("geom.zig");
pub const font = @import("font.zig");
pub const tess = @import("tess.zig");
pub const pick = @import("pick.zig");
pub const jv = @import("jv.zig");

test {
    _ = ir;
    _ = geom;
    _ = font;
    _ = tess;
    _ = pick;
    _ = jv;
}
