//! Win32 HWND surface source for the wgpu backend.
//!
//! One of the two pluggable "surface providers" consumed by
//! `wgpu_core.Gpu(Surface, Rasterizer)`. Exposes the platform-specific
//! `Handle` shape (matches `platform/win32.zig`'s `NativeHandle`) and the
//! `createSurface` that wraps it in a `WGPUSurface`. The Xlib counterpart
//! lives in `surface_xlib.zig`.
//!
//! `c` is re-imported from `wgpu_core.zig` so every provider shares the
//! single `@cImport` translation unit — without that, each file's
//! `@cImport` would mint a *distinct* `WGPUSurface` type and the seam
//! would not typecheck.

const std = @import("std");
const core = @import("wgpu_core.zig");
const c = core.c;

/// Documents the native window handle this provider consumes. Field
/// types are `*anyopaque` so this file carries no Win32 import;
/// `platform/win32.zig` produces a structurally identical `NativeHandle`.
/// `createSurface` takes `anytype` (duck-typed against this shape) so the
/// Host's nominally distinct struct coerces without cross-layer imports.
pub const Handle = struct {
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

pub fn createSurface(instance: c.WGPUInstance, handle: anytype) !c.WGPUSurface {
    var hwnd_source = std.mem.zeroes(c.WGPUSurfaceSourceWindowsHWND);
    hwnd_source.chain.sType = c.WGPUSType_SurfaceSourceWindowsHWND;
    hwnd_source.hinstance = @ptrCast(handle.hinstance);
    hwnd_source.hwnd = @ptrCast(handle.hwnd);

    var surface_desc = std.mem.zeroes(c.WGPUSurfaceDescriptor);
    surface_desc.nextInChain = @ptrCast(&hwnd_source.chain);
    surface_desc.label = core.wgpuStr("teak-surface");
    return c.wgpuInstanceCreateSurface(instance, &surface_desc) orelse error.SurfaceCreateFailed;
}
