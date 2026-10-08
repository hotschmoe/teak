//! Linux surface provider: builds the wgpu surface source for whichever
//! backend `platform/linux.zig` is running on (Xlib window or Wayland
//! surface), so one Gpu type serves both. `handle` is that host's
//! `NativeHandle` tagged union (duck-typed: the gpu layer does not import
//! the platform layer).

const std = @import("std");
const core = @import("wgpu_core.zig");
const c = core.c;

pub fn createSurface(instance: c.WGPUInstance, handle: anytype) !c.WGPUSurface {
    var desc = std.mem.zeroes(c.WGPUSurfaceDescriptor);
    desc.label = core.wgpuStr("teak-surface");
    switch (handle) {
        .x11 => |h| {
            var src = std.mem.zeroes(c.WGPUSurfaceSourceXlibWindow);
            src.chain.sType = c.WGPUSType_SurfaceSourceXlibWindow;
            src.display = @ptrCast(h.display);
            src.window = h.window;
            desc.nextInChain = @ptrCast(&src.chain);
            return c.wgpuInstanceCreateSurface(instance, &desc) orelse error.SurfaceCreateFailed;
        },
        .wayland => |h| {
            var src = std.mem.zeroes(c.WGPUSurfaceSourceWaylandSurface);
            src.chain.sType = c.WGPUSType_SurfaceSourceWaylandSurface;
            src.display = @ptrCast(h.display);
            src.surface = @ptrCast(h.surface);
            desc.nextInChain = @ptrCast(&src.chain);
            return c.wgpuInstanceCreateSurface(instance, &desc) orelse error.SurfaceCreateFailed;
        },
    }
}
