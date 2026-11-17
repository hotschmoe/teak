//! Live tests for the Wayland host (`zig build test-wayland`). They connect
//! to `$WAYLAND_DISPLAY` — in CI and locally a weston running on Xvfb
//! (`weston --backend=x11-backend.so --use-pixman`), whose seat takes real
//! input from `xdotool` — and skip when it is unset.
//!
//! Wayland delivers clipboard selections and keyboard events only to the
//! client that has keyboard focus, so tests that need it create a window
//! and click it (via xdotool on the Xvfb display holding weston's window)
//! before expecting events.

const std = @import("std");
const teak = @import("teak");
const wayland = @import("wayland.zig");

const Host = wayland.Host;
const EffectResult = teak.EffectResult;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn requireWayland() !void {
    if (getenv("WAYLAND_DISPLAY") == null) return error.SkipZigTest;
}

fn sleepMs(ms: i64) void {
    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(ms), .awake) catch {};
}

/// Poll `a` (and `b`, if given) until `done` says so or the budget is spent.
fn pumpUntil(hosts: []const *Host, comptime cond: anytype, ctx: anytype) !void {
    var spins: usize = 0;
    while (spins < 600) : (spins += 1) {
        for (hosts) |h| _ = h.pollInputs();
        if (cond(ctx)) return;
        sleepMs(5);
    }
    return error.Timeout;
}

fn alwaysFalse(_: void) bool {
    return false;
}





fn pumpThread(h: *Host, stop: *std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        _ = h.pollInputs();
        sleepMs(2);
    }
}

/// Move the (Xvfb) pointer across weston's output until `h`'s surface sees
/// it enter, then click: gives that window keyboard focus. Windows are placed
/// by the compositor, so the point is found rather than assumed.
fn clickInto(h: *Host) !void {
    const before = h.st.pointer_serial;
    var y: u32 = 80;
    while (y <= 640) : (y += 80) {
        var x: u32 = 40;
        while (x <= 960) : (x += 80) {
            var buf: [64]u8 = undefined;
            const cmd = try std.fmt.bufPrint(&buf, "xdotool mousemove {d} {d} >/dev/null 2>&1\x00", .{ x, y });
            if (system(@ptrCast(cmd.ptr)) != 0) return error.SkipZigTest;
            var i: usize = 0;
            while (i < 6) : (i += 1) {
                _ = h.pollInputs();
                sleepMs(4);
            }
            if (h.st.pointer_serial != before) {
                _ = system("xdotool click 1 >/dev/null 2>&1");
                sleepMs(60);
                return;
            }
        }
    }
    return error.SkipZigTest;
}

/// A mapped, focused host: weston gives keyboard focus to the window the
/// pointer clicked, so click it before typing.
fn focusedHost(title: [:0]const u8) !Host {
    var h = try Host.init(title, 400, 300);
    errdefer h.deinit();
    _ = h.pollInputs();
    try h.mapWithShmBuffer();
    try clickInto(&h);
    var spins: usize = 0;
    while (h.st.last_serial == 0 and spins < 300) : (spins += 1) {
        _ = h.pollInputs();
        sleepMs(5);
    }
    if (h.st.last_serial == 0) return error.SkipZigTest;
    return h;
}




const wl = @import("wayland/protocols.zig");
const client = @import("wayland/client.zig");

var drag_payload: [256]u8 = undefined;
var drag_len: usize = 0;

fn dragSend(_: ?*anyopaque, _: *wl.wl_data_source, _: [*:0]const u8, fd: i32) callconv(.c) void {
    extern_write(fd);
}
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
fn extern_write(fd: i32) void {
    _ = write(fd, &drag_payload, drag_len);
    _ = close(fd);
}
const drag_listener = wl.wl_data_source_listener{ .send = dragSend };

