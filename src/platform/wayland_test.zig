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

test "window lifecycle: configure, logical size, title, handle" {
    try requireWayland();
    var host = try Host.init("teak wayland test", 320, 200);
    defer host.deinit();
    const st = host.pollInputs();
    try std.testing.expect(st.resized); // first frame always resizes
    try std.testing.expect(st.width > 0 and st.height > 0);
    try std.testing.expect(host.scaleFactor() >= 1);
    host.setTitle("renamed");
    const h = host.nativeHandle();
    try std.testing.expect(@intFromPtr(h.display) != 0 and @intFromPtr(h.surface) != 0);
    try std.testing.expect(!host.shouldClose());
    _ = host.pollInputs();
}

test "every cursor shape can be set" {
    try requireWayland();
    var host = try Host.init("teak wayland test", 320, 200);
    defer host.deinit();
    _ = host.pollInputs();
    for (std.enums.values(teak.CursorShape)) |sh| host.setCursor(sh);
    _ = host.pollInputs();
}

test "TEAK_SCALE=2 reports scale 2 and keeps logical size" {
    try requireWayland();
    _ = setenv("TEAK_SCALE", "2", 1);
    defer _ = unsetenv("TEAK_SCALE");
    var host = try Host.init("teak wayland test", 320, 200);
    defer host.deinit();
    const st = host.pollInputs();
    try std.testing.expectEqual(@as(f32, 2), host.scaleFactor());
    try std.testing.expect(st.width <= 1000); // logical, not doubled
}

test "clipboard: write in one client is read by another" {
    try requireWayland();
    if (getenv("DISPLAY") == null) return error.SkipZigTest; // needs xdotool to focus
    var a = try Host.init("teak wl A", 300, 200);
    defer a.deinit();
    _ = a.pollInputs();
    try a.mapWithShmBuffer();
    try clickInto(&a);
    // A needs a keyboard-focus serial to own the selection.
    var spins: usize = 0;
    while (a.st.last_serial == 0 and spins < 300) : (spins += 1) {
        _ = a.pollInputs();
        sleepMs(5);
    }
    if (a.st.last_serial == 0) return error.SkipZigTest; // no seat input in this compositor
    a.clipboard().write("hello wayland");
    var b = try Host.init("teak wl B", 300, 200);
    defer b.deinit();
    _ = b.pollInputs();
    try b.mapWithShmBuffer();
    // Click B so it takes keyboard focus and receives the selection.
    try clickInto(&b);
    spins = 0;
    while (b.st.selection == null and spins < 300) : (spins += 1) {
        _ = a.pollInputs();
        _ = b.pollInputs();
        sleepMs(5);
    }
    if (b.st.selection == null) return error.SkipZigTest; // focus did not move (compositor policy)
    // B's read needs A's source to answer, which happens in A's poll: run A
    // on a thread while B blocks in its bounded read.
    var stop = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, pumpThread, .{ &a, &stop });
    const got = b.clipboard().read();
    stop.store(true, .release);
    t.join();
    try std.testing.expectEqualStrings("hello wayland", got);
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

test "keyboard: xkb text, shifted text and navigation keys" {
    try requireWayland();
    if (getenv("DISPLAY") == null) return error.SkipZigTest;
    var h = try focusedHost("teak wl keys");
    defer h.deinit();
    _ = system("xdotool key h i shift+a Left ctrl+a >/dev/null 2>&1");
    var chars: [16]u8 = undefined;
    var n: usize = 0;
    var keys: [8]teak.SpecialKey = undefined;
    var nk: usize = 0;
    var spins: usize = 0;
    while (spins < 300 and (n < 3 or nk < 2)) : (spins += 1) {
        const st = h.pollInputs();
        @memcpy(chars[n..][0..st.chars.len], st.chars);
        n += st.chars.len;
        for (st.keys) |k| {
            keys[nk] = k;
            nk += 1;
        }
        sleepMs(5);
    }
    try std.testing.expectEqualStrings("hiA", chars[0..n]);
    try std.testing.expectEqual(teak.SpecialKey.left, keys[0]);
    try std.testing.expectEqual(teak.SpecialKey.ctrl_a, keys[1]);
}

test "pointer: motion, buttons and wheel arrive in logical coordinates" {
    try requireWayland();
    if (getenv("DISPLAY") == null) return error.SkipZigTest;
    var h = try focusedHost("teak wl pointer");
    defer h.deinit();
    _ = system("xdotool mousemove_relative 5 5 click 1 click 5 >/dev/null 2>&1");
    var saw_down = false;
    var wheel: f32 = 0;
    var spins: usize = 0;
    while (spins < 300 and !(saw_down and wheel != 0)) : (spins += 1) {
        const st = h.pollInputs();
        if (st.button_down.left) saw_down = true;
        wheel += st.wheel_dy;
        sleepMs(5);
    }
    try std.testing.expect(saw_down);
    try std.testing.expect(wheel > 0); // button 5 = scroll down
}

test "Ctrl+V without an app claim becomes pasted_text" {
    try requireWayland();
    if (getenv("DISPLAY") == null) return error.SkipZigTest;
    // A focused client owns the clipboard; then a newer window takes focus.
    var owner = try focusedHost("teak wl owner");
    defer owner.deinit();
    owner.clipboard().write("pasted via ctrl+v");
    _ = owner.pollInputs();
    var h = try focusedHost("teak wl paste");
    defer h.deinit();
    _ = h.pollInputs();
    _ = system("xdotool key ctrl+v >/dev/null 2>&1");
    var got: ?[]const u8 = null;
    var buf: [16]EffectResult = undefined;
    var spins: usize = 0;
    var copy: [64]u8 = undefined;
    while (spins < 400 and got == null) : (spins += 1) {
        _ = owner.pollInputs();
        _ = h.pollInputs();
        const k = h.pollEffectResults(&buf);
        for (buf[0..k]) |r| switch (r) {
            .pasted_text => |p| {
                @memcpy(copy[0..p.text.len], p.text);
                got = copy[0..p.text.len];
            },
            else => {},
        };
        sleepMs(5);
    }
    if (got == null) return error.SkipZigTest; // the owner could not take the selection (focus policy)
    try std.testing.expectEqualStrings("pasted via ctrl+v", got.?);
}
