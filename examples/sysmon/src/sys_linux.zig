//! Linux backend: /proc and /sys through raw syscalls, no allocation.
//! Field layouts: proc(5), Documentation/admin-guide/iostats.rst, hwmon sysfs-interface.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const SensorPath = struct { len: u8 = 0, buf: [63:0]u8 = undefined };

pub const State = struct {
    page_bytes: u64,
    cpu_name_len: u8,
    cpu_name: [79]u8,
    n_sensors: u32,
    sensor_paths: [sys.max_sensors]SensorPath,
    sensor_labels: [sys.max_sensors]sys.Sensor,
    scratch: [64 * 1024]u8,

    pub fn init(self: *State) void {
        self.page_bytes = std.heap.pageSize();
        self.cpu_name_len = 0;
        self.n_sensors = 0;
        const info = readFile("/proc/cpuinfo", &self.scratch);
        if (fieldValue(info, "model name")) |v| {
            self.cpu_name_len = sys.copyUtf8(&self.cpu_name, v);
        }
        self.findSensors();
    }

    pub fn deinit(_: *State) void {}

    pub fn read(self: *State, s: *sys.Sample, c: *sys.Counters) void {
        s.setCpuName(self.cpu_name[0..self.cpu_name_len]);
        self.readCpu(s, c);
        self.readMemory(s);
        self.readDisks(c);
        self.readNetwork(c);
        self.readSensors(s);
        self.readProcs(s);

        var small: [128]u8 = undefined;
        var up = std.mem.tokenizeAny(u8, readFile("/proc/uptime", &small), " .\n");
        s.uptime_s = parseU64(up.next() orelse "0");
        var load = std.mem.tokenizeAny(u8, readFile("/proc/loadavg", &small), " \n");
        _ = load.next();
        _ = load.next();
        _ = load.next();
        if (load.next()) |running_total| {
            if (std.mem.indexOfScalar(u8, running_total, '/')) |slash| {
                s.n_threads = @intCast(@min(parseU64(running_total[slash + 1 ..]), std.math.maxInt(u32)));
            }
        }
    }

    fn readCpu(self: *State, s: *sys.Sample, c: *sys.Counters) void {
        var lines = std.mem.tokenizeScalar(u8, readFile("/proc/stat", &self.scratch), '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "cpu")) break;
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const tag = it.next().?;
            if (tag.len == 3) continue;
            const core = parseU64(tag[3..]);
            if (core >= sys.max_cores) continue;
            var fields: [8]u64 = @splat(0);
            for (&fields) |*f| f.* = parseU64(it.next() orelse "0");
            var total: u64 = 0;
            for (fields) |f| total += f;
            c.core_total[core] = total;
            c.core_busy[core] = total - fields[3] - fields[4];
            s.n_cores = @max(s.n_cores, @as(u32, @intCast(core)) + 1);
        }

        var mhz_sum: f64 = 0;
        var mhz_n: u32 = 0;
        var info = std.mem.tokenizeScalar(u8, readFile("/proc/cpuinfo", &self.scratch), '\n');
        while (info.next()) |line| {
            if (!std.mem.startsWith(u8, line, "cpu MHz")) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            mhz_sum += std.fmt.parseFloat(f64, std.mem.trim(u8, line[colon + 1 ..], " \t")) catch continue;
            mhz_n += 1;
        }
        if (mhz_n > 0) s.cpu_mhz = @floatCast(mhz_sum / @as(f64, @floatFromInt(mhz_n)));
    }

    fn readMemory(self: *State, s: *sys.Sample) void {
        const text = readFile("/proc/meminfo", &self.scratch);
        s.mem_total = kib(text, "MemTotal");
        s.mem_available = kib(text, "MemAvailable");
        s.mem_cached = kib(text, "Cached") + kib(text, "Buffers") + kib(text, "SReclaimable");
        s.commit_used = kib(text, "Committed_AS");
        s.commit_limit = kib(text, "CommitLimit");
        s.swap_total = kib(text, "SwapTotal");
        s.swap_used = s.swap_total -| kib(text, "SwapFree");
    }

    fn readDisks(self: *State, c: *sys.Counters) void {
        var lines = std.mem.tokenizeScalar(u8, readFile("/proc/diskstats", &self.scratch), '\n');
        while (lines.next()) |line| {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            _ = it.next();
            _ = it.next();
            const name = it.next() orelse continue;
            if (!isWholeDisk(name)) continue;
            _ = it.next();
            _ = it.next();
            const sectors_read = parseU64(it.next() orelse "0");
            _ = it.next();
            _ = it.next();
            _ = it.next();
            const sectors_written = parseU64(it.next() orelse "0");
            c.disk_read_bytes += sectors_read * 512;
            c.disk_write_bytes += sectors_written * 512;
        }
    }

    fn readNetwork(self: *State, c: *sys.Counters) void {
        var lines = std.mem.tokenizeScalar(u8, readFile("/proc/net/dev", &self.scratch), '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " ");
            if (std.mem.eql(u8, name, "lo")) continue;
            var it = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
            c.net_rx_bytes += parseU64(it.next() orelse "0");
            for (0..7) |_| _ = it.next();
            c.net_tx_bytes += parseU64(it.next() orelse "0");
        }
    }

    fn findSensors(self: *State) void {
        var hw: u32 = 0;
        while (hw < 16) : (hw += 1) {
            var path: [64]u8 = undefined;
            var small: [64]u8 = undefined;
            const name_path = std.fmt.bufPrintSentinel(&path, "/sys/class/hwmon/hwmon{d}/name", .{hw}, 0) catch continue;
            const chip = std.mem.trim(u8, readFile(name_path, &small), " \n");
            if (chip.len == 0) continue;
            var chip_buf: [24]u8 = undefined;
            const chip_name = chip_buf[0..sys.copyUtf8(&chip_buf, chip)];
            var t: u32 = 1;
            while (t <= 64 and self.n_sensors < sys.max_sensors) : (t += 1) {
                const slot = &self.sensor_paths[self.n_sensors];
                const input = std.fmt.bufPrintSentinel(&slot.buf, "/sys/class/hwmon/hwmon{d}/temp{d}_input", .{ hw, t }, 0) catch continue;
                if (readFile(input, &small).len == 0) continue;
                slot.len = @intCast(input.len);
                const label_path = std.fmt.bufPrintSentinel(&path, "/sys/class/hwmon/hwmon{d}/temp{d}_label", .{ hw, t }, 0) catch continue;
                var label_buf: [48]u8 = undefined;
                const label = std.mem.trim(u8, readFile(label_path, &label_buf), " \n");
                const out = &self.sensor_labels[self.n_sensors];
                var text: [47]u8 = undefined;
                const full = if (label.len > 0)
                    std.fmt.bufPrint(&text, "{s} {s}", .{ chip_name, label }) catch chip_name
                else
                    std.fmt.bufPrint(&text, "{s} temp{d}", .{ chip_name, t }) catch chip_name;
                out.label_len = sys.copyUtf8(&out.label_buf, full);
                self.n_sensors += 1;
            }
        }
    }

    fn readSensors(self: *State, s: *sys.Sample) void {
        var small: [32]u8 = undefined;
        for (0..self.n_sensors) |i| {
            const path = self.sensor_paths[i].buf[0..self.sensor_paths[i].len :0];
            const milli = parseU64(std.mem.trim(u8, readFile(path, &small), " \n"));
            const out = &s.sensors[s.n_sensors];
            out.* = self.sensor_labels[i];
            out.celsius = @as(f32, @floatFromInt(milli)) / 1000.0;
            s.n_sensors += 1;
        }
    }

    fn readProcs(self: *State, s: *sys.Sample) void {
        const rc = linux.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        const dir: linux.fd_t = @intCast(rc);
        defer _ = linux.close(dir);
        var entries: [8192]u8 align(8) = undefined;
        while (true) {
            const got = linux.getdents64(dir, &entries, entries.len);
            if (linux.errno(got) != .SUCCESS or got == 0) return;
            var at: usize = 0;
            while (at < got) {
                const reclen = std.mem.readInt(u16, entries[at + 16 ..][0..2], .little);
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(entries[at + 19 ..].ptr)), 0);
                at += reclen;
                if (name.len == 0 or name[0] < '0' or name[0] > '9') continue;
                if (s.n_procs == sys.max_procs) return;
                if (self.readProc(name, &s.procs[s.n_procs])) s.n_procs += 1;
            }
        }
    }

    /// One /proc/<pid>/stat line. Kernel threads (no address space) are skipped.
    fn readProc(self: *State, pid_text: []const u8, out: *sys.Proc) bool {
        var path: [32]u8 = undefined;
        const stat_path = std.fmt.bufPrintSentinel(&path, "/proc/{s}/stat", .{pid_text}, 0) catch return false;
        const text = readFile(stat_path, self.scratch[0..1024]);
        const open = std.mem.indexOfScalar(u8, text, '(') orelse return false;
        const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
        if (close < open) return false;
        var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
        var fields: [22][]const u8 = undefined;
        for (&fields) |*f| f.* = it.next() orelse return false;
        const vsize = parseU64(fields[20]);
        if (vsize == 0) return false;
        out.* = .{
            .pid = @intCast(@min(parseU64(pid_text), std.math.maxInt(u32))),
            .threads = @intCast(@min(parseU64(fields[17]), std.math.maxInt(u32))),
            .rss_bytes = parseU64(fields[21]) * self.page_bytes,
            .cpu_time = parseU64(fields[11]) + parseU64(fields[12]),
        };
        out.setName(text[open + 1 .. close]);
        return true;
    }
};

