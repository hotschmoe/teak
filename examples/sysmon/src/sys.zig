//! What the monitor measures, as plain data. A backend (sys_linux.zig,
//! sys_windows.zig) fills the instantaneous fields of a Sample and the
//! cumulative Counters; Sampler turns two readings into rates.

const std = @import("std");
const builtin = @import("builtin");

pub const max_cores = 256;
pub const max_procs = 1024;
pub const max_sensors = 32;

pub const backend = switch (builtin.os.tag) {
    .linux => @import("sys_linux.zig"),
    .windows => @import("sys_windows.zig"),
    else => @import("sys_none.zig"),
};

pub const supported = builtin.os.tag == .linux or builtin.os.tag == .windows;

pub const Proc = struct {
    pid: u32 = 0,
    threads: u32 = 0,
    rss_bytes: u64 = 0,
    /// Cumulative CPU time in the backend's unit (the unit of Counters.core_total).
    cpu_time: u64 = 0,
    /// Share of the whole machine since the previous sample, 0..100.
    cpu_pct: f32 = 0,
    name_len: u8 = 0,
    name_buf: [39]u8 = undefined,

    pub fn name(p: *const Proc) []const u8 {
        return p.name_buf[0..p.name_len];
    }

    pub fn setName(p: *Proc, s: []const u8) void {
        p.name_len = copyUtf8(&p.name_buf, s);
    }
};

pub const Sensor = struct {
    celsius: f32 = 0,
    label_len: u8 = 0,
    label_buf: [47]u8 = undefined,

    pub fn label(s: *const Sensor) []const u8 {
        return s.label_buf[0..s.label_len];
    }
};

pub const Counters = struct {
    core_busy: [max_cores]u64 = @splat(0),
    core_total: [max_cores]u64 = @splat(0),
    disk_read_bytes: u64 = 0,
    disk_write_bytes: u64 = 0,
    net_rx_bytes: u64 = 0,
    net_tx_bytes: u64 = 0,
    n_disks: u32 = 0,
    n_adapters: u32 = 0,
};

pub const Sample = struct {
    cpu_name_len: u8 = 0,
    cpu_name_buf: [79]u8 = undefined,
    n_cores: u32 = 0,
    cpu_mhz: f32 = 0,
    uptime_s: u64 = 0,
    n_threads: u32 = 0,

    /// False on a sampler's first reading: there is no interval to take a rate over yet.
    rates_valid: bool = false,
    cpu_pct: f32 = 0,
    core_pct: [max_cores]f32 = @splat(0),

    mem_total: u64 = 0,
    mem_available: u64 = 0,
    mem_cached: u64 = 0,
    commit_used: u64 = 0,
    commit_limit: u64 = 0,
    swap_total: u64 = 0,
    swap_used: u64 = 0,

    disk_read_bps: f32 = 0,
    disk_write_bps: f32 = 0,
    net_rx_bps: f32 = 0,
    net_tx_bps: f32 = 0,

    n_sensors: u32 = 0,
    sensors: [max_sensors]Sensor = undefined,

    /// Sorted by pid, so a row keeps its index while the process set is unchanged.
    n_procs: u32 = 0,
    procs: [max_procs]Proc = undefined,

    pub fn cpuName(s: *const Sample) []const u8 {
        return s.cpu_name_buf[0..s.cpu_name_len];
    }

    pub fn setCpuName(s: *Sample, text: []const u8) void {
        s.cpu_name_len = copyUtf8(&s.cpu_name_buf, std.mem.trim(u8, text, " \t\r\n\x00"));
    }

    pub fn memUsed(s: *const Sample) u64 {
        return s.mem_total -| s.mem_available;
    }

    pub fn findPid(s: *const Sample, pid: u32) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = s.n_procs;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s.procs[mid].pid < pid) lo = mid + 1 else hi = mid;
        }
        return if (lo < s.n_procs and s.procs[lo].pid == pid) lo else null;
    }

    /// False when a backend came back without the basics: the canary's verdict.
    pub fn plausible(s: *const Sample) bool {
        return s.n_cores > 0 and s.mem_total > 0 and s.mem_available <= s.mem_total and s.n_procs > 0;
    }
};

