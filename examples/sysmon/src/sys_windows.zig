//! Windows backend: ntdll, kernel32, iphlpapi and advapi32, no COM and no
//! elevated access. Temperatures are not here: Windows exposes them only
//! through WMI or vendor drivers.

const std = @import("std");
const sys = @import("sys.zig");

const HANDLE = *anyopaque;
const invalid_handle: usize = std.math.maxInt(usize);

const SystemProcessInformation = 5;
const SystemProcessorPerformanceInformation = 8;

extern "ntdll" fn NtQuerySystemInformation(class: u32, info: *anyopaque, len: u32, ret_len: ?*u32) callconv(.winapi) i32;
extern "kernel32" fn GlobalMemoryStatusEx(status: *MemoryStatusEx) callconv(.winapi) i32;
extern "kernel32" fn K32GetPerformanceInfo(info: *PerformanceInformation, cb: u32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) usize;
extern "kernel32" fn DeviceIoControl(device: usize, code: u32, in: ?*anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32, returned: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) i32;
extern "iphlpapi" fn GetIfTable2(table: *?*IfTable2) callconv(.winapi) u32;
extern "iphlpapi" fn FreeMibTable(table: *anyopaque) callconv(.winapi) void;
extern "advapi32" fn RegGetValueW(key: usize, subkey: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, len: ?*u32) callconv(.winapi) i32;

const ProcessorTimes = extern struct {
    idle: i64,
    kernel: i64,
    user: i64,
    dpc: i64,
    interrupt: i64,
    interrupt_count: u32,
};

const UnicodeString = extern struct {
    len: u16,
    cap: u16,
    buf: ?[*]const u16,
};

const ProcessInfo = extern struct {
    next_offset: u32,
    n_threads: u32,
    working_set_private: i64,
    hard_faults: u32,
    threads_high_water: u32,
    cycle_time: u64,
    create_time: i64,
    user_time: i64,
    kernel_time: i64,
    image_name: UnicodeString,
    base_priority: i32,
    pid: usize,
    parent_pid: usize,
    handle_count: u32,
    session_id: u32,
    unique_key: usize,
    peak_virtual: usize,
    virtual: usize,
    page_faults: u32,
    peak_working_set: usize,
    working_set: usize,
};

const MemoryStatusEx = extern struct {
    length: u32 = @sizeOf(MemoryStatusEx),
    load: u32 = 0,
    total_phys: u64 = 0,
    avail_phys: u64 = 0,
    total_page_file: u64 = 0,
    avail_page_file: u64 = 0,
    total_virtual: u64 = 0,
    avail_virtual: u64 = 0,
    avail_extended: u64 = 0,
};

const PerformanceInformation = extern struct {
    cb: u32 = @sizeOf(PerformanceInformation),
    commit_total: usize = 0,
    commit_limit: usize = 0,
    commit_peak: usize = 0,
    physical_total: usize = 0,
    physical_available: usize = 0,
    system_cache: usize = 0,
    kernel_total: usize = 0,
    kernel_paged: usize = 0,
    kernel_nonpaged: usize = 0,
    page_size: usize = 0,
    handle_count: u32 = 0,
    process_count: u32 = 0,
    thread_count: u32 = 0,
};

const DiskPerformance = extern struct {
    bytes_read: i64,
    bytes_written: i64,
    read_time: i64,
    write_time: i64,
    idle_time: i64,
    read_count: u32,
    write_count: u32,
    queue_depth: u32,
    split_count: u32,
    query_time: i64,
    storage_device_number: u32,
    storage_manager_name: [8]u16,
};

/// MIB_IF_ROW2 (netioapi.h). Only the fields read here are named.
const IfRow2 = extern struct {
    luid: u64,
    index: u32,
    guid: [16]u8,
    alias: [257]u16,
    description: [257]u16,
    physical_address_len: u32,
    physical_address: [32]u8,
    permanent_physical_address: [32]u8,
    mtu: u32,
    kind: u32,
    tunnel_type: u32,
    media_type: u32,
    physical_medium_type: u32,
    access_type: u32,
    direction_type: u32,
    flags: u8,
    oper_status: u32,
    admin_status: u32,
    media_connect_state: u32,
    network_guid: [16]u8,
    connection_type: u32,
    transmit_link_speed: u64,
    receive_link_speed: u64,
    in_octets: u64,
    in_other: [8]u64,
    out_octets: u64,
    out_other: [8]u64,
};

