//! Shared glyph cache for GPU backends.
//!
//! Both `gpu/native.zig` and `gpu/web.zig` rasterize text strings into
//! GPU textures and cache the results. The cache's data layout, keying,
//! lookup, LRU policy, and insert path are identical across backends —
//! only the concrete resource types (`WGPUTexture` vs `zgpu.Texture`,
//! etc.) and the destroy semantics differ. Factoring the cache here
//! removes the duplicate copies.
//!
//! Lives in `src/gpu/` per HARDLINE §4(a): platform-mutable resource
//! state is allowed in `src/platform/*` and `src/gpu/*`. Framework core
//! (core/, layout/, input/, render/) never imports this module.
//!
//! API shape: `GlyphCache(comptime Backend: type)` — same idiom as
//! `std.ArrayList(T)` / `std.io.Writer`. The Backend type declares the
//! resource types and a `destroyEntry` method; the cache dispatches to
//! it at compile time. No runtime fn-pointers.

const std = @import("std");
const builtin = @import("builtin");
const teak = @import("teak");

pub const CAPACITY: usize = 256;

/// Instrumentation toggle — debug builds track hits/misses/evictions,
/// release builds compile the increments out. Tests run in Debug by
/// default so counter assertions hold.
const track_stats = builtin.mode == .Debug;

/// Pure cache-key composition. Same XOR compose both backends used
/// before factoring.
pub fn textCacheKey(
    content: []const u8,
    font: teak.FontSpec,
    color: [4]f32,
    w: u32,
    h: u32,
) u64 {
    const content_hash = std.hash.Wyhash.hash(0, content);
    const color_bits =
        (@as(u32, @intFromFloat(std.math.clamp(color[0], 0, 1) * 255)) << 24) |
        (@as(u32, @intFromFloat(std.math.clamp(color[1], 0, 1) * 255)) << 16) |
        (@as(u32, @intFromFloat(std.math.clamp(color[2], 0, 1) * 255)) << 8) |
        (@as(u32, @intFromFloat(std.math.clamp(color[3], 0, 1) * 255)));
    const size_px: u16 = @intFromFloat(font.size_px);
    const font_bits: u64 = (@as(u64, size_px) << 16) | @as(u64, @intFromEnum(font.family));
    const dim_bits: u64 = (@as(u64, w) << 32) | @as(u64, h);
    return content_hash ^ font_bits ^ @as(u64, color_bits) ^ dim_bits;
}

pub const Stats = struct { hits: u32, misses: u32, evictions: u32 };

