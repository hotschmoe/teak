//! Wrapper exposing the .wgsl files as comptime-embedded strings.
//! Exists so GPU backends (`src/gpu/*.zig`) can pull shader source via a
//! named module — @embedFile can't cross a module's package boundary
//! from inside src/, and keeping the .wgsl files at repo root (per the
//! file-struct spec) means they can't be embedded directly from there.

pub const quad_wgsl = @embedFile("quad.wgsl");
pub const textured_quad_wgsl = @embedFile("textured_quad.wgsl");