const IfTable2 = extern struct {
    n: u32,
    rows: [1]IfRow2,
};

comptime {
    std.debug.assert(@sizeOf(usize) == 8);
    std.debug.assert(@sizeOf(ProcessorTimes) == 48);
    std.debug.assert(@offsetOf(ProcessInfo, "image_name") == 56);
    std.debug.assert(@offsetOf(ProcessInfo, "pid") == 80);
    std.debug.assert(@offsetOf(ProcessInfo, "working_set") == 144);
    std.debug.assert(@sizeOf(MemoryStatusEx) == 64);
    std.debug.assert(@sizeOf(PerformanceInformation) == 104);
    std.debug.assert(@sizeOf(DiskPerformance) == 88);
    std.debug.assert(@offsetOf(IfRow2, "in_octets") == 1208);
    std.debug.assert(@sizeOf(IfRow2) == 1352);
    std.debug.assert(@offsetOf(IfTable2, "rows") == 8);
}

const if_type_loopback = 24;
const if_oper_up = 1;
const if_flag_filter: u8 = 1 << 1;
const if_flag_connector: u8 = 1 << 2;

const ioctl_disk_performance = 0x70020;
const max_disks = 16;
const hklm: usize = 0xFFFF_FFFF_8000_0002;
const rrf_rt_reg_sz = 0x2;
const rrf_rt_reg_dword = 0x10;
const proc_buf_bytes = 4 << 20;

pub const State = struct {
    cpu_name_len: u8,
    cpu_name: [79]u8,
    cpu_mhz: f32,
    disks: [max_disks]usize,
    proc_buf: []align(8) u8,

    pub fn init(self: *State) void {
        self.cpu_name_len = 0;
        self.cpu_mhz = 0;
        const key = std.unicode.utf8ToUtf16LeStringLiteral("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0");
        var wide: [128]u16 = undefined;
        var bytes: u32 = @sizeOf(@TypeOf(wide));
        if (RegGetValueW(hklm, key, std.unicode.utf8ToUtf16LeStringLiteral("ProcessorNameString"), rrf_rt_reg_sz, null, &wide, &bytes) == 0) {
            const units = std.mem.sliceTo(wide[0 .. bytes / 2], 0);
            var utf8: [256]u8 = undefined;
            const n = std.unicode.utf16LeToUtf8(&utf8, units) catch 0;
            self.cpu_name_len = sys.copyUtf8(&self.cpu_name, std.mem.trim(u8, utf8[0..n], " "));
        }
        var mhz: u32 = 0;
        bytes = @sizeOf(u32);
        if (RegGetValueW(hklm, key, std.unicode.utf8ToUtf16LeStringLiteral("~MHz"), rrf_rt_reg_dword, null, &mhz, &bytes) == 0) {
            self.cpu_mhz = @floatFromInt(mhz);
        }
        for (&self.disks, 0..) |*d, i| {
            var name: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&name, "\\\\.\\PhysicalDrive{d}", .{i}) catch unreachable;
            var wname: [32:0]u16 = undefined;
            const wn = std.unicode.utf8ToUtf16Le(&wname, text) catch unreachable;
            wname[wn] = 0;
            d.* = CreateFileW(&wname, 0, 3, null, 3, 0, null);
        }
        self.proc_buf = std.heap.page_allocator.alignedAlloc(u8, .@"8", proc_buf_bytes) catch &.{};
    }

    pub fn deinit(self: *State) void {
        for (self.disks) |d| {
            if (d != invalid_handle) _ = CloseHandle(d);
        }
        if (self.proc_buf.len > 0) std.heap.page_allocator.free(self.proc_buf);
    }

    pub fn read(self: *State, s: *sys.Sample, c: *sys.Counters) void {
        s.setCpuName(self.cpu_name[0..self.cpu_name_len]);
        s.cpu_mhz = self.cpu_mhz;
        s.uptime_s = GetTickCount64() / 1000;
        readCpu(s, c);
        readMemory(s);
        self.readDisks(c);
        readNetwork(c);
        self.readProcs(s);
    }

    fn readDisks(self: *State, c: *sys.Counters) void {
        for (self.disks) |d| {
            if (d == invalid_handle) continue;
            var perf: DiskPerformance = undefined;
            var returned: u32 = 0;
            if (DeviceIoControl(d, ioctl_disk_performance, null, 0, &perf, @sizeOf(DiskPerformance), &returned, null) == 0) continue;
            c.disk_read_bytes += @intCast(@max(perf.bytes_read, 0));
            c.disk_write_bytes += @intCast(@max(perf.bytes_written, 0));
        }
    }

    fn readProcs(self: *State, s: *sys.Sample) void {
        if (self.proc_buf.len == 0) return;
        var needed: u32 = 0;
        if (NtQuerySystemInformation(SystemProcessInformation, self.proc_buf.ptr, @intCast(self.proc_buf.len), &needed) < 0) return;
        var at: usize = 0;
        while (at + @sizeOf(ProcessInfo) <= self.proc_buf.len) {
            const info: *const ProcessInfo = @ptrCast(@alignCast(self.proc_buf.ptr + at));
            s.n_threads += info.n_threads;
            if (info.pid != 0 and s.n_procs < sys.max_procs) {
                const p = &s.procs[s.n_procs];
                p.* = .{
                    .pid = @intCast(@min(info.pid, std.math.maxInt(u32))),
                    .threads = info.n_threads,
                    .rss_bytes = info.working_set,
                    .cpu_time = @intCast(@max(info.user_time + info.kernel_time, 0)),
                };
                var utf8: [128]u8 = undefined;
                const units = if (info.image_name.buf) |b| b[0 .. info.image_name.len / 2] else &[_]u16{};
                const n = std.unicode.utf16LeToUtf8(&utf8, units[0..@min(units.len, 40)]) catch 0;
                p.setName(if (n > 0) utf8[0..n] else "System");
                s.n_procs += 1;
            }
            if (info.next_offset == 0) break;
            at += info.next_offset;
        }
    }
};

