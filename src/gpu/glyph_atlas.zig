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

        /// Whether `e` (an entry returned earlier) still describes live texels.
        pub fn stillValid(self: *const Self, e: *const Entry) bool {
            return self.isValid(e);
        }

        /// Pin `e`'s page for the current frame, as a `lookup` hit does.
        /// Pin `page` for this frame (reused instances keep pointing into it).
        pub fn pinPage(self: *Self, page: u8) void {
            self.pages.items[page].last_used_frame = self.frame;
        }

        pub fn touch(self: *Self, e: *const Entry) void {
            if (e.rect.w != 0 and e.rect.h != 0) self.pages.items[e.page].last_used_frame = self.frame;
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
            if (self.tryExisting(pw, ph)) |loc| return loc;
            if (self.pages.items.len < self.max_pages) {
                try self.pages.append(self.allocator, .{});
                const idx: u8 = @intCast(self.pages.items.len - 1);
                return tryPage(&self.pages.items[idx], idx, pw, ph) orelse error.GlyphTooLarge;
            }
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

const testing = std.testing;

fn K(glyph: u16, size_q: u16, bin: u2) GlyphKey {
    return .{ .face = 1, .glyph = glyph, .size_q = size_q, .bin = bin };
}

fn collideHash(_: GlyphKey) u64 {
    return 7;
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
