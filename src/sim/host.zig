//! See SRC.md, src/sim/host.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const interface = @import("../platform/host.zig");
const Queue = @import("../platform/input_queue.zig").InputQueue;
const input = @import("input.zig");
const hashing = @import("hash.zig");
const effects = @import("../core/effects.zig");

pub const effects_max = 1024;
pub const clipboard_max = 8192;
pub const capture_bytes_max = 65536;
pub const headers_max = 1024;

pub const Captured = struct {
    kind: std.meta.Tag(interface.Effect),
    id: u32,
    digest: u64,
    effect: interface.Effect,
};

pub fn Host(comptime Metrics: type) type {
    assert(@hasDecl(Metrics, "init"));
    assert(@hasDecl(Metrics, "measure"));
    return struct {
        const Self = @This();
        metrics: Metrics,
        live: bool = true,
        clock_ms: u64 = 0,
        width: u32 = 1280,
        height: u32 = 800,
        scale: f32 = 1,
        first_poll: bool = true,
        queue: Queue = .{},
        next: input.Frame = .{},
        last: interface.InputState = undefined,
        clip: [clipboard_max]u8 = @splat(0),
        clip_len: u32 = 0,
        captures: [effects_max]Captured = undefined,
        capture_count: u16 = 0,
        capture_bytes: [capture_bytes_max]u8 = undefined,
        bytes_used: u32 = 0,
        headers: [headers_max]effects.Header = undefined,
        headers_used: u16 = 0,
        effects_issued: u64 = 0,
        unanswered: u64 = 0,
        limits: u64 = 0,
        unsupported: u64 = 0,
        a11y_publications: u64 = 0,
        title_hash: u64 = 0,
        failure: ?anyerror = null,

        pub fn init() !Self {
            const metrics = try Metrics.init();
            assert(@sizeOf(Metrics) > 0);
            assert(clipboard_max > Queue.CHARS_CAP);
            return .{ .metrics = metrics };
        }

        pub fn deinit(self: *Self) void {
            assert(self.live);
            if (comptime @import("sim.zig").verify) for (
                self.captures[0..self.capture_count],
            ) |capture| {
                const digest = hashing.hash(capture.effect) catch |err| {
                    self.failure = err;
                    break;
                };
                if (digest != capture.digest) self.failure = error.CaptureLifetime;
            };
            self.live = false;
            assert(!self.live);
        }

        pub fn pollInputs(self: *Self) interface.InputState {
            assert(self.live);
            assert(self.next.count <= input.events_max);
            self.queue.beginFrame();
            var resized = self.first_poll;
            var focus_lost = false;
            for (self.next.events[0..self.next.count]) |event| switch (event) {
                .move => |p| self.queue.pointerMoved(p[0], p[1]),
                .down => |b| self.queue.buttonDown(b),
                .up => |b| self.queue.buttonUp(b),
                .wheel => |w| self.queue.wheel(w[0], w[1]),
                .key => |k| self.apply_key(k),
                .text => |i| self.apply_text(i),
                .modifiers => |m| self.queue.mods = m,
                .shortcut => |c| self.apply_shortcut(c),
                .resize => |size| {
                    self.width = size[0];
                    self.height = size[1];
                    resized = true;
                },
                .scale => |scale| {
                    self.scale = scale;
                    resized = true;
                },
                .focus_loss => {
                    focus_lost = true;
                    self.queue.buttons = .{};
                    self.queue.pressed = .{};
                    self.queue.released = .{};
                    self.queue.mods = .{};
                },
            };
            self.clock_ms += self.next.advance_ms;
            self.next = .{};
            self.first_poll = false;
            self.limits += self.queue.dropped;
            self.last = self.queue.finish(resized, self.width, self.height);
            self.last.focus_lost = focus_lost;
            return self.last;
        }

        fn apply_key(self: *Self, key: interface.SpecialKey) void {
            assert(self.live);
            assert(self.queue.keys_len <= Queue.KEYS_CAP);
            if (self.queue.keys_len == Queue.KEYS_CAP) {
                self.limits += 1;
                return;
            }
            self.queue.pushKey(key);
        }

        fn apply_text(self: *Self, sample: u8) void {
            assert(self.live);
            assert(sample < input.text_samples.len);
            const bytes = input.text_samples[sample];
            if (self.queue.chars_len + bytes.len > Queue.CHARS_CAP) {
                self.limits += 1;
                return;
            }
            self.queue.pushText(bytes);
        }

        fn apply_shortcut(self: *Self, chord: interface.Chord) void {
            assert(self.live);
            assert(self.queue.chords_len <= Queue.CHORDS_CAP);
            if (self.queue.chords_len == Queue.CHORDS_CAP) {
                self.limits += 1;
                return;
            }
            self.queue.pushChord(chord);
        }

        pub fn nowMs(self: *const Self) u64 {
            assert(self.live);
            assert(self.clock_ms <= std.math.maxInt(u64) / 1000000);
            return self.clock_ms;
        }

        pub fn stats_now_ns(self: *const Self) u64 {
            assert(self.live);
            assert(self.clock_ms <= std.math.maxInt(u64) / 1000000);
            return self.clock_ms * 1000000;
        }

        pub fn scaleFactor(self: *const Self) f32 {
            assert(self.live);
            assert(self.scale > 0);
            return self.scale;
        }

        pub fn shouldClose(self: *const Self) bool {
            assert(self.live);
            assert(self.next.count <= input.events_max);
            return false;
        }

        pub fn nativeHandle(self: *Self) void {
            assert(self.live);
            assert(self.failure == null);
        }

        pub fn textMeasurer(self: *Self) interface.TextMeasurer {
            assert(self.live);
            assert(@sizeOf(Metrics) > 0);
            return .{ .ctx = @ptrCast(self), .measure_fn = measure };
        }

        fn measure(
            context: *anyopaque,
            bytes: []const u8,
            font: interface.FontSpec,
        ) interface.TextMetrics {
            const self: *Self = @ptrCast(@alignCast(context));
            assert(self.live);
            assert(font.size_px > 0);
            return self.metrics.measure(bytes, font);
        }

        pub fn clipboard(self: *Self) interface.Clipboard {
            assert(self.live);
            assert(self.clip_len <= clipboard_max);
            return .{ .ctx = @ptrCast(self), .read_fn = clip_read, .write_fn = clip_write };
        }

        fn clip_read(context: *anyopaque) []const u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            assert(self.live);
            assert(self.clip_len <= clipboard_max);
            return self.clip[0..self.clip_len];
        }

        fn clip_write(context: *anyopaque, bytes: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            assert(self.live);
            assert(self.clip_len <= clipboard_max);
            if (bytes.len > clipboard_max) {
                self.limits += 1;
                return;
            }
            self.clip_len = @intCast(bytes.len);
            @memcpy(self.clip[0..bytes.len], bytes);
        }

        pub fn imeState(self: *const Self) interface.ImeState {
            assert(self.live);
            assert(self.clip_len <= clipboard_max);
            return .{};
        }

        pub fn publishA11yTree(self: *Self, nodes: []const interface.A11yNode) void {
            assert(self.live);
            assert(self.a11y_publications < std.math.maxInt(u64));
            _ = nodes;
            self.a11y_publications += 1;
        }

        pub fn setTitle(self: *Self, title: []const u8) void {
            assert(self.live);
            assert(self.failure == null);
            self.title_hash = std.hash.Wyhash.hash(0, title);
        }

        pub fn submit(self: *Self, effect: interface.Effect) interface.EffectSubmit {
            assert(self.live);
            assert(self.capture_count <= effects_max);
            if (self.capture_count == effects_max) {
                self.limits += 1;
                return .busy;
            }
            const digest = hashing.hash(effect) catch |err| {
                self.failure = err;
                return .busy;
            };
            const owned = self.copy_effect(effect) catch {
                self.limits += 1;
                return .busy;
            };
            self.captures[self.capture_count] = .{
                .kind = std.meta.activeTag(effect),
                .id = effect.id(),
                .digest = digest,
                .effect = owned,
            };
            self.capture_count += 1;
            self.effects_issued += 1;
            if (effect.wantsResult()) self.unanswered += 1;
            return .accepted;
        }

        pub fn pollEffectResults(self: *Self, buffer: []interface.EffectResult) usize {
            assert(self.live);
            assert(self.capture_count <= effects_max);
            _ = buffer;
            return 0;
        }

        fn copy_bytes(self: *Self, bytes: []const u8) error{CaptureLimit}![]const u8 {
            assert(self.live);
            assert(self.bytes_used <= capture_bytes_max);
            if (bytes.len > capture_bytes_max - self.bytes_used) return error.CaptureLimit;
            const start = self.bytes_used;
            self.bytes_used += @intCast(bytes.len);
            @memcpy(self.capture_bytes[start..self.bytes_used], bytes);
            return self.capture_bytes[start..self.bytes_used];
        }

        fn copy_effect(self: *Self, effect: interface.Effect) error{CaptureLimit}!interface.Effect {
            assert(self.live);
            assert(self.headers_used <= headers_max);
            const bytes_start = self.bytes_used;
            const headers_start = self.headers_used;
            errdefer {
                self.bytes_used = bytes_start;
                self.headers_used = headers_start;
            }
            var owned = effect;
            switch (owned) {
                .http => |*request| {
                    request.url = try self.copy_bytes(request.url);
                    request.body = try self.copy_bytes(request.body);
                    if (request.headers.len > headers_max - self.headers_used)
                        return error.CaptureLimit;
                    const start = self.headers_used;
                    self.headers_used += @intCast(request.headers.len);
                    const owned_headers = self.headers[start..self.headers_used];
                    for (request.headers, owned_headers) |source, *header| {
                        header.* = .{
                            .name = try self.copy_bytes(source.name),
                            .value = try self.copy_bytes(source.value),
                        };
                    }
                    request.headers = self.headers[start..self.headers_used];
                },
                .download => |*download| {
                    download.name = try self.copy_bytes(download.name);
                    download.mime = try self.copy_bytes(download.mime);
                    download.bytes = try self.copy_bytes(download.bytes);
                    download.title = try self.copy_bytes(download.title);
                },
                .open_file => |*file| {
                    file.accept = try self.copy_bytes(file.accept);
                    file.title = try self.copy_bytes(file.title);
                },
                .write_clipboard => |*clip| clip.text = try self.copy_bytes(clip.text),
                .write_clipboard_image => |*image| image.png = try self.copy_bytes(image.png),
                .storage_set => |*storage| {
                    storage.key = try self.copy_bytes(storage.key);
                    storage.value = try self.copy_bytes(storage.value);
                },
                .storage_get => |*storage| storage.key = try self.copy_bytes(storage.key),
                .query_param => |*query| query.name = try self.copy_bytes(query.name),
                .clock => {},
            }
            return owned;
        }

        pub fn openFileDialog(
            self: *Self,
            filter: interface.FileDialogFilter,
        ) interface.FileDialogResult {
            assert(self.live);
            assert(self.unsupported < std.math.maxInt(u64));
            _ = filter;
            self.unsupported += 1;
            return null;
        }

        pub fn saveFileDialog(
            self: *Self,
            filter: interface.FileDialogFilter,
        ) interface.FileDialogResult {
            assert(self.live);
            assert(self.unsupported < std.math.maxInt(u64));
            _ = filter;
            self.unsupported += 1;
            return null;
        }

        pub fn requestFileDialog(self: *Self, filter: interface.FileDialogFilter) u32 {
            assert(self.live);
            assert(self.unsupported < std.math.maxInt(u64));
            _ = filter;
            self.unsupported += 1;
            return 0;
        }

        pub fn requestSaveFileDialog(self: *Self, filter: interface.FileDialogFilter) u32 {
            assert(self.live);
            assert(self.unsupported < std.math.maxInt(u64));
            _ = filter;
            self.unsupported += 1;
            return 0;
        }

        pub fn pollFileDialogResult(self: *Self, id: u32) interface.FileDialogPoll {
            assert(self.live);
            assert(self.unsupported < std.math.maxInt(u64));
            _ = id;
            self.unsupported += 1;
            return .cancelled;
        }

        pub fn openSecondaryWindow(self: *Self, title: []const u8, w: u32, h: u32) ?u32 {
            assert(self.live);
            assert(self.unsupported < std.math.maxInt(u64));
            _ = .{ title, w, h };
            self.unsupported += 1;
            return null;
        }

        pub fn pollSecondaryInputs(self: *Self, id: u32) ?interface.InputState {
            assert(self.live);
            assert(self.unsupported < std.math.maxInt(u64));
            _ = id;
            self.unsupported += 1;
            return null;
        }

        pub fn closeSecondaryWindow(self: *Self, id: u32) void {
            assert(self.live);
            assert(id != 0);
            self.failure = error.UnknownWindow;
        }

        pub fn secondaryWindowHandle(self: *const Self, id: u32) ?void {
            assert(self.live);
            assert(id != 0);
            return null;
        }

        comptime {
            interface.validateHost(Self);
        }
    };
}
