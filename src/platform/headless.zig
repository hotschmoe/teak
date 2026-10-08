//! Headless Host: scripted input, a fake clock and real text metrics, for
//! running a teak App with no window system (agent screenshots, CI,
//! deterministic end-to-end tests). Pair it with the surface-less native
//! Gpu (`Gpu.initOffscreen`, `gpu/native_headless.zig`) and drive it with
//! `teak.Runtime`; `teak.headless` (`headless_run.zig`) wraps the whole
//! "script -> frames -> PNG" flow.
//!
//! Input is *queued*: `pushMouseMove` / `pushMouseDown` / ... append to a
//! script queue, and the next `pollInputs` (one per `Runtime.frame`) drains
//! the whole queue into that frame, in order. A click therefore needs frames
//! between its parts the same way a real mouse does: the runtime routes
//! input against the PREVIOUS frame's layout, so move over a widget and run
//! a frame before pressing. `headless.play` does that for you.
//!
//! Time is fake and deterministic: `nowMs` advances `frame_ms` (16) per
//! `pollInputs`, starting at 0, so `Sub.every` / `Sub.at` timers fire on a
//! fixed schedule independent of how fast the frames really run.
//!
//! Text is measured by the same stb_truetype `Font` the native Gpu
//! rasterizes with (`TEAK_FONT`, else a system DejaVu/Liberation mono), so
//! layout matches the rendered pixels.
//!
//! Effects: every submitted effect is accepted and *captured* (deep copy)
//! for assertions; an effect is answered only when the test calls
//! `injectEffectResult`, so apps see exactly the results the test chooses.
//! The clipboard is an in-memory buffer; file dialogs cancel; there are no
//! secondary windows.

const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");
const control_socket = @import("control_socket.zig");

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const Effect = teak.Effect;
pub const EffectResult = teak.EffectResult;
pub const EffectSubmit = teak.EffectSubmit;
const Button = teak.Button;
const Modifiers = teak.Modifiers;

/// One queued input event (applied in order by the next `pollInputs`).
const Event = union(enum) {
    move: [2]f32,
    down: Button,
    up: Button,
    wheel: [2]f32,
    chars: struct { buf: [32]u8, len: u8 },
    key: SpecialKey,
    mods: Modifiers,
    chord: teak.Chord,
};

/// A submitted effect, deep-copied so tests can assert on it after the
/// frame that issued it. `name` is the primary string (HTTP url, download
/// file name, open-file accept list, clipboard text, storage key, query
/// parameter name); `bytes` the payload (HTTP body, download bytes, storage
/// value); `mime` the download MIME type; `method` the HTTP method.
pub const Captured = struct {
    kind: std.meta.Tag(Effect),
    id: u32,
    name: []u8 = &.{},
    bytes: []u8 = &.{},
    mime: []u8 = &.{},
    method: teak.HttpMethod = .get,
};

