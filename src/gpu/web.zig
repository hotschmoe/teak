//! Web (WebGPU via zunk) GPU stub. Real implementation is blocked on
//! zunk's `zunk.web.gpu` coverage audit (see `tasks.md` §6). Declares the
//! interface-satisfying shape; every entry point panics until the audit
//! confirms wgpu call parity and the async adapter/device acquisition
//! pattern is understood.
//!
//! When filled in, this file must avoid blocking calls anywhere — zunk's
//! bundle-size story depends on no hidden heap growth and the adapter/
//! device handshake yields through multiple rAF ticks rather than
//! spinning.

const std = @import("std");
const teak = @import("teak");

const Vertex = teak.Vertex;

pub const ClearColor = teak.ClearColor;

pub const Gpu = struct {
    pub fn init() !Gpu {
        @panic("gpu/web.zig: not implemented — see tasks.md §6 zunk audit");
    }

    pub fn deinit(_: *Gpu) void {}

    pub fn resize(_: *Gpu, _: u32, _: u32) void {
        @panic("gpu/web.zig: resize not implemented");
    }

    pub fn uploadVertices(_: *Gpu, _: []const Vertex) void {
        @panic("gpu/web.zig: uploadVertices not implemented");
    }

    pub fn renderFrame(_: *Gpu, _: ClearColor) void {
        @panic("gpu/web.zig: renderFrame not implemented");
    }
};

comptime {
    teak.validateGpu(Gpu);
}
