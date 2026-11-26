//! Headless screenshot (no display):
//!
//!   zig build shot -- out.png [--page performance|processes|sensors]
//!                             [--device cpu|memory|disk|network] [--cores] [--live]
//!
//! By default the App is fed sixty synthetic samples, so the picture is the
//! same on every machine. --live feeds it real readings from this machine.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");
const sys = @import("sys.zig");

const Opts = struct {
    path: []const u8 = "sysmon.png",
    page: App.Page = .performance,
    device: App.Device = .cpu,
    cores: bool = false,
    live: bool = false,
};

fn parseArgs(init: std.process.Init) Opts {
    var o: Opts = .{};
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return o;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value: []const u8 = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--page")) {
            o.page = std.meta.stringToEnum(App.Page, value) orelse o.page;
            i += 1;
        } else if (std.mem.eql(u8, a, "--device")) {
            o.device = std.meta.stringToEnum(App.Device, value) orelse o.device;
            i += 1;
        } else if (std.mem.eql(u8, a, "--cores")) {
            o.cores = true;
        } else if (std.mem.eql(u8, a, "--live")) {
            o.live = true;
        } else o.path = a;
    }
    return o;
}

fn nowMs(io: std.Io) u64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

pub fn main(init: std.process.Init) !void {
    const o = parseArgs(init);
    const gpa = init.gpa;
    const w: u32 = 1100;
    const h: u32 = 720;
    var host = try Host.init(gpa, w, h);
    defer host.deinit();
    var gpu = try Gpu.initOffscreen(w, h, .{ .msaa = false });
    defer gpu.deinit();
    var rt = try teak.Runtime(App, Host, Gpu).init(gpa, &host, &gpu, .{ .idle_skip = false });
    defer rt.deinit();

    rt.post(.{ .page = o.page });
    rt.post(.{ .device = o.device });
    rt.post(.{ .per_core = o.cores });

    const sample = try gpa.create(sys.Sample);
    defer gpa.destroy(sample);
    if (o.live and sys.supported) {
        const sampler = try gpa.create(sys.Sampler);
        defer gpa.destroy(sampler);
        sampler.init();
        defer sampler.deinit();
        for (0..12) |_| {
            sampler.sample(nowMs(init.io), sample);
            rt.post(.{ .sample = sample });
            try rt.frame();
            try std.Io.sleep(init.io, .fromMilliseconds(250), .awake);
        }
    } else {
        for (0..App.history_len) |tick| {
            sys.synthetic(@intCast(tick), sample);
            rt.post(.{ .sample = sample });
            try rt.frame();
        }
    }
    for (0..4) |_| try rt.frame();

    try teak.headless.writeFramePng(&gpu, gpa, o.path);
    std.debug.print("wrote {s} ({s}, {d} samples)\n", .{ o.path, if (o.live and sys.supported) "live" else "synthetic", rt.model.data.n_samples });
}