pub const Host = struct {
    pub const frame_ms: u64 = 16;
    pub const MAX_EVENTS = 512;
    pub const MAX_INJECTED = 32;

    gpa: std.mem.Allocator,
    width: u32,
    height: u32,

    queue: teak.InputQueue = .{},
    events: [MAX_EVENTS]Event = undefined,
    event_count: usize = 0,
    first_poll: bool = true,
    closed: bool = false,
    clock_ms: u64 = 0,
    /// `waitEvents` calls (idle blocks) and the total fake time they skipped.
    wait_calls: u32 = 0,
    waited_ms: u64 = 0,
    /// `pollInputs` calls so far (= frames run).
    frames: u32 = 0,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,

    clip: [4096]u8 = undefined,
    clip_len: usize = 0,

    /// Agent control channel (`controlListen`); inactive unless listened.
    ctl: control_socket.Server = .{},

    captured: std.ArrayList(Captured) = .empty,
    injected: [MAX_INJECTED]EffectResult = undefined,
    injected_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Host {
        return .{ .gpa = gpa, .width = width, .height = height };
    }

    pub fn deinit(self: *Host) void {
        self.ctl.deinit();
        for (self.captured.items) |c| freeCaptured(self.gpa, c);
        self.captured.deinit(self.gpa);
    }

    // ── Scripting API ──────────────────────────────────────────────

    fn push(self: *Host, e: Event) void {
        if (self.event_count == MAX_EVENTS) return; // a script that outruns its frames: drop, not crash
        self.events[self.event_count] = e;
        self.event_count += 1;
    }

    pub fn pushMouseMove(self: *Host, x: f32, y: f32) void {
        self.push(.{ .move = .{ x, y } });
    }
    pub fn pushMouseDown(self: *Host, b: Button) void {
        self.push(.{ .down = b });
    }
    pub fn pushMouseUp(self: *Host, b: Button) void {
        self.push(.{ .up = b });
    }
    /// Scroll, DOM sign convention: positive `dy` scrolls content down.
    pub fn pushWheel(self: *Host, dx: f32, dy: f32) void {
        self.push(.{ .wheel = .{ dx, dy } });
    }
    /// Typed UTF-8 text (queued in chunks of up to 32 bytes).
    pub fn pushChars(self: *Host, utf8: []const u8) void {
        var rest = utf8;
        while (rest.len > 0) {
            var n = @min(rest.len, 32);
            // Never split a UTF-8 sequence across chunks.
            while (n < rest.len and n > 0 and (rest[n] & 0xC0) == 0x80) n -= 1;
            if (n == 0) return;
            var ev: Event = .{ .chars = .{ .buf = undefined, .len = @intCast(n) } };
            @memcpy(ev.chars.buf[0..n], rest[0..n]);
            self.push(ev);
            rest = rest[n..];
        }
    }
    /// A keyboard shortcut (`InputState.chords`), e.g. `.{ .key = .s, .mod = true }`.
    pub fn pushChord(self: *Host, c: teak.Chord) void {
        self.push(.{ .chord = c });
    }
    pub fn pushKey(self: *Host, k: SpecialKey) void {
        self.push(.{ .key = k });
    }
    /// Modifier state from the next event on (shift / ctrl / alt / meta).
    pub fn setModifiers(self: *Host, m: Modifiers) void {
        self.push(.{ .mods = m });
    }
    /// Make `shouldClose` true.
    pub fn close(self: *Host) void {
        self.closed = true;
    }

    /// Answer an effect (or deliver an unsolicited `dropped` / `pasted_text`)
    /// in the next frame. Slices inside `r` must stay valid until the frame
    /// after that (the runtime dispatches within the frame it is handed in).
    pub fn injectEffectResult(self: *Host, r: EffectResult) void {
        if (self.injected_len == MAX_INJECTED) return;
        self.injected[self.injected_len] = r;
        self.injected_len += 1;
    }

    /// Every effect submitted so far, oldest first.
    pub fn submittedEffects(self: *const Host) []const Captured {
        return self.captured.items;
    }

    /// The submitted effects of one kind.
    pub fn countEffects(self: *const Host, kind: std.meta.Tag(Effect)) usize {
        var n: usize = 0;
        for (self.captured.items) |c| {
            if (c.kind == kind) n += 1;
        }
        return n;
    }

    pub fn clearSubmittedEffects(self: *Host) void {
        for (self.captured.items) |c| freeCaptured(self.gpa, c);
        self.captured.clearRetainingCapacity();
    }

    pub fn title(self: *const Host) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    // ── Agent control channel (optional Host surface; src/control.zig) ──

    /// Start listening on the Unix socket `path`. False: unsupported OS or
    /// the socket could not be created.
    pub fn controlListen(self: *Host, path: []const u8) bool {
        return self.ctl.listen(path);
    }
    /// The next complete protocol line from the client, or null. Never blocks.
    pub fn controlRecv(self: *Host, out: []u8) ?[]u8 {
        return self.ctl.recvLine(out);
    }
    pub fn controlSend(self: *Host, bytes: []const u8) void {
        self.ctl.send(bytes);
    }
    /// Queue a synthetic event: same queue, same path as the scripted
    /// `push*` API (applied by the next `pollInputs`).
    pub fn injectInput(self: *Host, ev: teak.host.InjectEvent) void {
        switch (ev) {
            .move => |p| self.pushMouseMove(p[0], p[1]),
            .down => |b| self.pushMouseDown(b),
            .up => |b| self.pushMouseUp(b),
            .wheel => |w| self.pushWheel(w[0], w[1]),
            .chars => |t| self.pushChars(t),
            .key => |k| self.pushKey(k),
            .mods => |m| self.setModifiers(m),
            .chord => |c| self.pushChord(c),
        }
    }
    /// Make `shouldClose` true (the control `quit` command).
    pub fn requestClose(self: *Host) void {
        self.close();
    }

    // ── validateHost surface ───────────────────────────────────────

    pub fn nativeHandle(_: *Host) void {}

    /// Event-driven idle (`RunOptions.idle_skip`): `run` calls this after a
    /// quiet frame. A real Host blocks until an input event or `timeout_ms`;
    /// the headless Host has no event source, so it just jumps its fake clock
    /// forward by the timeout (minus the frame the next poll adds), which
    /// makes timer-driven scripts deterministic and fast.
    pub fn waitEvents(self: *Host, timeout_ms: u32) void {
        self.wait_calls += 1;
        const skip = if (timeout_ms > frame_ms) timeout_ms - frame_ms else 0;
        self.waited_ms += skip;
        self.clock_ms += skip;
    }

    pub fn shouldClose(self: *const Host) bool {
        return self.closed;
    }

    pub fn pollInputs(self: *Host) InputState {
        const q = &self.queue;
        q.beginFrame();
        for (self.events[0..self.event_count]) |ev| switch (ev) {
            .move => |p| q.pointerMoved(p[0], p[1]),
            .down => |b| q.buttonDown(b),
            .up => |b| q.buttonUp(b),
            .wheel => |w| q.wheel(w[0], w[1]),
            .chars => |ch| q.pushText(ch.buf[0..ch.len]),
            .key => |k| q.pushKey(k),
            .mods => |m| q.mods = m,
            .chord => |c| q.pushChord(c),
        };
        self.event_count = 0;

        self.clock_ms += frame_ms;
        self.frames += 1;
        const resized = self.first_poll;
        self.first_poll = false;
        return q.finish(resized, self.width, self.height);
    }

    pub fn textMeasurer(self: *Host) teak.TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = measure };
    }

    fn measure(_: *anyopaque, bytes: []const u8, font: teak.FontSpec) teak.TextMetrics {
        return text.measure(bytes, font);
    }

    /// Register the TTF `ttf` as the face for (`family`, `weight`) (shared with the Gpu's
    /// rasterizer through the face table). The bytes are borrowed: pass an `@embedFile` slice.
    pub fn registerFont(_: *Host, family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) !void {
        try text.registerFace(family, weight, ttf);
    }

    pub fn clipboard(self: *Host) teak.Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipRead, .write_fn = clipWrite };
    }

    fn clipRead(ctx: *anyopaque) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.clip[0..self.clip_len];
    }

    fn clipWrite(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.clip_len = @min(bytes.len, self.clip.len);
        @memcpy(self.clip[0..self.clip_len], bytes[0..self.clip_len]);
    }

    pub fn imeState(_: *const Host) teak.ImeState {
        return .{};
    }

    pub fn publishA11yTree(_: *Host, _: []const teak.A11yNode) void {}

    pub fn openFileDialog(_: *Host, _: teak.FileDialogFilter) teak.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *Host, _: teak.FileDialogFilter) teak.FileDialogResult {
        return null;
    }
    pub fn requestFileDialog(_: *Host, _: teak.FileDialogFilter) u32 {
        return 0;
    }
    pub fn requestSaveFileDialog(_: *Host, _: teak.FileDialogFilter) u32 {
        return 0;
    }
    pub fn pollFileDialogResult(_: *Host, _: u32) teak.FileDialogPoll {
        return .{ .cancelled = {} };
    }

    pub fn openSecondaryWindow(_: *Host, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn pollSecondaryInputs(_: *Host, _: u32) ?InputState {
        return null;
    }
    pub fn closeSecondaryWindow(_: *Host, _: u32) void {}
    pub fn secondaryWindowHandle(_: *const Host, _: u32) ?void {
        return null;
    }

    pub fn setTitle(self: *Host, t: []const u8) void {
        self.title_len = @min(t.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], t[0..self.title_len]);
    }

    /// Fake monotonic clock: 16 ms per frame.
    pub fn nowMs(self: *const Host) u64 {
        return self.clock_ms;
    }

    pub fn scaleFactor(_: *const Host) f32 {
        return 1.0;
    }

    // ── Effects: capture + scripted answers ────────────────────────

    pub fn submit(self: *Host, e: Effect) EffectSubmit {
        const cap = self.capture(e) catch return .busy;
        self.captured.append(self.gpa, cap) catch {
            freeCaptured(self.gpa, cap);
            return .busy;
        };
        return .accepted;
    }

    pub fn pollEffectResults(self: *Host, buf: []EffectResult) usize {
        const n = @min(buf.len, self.injected_len);
        @memcpy(buf[0..n], self.injected[0..n]);
        std.mem.copyForwards(EffectResult, self.injected[0 .. self.injected_len - n], self.injected[n..self.injected_len]);
        self.injected_len -= n;
        return n;
    }

    fn capture(self: *Host, e: Effect) !Captured {
        const a = self.gpa;
        var c: Captured = .{ .kind = std.meta.activeTag(e), .id = e.id() };
        errdefer freeCaptured(a, c);
        switch (e) {
            .http => |r| {
                c.name = try a.dupe(u8, r.url);
                c.bytes = try a.dupe(u8, r.body);
                c.method = r.method;
            },
            .download => |d| {
                c.name = try a.dupe(u8, d.name);
                c.bytes = try a.dupe(u8, d.bytes);
                c.mime = try a.dupe(u8, d.mime);
            },
            .open_file => |o| c.name = try a.dupe(u8, o.accept),
            .write_clipboard => |w| c.name = try a.dupe(u8, w.text),
            .write_clipboard_image => |w| {
                c.name = try a.dupe(u8, "image/png");
                c.bytes = try a.dupe(u8, w.png);
            },
            .storage_set => |s| {
                c.name = try a.dupe(u8, s.key);
                c.bytes = try a.dupe(u8, s.value);
            },
            .storage_get => |g| c.name = try a.dupe(u8, g.key),
            .clock => {},
            .query_param => |q| c.name = try a.dupe(u8, q.name),
        }
        return c;
    }
};

