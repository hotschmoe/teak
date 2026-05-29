//! Xlib `Window` surface source for the wgpu backend — the Linux
//! counterpart to `surface_win32.zig`. Wraps an X11 `Display*` + `Window`
//! (supplied by `platform/x11.zig`'s `nativeHandle`) in a `WGPUSurface`.
//!
//! `c` is re-imported from `wgpu_core.zig` so the `WGPUSurface` type has
//! one identity across the seam. `createSurface` takes `anytype` so the
//! X11 Host's nominally distinct `NativeHandle` coerces without the
//! platform layer importing the gpu layer.

const std = @import("std");
const core = @import("wgpu_core.zig");
const c = core.c;

/// Documents the handle this provider consumes: an opaque X11 `Display*`
/// and the `Window` XID (`unsigned long`, widened to u64).
pub const Handle = struct {
    display: *anyopaque,
    window: u64,
};

pub fn createSurface(instance: c.WGPUInstance, handle: anytype) !c.WGPUSurface {
    var xlib_source = std.mem.zeroes(c.WGPUSurfaceSourceXlibWindow);
    xlib_source.chain.sType = c.WGPUSType_SurfaceSourceXlibWindow;
    xlib_source.display = @ptrCast(handle.display);
    xlib_source.window = handle.window;

    var surface_desc = std.mem.zeroes(c.WGPUSurfaceDescriptor);
    surface_desc.nextInChain = @ptrCast(&xlib_source.chain);
    surface_desc.label = core.wgpuStr("teak-surface");
    return c.wgpuInstanceCreateSurface(instance, &surface_desc) orelse error.SurfaceCreateFailed;
}
