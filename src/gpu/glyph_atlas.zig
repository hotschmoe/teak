//! GlyphAtlas: pure CPU-side bookkeeping for a paged glyph-texture atlas
//! (docs/features/text-engine.md section 3). No GPU types and no pixel storage:
//! the backend owns the R8 page textures/staging and consumes this structure's
//! answers ("glyph K lives at page P, rect R") and dirty rects.
//!
//! Model:
//! * Pages are `page_size` x `page_size` R8 (1 MiB), created lazily up to `max_pages`.
//! * Each page is a shelf packer (shelf height = glyph height rounded up to 4 px).
//! * Eviction is page-granular: resetting a page bumps its `gen`, which makes every
//!   table entry that points into it stale in O(1) (valid iff `entry.gen == page.gen`).
//! * Pinning is per frame: any page that served a lookup/insert this frame
//!   (`last_used_frame == frame`) is never reset. If every page is pinned and a glyph
//!   does not fit, `insert` returns `error.AllPagesPinned` (the caller logs loudly and
//!   drops the glyph for the frame).
//! * Keys are compared in full; the hash only picks the probe start.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const page_size: u32 = 1024;
pub const default_max_pages: u8 = 8;
/// Transparent border reserved around every glyph so bilinear sampling can't bleed.
pub const padding: u32 = 1;
/// Shelf heights are rounded up to a multiple of this.
pub const shelf_quantum: u32 = 4;
const max_shelves: usize = page_size / shelf_quantum;

/// Atlas entry identity. Compared in full (never hash-only).
pub const GlyphKey = packed struct(u64) {
    /// Index into the Host face table (family x weight x fallback slot).
    face: u16,
    /// Glyph id.
    glyph: u16,
    /// Physical pixel size in 1/4 px: round(size_px * scale * 4).
    size_q: u16,
    /// X subpixel bin 0..3 (0.25 px steps); 0 for grid-snapped faces.
    bin: u2,
    /// 0 = coverage, 1 = sdf (reserved).
    mode: u2 = 0,
    _pad: u12 = 0,

    pub fn asInt(self: GlyphKey) u64 {
        return @bitCast(self);
    }
};

/// Per-glyph GPU instance (section 3.5). Layout is part of the shader contract.
pub const GlyphInstance = extern struct {
    /// Quad top-left in physical px, already bearing-adjusted and bin-snapped.
    x: f32,
    y: f32,
    /// Quad size in px == atlas rect size.
    w: u16,
    h: u16,
    /// Atlas texel origin of the glyph rect.
    u: u16,
    v: u16,
    /// RGBA8; alpha scales coverage.
    color: u32,
    /// Scroll clip in physical px; all zero = unclipped.
    clip_xy: [2]i16 = .{ 0, 0 },
    clip_wh: [2]u16 = .{ 0, 0 },
    /// bit0-1 mode (coverage/sdf), bits 8+ reserved.
    flags: u32 = 0,
};

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// Resolved glyph location. `rect` excludes the padding border.
pub const Entry = struct {
    key: GlyphKey,
    page: u8,
    gen: u32,
    rect: Rect,
    bearing_x: i16,
    bearing_y: i16,
};

pub const InsertError = error{
    /// Glyph (plus padding) is larger than a page.
    GlyphTooLarge,
    /// Every page was used this frame and none has room: loud, never UB.
    AllPagesPinned,
    OutOfMemory,
};