fn freeCaptured(a: std.mem.Allocator, c: Captured) void {
    a.free(c.name);
    a.free(c.bytes);
    a.free(c.mime);
}

comptime {
    teak.validateHost(Host);
}

// ── Tests ──────────────────────────────────────────────────────────

fn testHost() !Host {
    return Host.init(std.testing.allocator, 640, 480) catch |e| switch (e) {
        error.FontNotFound => return error.SkipZigTest, // no system TTF (headless CI)
        else => return e,
    };
}

test "queued input is delivered by the next poll, in order, with single-frame edges" {
    var h = try testHost();
    defer h.deinit();

    h.pushMouseMove(10, 20);
    h.pushMouseDown(.left);
    h.pushMouseUp(.left); // a fast click: both edges in one frame
    h.pushChars("héllo");
    h.pushKey(.enter);
    h.pushWheel(0, 48);
    h.setModifiers(.{ .shift = true });

    const in = h.pollInputs();
    try std.testing.expect(in.resized); // first frame reports the size
    try std.testing.expectEqual(@as(u32, 640), in.width);
    try std.testing.expectEqual(@as(f32, 10), in.mouse_x);
    try std.testing.expect(in.mouse_down and in.mouse_up);
    try std.testing.expect(!in.buttons.left); // released again
    try std.testing.expectEqualStrings("héllo", in.chars);
    try std.testing.expectEqual(@as(usize, 1), in.keys.len);
    try std.testing.expectEqual(SpecialKey.enter, in.keys[0]);
    try std.testing.expectEqual(@as(f32, 48), in.wheel_dy);
    try std.testing.expect(in.mods.shift);

    // Nothing queued: edges, text, keys and wheel are gone; state persists.
    const next = h.pollInputs();
    try std.testing.expect(!next.resized);
    try std.testing.expect(!next.mouse_down and !next.mouse_up);
    try std.testing.expectEqual(@as(usize, 0), next.chars.len);
    try std.testing.expectEqual(@as(usize, 0), next.keys.len);
    try std.testing.expectEqual(@as(f32, 0), next.wheel_dy);
    try std.testing.expectEqual(@as(f32, 10), next.mouse_x);
}

