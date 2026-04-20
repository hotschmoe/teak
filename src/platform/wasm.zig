//! Wasm host backed by zunk's `web.input` + `web.app` modules. Zunk
//! owns the rAF loop; `pollInputs` snapshots zunk's shared-memory
//! state into teak's `InputState`.
//!
//! Mouse `mouse_down`/`mouse_up` are derived locally from diffs of the
//! button state because zunk reports held-state, not edges.
//!
//! All pointer + viewport coords are CSS pixels (zunk v0.5.2+).

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");

const zinput = zunk.web.input;
const zapp = zunk.web.app;
const zgpu = zunk.web.gpu;

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const TextMeasurer = teak.TextMeasurer;
pub const TextMetrics = teak.TextMetrics;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;

pub const NativeHandle = struct {};

const MEASURE_CACHE_CAPACITY: usize = 128;

const MeasureCacheEntry = struct {
    content_hash: u64,
    content_len: u32,
    size_px: u16,
    family: FontFamily,
    metrics: TextMetrics,
    last_used: u64,
};

// Delete/Home/End are absent from zunk.web.input.Key; tracked in
// docs/zunk-handoff.md as a follow-up ask.
const key_mappings = [_]struct { from: zinput.Key, to: SpecialKey }{
    .{ .from = .backspace, .to = .backspace },
    .{ .from = .enter, .to = .enter },
    .{ .from = .tab, .to = .tab },
    .{ .from = .escape, .to = .escape },
    .{ .from = .arrow_left, .to = .left },
    .{ .from = .arrow_right, .to = .right },
    .{ .from = .arrow_up, .to = .up },
    .{ .from = .arrow_down, .to = .down },
};

pub const Host = struct {
    width: u32,
    height: u32,
    prev_left: bool = false,
    first_poll: bool = true,
    keys_buf: [16]SpecialKey = undefined,
    keys_len: usize = 0,
    chars_buf: [32]u8 = undefined,
    chars_len: usize = 0,
    measure_cache: [MEASURE_CACHE_CAPACITY]MeasureCacheEntry = undefined,
    measure_cache_len: usize = 0,
    measure_tick: u64 = 0,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        zinput.init();
        zapp.setTitle(title);
        return .{ .width = width, .height = height };
    }

    pub fn deinit(_: *Host) void {}

    pub fn pollInputs(self: *Host) InputState {
        zinput.poll();

        const mouse = zinput.getMouse();
        const cur_left = mouse.buttons.left;
        const mouse_down = !self.prev_left and cur_left;
        const mouse_up = self.prev_left and !cur_left;
        self.prev_left = cur_left;

        self.keys_len = 0;
        for (key_mappings) |m| {
            if (self.keys_len >= self.keys_buf.len) break;
            if (zinput.isKeyPressed(m.from)) {
                self.keys_buf[self.keys_len] = m.to;
                self.keys_len += 1;
            }
        }

        // Zunk pushes Backspace (8) and Enter (10) into typed_chars in
        // addition to reporting them as pressed keys. Without this filter,
        // backspace double-acts: it inserts char 8 then deletes one, and the
        // user sees nothing change. Drop ASCII control codes here — the
        // special-key path owns those events. Tracked upstream at
        // https://github.com/hotschmoe/zunk/issues/8.
        self.chars_len = 0;
        for (zinput.getTypedChars()) |c| {
            if (c < 0x20 or c == 0x7f) continue;
            if (self.chars_len >= self.chars_buf.len) break;
            self.chars_buf[self.chars_len] = c;
            self.chars_len += 1;
        }

        const vp = zinput.getViewportSize();
        const w = if (vp.w != 0) vp.w else self.width;
        const h = if (vp.h != 0) vp.h else self.height;
        const resized = self.first_poll or w != self.width or h != self.height;
        self.first_poll = false;
        self.width = w;
        self.height = h;

        return .{
            .mouse_x = mouse.x,
            .mouse_y = mouse.y,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .chars = self.chars_buf[0..self.chars_len],
            .keys = self.keys_buf[0..self.keys_len],
            .resized = resized,
            .width = w,
            .height = h,
        };
    }

    pub fn shouldClose(_: *const Host) bool {
        return false;
    }

    pub fn nativeHandle(_: *const Host) NativeHandle {
        return .{};
    }

    /// Measures via canvas 2D through `zunk.web.gpu.measureText`. Results
    /// are cached by (content_hash, size, family) because every
    /// measurement pays a wasm↔JS round-trip. Zunk's `TextMetrics`
    /// carries only width/height; ascent/descent are synthesized with
    /// the same 0.75/0.25 split `teak.monoMeasurer` uses.
    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = zunkMeasure };
    }

    fn zunkMeasure(ctx: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.measure_tick += 1;
        const size_px: u16 = @intFromFloat(font.size_px);
        const content_hash = std.hash.Wyhash.hash(0, text_bytes);

        for (self.measure_cache[0..self.measure_cache_len]) |*e| {
            if (e.content_hash == content_hash and
                e.content_len == text_bytes.len and
                e.size_px == size_px and
                e.family == font.family)
            {
                e.last_used = self.measure_tick;
                return e.metrics;
            }
        }

        var font_buf: [32]u8 = undefined;
        const css = std.fmt.bufPrint(&font_buf, "{d}px {s}", .{
            size_px,
            cssFontFamily(font.family),
        }) catch return fallbackMetrics(font);

        const raw = zgpu.measureText(text_bytes, css);
        // Canvas `measureText` returns glyph-tight height
        // (actualBoundingBoxAscent + Descent), which varies per string —
        // "hello" is shorter than "helloy". Native returns font-scope
        // `tm.tmHeight` so every label sits on the same baseline.
        // Stabilize the web side with an em-plus-leading approximation;
        // rasterize-side em still fits because canvas `textBaseline='top'`
        // draws em-top at y=0 and 1.2× em leaves room for descenders.
        const stable_h = @ceil(font.size_px * 1.2);
        const metrics: TextMetrics = .{
            .width = @floatFromInt(raw.width),
            .height = stable_h,
            .ascent = font.size_px * 0.75,
            .descent = font.size_px * 0.25,
        };

        const slot = if (self.measure_cache_len < self.measure_cache.len) blk: {
            const i = self.measure_cache_len;
            self.measure_cache_len += 1;
            break :blk i;
        } else blk: {
            var oldest: usize = 0;
            var oldest_tick: u64 = self.measure_cache[0].last_used;
            for (self.measure_cache[0..self.measure_cache_len], 0..) |*e, i| {
                if (e.last_used < oldest_tick) {
                    oldest = i;
                    oldest_tick = e.last_used;
                }
            }
            break :blk oldest;
        };

        self.measure_cache[slot] = .{
            .content_hash = content_hash,
            .content_len = @intCast(text_bytes.len),
            .size_px = size_px,
            .family = font.family,
            .metrics = metrics,
            .last_used = self.measure_tick,
        };
        return metrics;
    }

    fn fallbackMetrics(font: FontSpec) TextMetrics {
        return .{
            .width = 0,
            .height = font.size_px,
            .ascent = font.size_px * 0.75,
            .descent = font.size_px * 0.25,
        };
    }
};

fn cssFontFamily(family: FontFamily) []const u8 {
    return switch (family) {
        .sans => "sans-serif",
        .serif => "serif",
        .mono => "monospace",
    };
}

comptime {
    teak.validateHost(Host);
}