/// Backend contract:
/// ```
/// pub const Texture = …;
/// pub const View = …;
/// pub const BindGroup = …;
/// pub fn destroyEntry(e: anytype) void;   // called on evict + clear
/// ```
/// `destroyEntry` receives a pointer to the cache Entry and is
/// responsible for releasing whichever resource fields the backend
/// actually owns (native releases all three; web releases only the
/// texture because zunk has no destroy for views / bind groups).
pub fn GlyphCache(comptime Backend: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: u64 = 0,
            content_len: u32 = 0,
            content_hash: u64 = 0,
            texture: Backend.Texture = undefined,
            view: Backend.View = undefined,
            bind_group: Backend.BindGroup = undefined,
            last_used_frame: u64 = 0,
        };

        entries: [CAPACITY]Entry = [_]Entry{.{}} ** CAPACITY,
        len: usize = 0,
        frame_counter: u64 = 0,
        hits: u32 = 0,
        misses: u32 = 0,
        evictions: u32 = 0,

        /// Advance frame counter. Call once per frame before any lookups.
        pub fn tick(self: *Self) void {
            self.frame_counter += 1;
        }

        /// Returns a handle (`slot + 1`) on hit, `TEXTURE_HANDLE_NONE` on
        /// miss. On hit, updates `last_used_frame`.
        pub fn lookup(
            self: *Self,
            key: u64,
            content_len: usize,
            content_hash: u64,
        ) teak.TextureHandle {
            for (self.entries[0..self.len], 0..) |*e, i| {
                if (e.key == key and e.content_len == content_len and e.content_hash == content_hash) {
                    e.last_used_frame = self.frame_counter;
                    if (track_stats) self.hits += 1;
                    return @intCast(i + 1);
                }
            }
            if (track_stats) self.misses += 1;
            return teak.TEXTURE_HANDLE_NONE;
        }

        /// Evict the LRU entry iff at capacity. No-op below capacity.
        /// Calls `Backend.destroyEntry` on the victim, then swap-with-
        /// last to keep the array compact.
        pub fn evictLRU(self: *Self) void {
            if (self.len < self.entries.len) return;
            var oldest: usize = 0;
            var oldest_frame: u64 = self.entries[0].last_used_frame;
            for (self.entries[0..self.len], 0..) |*e, i| {
                if (e.last_used_frame < oldest_frame) {
                    oldest = i;
                    oldest_frame = e.last_used_frame;
                }
            }
            Backend.destroyEntry(&self.entries[oldest]);
            self.entries[oldest] = self.entries[self.len - 1];
            self.len -= 1;
            if (track_stats) self.evictions += 1;
        }

        /// Insert a freshly-rasterized entry. Caller must have ensured
        /// capacity via `evictLRU` first.
        pub fn insert(
            self: *Self,
            key: u64,
            content_len: u32,
            content_hash: u64,
            texture: Backend.Texture,
            view: Backend.View,
            bind_group: Backend.BindGroup,
        ) teak.TextureHandle {
            self.entries[self.len] = .{
                .key = key,
                .content_len = content_len,
                .content_hash = content_hash,
                .texture = texture,
                .view = view,
                .bind_group = bind_group,
                .last_used_frame = self.frame_counter,
            };
            self.len += 1;
            return @intCast(self.len);
        }

        pub fn entryPtr(self: *Self, handle: teak.TextureHandle) *Entry {
            return &self.entries[handle - 1];
        }

        /// Drop all entries, calling `Backend.destroyEntry` on each.
        pub fn clear(self: *Self) void {
            for (self.entries[0..self.len]) |*e| Backend.destroyEntry(e);
            self.len = 0;
        }

        pub fn stats(self: *const Self) Stats {
            return .{ .hits = self.hits, .misses = self.misses, .evictions = self.evictions };
        }

        pub fn resetStats(self: *Self) void {
            self.hits = 0;
            self.misses = 0;
            self.evictions = 0;
        }

        /// True once every 60 frames in Debug, never in Release.
        /// Backends gate periodic stats logging on this without pulling
        /// in a wall-clock.
        pub fn shouldReport(self: *const Self) bool {
            return track_stats and self.frame_counter != 0 and self.frame_counter % 60 == 0;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────
//
// Use stub u32 placeholders for the three resource types; real GPU
// resources aren't needed to exercise the cache's data layout and
// policy.

const TestBackend = struct {
    pub const Texture = u32;
    pub const View = u32;
    pub const BindGroup = u32;

    pub var destroy_count: u32 = 0;

    pub fn destroyEntry(_: anytype) void {
        destroy_count += 1;
    }
};

fn resetTestBackend() void {
    TestBackend.destroy_count = 0;
}

test "lookup miss, insert, then hit" {
    resetTestBackend();
    var cache = GlyphCache(TestBackend){};
    const font = teak.FontSpec{ .family = .sans, .size_px = 14 };
    const color = [4]f32{ 1, 1, 1, 1 };

    cache.tick();
    const content = "hello";
    const key = textCacheKey(content, font, color, 50, 20);
    const hash = std.hash.Wyhash.hash(0, content);

    try std.testing.expectEqual(teak.TEXTURE_HANDLE_NONE, cache.lookup(key, content.len, hash));
    cache.evictLRU();
    const h1 = cache.insert(key, @intCast(content.len), hash, 1, 2, 3);
    try std.testing.expect(h1 != teak.TEXTURE_HANDLE_NONE);

    const h2 = cache.lookup(key, content.len, hash);
    try std.testing.expectEqual(h1, h2);

    const e = cache.entryPtr(h2);
    try std.testing.expectEqual(@as(u32, 1), e.texture);
    try std.testing.expectEqual(@as(u32, 2), e.view);
    try std.testing.expectEqual(@as(u32, 3), e.bind_group);

    const s = cache.stats();
    try std.testing.expectEqual(@as(u32, 1), s.misses);
    try std.testing.expectEqual(@as(u32, 1), s.hits);
    try std.testing.expectEqual(@as(u32, 0), s.evictions);
}

test "LRU eviction picks the oldest untouched entry" {
    resetTestBackend();
    var cache = GlyphCache(TestBackend){};
    const font = teak.FontSpec{ .family = .sans, .size_px = 14 };
    const color = [4]f32{ 1, 1, 1, 1 };

    // Fill to capacity, one entry per frame, so slot 0 has
    // last_used_frame == 1 and slot CAPACITY-1 has == CAPACITY.
    var i: u32 = 0;
    while (i < CAPACITY) : (i += 1) {
        cache.tick();
        var buf: [8]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        const key = textCacheKey(content, font, color, 50, 20);
        const hash = std.hash.Wyhash.hash(0, content);
        _ = cache.insert(key, @intCast(content.len), hash, i + 1, i + 1, i + 1);
    }
    try std.testing.expectEqual(@as(usize, CAPACITY), cache.len);

    // Refresh slot 0 by looking it up on a later frame.
    cache.tick();
    {
        const content = "0";
        const key = textCacheKey(content, font, color, 50, 20);
        const hash = std.hash.Wyhash.hash(0, content);
        const h = cache.lookup(key, content.len, hash);
        try std.testing.expect(h != teak.TEXTURE_HANDLE_NONE);
    }

    // Oldest untouched is now slot 1 (content "1"). Insert a new
    // entry; eviction should remove slot 1's texture (u32 value 2).
    cache.tick();
    const fresh = "fresh";
    const fresh_key = textCacheKey(fresh, font, color, 50, 20);
    const fresh_hash = std.hash.Wyhash.hash(0, fresh);

    const before_evictions = cache.stats().evictions;
    cache.evictLRU();
    try std.testing.expectEqual(before_evictions + 1, cache.stats().evictions);
    try std.testing.expectEqual(@as(u32, 1), TestBackend.destroy_count);

    _ = cache.insert(fresh_key, @intCast(fresh.len), fresh_hash, 9999, 9999, 9999);
    try std.testing.expectEqual(@as(usize, CAPACITY), cache.len);

    // Slot 1's content "1" should no longer hit.
    const gone = "1";
    const gone_key = textCacheKey(gone, font, color, 50, 20);
    const gone_hash = std.hash.Wyhash.hash(0, gone);
    try std.testing.expectEqual(teak.TEXTURE_HANDLE_NONE, cache.lookup(gone_key, gone.len, gone_hash));

    // Slot 0's content "0" still hits (we refreshed it).
    const kept = "0";
    const kept_key = textCacheKey(kept, font, color, 50, 20);
    const kept_hash = std.hash.Wyhash.hash(0, kept);
    try std.testing.expect(cache.lookup(kept_key, kept.len, kept_hash) != teak.TEXTURE_HANDLE_NONE);
}

test "WS5: fixed UI × 200 frames drops to 0 misses after frame 1" {
    resetTestBackend();
    var cache = GlyphCache(TestBackend){};
    const font = teak.FontSpec{ .family = .sans, .size_px = 14 };
    const color = [4]f32{ 1, 1, 1, 1 };
    const strings = [_][]const u8{ "Hello", "+", "-", "count: 0" };

    var frame: u32 = 0;
    while (frame < 200) : (frame += 1) {
        cache.tick();
        for (strings) |s| {
            const key = textCacheKey(s, font, color, 100, 20);
            const hash = std.hash.Wyhash.hash(0, s);
            const handle = cache.lookup(key, s.len, hash);
            if (handle == teak.TEXTURE_HANDLE_NONE) {
                cache.evictLRU();
                _ = cache.insert(key, @intCast(s.len), hash, frame, frame, frame);
            }
        }
    }

    const s = cache.stats();
    // Exactly strings.len misses (all on frame 1), rest are hits.
    try std.testing.expectEqual(@as(u32, strings.len), s.misses);
    try std.testing.expectEqual(@as(u32, strings.len * 199), s.hits);
    try std.testing.expectEqual(@as(u32, 0), s.evictions);
}

test "clear calls destroyEntry on every entry and resets len" {
    resetTestBackend();
    var cache = GlyphCache(TestBackend){};
    const font = teak.FontSpec{ .family = .sans, .size_px = 14 };
    const color = [4]f32{ 1, 1, 1, 1 };

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        cache.tick();
        var buf: [4]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable;
        const key = textCacheKey(content, font, color, 50, 20);
        const hash = std.hash.Wyhash.hash(0, content);
        _ = cache.insert(key, @intCast(content.len), hash, i, i, i);
    }
    try std.testing.expectEqual(@as(usize, 5), cache.len);

    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.len);
    try std.testing.expectEqual(@as(u32, 5), TestBackend.destroy_count);
}
