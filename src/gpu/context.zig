//! Gpu interface: the only layer allowed to touch wgpu-native or
//! zunk.web.gpu. Everything above (render/, layout/, input/, core/)
//! compiles wasm32-freestanding-clean.
//!
//! Concrete backends live in sibling files (native.zig, web.zig, ...).
//! Comptime-parameterized — the example picks a backend at build time;
//! there is no runtime dispatch.

const std = @import("std");

const Vertex = @import("../render/vertex.zig").Vertex;
const text = @import("../core/text.zig");
const ImageDraw = @import("../render/build.zig").ImageDraw;

pub const ClearColor = [4]f32;
pub const FontSpec = text.FontSpec;
pub const TextureHandle = text.TextureHandle;
pub const TEXTURE_HANDLE_NONE = text.TEXTURE_HANDLE_NONE;
pub const TextDraw = text.TextDraw;

/// Comptime contract. A Gpu must expose these declarations. `init`
/// signatures vary per backend (the handle shape is platform-specific).
///
/// Surface extension (HARDLINE §4(d)): `uploadImage` / `uploadImages`
/// added for ImageCmd rendering. Image handles share `TextureHandle`'s
/// type but are interpreted by the *image* cache, not the text cache —
/// no per-handle discriminator needed because dispatch happens at the
/// uploadText / uploadImages call site.
/// One required Gpu declaration + the signature the error quotes when it
/// is missing or not a function. Like `validateHost`, this checks
/// presence + callability and names the expected shape; exact parameter
/// types are left unpinned because the handle shapes are backend-specific.
const GpuDecl = struct { name: []const u8, sig: []const u8 };

pub fn validateGpu(comptime T: type) void {
    const tn = @typeName(T);
    const required = [_]GpuDecl{
        .{ .name = "deinit", .sig = "fn(*Gpu) void" },
        .{ .name = "resize", .sig = "fn(*Gpu, u32, u32) void" },
        .{ .name = "uploadVertices", .sig = "fn(*Gpu, []const Vertex) void" },
        .{ .name = "renderFrame", .sig = "fn(*Gpu, ClearColor) void" },
        .{ .name = "rasterizeText", .sig = "fn(*Gpu, []const u8, FontSpec, [4]f32, u32, u32) TextureHandle" },
        .{ .name = "uploadText", .sig = "fn(*Gpu, []const TextDraw) void" },
        .{ .name = "uploadImage", .sig = "fn(*Gpu, []const u8, u32, u32) TextureHandle" },
        .{ .name = "uploadImages", .sig = "fn(*Gpu, []const ImageDraw) void" },
    };
    inline for (required) |d| {
        if (!@hasDecl(T, d.name))
            @compileError("Gpu '" ++ tn ++ "' is missing declaration '" ++ d.name ++
                "' (expected " ++ d.sig ++ ")");
        if (@typeInfo(@TypeOf(@field(T, d.name))) != .@"fn")
            @compileError("Gpu '" ++ tn ++ "'." ++ d.name ++ " must be a function " ++
                "(expected " ++ d.sig ++ ")");
    }
}

test "validateGpu accepts a minimal shape" {
    const Stub = struct {
        pub fn init() void {}
        pub fn deinit(_: *@This()) void {}
        pub fn resize(_: *@This(), _: u32, _: u32) void {}
        pub fn uploadVertices(_: *@This(), _: []const Vertex) void {}
        pub fn renderFrame(_: *@This(), _: ClearColor) void {}
        pub fn rasterizeText(
            _: *@This(),
            _: []const u8,
            _: FontSpec,
            _: [4]f32,
            _: u32,
            _: u32,
        ) TextureHandle {
            return TEXTURE_HANDLE_NONE;
        }
        pub fn uploadText(_: *@This(), _: []const TextDraw) void {}
        /// Upload an RGBA8 image. `bytes` is `width * height * 4` bytes,
        /// premultiplied or not — the shader multiplies by tint then
        /// outputs the result; the host picks blending. Returns an
        /// opaque handle the app stashes in `ImageCmd.handle`.
        pub fn uploadImage(_: *@This(), _: []const u8, _: u32, _: u32) TextureHandle {
            return TEXTURE_HANDLE_NONE;
        }
        /// Per-frame counterpart to `uploadText`. Walks ImageDraws and
        /// records a draw entry per visible image.
        pub fn uploadImages(_: *@This(), _: []const ImageDraw) void {}
    };
    comptime validateGpu(Stub);
}
