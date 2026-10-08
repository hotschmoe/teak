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

test "clipboard write is served to another client (xclip -o)" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    _ = host.pollInputs();

    // Through the Clipboard vtable (Ctrl+C path) ...
    host.clipboard().write("héllo from teak");
    var job: Job = .{ .cmd = "xclip -selection clipboard -o > .x11_test/x11_clip_out" };
    try pumpWhile(&host, &job);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("héllo from teak", try readSmallFile(".x11_test/x11_clip_out", &buf));

    // ... and through the declarative effect.
    try std.testing.expectEqual(teak.EffectSubmit.accepted, host.submit(.{ .write_clipboard = .{ .id = 1, .text = "via effect" } }));
    var job2: Job = .{ .cmd = "xclip -selection clipboard -o -t STRING > .x11_test/x11_clip_out" };
    try pumpWhile(&host, &job2);
    try std.testing.expectEqualStrings("via effect", try readSmallFile(".x11_test/x11_clip_out", &buf));

    // Reading back what we own never leaves the process.
    try std.testing.expectEqualStrings("via effect", host.clipboard().read());
}

test "clipboard read round-trips another owner's text" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    _ = host.pollInputs();

    try sh("printf 'pasted by xclip' | xclip -selection clipboard -i >/dev/null 2>&1", .{});
    // xclip forks to serve the selection; give it a beat to take ownership.
    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(150), .awake) catch {};
    try std.testing.expectEqualStrings("pasted by xclip", host.clipboard().read());
    // A synchronous read claims the paste: nothing is queued as pasted_text.
    var buf: [4]EffectResult = undefined;
    try std.testing.expectEqual(@as(usize, 0), host.pollEffectResults(&buf));
}

test "unclaimed Ctrl+V becomes pasted_text" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    _ = host.pollInputs();

    try sh("printf 'async paste' | xclip -selection clipboard -i >/dev/null 2>&1", .{});
    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(150), .awake) catch {};
    try pressCtrlV(&host);
    var r: EffectResult = undefined;
    try nextResult(&host, &r);
    try std.testing.expectEqualStrings("async paste", r.pasted_text.text);
}

test "pasted PNG arrives as an image drop" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    _ = host.pollInputs();

    // Header-only PNG: xclip serves the bytes verbatim; the host reads IHDR.
    var png: [33]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 7, .big);
    std.mem.writeInt(u32, png[20..24], 5, .big);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ".x11_test/x11_test.png", .data = &png });
    try sh("xclip -selection clipboard -t image/png -i .x11_test/x11_test.png >/dev/null 2>&1", .{});
    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(150), .awake) catch {};
    try pressCtrlV(&host);
    var r: EffectResult = undefined;
    try nextResult(&host, &r);
    try std.testing.expectEqual(teak.DropKind.image, r.dropped.kind);
    try std.testing.expectEqualStrings("image/png", r.dropped.mime);
    try std.testing.expectEqual(@as(u32, 7), r.dropped.width);
    try std.testing.expectEqual(@as(u32, 5), r.dropped.height);
    try std.testing.expectEqualSlices(u8, &png, r.dropped.bytes);
}

test "large clipboard text arrives intact (INCR or one shot)" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    _ = host.pollInputs();

    var big: [3 * 1024 * 1024]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ".x11_test/x11_big.txt", .data = &big });
    try sh("xclip -selection clipboard -i .x11_test/x11_big.txt >/dev/null 2>&1", .{});
    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(150), .awake) catch {};
    try pressCtrlV(&host);
    var r: EffectResult = undefined;
    try nextResult(&host, &r);
    try std.testing.expectEqualSlices(u8, &big, r.pasted_text.text);
}