/// Copy as much of `src` as fits without splitting a UTF-8 sequence.
pub fn copyUtf8(dst: []u8, src: []const u8) u8 {
    var n: usize = @min(dst.len, src.len, 255);
    while (n > 0 and n < src.len and (src[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

const PrevProc = struct { pid: u32, cpu_time: u64 };

/// Owns the backend's handles and the previous reading. About 100 KB: keep it off the stack.
pub const Sampler = struct {
    state: backend.State,
    prev: Counters = .{},
    cur: Counters = .{},
    prev_procs: [max_procs]PrevProc = undefined,
    n_prev_procs: u32 = 0,
    prev_ms: u64 = 0,
    primed: bool = false,

    pub fn init(self: *Sampler) void {
        self.* = .{ .state = undefined };
        self.state.init();
    }

    pub fn deinit(self: *Sampler) void {
        self.state.deinit();
    }

    /// Fill `out` with the machine's state at `now_ms` (any monotonic clock).
    /// Rates cover the time since the previous call and are zero on the first.
    pub fn sample(self: *Sampler, now_ms: u64, out: *Sample) void {
        out.* = .{};
        self.cur = .{};
        self.state.read(out, &self.cur);
        std.debug.assert(out.n_cores <= max_cores);
        std.debug.assert(out.n_procs <= max_procs);
        std.debug.assert(out.n_sensors <= max_sensors);
        std.sort.pdq(Proc, out.procs[0..out.n_procs], {}, pidLess);

        const elapsed_ms = now_ms -| self.prev_ms;
        if (self.primed and elapsed_ms > 0) {
            const secs = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;
            out.rates_valid = true;
            var busy_sum: u64 = 0;
            var total_sum: u64 = 0;
            for (0..out.n_cores) |i| {
                const busy = self.cur.core_busy[i] -| self.prev.core_busy[i];
                const total = self.cur.core_total[i] -| self.prev.core_total[i];
                out.core_pct[i] = percent(busy, total);
                busy_sum += busy;
                total_sum += total;
            }
            out.cpu_pct = percent(busy_sum, total_sum);
            out.disk_read_bps = rate(self.cur.disk_read_bytes, self.prev.disk_read_bytes, secs);
            out.disk_write_bps = rate(self.cur.disk_write_bytes, self.prev.disk_write_bytes, secs);
            out.net_rx_bps = rate(self.cur.net_rx_bytes, self.prev.net_rx_bytes, secs);
            out.net_tx_bps = rate(self.cur.net_tx_bytes, self.prev.net_tx_bytes, secs);
            for (out.procs[0..out.n_procs]) |*p| {
                const before = self.prevCpuTime(p.pid) orelse continue;
                p.cpu_pct = percent(p.cpu_time -| before, total_sum);
            }
        }

        self.prev = self.cur;
        self.prev_ms = now_ms;
        self.n_prev_procs = out.n_procs;
        for (out.procs[0..out.n_procs], 0..) |p, i| self.prev_procs[i] = .{ .pid = p.pid, .cpu_time = p.cpu_time };
        self.primed = true;
    }

    fn prevCpuTime(self: *const Sampler, pid: u32) ?u64 {
        var lo: u32 = 0;
        var hi: u32 = self.n_prev_procs;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.prev_procs[mid].pid < pid) lo = mid + 1 else hi = mid;
        }
        return if (lo < self.n_prev_procs and self.prev_procs[lo].pid == pid) self.prev_procs[lo].cpu_time else null;
    }
};

fn pidLess(_: void, a: Proc, b: Proc) bool {
    return a.pid < b.pid;
}

fn percent(part: u64, whole: u64) f32 {
    if (whole == 0) return 0;
    return @min(100.0, 100.0 * @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(whole)));
}

fn rate(now: u64, before: u64, secs: f32) f32 {
    return @as(f32, @floatFromInt(now -| before)) / secs;
}

const fake_names = [_][]const u8{
    "compositor", "terminal", "editor",          "browser",      "browser-gpu",     "browser-tab",
    "indexer",    "zig",      "language-server", "audio-daemon", "network-manager", "shell",
    "sync-agent", "mail",     "chat",            "updater",      "print-queue",     "bluetooth",
    "login",      "session",  "clipboard",       "notifier",     "search",          "backup",
};

fn wave(tick: u32, period: f32, phase: f32) f32 {
    const t = @as(f32, @floatFromInt(tick)) / period + phase;
    return 0.5 + 0.5 * @sin(t * std.math.tau);
}

/// A deterministic machine for screenshots and for hosts without a backend:
/// the same `tick` always gives the same Sample.
pub fn synthetic(tick: u32, out: *Sample) void {
    out.* = .{};
    out.setCpuName("Teak Synthetic 8-Core Processor");
    out.rates_valid = true;
    out.n_cores = 8;
    out.cpu_mhz = 3600 + 600 * wave(tick, 40, 0.1);
    out.uptime_s = 3 * 86400 + 4 * 3600 + 5 * 60 + tick;
    var sum: f32 = 0;
    for (0..out.n_cores) |i| {
        const fi: f32 = @floatFromInt(i);
        const v = 8 + 70 * wave(tick, 18 + 3 * fi, fi * 0.17) * wave(tick, 47, fi * 0.31);
        out.core_pct[i] = v;
        sum += v;
    }
    out.cpu_pct = sum / @as(f32, @floatFromInt(out.n_cores));

    const gib: u64 = 1 << 30;
    out.mem_total = 16 * gib;
    out.mem_available = @intFromFloat(@as(f32, @floatFromInt(6 * gib)) + @as(f32, @floatFromInt(3 * gib)) * wave(tick, 90, 0.4));
    out.mem_cached = 4 * gib;
    out.commit_limit = 24 * gib;
    out.commit_used = out.memUsed() + 2 * gib;
    out.swap_total = 8 * gib;
    out.swap_used = gib / 2;

    const mib: f32 = 1 << 20;
    out.disk_read_bps = 42 * mib * wave(tick, 23, 0) * wave(tick, 7, 0.2);
    out.disk_write_bps = 18 * mib * wave(tick, 31, 0.5);
    out.net_rx_bps = 6 * mib * wave(tick, 27, 0.3);
    out.net_tx_bps = 0.9 * mib * wave(tick, 13, 0.6);

    const sensor_names = [_][]const u8{ "cpu package", "cpu core 0", "cpu core 1", "nvme", "wifi" };
    out.n_sensors = sensor_names.len;
    for (sensor_names, 0..) |n, i| {
        const fi: f32 = @floatFromInt(i);
        out.sensors[i] = .{ .celsius = 38 + 4 * fi + 22 * wave(tick, 60, fi * 0.2) };
        out.sensors[i].label_len = copyUtf8(&out.sensors[i].label_buf, n);
    }

    out.n_procs = fake_names.len;
    var threads: u32 = 0;
    for (fake_names, 0..) |n, i| {
        const fi: f32 = @floatFromInt(i);
        const p = &out.procs[i];
        p.* = .{
            .pid = 100 + @as(u32, @intCast(i)) * 37,
            .threads = 1 + @as(u32, @intCast((i * 7) % 23)),
            .rss_bytes = (@as(u64, @intCast((i * 53) % 900)) + 12) << 20,
            .cpu_pct = 9 * wave(tick, 11 + fi, fi * 0.13) * wave(tick, 5 + fi, fi * 0.29),
        };
        p.setName(n);
        threads += p.threads;
    }
    out.n_threads = threads;
}
