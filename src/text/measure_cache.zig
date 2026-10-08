//! Memo table for `measure.measure` (text-engine plan 8.1).
//!
//! Text measurement is a pure function of (text, font) but costs a shaper
//! run per call, and layout, render and caret placement ask for the same
//! strings every frame. This cache lives in the Host layer (`teak-text`), so
//! core layout stays a pure function of its inputs; a miss just re-measures.
//!
//! Key: full 64-bit wyhash of the text mixed with every `FontSpec` field that
//! affects metrics, plus the text length and a second independent 32-bit hash
//! (96 bits of collision guard in total; no raw text is stored).
//! Policy: fixed `capacity` open-addressed slots, linear probing of
//! `probe_limit`; when a probe window is full the entry is dropped (lookups
//! then simply miss) and the table is cleared wholesale once 75% full.
//! `clear()` is called whenever a font is registered or released, because
//! that changes what any (family, weight) resolves to.
//!
//! Single-threaded like the rest of the face registry (the Host owns it).

const std = @import("std");
const teak = @import("teak");

pub const capacity = 4096;
const probe_limit = 8;
const max_load = capacity / 4 * 3;

const Entry = struct {
    key: u64 = 0,
    check: u32 = 0,
    len: u32 = 0,
    used: bool = false,
    metrics: teak.TextMetrics = undefined,
};

var table: [capacity]Entry = @splat(.{});
var count: usize = 0;

/// Forget every memoized measurement.
pub fn clear() void {
    table = @splat(.{});
    count = 0;
}

fn fontBits(font: teak.FontSpec) u64 {
    const size: u64 = @as(u32, @bitCast(font.size_px));
    const ls: u64 = @as(u32, @bitCast(font.letter_spacing));
    return size ^ (ls << 32) ^ (@as(u64, @backingInt(font.family)) << 56) ^
        (@as(u64, @backingInt(font.weight)) << 48) ^ (@as(u64, if (font.snap_advance) |b| 1 + @as(u64, @intFromBool(b)) else 0) << 40);
}

fn hashKey(text: []const u8, font: teak.FontSpec) struct { key: u64, check: u32 } {
    const fb = fontBits(font);
    return .{
        .key = std.hash.Wyhash.hash(fb, text),
        .check = @truncate(std.hash.Wyhash.hash(~fb ^ 0x9e3779b97f4a7c15, text)),
    };
}

/// Cached metrics for (`text`, `font`), or null on a miss.
pub fn lookup(text: []const u8, font: teak.FontSpec) ?teak.TextMetrics {
    const h = hashKey(text, font);
    var i: usize = @intCast(h.key % capacity);
    for (0..probe_limit) |_| {
        const e = &table[i];
        if (!e.used) return null;
        if (e.key == h.key and e.check == h.check and e.len == text.len) return e.metrics;
        i = (i + 1) % capacity;
    }
    return null;
}

/// Remember `m` as the metrics of (`text`, `font`).
pub fn insert(text: []const u8, font: teak.FontSpec, m: teak.TextMetrics) void {
    if (count >= max_load) clear();
    const h = hashKey(text, font);
    var i: usize = @intCast(h.key % capacity);
    for (0..probe_limit) |_| {
        const e = &table[i];
        if (!e.used) count += 1;
        if (!e.used or (e.key == h.key and e.check == h.check and e.len == text.len)) {
            e.* = .{ .key = h.key, .check = h.check, .len = @intCast(text.len), .used = true, .metrics = m };
            return;
        }
        i = (i + 1) % capacity;
    }
    // Probe window full: drop the entry (a later lookup re-measures).
}

test "lookup misses, then hits after insert; font and text both key it" {
    clear();
    const f: teak.FontSpec = .{};
    const m: teak.TextMetrics = .{ .width = 10, .height = 20, .ascent = 15, .descent = 5 };
    try std.testing.expect(lookup("hello", f) == null);
    insert("hello", f, m);
    try std.testing.expectEqual(@as(f32, 10), lookup("hello", f).?.width);
    try std.testing.expect(lookup("hellO", f) == null);
    var g = f;
    g.size_px = 15;
    try std.testing.expect(lookup("hello", g) == null);
    g = f;
    g.weight = .bold;
    try std.testing.expect(lookup("hello", g) == null);
    clear();
    try std.testing.expect(lookup("hello", f) == null);
}

test "fills past 75% by clearing wholesale; never returns a wrong entry" {
    clear();
    const f: teak.FontSpec = .{};
    var buf: [16]u8 = undefined;
    for (0..capacity * 2) |i| {
        const s = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable;
        insert(s, f, .{ .width = @floatFromInt(i), .height = 0, .ascent = 0, .descent = 0 });
        if (lookup(s, f)) |m| try std.testing.expectEqual(@as(f32, @floatFromInt(i)), m.width);
    }
    try std.testing.expect(count <= max_load + 1);
    clear();
}
