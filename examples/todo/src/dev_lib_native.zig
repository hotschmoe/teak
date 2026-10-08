//! `libapp.so` for hot reload, native window backend (X11 / Win32 + wgpu).
//! Built by `zig build dev`. See docs/features/hot-reload.md.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

const Init = struct {
    pub fn host(_: std.mem.Allocator) !platform.Host {
        return platform.Host.init("Teak — Todo (dev)", 720, 600);
    }
    pub fn gpu(h: *platform.Host) !gpu_native.Gpu {
        return gpu_native.Gpu.init(h.nativeHandle(), 720, 600);
    }
};

comptime {
    teak.dev.Plugin(App, platform.Host, gpu_native.Gpu, Init).exportAll();
}
