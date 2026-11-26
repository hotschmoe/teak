//! CLI canary: take two real readings a moment apart, print them, and build
//! one frame of the App from the second. Exits 1 when the OS backend came
//! back without the basics, so a gate that runs it checks the sampler.

const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");
const sys = @import("sys.zig");

fn nowMs(io: std.Io) u64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const sample = try gpa.create(sys.Sample);
    defer gpa.destroy(sample);

    if (sys.supported) {
        const sampler = try gpa.create(sys.Sampler);
        defer gpa.destroy(sampler);
        sampler.init();
        defer sampler.deinit();
        sampler.sample(nowMs(init.io), sample);
        try std.Io.sleep(init.io, .fromMilliseconds(400), .awake);
        sampler.sample(nowMs(init.io), sample);
    } else {
        std.debug.print("sysmon: no sampler for this OS, showing synthetic data\n", .{});
        sys.synthetic(30, sample);
    }

    const s = sample;
    std.debug.print("cpu: {s}, {d} logical processors, {d:.0} MHz, {d:.1}% busy\n", .{ s.cpuName(), s.n_cores, s.cpu_mhz, s.cpu_pct });
    std.debug.print("memory: {d} MiB total, {d} MiB available, {d} MiB cached, commit {d}/{d} MiB\n", .{
        s.mem_total >> 20, s.mem_available >> 20, s.mem_cached >> 20, s.commit_used >> 20, s.commit_limit >> 20,
    });
    std.debug.print("disk: read {d:.0} B/s, write {d:.0} B/s\n", .{ s.disk_read_bps, s.disk_write_bps });
    std.debug.print("network: rx {d:.0} B/s, tx {d:.0} B/s\n", .{ s.net_rx_bps, s.net_tx_bps });
    std.debug.print("processes: {d}, threads: {d}, uptime: {d} s, sensors: {d}\n", .{ s.n_procs, s.n_threads, s.uptime_s, s.n_sensors });
    var top: ?*const sys.Proc = null;
    for (s.procs[0..s.n_procs]) |*p| {
        if (top == null or p.cpu_pct > top.?.cpu_pct) top = p;
    }
    if (top) |p| std.debug.print("busiest: {s} (pid {d}) {d:.1}% cpu, {d} MiB\n", .{ p.name(), p.pid, p.cpu_pct, p.rss_bytes >> 20 });
    for (s.sensors[0..s.n_sensors]) |*t| std.debug.print("sensor: {s} {d:.1} C\n", .{ t.label(), t.celsius });

    var model = App.Model.init();
    App.update(&model, .{ .sample = sample });
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();
    cb.theme = App.themeFor(&model);
    App.view(&model, &cb);
    const frame_rects = try gpa.alloc(teak.Rect, cb.cmds.items.len);
    defer gpa.free(frame_rects);
    teak.LayoutEngine.doLayout(frame_rects, cb.cmds.items, 1100, 720, teak.monoMeasurer());
    std.debug.print("frame: {d} cmds\n", .{cb.cmds.items.len});

    if (!sample.plausible()) {
        std.debug.print("sysmon: implausible sample (cores, memory or processes missing)\n", .{});
        std.process.exit(1);
    }
}
