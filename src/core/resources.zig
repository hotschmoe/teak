//! Declarative GPU resources (HARDLINE §2 escape hatch 8).
//!
//! An App may declare `pub fn resources(*const Model) []const Resource`:
//! a pure function listing the meshes, images and canvas geometries the
//! current Model needs on the GPU, each under an app-chosen `key` with a
//! content revision `rev`. `teak.run` owns the upload / release
//! bookkeeping (see `src/resources.zig`): it uploads a resource when its
//! (key, rev) is new, re-uploads when `rev` changes, and releases keys
//! that disappear from the list. `Cmd`s refer to resources by key
//! (`ImageCmd.handle`, `SceneCmd.mesh`, `CanvasPrimitive.geometry`); the
//! loop maps keys to backend handles right before the Gpu sees the draw
//! records, so view code never touches a handle.
//!
//! Like `Sub` and `Effect`, a `Resource` is plain data. Slices (`data`,
//! `rgba`) must stay valid for the frame they are listed in — typically
//! they point into Model-owned storage, or a per-frame arena.

const std = @import("std");
const scene = @import("scene.zig");
const cmd = @import("cmd.zig");

pub const Kind = enum { mesh, image, canvas_geometry };

pub const MeshResource = struct {
    /// App-chosen id, unique among meshes. 0 is reserved ("no mesh").
    key: u32,
    /// Content revision: bump to re-upload `data` under the same key.
    rev: u32,
    data: scene.MeshData,
};

pub const ImageResource = struct {
    /// App-chosen id, unique among images. 0 is reserved ("no image").
    key: u32,
    rev: u32,
    width: u32,
    height: u32,
    /// `width * height * 4` bytes of RGBA8.
    rgba: []const u8,
};

pub const CanvasGeometryResource = struct {
    /// App-chosen id, unique among canvas geometries. 0 is reserved.
    key: u32,
    /// Content revision. Bump to tessellate and re-upload `prims`.
    rev: u32,
    /// Baked into the vertex buffer. Pan and zoom do not re-tessellate;
    /// toggling this without a new `rev` leaves the old edges in place.
    antialias: bool = false,
    /// World-space primitives. `hline`, `vline`, `text` and a nested
    /// `.geometry` are skipped. The slice must stay valid for the frame
    /// the resource is listed (Model-owned, like an image's pixels).
    prims: []const cmd.CanvasPrimitive,
};

pub const Resource = union(Kind) {
    mesh: MeshResource,
    image: ImageResource,
    canvas_geometry: CanvasGeometryResource,

    pub fn kind(self: Resource) Kind {
        return std.meta.activeTag(self);
    }

    pub fn key(self: Resource) u32 {
        return switch (self) {
            inline else => |r| r.key,
        };
    }

    pub fn rev(self: Resource) u32 {
        return switch (self) {
            inline else => |r| r.rev,
        };
    }
};
