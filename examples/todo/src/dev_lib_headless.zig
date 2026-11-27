//! `libapp.so` for hot reload, headless backend (offscreen wgpu, controlled
//! over TEAK_CONTROL). Built by `zig build dev -Dbackend=headless`.
//! See docs/features/hot-reload.md.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

const Init = struct {
    pub fn host(gpa: std.mem.Allocator, options: teak.Options) !Host {
        return Host.init(gpa, 720, 600, options);
    }
    pub fn gpu(h: *Host, options: teak.Options) !Gpu {
        return Gpu.initOffscreen(h.nativeHandle(), 720, 600, .{
            .msaa = true,
            .gpu_fallback = options.gpu_fallback,
        });
    }
};

comptime {
    teak.dev.Plugin(App, Host, Gpu, Init).exportAll();
}