test "a held button spans frames; chars are never split across chunks" {
    var h = try testHost();
    defer h.deinit();
    h.pushMouseDown(.left);
    try std.testing.expect(h.pollInputs().buttons.left);
    try std.testing.expect(h.pollInputs().buttons.left); // still held
    h.pushMouseUp(.left);
    const up = h.pollInputs();
    try std.testing.expect(up.mouse_up and !up.buttons.left);

    // 40 bytes of 2-byte code points: chunking at 32 must not cut one in half.
    h.pushChars("éééééééééééééééééééé");
    const in = h.pollInputs();
    try std.testing.expect(std.unicode.utf8ValidateSlice(in.chars));
    try std.testing.expectEqual(@as(usize, 40), in.chars.len);
}

test "the clock is fake and advances 16 ms per frame" {
    var h = try testHost();
    defer h.deinit();
    try std.testing.expectEqual(@as(u64, 0), h.nowMs());
    _ = h.pollInputs();
    try std.testing.expectEqual(@as(u64, 16), h.nowMs());
    _ = h.pollInputs();
    _ = h.pollInputs();
    try std.testing.expectEqual(@as(u64, 48), h.nowMs());
    try std.testing.expectEqual(@as(u32, 3), h.frames);
}

test "text measurement uses the real font: wider for longer text and larger size" {
    var h = try testHost();
    defer h.deinit();
    const m = h.textMeasurer();
    const a = m.measure("ab", .{ .size_px = 14 });
    const b = m.measure("abcd", .{ .size_px = 14 });
    const big = m.measure("ab", .{ .size_px = 28 });
    // Host.init succeeds without a font (it loads lazily); with none on this
    // machine (Windows/macOS CI have no system TTF probed) measure() is a stub.
    if (a.width == 0) return error.SkipZigTest;
    try std.testing.expect(a.width > 0 and b.width > a.width);
    try std.testing.expect(big.width > a.width and big.height > a.height);
    try std.testing.expect(a.ascent > 0);
}

