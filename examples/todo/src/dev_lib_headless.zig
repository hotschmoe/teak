//! `libapp.so` for hot reload, headless backend (offscreen wgpu, controlled
//! over TEAK_CONTROL). Built by `zig build dev -Dbackend=headless`.
//! See docs/features/hot-reload.md.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

const Init = struct {
    pub fn host(gpa: std.mem.Allocator) !Host {
        return Host.init(gpa, 720, 600);
    }
    pub fn gpu(_: *Host) !Gpu {
        return Gpu.initOffscreen(720, 600, .{ .msaa = true });
    }
};

comptime {
    teak.dev.Plugin(App, Host, Gpu, Init).exportAll();
}
