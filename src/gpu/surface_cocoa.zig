//! Metal-layer surface source for the wgpu backend — the macOS counterpart
//! to `surface_win32.zig` / `surface_xlib.zig`. Wraps the `CAMetalLayer` that
//! `platform/cocoa.zig`'s `nativeHandle` supplies in a `WGPUSurface`.
//!
//! `createSurface` takes `anytype` so the Cocoa Host's nominally distinct
//! `NativeHandle` coerces without the platform layer importing the gpu layer.

const std = @import("std");
const core = @import("wgpu_core.zig");
const c = core.c;

/// Documents the handle this provider consumes: the `CAMetalLayer*`.
pub const Handle = struct {
    layer: *anyopaque,
};

pub fn createSurface(instance: c.WGPUInstance, handle: anytype) !c.WGPUSurface {
    var metal_source = std.mem.zeroes(c.WGPUSurfaceSourceMetalLayer);
    metal_source.chain.sType = c.WGPUSType_SurfaceSourceMetalLayer;
    metal_source.layer = @ptrCast(handle.layer);

    var surface_desc = std.mem.zeroes(c.WGPUSurfaceDescriptor);
    surface_desc.nextInChain = @ptrCast(&metal_source.chain);
    surface_desc.label = core.wgpuStr("teak-surface");
    return c.wgpuInstanceCreateSurface(instance, &surface_desc) orelse error.SurfaceCreateFailed;
}