test "effects are accepted and captured by deep copy; results come only from injection" {
    var h = try testHost();
    defer h.deinit();

    var url = "https://example.test/a".*;
    try std.testing.expectEqual(EffectSubmit.accepted, h.submit(.{ .http = .{ .id = 1, .method = .post, .url = &url, .body = "payload" } }));
    try std.testing.expectEqual(EffectSubmit.accepted, h.submit(.{ .download = .{ .id = 2, .name = "out.dxf", .mime = "image/vnd.dxf", .bytes = "0\nSECTION" } }));
    try std.testing.expectEqual(EffectSubmit.accepted, h.submit(.{ .storage_set = .{ .id = 3, .key = "k", .value = "v" } }));
    try std.testing.expectEqual(EffectSubmit.accepted, h.submit(.{ .write_clipboard_image = .{ .id = 4, .png = "\x89PNG" } }));
    try std.testing.expectEqual(@as(usize, 1), h.countEffects(.write_clipboard_image));
    try std.testing.expectEqualStrings("\x89PNG", h.submittedEffects()[h.submittedEffects().len - 1].bytes);
    @memset(&url, 'X'); // the host must not alias the caller's slice

    const got = h.submittedEffects();
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("https://example.test/a", got[0].name);
    try std.testing.expectEqualStrings("payload", got[0].bytes);
    try std.testing.expectEqual(teak.HttpMethod.post, got[0].method);
    try std.testing.expectEqualStrings("out.dxf", got[1].name);
    try std.testing.expectEqualStrings("image/vnd.dxf", got[1].mime);
    try std.testing.expectEqual(@as(usize, 1), h.countEffects(.download));

    // Nothing answers until the test says so.
    var buf: [4]EffectResult = undefined;
    try std.testing.expectEqual(@as(usize, 0), h.pollEffectResults(&buf));
    h.injectEffectResult(.{ .http = .{ .id = 1, .status = 200, .body = "ok" } });
    h.injectEffectResult(.{ .downloaded = .{ .id = 2, .ok = true } });
    try std.testing.expectEqual(@as(usize, 2), h.pollEffectResults(&buf));
    try std.testing.expectEqual(@as(u16, 200), buf[0].http.status);
    try std.testing.expect(buf[1].downloaded.ok);
    try std.testing.expectEqual(@as(usize, 0), h.pollEffectResults(&buf)); // drained

    h.clearSubmittedEffects();
    try std.testing.expectEqual(@as(usize, 0), h.submittedEffects().len);
}

test "clipboard round-trips, titles are kept, close ends the run" {
    var h = try testHost();
    defer h.deinit();
    const cb = h.clipboard();
    try std.testing.expectEqualStrings("", cb.read());
    cb.write("copied");
    try std.testing.expectEqualStrings("copied", cb.read());
    h.setTitle("My App");
    try std.testing.expectEqualStrings("My App", h.title());
    try std.testing.expect(!h.shouldClose());
    h.close();
    try std.testing.expect(h.shouldClose());
}

test "waitEvents jumps the fake clock by the timeout (minus the next poll's frame)" {
    var h = try testHost();
    defer h.deinit();
    h.waitEvents(116);
    try std.testing.expectEqual(@as(u32, 1), h.wait_calls);
    try std.testing.expectEqual(@as(u64, 100), h.nowMs());
    h.waitEvents(5); // shorter than a frame: nothing to skip
    try std.testing.expectEqual(@as(u64, 100), h.nowMs());
}

test {
    _ = @import("headless_drive_test.zig");
}