fn readCpu(s: *sys.Sample, c: *sys.Counters) void {
    var times: [sys.max_cores]ProcessorTimes = undefined;
    var returned: u32 = 0;
    if (NtQuerySystemInformation(SystemProcessorPerformanceInformation, &times, @sizeOf(@TypeOf(times)), &returned) < 0) return;
    const n = @min(returned / @sizeOf(ProcessorTimes), sys.max_cores);
    s.n_cores = @intCast(n);
    for (times[0..n], 0..) |t, i| {
        const total: u64 = @intCast(@max(t.kernel + t.user, 0));
        const idle: u64 = @intCast(@max(t.idle, 0));
        c.core_total[i] = total;
        c.core_busy[i] = total -| idle;
    }
}

fn readMemory(s: *sys.Sample) void {
    var status: MemoryStatusEx = .{};
    if (GlobalMemoryStatusEx(&status) != 0) {
        s.mem_total = status.total_phys;
        s.mem_available = status.avail_phys;
    }
    var perf: PerformanceInformation = .{};
    if (K32GetPerformanceInfo(&perf, @sizeOf(PerformanceInformation)) != 0) {
        s.mem_cached = @as(u64, perf.system_cache) * perf.page_size;
        s.commit_used = @as(u64, perf.commit_total) * perf.page_size;
        s.commit_limit = @as(u64, perf.commit_limit) * perf.page_size;
    }
}

/// Connected, non-loopback adapters with a physical connector; the filter-layer
/// rows that mirror an adapter's counters would count its traffic again.
fn readNetwork(c: *sys.Counters) void {
    var table: ?*IfTable2 = null;
    if (GetIfTable2(&table) != 0) return;
    const t = table orelse return;
    defer FreeMibTable(t);
    const rows: [*]const IfRow2 = @ptrCast(&t.rows);
    for (rows[0..t.n]) |row| {
        if (row.kind == if_type_loopback or row.oper_status != if_oper_up) continue;
        if (row.flags & if_flag_filter != 0 or row.flags & if_flag_connector == 0) continue;
        c.net_rx_bytes += row.in_octets;
        c.net_tx_bytes += row.out_octets;
    }
}
