//! Declarative GPU resources (HARDLINE §2 escape hatch 8).
//!
//! An App may declare `pub fn resources(*const Model) []const Resource`:
//! a pure function listing the meshes and images the current Model needs
//! on the GPU, each under an app-chosen `key` with a content revision
//! `rev`. `teak.run` owns the upload / release bookkeeping (see
//! `src/resources.zig`): it uploads a resource when its (key, rev) is new,
//! re-uploads when `rev` changes, and releases keys that disappear from
//! the list. `Cmd`s refer to resources by key (`ImageCmd.handle`,
//! `SceneCmd.mesh`); the loop maps keys to backend handles right before
//! the Gpu sees the draw records, so view code never touches a handle.
//!
//! Like `Sub` and `Effect`, a `Resource` is plain data. Slices (`data`,
//! `rgba`) must stay valid for the frame they are listed in — typically
//! they point into Model-owned storage, or a per-frame arena.

const std = @import("std");
const scene = @import("scene.zig");

pub const Kind = enum { mesh, image };

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

pub const Resource = union(Kind) {
    mesh: MeshResource,
    image: ImageResource,

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

test "Resource accessors" {
    const r: Resource = .{ .image = .{ .key = 4, .rev = 2, .width = 1, .height = 1, .rgba = &.{ 0, 0, 0, 0 } } };
    try std.testing.expectEqual(Kind.image, r.kind());
    try std.testing.expectEqual(@as(u32, 4), r.key());
    try std.testing.expectEqual(@as(u32, 2), r.rev());
    const m: Resource = .{ .mesh = .{ .key = 9, .rev = 1, .data = .{} } };
    try std.testing.expectEqual(Kind.mesh, m.kind());
    try std.testing.expectEqual(@as(u32, 9), m.key());
}
