//! Gpu interface: the only layer allowed to touch wgpu-native or
//! zunk.web.gpu. Everything above (render/, layout/, input/, core/)
//! compiles wasm32-freestanding-clean.
//!
//! Concrete backends live in sibling files (native.zig, web.zig, ...).
//! Comptime-parameterized — the example picks a backend at build time;
//! there is no runtime dispatch.

const std = @import("std");

const Vertex = @import("../render/vertex.zig").Vertex;

pub const ClearColor = [4]f32;

/// Comptime contract. A Gpu must expose these declarations. `init`
/// signatures vary per backend (the handle shape is platform-specific).
pub fn validateGpu(comptime T: type) void {
    const required = [_][]const u8{ "deinit", "resize", "uploadVertices", "renderFrame" };
    inline for (required) |name| {
        if (!@hasDecl(T, name)) {
            @compileError("Gpu '" ++ @typeName(T) ++ "' is missing declaration '" ++ name ++ "'");
        }
    }
}

test "validateGpu accepts a minimal shape" {
    const Stub = struct {
        pub fn init() void {}
        pub fn deinit(_: *@This()) void {}
        pub fn resize(_: *@This(), _: u32, _: u32) void {}
        pub fn uploadVertices(_: *@This(), _: []const Vertex) void {}
        pub fn renderFrame(_: *@This(), _: ClearColor) void {}
    };
    comptime validateGpu(Stub);
}