pub fn defaultHash(key: GlyphKey) u64 {
    // splitmix64 finalizer.
    var z = key.asInt() +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub const GlyphAtlas = GlyphAtlasWith(defaultHash);

/// Atlas parameterised on the hash function so tests can force collisions.
pub fn GlyphAtlasWith(comptime hashFn: fn (GlyphKey) u64) type {
    return struct {
        const Self = @This();

        const Shelf = struct { y: u16, h: u16, x: u16 };

        const Page = struct {
            gen: u32 = 0,
            /// Frame number of the last lookup/insert that touched this page; 0 = never.
            last_used_frame: u64 = 0,
            shelf_count: u16 = 0,
            /// Next free y for opening a shelf.
            next_y: u16 = 0,
            /// Padded area currently allocated (diagnostics: fill ratio).
            used_area: u32 = 0,
            dirty: ?Rect = null,
            shelves: [max_shelves]Shelf = undefined,
        };

        /// Slot state: `.page == empty_page` marks an empty slot (probe terminator).
        const empty_page: u8 = 0xff;

        allocator: Allocator,
        max_pages: u8,
        pages: std.ArrayList(Page) = .empty,
        slots: []Entry,
        occupied: usize = 0,
        /// Current frame, starts at 1 so `last_used_frame == 0` means "never used".
        frame: u64 = 1,

        pub fn init(allocator: Allocator, max_pages: u8) Allocator.Error!Self {
            std.debug.assert(max_pages > 0 and max_pages < empty_page);
            var self: Self = .{
                .allocator = allocator,
                .max_pages = max_pages,
                .slots = &.{},
            };
            self.slots = try allocSlots(allocator, 256);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.pages.deinit(self.allocator);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        fn allocSlots(allocator: Allocator, n: usize) Allocator.Error![]Entry {
            const slots = try allocator.alloc(Entry, n);
            for (slots) |*s| s.page = empty_page;
            return slots;
        }

        /// Start a new frame: pages touched in earlier frames become evictable.
        pub fn beginFrame(self: *Self) void {
            self.frame += 1;
        }

        pub fn pageCount(self: *const Self) usize {
            return self.pages.items.len;
        }

        pub fn pageGen(self: *const Self, page: u8) u32 {
            return self.pages.items[page].gen;
        }

        /// Fraction (0..1) of a page's area occupied by padded glyph rects.
        pub fn pageFill(self: *const Self, page: u8) f32 {
            const area: f32 = @floatFromInt(page_size * page_size);
            return @as(f32, @floatFromInt(self.pages.items[page].used_area)) / area;
        }

        fn isValid(self: *const Self, e: *const Entry) bool {
            if (e.rect.w == 0 or e.rect.h == 0) return true; // blank glyph, owns no texels
            return e.gen == self.pages.items[e.page].gen;
        }

        fn mask(self: *const Self) usize {
            return self.slots.len - 1;
        }

        /// Find a live entry. A hit pins its page for the current frame.
        pub fn lookup(self: *Self, key: GlyphKey) ?Entry {
            var i: usize = @intCast(hashFn(key) & self.mask());
            while (true) : (i = (i + 1) & self.mask()) {
                const s = &self.slots[i];
                if (s.page == empty_page) return null;
                if (s.key.asInt() == key.asInt()) {
                    if (!self.isValid(s)) return null;
                    if (s.rect.w != 0 and s.rect.h != 0) self.pages.items[s.page].last_used_frame = self.frame;
                    return s.*;
                }
            }
        }

        /// Reserve space for a glyph bitmap of `w` x `h` texels and record it.
        /// The caller writes the pixels at `entry.rect` in page `entry.page`; the rect
        /// is already marked dirty. Any previous entry for `key` is replaced.
        pub fn insert(self: *Self, key: GlyphKey, w: u16, h: u16, bearing_x: i16, bearing_y: i16) InsertError!Entry {
            var entry: Entry = .{
                .key = key,
                .page = 0,
                .gen = 0,
                .rect = .{ .x = 0, .y = 0, .w = w, .h = h },
                .bearing_x = bearing_x,
                .bearing_y = bearing_y,
            };
            if (w != 0 and h != 0) {
                const pw = @as(u32, w) + 2 * padding;
                const ph = @as(u32, h) + 2 * padding;
                if (pw > page_size or ph > page_size) return error.GlyphTooLarge;
                const loc = try self.allocRect(pw, ph);
                const page = &self.pages.items[loc.page];
                page.last_used_frame = self.frame;
                entry.page = loc.page;
                entry.gen = page.gen;
                entry.rect.x = loc.x + @as(u16, padding);
                entry.rect.y = loc.y + @as(u16, padding);
                // Dirty region covers the padding so stale texels get cleared.
                self.markDirty(page, .{ .x = loc.x, .y = loc.y, .w = @intCast(pw), .h = @intCast(ph) });
            }
            try self.put(entry);
            return entry;
        }

        const Loc = struct { page: u8, x: u16, y: u16 };

        fn allocRect(self: *Self, pw: u32, ph: u32) InsertError!Loc {
            // 1. any existing page with room (newest first: most likely to have space).
            if (self.tryExisting(pw, ph)) |loc| return loc;
            // 2. open a new page.
            if (self.pages.items.len < self.max_pages) {
                try self.pages.append(self.allocator, .{});
                const idx: u8 = @intCast(self.pages.items.len - 1);
                return tryPage(&self.pages.items[idx], idx, pw, ph) orelse error.GlyphTooLarge;
            }
            // 3. reset the oldest page not used this frame.
            var victim: ?u8 = null;
            var oldest: u64 = std.math.maxInt(u64);
            for (self.pages.items, 0..) |p, i| {
                if (p.last_used_frame < self.frame and p.last_used_frame < oldest) {
                    oldest = p.last_used_frame;
                    victim = @intCast(i);
                }
            }
            const v = victim orelse return error.AllPagesPinned;
            self.resetPage(v);
            return tryPage(&self.pages.items[v], v, pw, ph) orelse error.GlyphTooLarge;
        }

        fn tryExisting(self: *Self, pw: u32, ph: u32) ?Loc {
            var i = self.pages.items.len;
            while (i > 0) {
                i -= 1;
                if (tryPage(&self.pages.items[i], @intCast(i), pw, ph)) |loc| return loc;
            }
            return null;
        }

        fn tryPage(page: *Page, idx: u8, pw: u32, ph: u32) ?Loc {
            const class = std.mem.alignForward(u32, ph, shelf_quantum);
            var best: ?*Shelf = null;
            for (page.shelves[0..page.shelf_count]) |*s| {
                if (s.h < ph or s.h > class or s.x + pw > page_size) continue;
                if (best == null or s.h < best.?.h) best = s;
            }
            if (best) |s| {
                const loc: Loc = .{ .page = idx, .x = s.x, .y = s.y };
                s.x += @intCast(pw);
                page.used_area += pw * ph;
                return loc;
            }
            if (page.next_y + class > page_size) return null;
            page.shelves[page.shelf_count] = .{ .y = page.next_y, .h = @intCast(class), .x = @intCast(pw) };
            const loc: Loc = .{ .page = idx, .x = 0, .y = page.next_y };
            page.shelf_count += 1;
            page.next_y += @intCast(class);
            page.used_area += pw * ph;
            return loc;
        }

        fn resetPage(self: *Self, idx: u8) void {
            const p = &self.pages.items[idx];
            p.gen +%= 1; // O(1) invalidation of every entry in this page
            p.shelf_count = 0;
            p.next_y = 0;
            p.used_area = 0;
            p.dirty = null;
            p.last_used_frame = 0;
        }

        fn markDirty(_: *Self, page: *Page, r: Rect) void {
            if (page.dirty) |d| {
                const x0 = @min(d.x, r.x);
                const y0 = @min(d.y, r.y);
                const x1 = @max(@as(u32, d.x) + d.w, @as(u32, r.x) + r.w);
                const y1 = @max(@as(u32, d.y) + d.h, @as(u32, r.y) + r.h);
                page.dirty = .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
            } else page.dirty = r;
        }

        /// Take (and clear) the page's dirty rect for upload. A page recycled by
        /// eviction reports only rects written since the reset.
        pub fn takeDirty(self: *Self, page: u8) ?Rect {
            const p = &self.pages.items[page];
            const d = p.dirty;
            p.dirty = null;
            return d;
        }

        fn put(self: *Self, entry: Entry) Allocator.Error!void {
            if ((self.occupied + 1) * 10 > self.slots.len * 7) try self.rehash();
            var i: usize = @intCast(hashFn(entry.key) & self.mask());
            var reuse: ?usize = null;
            while (true) : (i = (i + 1) & self.mask()) {
                const s = &self.slots[i];
                if (s.page == empty_page) break;
                if (s.key.asInt() == entry.key.asInt()) {
                    s.* = entry;
                    return;
                }
                // Stale slots keep their chain intact, so they can host a new key.
                if (reuse == null and !self.isValid(s)) reuse = i;
            }
            if (reuse) |r| {
                self.slots[r] = entry;
            } else {
                self.slots[i] = entry;
                self.occupied += 1;
            }
        }

        /// Rebuild the table: drop stale entries, grow if mostly live.
        fn rehash(self: *Self) Allocator.Error!void {
            var live: usize = 0;
            for (self.slots) |*s| {
                if (s.page != empty_page and self.isValid(s)) live += 1;
            }
            var n = self.slots.len;
            if ((live + 1) * 10 > n * 4) n *= 2;
            const fresh = try allocSlots(self.allocator, n);
            const old = self.slots;
            self.slots = fresh;
            self.occupied = 0;
            for (old) |*s| {
                if (s.page == empty_page or !self.isValid(s)) continue;
                var i: usize = @intCast(hashFn(s.key) & self.mask());
                while (self.slots[i].page != empty_page) i = (i + 1) & self.mask();
                self.slots[i] = s.*;
                self.occupied += 1;
            }
            self.allocator.free(old);
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn K(glyph: u16, size_q: u16, bin: u2) GlyphKey {
    return .{ .face = 1, .glyph = glyph, .size_q = size_q, .bin = bin };
}

test "GlyphKey and GlyphInstance layout" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(GlyphKey));
    try testing.expectEqual(@as(usize, 32), @sizeOf(GlyphInstance));
    try testing.expectEqual(@as(usize, 4), @alignOf(GlyphInstance));
    try testing.expectEqual(@as(usize, 0), @offsetOf(GlyphInstance, "x"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(GlyphInstance, "y"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(GlyphInstance, "w"));
    try testing.expectEqual(@as(usize, 10), @offsetOf(GlyphInstance, "h"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(GlyphInstance, "u"));
    try testing.expectEqual(@as(usize, 14), @offsetOf(GlyphInstance, "v"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(GlyphInstance, "color"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(GlyphInstance, "clip_xy"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(GlyphInstance, "clip_wh"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(GlyphInstance, "flags"));
    // Bit layout of the key: face is the low 16 bits.
    const k = GlyphKey{ .face = 0xabcd, .glyph = 0, .size_q = 0, .bin = 3 };
    try testing.expectEqual(@as(u16, 0xabcd), @as(u16, @truncate(k.asInt())));
    try testing.expectEqual(@as(u64, 3) << 48, k.asInt() & (@as(u64, 3) << 48));
}

test "insert then lookup, rects are padded and disjoint" {
    var a = try GlyphAtlas.init(testing.allocator, 2);
    defer a.deinit();
    const e1 = try a.insert(K(1, 56, 0), 8, 10, 1, 9);
    const e2 = try a.insert(K(2, 56, 0), 8, 10, 0, 9);
    try testing.expect(e1.rect.x >= padding and e1.rect.y >= padding);
    try testing.expect(e2.rect.x >= e1.rect.x + e1.rect.w + 2 * padding - padding);
    const got = a.lookup(K(1, 56, 0)).?;
    try testing.expectEqual(e1.rect, got.rect);
    try testing.expectEqual(@as(i16, 9), got.bearing_y);
    try testing.expect(a.lookup(K(1, 56, 1)) == null);
    try testing.expect(a.lookup(K(3, 56, 0)) == null);
}

test "blank glyph needs no texels and never goes stale" {
    var a = try GlyphAtlas.init(testing.allocator, 1);
    defer a.deinit();
    _ = try a.insert(K(32, 56, 0), 0, 0, 0, 0);
    try testing.expectEqual(@as(usize, 0), a.pageCount());
    try testing.expect(a.lookup(K(32, 56, 0)) != null);
}

fn collideHash(_: GlyphKey) u64 {
    return 7;
}

test "full-key comparison under identical hashes" {
    var a = try GlyphAtlasWith(collideHash).init(testing.allocator, 1);
    defer a.deinit();
    var i: u16 = 0;
    while (i < 100) : (i += 1) _ = try a.insert(K(i, 56, 0), 6, 8, 0, 0);
    i = 0;
    while (i < 100) : (i += 1) {
        const e = a.lookup(K(i, 56, 0)).?;
        try testing.expectEqual(i, e.key.glyph);
    }
    try testing.expect(a.lookup(K(100, 56, 0)) == null);
    // Same glyph, different size/bin: distinct identity despite equal hash.
    try testing.expect(a.lookup(K(5, 60, 0)) == null);
    try testing.expect(a.lookup(K(5, 56, 2)) == null);
    // Re-inserting replaces rather than duplicates.
    const again = try a.insert(K(5, 56, 0), 6, 8, 0, 0);
    try testing.expectEqual(again.rect, a.lookup(K(5, 56, 0)).?.rect);
}

test "page-granular eviction bumps gen and invalidates in O(1)" {
    var a = try GlyphAtlas.init(testing.allocator, 2);
    defer a.deinit();
    // Page 0: fill with 256x256 glyphs (16 fit), then page 1.
    var n: u16 = 0;
    while (a.pageCount() < 2) : (n += 1) _ = try a.insert(K(n, 56, 0), 254, 254, 0, 0);
    const on_p0 = a.lookup(K(0, 56, 0)).?;
    try testing.expectEqual(@as(u8, 0), on_p0.page);
    try testing.expectEqual(@as(u32, 0), a.pageGen(0));
    // Fill page 1 completely; now everything is full. Same frame => all pinned.
    while (true) : (n += 1) {
        _ = a.insert(K(n, 56, 0), 254, 254, 0, 0) catch |err| {
            try testing.expectEqual(error.AllPagesPinned, err);
            break;
        };
    }
    // Next frame: touch page 1 only; page 0 is the oldest unpinned victim.
    a.beginFrame();
    const keep = a.lookup(K(n - 1, 56, 0)).?;
    try testing.expectEqual(@as(u8, 1), keep.page);
    const fresh = try a.insert(K(9999, 56, 0), 254, 254, 0, 0);
    try testing.expectEqual(@as(u8, 0), fresh.page);
    try testing.expectEqual(@as(u32, 1), a.pageGen(0));
    try testing.expectEqual(@as(u32, 0), a.pageGen(1));
    try testing.expect(a.lookup(K(0, 56, 0)) == null); // evicted, no per-entry work
    try testing.expect(a.lookup(K(n - 1, 56, 0)) != null); // untouched page survives
    try testing.expect(a.lookup(K(9999, 56, 0)) != null);
}

test "glyphs used this frame are never evicted mid-frame" {
    var a = try GlyphAtlas.init(testing.allocator, 1);
    defer a.deinit();
    var n: u16 = 0;
    while (true) : (n += 1) {
        _ = a.insert(K(n, 56, 0), 254, 254, 0, 0) catch break;
    }
    try testing.expectEqual(error.AllPagesPinned, a.insert(K(5000, 56, 0), 10, 10, 0, 0));
    try testing.expect(a.lookup(K(0, 56, 0)) != null);
    // The failed insert left the table consistent.
    try testing.expect(a.lookup(K(5000, 56, 0)) == null);
    a.beginFrame();
    _ = try a.insert(K(5000, 56, 0), 10, 10, 0, 0);
    try testing.expectEqual(@as(u32, 1), a.pageGen(0));
}

test "oversized glyph is an error value" {
    var a = try GlyphAtlas.init(testing.allocator, 1);
    defer a.deinit();
    try testing.expectError(error.GlyphTooLarge, a.insert(K(1, 1, 0), 1024, 10, 0, 0));
}

test "dirty rect is the union of inserts and clears on take" {
    var a = try GlyphAtlas.init(testing.allocator, 1);
    defer a.deinit();
    const e1 = try a.insert(K(1, 56, 0), 10, 10, 0, 0);
    const e2 = try a.insert(K(2, 56, 0), 10, 10, 0, 0);
    const d = a.takeDirty(0).?;
    try testing.expect(d.x <= e1.rect.x - 1 and d.y <= e1.rect.y - 1);
    try testing.expect(d.x + d.w >= e2.rect.x + e2.rect.w + 1);
    try testing.expect(a.takeDirty(0) == null);
}

test "table survives many stale generations (rehash drops stale slots)" {
    var a = try GlyphAtlas.init(testing.allocator, 2);
    defer a.deinit();
    var n: u16 = 0;
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        a.beginFrame();
        // 128 px cells => 64 per page, 128 across both pages: 50 per frame always fits.
        var j: u16 = 0;
        while (j < 50) : (j += 1) {
            _ = try a.insert(K(n, 56, 0), 126, 126, 0, 0);
            n +%= 1;
        }
    }
    try testing.expect(a.slots.len <= 1024);
    try testing.expect(a.lookup(K(n -% 1, 56, 0)) != null);
}

/// Synthetic realistic glyph mix (documented distribution): UI font sizes
/// 11..32 px with weights favouring body sizes; per size, width 0.30..0.65 em,
/// height 0.55..1.15 em (x-height glyphs through ascender+descender).
fn syntheticGlyph(rng: std.Random) struct { w: u16, h: u16 } {
    const sizes = [_]u8{ 11, 12, 12, 13, 13, 14, 14, 14, 16, 16, 18, 20, 24, 32 };
    const s: f32 = @floatFromInt(sizes[rng.uintLessThan(usize, sizes.len)]);
    const w = s * (0.30 + 0.35 * rng.float(f32));
    const h = s * (0.55 + 0.60 * rng.float(f32));
    return .{ .w = @max(1, @as(u16, @intFromFloat(@round(w)))), .h = @max(1, @as(u16, @intFromFloat(@round(h)))) };
}

test "shelf packer fills a page to at least 80% with a realistic mix" {
    var prng = std.Random.DefaultPrng.init(0x7ea4);
    var a = try GlyphAtlas.init(testing.allocator, 1);
    defer a.deinit();
    var n: u32 = 0;
    while (true) : (n += 1) {
        const g = syntheticGlyph(prng.random());
        _ = a.insert(K(@truncate(n), @truncate(n >> 16), 0), g.w, g.h, 0, 0) catch break;
    }
    const fill = a.pageFill(0);
    std.debug.print("\natlas fill at first overflow: {d:.1}% after {d} glyphs\n", .{ fill * 100, n });
    try testing.expect(fill >= 0.80);
}

test "bench: 100k warm lookups" {
    var a = try GlyphAtlas.init(testing.allocator, 8);
    defer a.deinit();
    var g: u16 = 0;
    while (g < 95) : (g += 1) {
        var b: u2 = 0;
        while (true) : (b += 1) {
            _ = try a.insert(K(g, 56, b), 8, 11, 0, 0);
            if (b == 3) break;
        }
    }
    const t0 = std.Io.Clock.awake.now(testing.io);
    var hits: usize = 0;
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const k = K(@intCast(i % 95), 56, @truncate(i >> 3));
        if (a.lookup(k) != null) hits += 1;
    }
    const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds);
    std.debug.print("\n100k warm lookups: {d} ns total, {d:.1} ns/lookup (hits {d})\n", .{ ns, @as(f64, @floatFromInt(ns)) / 100_000.0, hits });
    try testing.expectEqual(@as(usize, 100_000), hits);
}