fn readFile(path: [*:0]const u8, buf: []u8) []const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return buf[0..0];
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const got = linux.read(fd, buf.ptr + n, buf.len - n);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        n += got;
    }
    return buf[0..n];
}

fn parseU64(text: []const u8) u64 {
    var v: u64 = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') break;
        v = v *| 10 +| (ch - '0');
    }
    return v;
}

/// The value after "key<spaces>:" on the first line that starts with key.
fn fieldValue(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != ':') continue;
        return std.mem.trim(u8, rest[1..], " \t");
    }
    return null;
}

fn kib(text: []const u8, key: []const u8) u64 {
    return parseU64(fieldValue(text, key) orelse return 0) * 1024;
}

/// Whole devices only: a partition's sectors are already in its disk's row.
fn isWholeDisk(name: []const u8) bool {
    for ([_][]const u8{ "loop", "ram", "zram", "dm-", "md", "sr", "fd" }) |skip| {
        if (std.mem.startsWith(u8, name, skip)) return false;
    }
    const last = name[name.len - 1];
    const ends_in_digit = last >= '0' and last <= '9';
    if (std.mem.startsWith(u8, name, "nvme") or std.mem.startsWith(u8, name, "mmcblk")) {
        return std.mem.indexOfScalar(u8, name[4..], 'p') == null;
    }
    return !ends_in_digit;
}
