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
const scene = @import("../core/scene.zig");
const MeshData = scene.MeshData;
const MeshHandle = scene.MeshHandle;
const SceneDraw = scene.SceneDraw;
const OverlaySplit = @import("../render/build.zig").OverlaySplit;

pub const ClearColor = [4]f32;
pub const FontSpec = text.FontSpec;
pub const TextureHandle = text.TextureHandle;
pub const TEXTURE_HANDLE_NONE = text.TEXTURE_HANDLE_NONE;
pub const TextDraw = text.TextDraw;

/// Options a backend's `initWithOptions` accepts (it also keeps a plain
/// `init(handle, w, h)` that behaves like `.{}`).
pub const InitOptions = struct {
    /// 4x multisampling of the main UI pass, so rotated quads and canvas
    /// triangles are antialiased. Costs one extra full-size colour target.
    /// Off by default: axis-aligned UI is pixel-exact without it.
    msaa: bool = false,
    /// 4x multisampling of offscreen 3D scene targets (see `renderScenes`).
    scene_msaa: bool = true,
    /// Device pixels per logical pixel. The UI is laid out in logical px and
    /// `init`/`resize` take the logical size, so the surface is
    /// `logical * scale` device px (a Host that already reports device px
    /// keeps the default 1). Text is rasterized at the physical size (true
    /// HiDPI), solids scale as vectors.
    scale: f32 = 1,
    /// Glyph-atlas page cap (1024x1024 R8 each, 1 MiB). Running out logs loudly
    /// and drops glyphs for that frame instead of growing without bound.
    max_atlas_pages: u8 = 8,
};

/// Comptime contract. A Gpu must expose these declarations. `init`
/// signatures vary per backend (the handle shape is platform-specific).
///
/// Surface extension (HARDLINE §4(d)): `uploadImage` / `uploadImages`
/// added for ImageCmd rendering. Image handles share `TextureHandle`'s
/// type but are interpreted by the *image* cache, not the text cache —
/// no per-handle discriminator needed because dispatch happens at the
/// uploadText / uploadImages call site.
/// Surface extension (HARDLINE §4(d)): `setOverlayStart(*Gpu, OverlaySplit)`
/// — optional; a backend that has it draws the overlay layer's solids,
/// images, scene composites and text after the base layer's (so an opaque
/// overlay hides base text). Backends without it draw by kind, as before.
///
/// Surface extension (HARDLINE §4(d)): the 3D scene block —
/// `uploadMesh` / `releaseMesh` / `renderScenes` — plus `releaseImage`.
/// All optional and checked only when declared; the three scene decls
/// must come together (a backend that renders scenes but cannot upload
/// meshes is useless). `run` only calls them when present.
///
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
        .{ .name = "uploadText", .sig = "fn(*Gpu, []const TextDraw) void" },
        .{ .name = "uploadImage", .sig = "fn(*Gpu, []const u8, u32, u32) TextureHandle" },
        .{ .name = "releaseImage", .sig = "fn(*Gpu, TextureHandle) void" },
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

    // Optional 3D scene extension: all-or-none, each a function.
    const scene_block = [_]GpuDecl{
        .{ .name = "uploadMesh", .sig = "fn(*Gpu, MeshData) MeshHandle" },
        .{ .name = "releaseMesh", .sig = "fn(*Gpu, MeshHandle) void" },
        .{ .name = "renderScenes", .sig = "fn(*Gpu, []const SceneDraw) void" },
    };
    comptime var present = 0;
    inline for (scene_block) |d| {
        if (@hasDecl(T, d.name)) {
            present += 1;
            if (@typeInfo(@TypeOf(@field(T, d.name))) != .@"fn")
                @compileError("Gpu '" ++ tn ++ "'." ++ d.name ++ " must be a function " ++
                    "(expected " ++ d.sig ++ ")");
        }
    }
    if (present != 0 and present != scene_block.len)
        @compileError("Gpu '" ++ tn ++ "' declares part of the scene extension; " ++
            "uploadMesh, releaseMesh and renderScenes come together");
    // Optional overlay layering: where the overlay layer starts in each
    // staged list. Called before the uploads of a frame.
    if (@hasDecl(T, "setOverlayStart") and @typeInfo(@TypeOf(T.setOverlayStart)) != .@"fn")
        @compileError("Gpu '" ++ tn ++ "'.setOverlayStart must be a function " ++
            "(expected fn(*Gpu, OverlaySplit) void)");
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
        pub fn releaseImage(_: *@This(), _: TextureHandle) void {}
    };
    comptime validateGpu(Stub);
}

test "validateGpu accepts the full scene extension" {
    const Stub = struct {
        pub fn deinit(_: *@This()) void {}
        pub fn resize(_: *@This(), _: u32, _: u32) void {}
        pub fn uploadVertices(_: *@This(), _: []const Vertex) void {}
        pub fn renderFrame(_: *@This(), _: ClearColor) void {}
        pub fn rasterizeText(_: *@This(), _: []const u8, _: FontSpec, _: [4]f32, _: u32, _: u32) TextureHandle {
            return TEXTURE_HANDLE_NONE;
        }
        pub fn uploadText(_: *@This(), _: []const TextDraw) void {}
        pub fn uploadImage(_: *@This(), _: []const u8, _: u32, _: u32) TextureHandle {
            return TEXTURE_HANDLE_NONE;
        }
        pub fn uploadImages(_: *@This(), _: []const ImageDraw) void {}
        pub fn releaseImage(_: *@This(), _: TextureHandle) void {}
        pub fn setOverlayStart(_: *@This(), _: OverlaySplit) void {}
        pub fn uploadMesh(_: *@This(), _: MeshData) MeshHandle {
            return scene.MESH_HANDLE_NONE;
        }
        pub fn releaseMesh(_: *@This(), _: MeshHandle) void {}
        pub fn renderScenes(_: *@This(), _: []const SceneDraw) void {}
    };
    comptime validateGpu(Stub);
}
