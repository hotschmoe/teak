//! Native entry. This file owns the loop instead of calling teak.run because
//! it also owns the sampler: once a second it reads the machine and posts the
//! reading to the Runtime as a Msg, then lets the Host sleep until input or
//! the next reading is due.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");
const sys = @import("sys.zig");

const Host = platform.Host;
const Gpu = gpu_native.Gpu;

pub fn main(init: std.process.Init) !void {
    const options = try teak.options_from_environment(init, .{ .app_name = "sysmon" });
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try Host.init("System Monitor", 1100, 720, options);
    defer host.deinit();
    var gpu = try Gpu.initWithOptions(host.nativeHandle(), 1100, 720, .{ .gpu_fallback = options.gpu_fallback });
    defer gpu.deinit();

    var rt = try teak.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, options);
    defer rt.deinit();

    const sampler = try gpa.create(sys.Sampler);
    defer gpa.destroy(sampler);
    sampler.init();
    defer sampler.deinit();
    const sample = try gpa.create(sys.Sample);
    defer gpa.destroy(sample);

    var due_ms: u64 = 0;
    while (!host.shouldClose() and !rt.exitRequested()) {
        const now = host.nowMs();
        if (now >= due_ms) {
            if (sys.supported) sampler.sample(now, sample) else sys.synthetic(@intCast(now / App.sample_interval_ms), sample);
            rt.post(.{ .sample = sample });
            due_ms = now + App.sample_interval_ms;
        }
        try rt.frame();
        if (comptime @hasDecl(Host, "waitEvents")) {
            if (rt.quiet and !host.shouldClose()) {
                const until_sample: u32 = @intCast(@min(due_ms -| host.nowMs(), App.sample_interval_ms));
                host.waitEvents(@min(rt.idleTimeoutMs(), until_sample));
            }
        }
    }
}
