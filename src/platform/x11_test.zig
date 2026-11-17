//! Live-display tests for the X11 host (`zig build test-x11`). They open a
//! real `Host` (no Gpu) on `$DISPLAY` — Xvfb is enough — and drive it with
//! `xclip` / `xdotool` and a second in-process Host acting as an XDND drag
//! source. Every test skips when `DISPLAY` is unset or a helper tool is
//! missing, so the step is safe anywhere.

const std = @import("std");
const teak = @import("teak");
const x11 = @import("x11.zig");

const Host = x11.Host;
const EffectResult = teak.EffectResult;

extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

fn requireDisplay() !void {
    if (getenv("DISPLAY") == null) return error.SkipZigTest;
    if (system("command -v xclip >/dev/null 2>&1") != 0) return error.SkipZigTest;
    if (system("command -v xdotool >/dev/null 2>&1") != 0) return error.SkipZigTest;
    // Scratch dir (gitignored) in the package root, the test's cwd.
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, ".x11_test") catch {};
}

fn sh(comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&buf, fmt ++ "\x00", args);
    if (system(@ptrCast(cmd.ptr)) != 0) return error.ShellFailed;
}

fn readSmallFile(path: []const u8, out: []u8) ![]u8 {
    const f = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(f);
    @memcpy(out[0..f.len], f);
    return out[0..f.len];
}

/// Run a shell command on a thread while the caller keeps the host pumping
/// (the command is a client that needs our host to answer it).
const Job = struct {
    cmd: [:0]const u8,
    done: std.atomic.Value(bool) = .init(false),
    rc: c_int = -1,
    fn run(self: *Job) void {
        self.rc = system(self.cmd.ptr);
        self.done.store(true, .release);
    }
};

fn pumpWhile(host: *Host, job: *Job) !void {
    const t = try std.Thread.spawn(.{}, Job.run, .{job});
    defer t.join();
    var spins: usize = 0;
    while (!job.done.load(.acquire)) : (spins += 1) {
        _ = host.pollInputs();
        std.Io.sleep(std.Options.debug_io, .fromMilliseconds(2), .awake) catch {};
        if (spins > 3000) return error.Timeout;
    }
}

/// Pump frames until `pollEffectResults` yields a result or the budget ends.
fn nextResult(host: *Host, out: *EffectResult) !void {
    var buf: [16]EffectResult = undefined;
    var spins: usize = 0;
    while (spins < 1500) : (spins += 1) {
        _ = host.pollInputs();
        if (host.pollEffectResults(&buf) > 0) {
            out.* = buf[0];
            return;
        }
        std.Io.sleep(std.Options.debug_io, .fromMilliseconds(2), .awake) catch {};
    }
    return error.NoResult;
}

/// Inject Ctrl+V and run exactly the frame the runtime would: poll inputs,
/// (the app does not claim the paste), then `pollEffectResults`, which starts
/// the asynchronous paste. Later frames deliver the answer.
fn pressCtrlV(host: *Host) !void {
    try sh("xdotool key --window {d} ctrl+v", .{host.window});
    var spins: usize = 0;
    while (spins < 500) : (spins += 1) {
        const st = host.pollInputs();
        for (st.keys) |k| if (k == .ctrl_v) {
            var none: [1]EffectResult = undefined;
            _ = host.pollEffectResults(&none);
            return;
        };
        std.Io.sleep(std.Options.debug_io, .fromMilliseconds(2), .awake) catch {};
    }
    return error.KeyNotSeen;
}










extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;



fn elapsedMs(host: *const Host, since: u64) u64 {
    return host.nowMs() - since;
}


// ── Idle CPU probe (opt-in: TEAK_IDLE_PROBE=1 zig build test-x11) ──────

const ProbeGpu = struct {
    renders: u32 = 0,
    pub fn deinit(_: *ProbeGpu) void {}
    pub fn resize(_: *ProbeGpu, _: u32, _: u32) void {}
    pub fn uploadVertices(_: *ProbeGpu, _: []const teak.Vertex) void {}
    pub fn uploadText(_: *ProbeGpu, _: []const teak.TextDraw) void {}
    pub fn uploadImage(_: *ProbeGpu, _: []const u8, _: u32, _: u32) teak.TextureHandle {
        return teak.TEXTURE_HANDLE_NONE;
    }
    pub fn releaseImage(_: *ProbeGpu, _: teak.TextureHandle) void {}
    pub fn uploadImages(_: *ProbeGpu, _: []const teak.ImageDraw) void {}
    pub fn renderFrame(self: *ProbeGpu, _: [4]f32) void {
        self.renders += 1;
    }
};

const ProbeApp = struct {
    pub const Model = struct {};
    pub const Msg = union(enum) { focus, noop };
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical });
        cb.pushScroll(.{ .id = 1, .flex = 1 });
        for (0..500) |_| {
            cb.pushGroup(.{ .direction = .horizontal, .gap = 8 });
            cb.text("some description text");
            cb.button(.noop, "Edit");
            cb.popGroup();
        }
        cb.popScroll();
        cb.textInput(.focus, "hello", 5);
        cb.popGroup();
    }
    pub fn focusedMsg(_: *const Model) ?Msg {
        return .focus; // a focused input: the blink case
    }
};

fn processCpuMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.PROCESS_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Run the real loop on a live X11 Host for `secs`; returns CPU ms used.
fn idleRun(secs: u64, idle_skip: bool) !struct { cpu_ms: u64, renders: u32 } {
    var host = try Host.init("teak idle probe", 800, 600);
    defer host.deinit();
    var gpu: ProbeGpu = .{};
    var rt = try teak.Runtime(ProbeApp, Host, ProbeGpu).init(std.testing.allocator, &host, &gpu, .{ .idle_skip = idle_skip });
    defer rt.deinit();
    try rt.frame();
    try rt.frame();
    const cpu0 = processCpuMs();
    const t0 = host.nowMs();
    while (host.nowMs() - t0 < secs * 1000) {
        try rt.frame();
        if (idle_skip) {
            if (rt.quiet) host.waitEvents(rt.idleTimeoutMs());
        } else {
            // What vsync (FIFO present) does for the old always-render loop.
            std.Io.sleep(std.Options.debug_io, .fromMilliseconds(16), .awake) catch {};
        }
    }
    return .{ .cpu_ms = processCpuMs() - cpu0, .renders = gpu.renders };
}