test "XDND file drop delivers a Drop and finishes the session" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    var src = try Host.init("xdnd source", 50, 50);
    defer src.deinit();
    _ = host.pollInputs();
    _ = src.pollInputs();

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = ".x11_test/dropped file.json", .data = "{\"k\":1}" });
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_n = try std.process.currentPath(std.Options.debug_io, &cwd_buf);
    var uri_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const uri_list = try std.fmt.bufPrint(&uri_buf, "# comment\r\nfile://{s}/.x11_test/dropped%20file.json\r\nfile://remotehost/etc/passwd\r\n", .{cwd_buf[0..cwd_n]});

    const a = &src.atoms;
    _ = src.x.XSetSelectionOwner(src.display, a.xdnd_selection, src.window, 0);
    _ = src.x.XFlush(src.display);
    // Enter (version 5, 3 inline types), then Position, then Drop.
    const l1: c_long = (5 << 24);
    src.sendClientMessage(host.window, a.xdnd_enter, .{ @bitCast(src.window), l1, @bitCast(a.uri_list), 0, 0 });
    src.sendClientMessage(host.window, a.xdnd_position, .{ @bitCast(src.window), 0, (10 << 16) | 10, 0, @bitCast(a.xdnd_action_copy) });

    var got_status = false;
    var got_finished = false;
    var sent_drop = false;
    var result: ?EffectResult = null;
    var buf: [16]EffectResult = undefined;
    var spins: usize = 0;
    while (spins < 1500 and !(got_finished and result != null)) : (spins += 1) {
        _ = host.pollInputs();
        // Result slices die at the next poll: stop polling once we hold one.
        if (result == null and host.pollEffectResults(&buf) > 0) result = buf[0];
        while (src.x.XPending(src.display) > 0) {
            var ev: x11.XEvent = undefined;
            _ = src.x.XNextEvent(src.display, &ev);
            switch (ev.kind) {
                30 => { // SelectionRequest on the XdndSelection: serve the list.
                    const req = ev.xselectionrequest;
                    _ = src.x.XChangeProperty(src.display, req.requestor, req.property, a.uri_list, 8, 0, uri_list.ptr, @intCast(uri_list.len));
                    var reply: x11.XEvent = undefined;
                    reply.xselection = .{ .kind = 31, .serial = 0, .send_event = 1, .display = src.display, .requestor = req.requestor, .selection = req.selection, .target = req.target, .property = req.property, .time = req.time };
                    _ = src.x.XSendEvent(src.display, req.requestor, 0, 0, &reply);
                    _ = src.x.XFlush(src.display);
                },
                33 => {
                    if (ev.xclient.message_type == a.xdnd_status) {
                        try std.testing.expectEqual(@as(c_long, 1), ev.xclient.data.l[1] & 1); // accepted
                        got_status = true;
                        if (!sent_drop) {
                            sent_drop = true;
                            src.sendClientMessage(host.window, a.xdnd_drop, .{ @bitCast(src.window), 0, 0, 0, 0 });
                        }
                    } else if (ev.xclient.message_type == a.xdnd_finished) {
                        try std.testing.expectEqual(@as(c_long, 1), ev.xclient.data.l[1] & 1);
                        got_finished = true;
                    }
                },
                else => {},
            }
        }
        std.Io.sleep(std.Options.debug_io, .fromMilliseconds(2), .awake) catch {};
    }
    try std.testing.expect(got_status);
    try std.testing.expect(got_finished);
    const r = result orelse return error.NoResult;
    try std.testing.expectEqual(teak.DropKind.file, r.dropped.kind);
    try std.testing.expectEqualStrings("dropped file.json", r.dropped.name);
    try std.testing.expectEqualStrings("application/json", r.dropped.mime);
    try std.testing.expectEqualStrings("{\"k\":1}", r.dropped.bytes);
}

test "typed keys reach the text queue with or without an input method" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    _ = host.pollInputs();
    // `host.xic` is non-null when an IM (even the built-in one) negotiated;
    // either way plain typing must work and composition must be inactive.
    try sh("xdotool key --window {d} h i", .{host.window});
    var text: [8]u8 = undefined;
    var n: usize = 0;
    var spins: usize = 0;
    while (n < 2 and spins < 500) : (spins += 1) {
        const st = host.pollInputs();
        @memcpy(text[n..][0..st.chars.len], st.chars);
        n += st.chars.len;
        std.Io.sleep(std.Options.debug_io, .fromMilliseconds(2), .awake) catch {};
    }
    try std.testing.expectEqualStrings("hi", text[0..n]);
    try std.testing.expect(!host.imeState().active);
}

test "input method negotiation either completes or falls back cleanly" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    // Either a full input method (xim + ic) or a clean fallback (neither).
    try std.testing.expectEqual(host.xim != null, host.xic != null);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "every cursor shape can be set (themed or font fallback)" {
    try requireDisplay();
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    _ = host.pollInputs();
    for (std.enums.values(teak.CursorShape)) |shape| host.setCursor(shape);
    // Cached on the second pass: no new server round trips needed.
    for (std.enums.values(teak.CursorShape)) |shape| host.setCursor(shape);
    _ = host.pollInputs();
}

test "TEAK_SCALE=2: window is 2x physical, input and size are logical" {
    try requireDisplay();
    _ = setenv("TEAK_SCALE", "2", 1);
    defer _ = unsetenv("TEAK_SCALE");
    var host = try Host.init("teak x11 test", 200, 100);
    defer host.deinit();
    try std.testing.expectEqual(@as(f32, 2), host.scaleFactor());
    _ = host.pollInputs();
    // Physical size as the server sees it.
    try sh("xdotool getwindowgeometry {d} | grep -q 'Geometry: 400x200'", .{host.window});
    // The Host still reports logical size ...
    var st = host.pollInputs();
    var spins: usize = 0;
    while (st.width != 200 and spins < 200) : (spins += 1) st = host.pollInputs();
    try std.testing.expectEqual(@as(u32, 200), st.width);
    try std.testing.expectEqual(@as(u32, 100), st.height);
    // ... and a pointer at device pixel (100, 60) is logical (50, 30).
    try sh("xdotool mousemove --window {d} 100 60", .{host.window});
    spins = 0;
    while (spins < 200) : (spins += 1) {
        st = host.pollInputs();
        if (st.mouse_x != 0) break;
        std.Io.sleep(std.Options.debug_io, .fromMilliseconds(2), .awake) catch {};
    }
    try std.testing.expectEqual(@as(f32, 50), st.mouse_x);
    try std.testing.expectEqual(@as(f32, 30), st.mouse_y);
}
