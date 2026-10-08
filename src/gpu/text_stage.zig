//! Backend-neutral text staging for the glyph-atlas path (shared by the wgpu
//! core and the web backend). Pure CPU: no GPU types, no logging.
//!
//! `stage` shapes every `TextDraw` (through the Raster provider, reusing the
//! shaped run of identical text from earlier frames), packs the glyphs the atlas
//! has not seen into CPU staging pages, and appends one `GlyphInstance` per
//! visible glyph to per-(page, layer) lists. The backend then
//!   * creates GPU textures for any new pages (`pageCount`),
//!   * uploads `takeDirty` rects out of `pageStaging`,
//!   * writes the instance lists (`finish` assigns each its `first` offset),
//!   * draws one instanced call per non-empty list.
//!
//! The Raster provider supplies (see `text/raster.zig` for the native one):
//!   init-free `shape`, `ascent`, `rasterizeGlyph`, optional `epoch` (bumped when
//!   faces change, invalidating the shaped-run cache) and optional
//!   `rasterizeCluster(utf8, FontSpec, size_px) ?GlyphBitmap` for code points no
//!   face has (the web backend asks canvas2D).

const std = @import("std");
const teak = @import("teak");
const glyph_atlas = @import("glyph_atlas.zig");

const GlyphInstance = glyph_atlas.GlyphInstance;
pub const atlas_dim: u32 = glyph_atlas.page_size;

/// Face id of canvas-rasterized fallback clusters (the shaper never produces it).
pub const cluster_face: u16 = 0xFFFF;

/// A draw's clip rect in device px, clamped to what the instance's 16-bit clip fields hold.
const DeviceClip = struct { x0: f32, y0: f32, x1: f32, y1: f32, xy: [2]i16, wh: [2]u16 };

pub fn TextStage(comptime Raster: type) type {
    return struct {
        const Self = @This();

        pub const PageInstances = struct {
            list: [2]std.ArrayList(GlyphInstance) = .{ .empty, .empty },
            first: [2]u32 = .{ 0, 0 },
        };

        /// A slice of the glyph pool.
        const RunSpan = struct { off: usize, len: usize };

        /// One cached shaped run: the glyphs of `text` in `font`.
        const Run = struct {
            hash: u64,
            text_off: u32,
            text_len: u32,
            glyph_off: u32,
            glyph_len: u32,
            width: f32,
            font: teak.FontSpec,
            used: bool = false,
        };

        /// What one draw emitted last frame (Host-side, safely losable): when the next
        /// frame's draw at the same index has the same `sig`, its instances are copied
        /// from `prev_insts` instead of re-resolving every glyph. Valid only while the
        /// atlas page they point into keeps its generation.
        const Memo = struct {
            sig: u64 = 0,
            start: u32 = 0,
            count: u32 = 0,
            page: u8 = 0,
            layer: u8 = 0,
            gen: u32 = 0,
            ok: bool = false,
        };

        gpa: std.mem.Allocator,
        raster: Raster,
        memo: std.ArrayList(Memo) = .empty,
        memo_prev: std.ArrayList(Memo) = .empty,
        /// Last frame's instance lists (double buffer of `insts`).
        prev_insts: std.ArrayList(PageInstances) = .empty,
        // Per-draw emission tracking (see `appendInstance`).
        cur_count: u32 = 0,
        cur_page: u8 = 0,
        cur_layer: u8 = 0,
        cur_start: u32 = 0,
        cur_multi: bool = false,
        atlas: glyph_atlas.GlyphAtlas,
        /// CPU copy of each atlas page (`atlas_dim^2` bytes).
        pages: std.ArrayList([]u8) = .empty,
        insts: std.ArrayList(PageInstances) = .empty,
        // Colour glyphs (emoji): a second atlas of RGBA pages. Its keys use `mode = 2`;
        // the shader reads the texel's own colour instead of tinting coverage.
        catlas: glyph_atlas.GlyphAtlas,
        cpages: std.ArrayList([]u8) = .empty,
        cinsts: std.ArrayList(PageInstances) = .empty,
        /// Device pixels per logical pixel.
        scale: f32,
        /// Glyphs dropped in the latest `stage` (every atlas page was in use).
        dropped: u32 = 0,
        frame_no: u64 = 0,
        log_frame: u64 = 0,

        // Shaped-run cache (open addressing; cleared wholesale when the pools fill).
        runs: []Run = &.{},
        run_count: usize = 0,
        run_glyphs: std.ArrayList(teak.ShapedGlyph) = .empty,
        /// Atlas entry last resolved for each cached glyph.
        run_entries: std.ArrayList(?glyph_atlas.Entry) = .empty,
        entries_scale: f32 = 0,
        run_text: std.ArrayList(u8) = .empty,
        epoch: u64 = 0,

        /// Fallback clusters: code point -> synthetic glyph id.
        cluster_cps: std.ArrayList(u21) = .empty,

        /// Raster providers may opt out of the cross-frame shaped-run cache
        /// (`pub const shaped_run_cache = false`): the web build trades the speed for
        /// ~1.5 KB gzip of wasm.
        const run_cache = if (@hasDecl(Raster, "shaped_run_cache")) Raster.shaped_run_cache else true;

        const max_pool_glyphs = 1 << 20;
        const max_pool_text = 1 << 22;

        pub fn init(gpa: std.mem.Allocator, raster: Raster, max_pages: u8, scale: f32) !Self {
            var atlas = try glyph_atlas.GlyphAtlas.init(gpa, @max(max_pages, 1));
            errdefer atlas.deinit();
            // Colour pages are 4 MiB each: a couple is plenty for emoji.
            var catlas = try glyph_atlas.GlyphAtlas.init(gpa, 2);
            errdefer catlas.deinit();
            const runs = try gpa.alloc(Run, 256);
            for (runs) |*r| r.used = false;
            return .{ .gpa = gpa, .raster = raster, .atlas = atlas, .catlas = catlas, .scale = scale, .runs = runs };
        }

        pub fn deinit(self: *Self) void {
            for (self.pages.items) |p| self.gpa.free(p);
            self.pages.deinit(self.gpa);
            for (self.insts.items) |*pi| for (&pi.list) |*l| l.deinit(self.gpa);
            self.insts.deinit(self.gpa);
            for (self.prev_insts.items) |*pi| for (&pi.list) |*l| l.deinit(self.gpa);
            self.prev_insts.deinit(self.gpa);
            self.memo.deinit(self.gpa);
            self.memo_prev.deinit(self.gpa);
            self.atlas.deinit();
            for (self.cpages.items) |p| self.gpa.free(p);
            self.cpages.deinit(self.gpa);
            for (self.cinsts.items) |*pi| for (&pi.list) |*l| l.deinit(self.gpa);
            self.cinsts.deinit(self.gpa);
            self.catlas.deinit();
            self.gpa.free(self.runs);
            self.run_glyphs.deinit(self.gpa);
            self.run_entries.deinit(self.gpa);
            self.run_text.deinit(self.gpa);
            self.cluster_cps.deinit(self.gpa);
            if (@hasDecl(Raster, "deinit")) self.raster.deinit();
        }

        pub fn pageCount(self: *const Self) usize {
            return self.pages.items.len;
        }

        pub fn pageStaging(self: *const Self, page: usize) []const u8 {
            return self.pages.items[page];
        }

        pub fn takeDirty(self: *Self, page: usize) ?glyph_atlas.Rect {
            return self.atlas.takeDirty(@intCast(page));
        }

        /// RGBA colour pages (4 bytes per texel, same `atlas_dim` edge).
        pub fn colorPageCount(self: *const Self) usize {
            return self.cpages.items.len;
        }

        pub fn colorStaging(self: *const Self, page: usize) []const u8 {
            return self.cpages.items[page];
        }

        pub fn takeColorDirty(self: *Self, page: usize) ?glyph_atlas.Rect {
            return self.catlas.takeDirty(@intCast(page));
        }

        /// True once per ~60 frames while glyphs are being dropped: the caller logs.
        pub fn shouldReportDrops(self: *Self) bool {
            if (self.dropped == 0) return false;
            if (self.log_frame != 0 and self.frame_no - self.log_frame < 60) return false;
            self.log_frame = self.frame_no;
            return true;
        }

        /// Assign every (page, layer) list its first-instance offset; returns the total.
        pub fn finish(self: *Self) u32 {
            var total: u32 = 0;
            for (0..2) |layer| {
                for (self.insts.items) |*pi| {
                    pi.first[layer] = total;
                    total += @intCast(pi.list[layer].items.len);
                }
                for (self.cinsts.items) |*pi| {
                    pi.first[layer] = total;
                    total += @intCast(pi.list[layer].items.len);
                }
            }
            return total;
        }

        /// Shape, pack and emit this frame's text. `overlay_start` is the index of
        /// the first overlay-layer draw (`draws.len` = none).
        pub fn stage(self: *Self, draws: []const teak.TextDraw, overlay_start: usize) void {
            self.atlas.beginFrame();
            self.frame_no += 1;
            self.dropped = 0;
            if (comptime run_cache) {
                std.mem.swap(std.ArrayList(PageInstances), &self.insts, &self.prev_insts);
                std.mem.swap(std.ArrayList(Memo), &self.memo, &self.memo_prev);
                self.memo.clearRetainingCapacity();
            }
            for (self.insts.items) |*pi| for (&pi.list) |*l| l.clearRetainingCapacity();
            self.catlas.beginFrame();
            for (self.cinsts.items) |*pi| for (&pi.list) |*l| l.clearRetainingCapacity();
            if (@hasDecl(Raster, "epoch")) {
                const e = self.raster.epoch();
                if (e != self.epoch) {
                    self.epoch = e;
                    self.clearRuns();
                }
            }

            const scale = self.scale;
            if (scale != self.entries_scale) {
                self.entries_scale = scale;
                self.clearRuns(); // cached atlas entries are for one device size
            }
            var last_font: teak.FontSpec = undefined;
            var have_last = false;
            var ascent: f32 = 0;

            for (draws, 0..) |draw, di| {
                const layer: usize = if (di >= overlay_start) 1 else 0;
                var sig: u64 = 0;
                if (comptime run_cache) {
                    sig = drawSig(draw, layer);
                    if (di < self.memo_prev.items.len) {
                        const m = self.memo_prev.items[di];
                        var nm = m;
                        if (m.ok and m.sig == sig and self.reuse(&nm)) {
                            self.memo.append(self.gpa, nm) catch {};
                            continue;
                        }
                    }
                    self.cur_count = 0;
                    self.cur_multi = false;
                }
                const dropped0 = self.dropped;
                defer if (comptime run_cache) {
                    self.memo.append(self.gpa, .{
                        .sig = sig,
                        .start = self.cur_start,
                        .count = self.cur_count,
                        .page = self.cur_page,
                        .layer = self.cur_layer,
                        .gen = if (self.cur_count > 0) self.atlas.pageGen(self.cur_page) else 0,
                        .ok = !self.cur_multi and self.dropped == dropped0,
                    }) catch {};
                };
                // Cull runs entirely outside their clip (logical px).
                const vx0 = @max(draw.rect_x, draw.clip_x);
                const vy0 = @max(draw.rect_y, draw.clip_y);
                const vx1 = @min(draw.rect_x + draw.rect_w, draw.clip_x + draw.clip_w);
                const vy1 = @min(draw.rect_y + draw.rect_h, draw.clip_y + draw.clip_h);
                if (vx1 <= vx0 or vy1 <= vy0) continue;

                const font = draw.font;
                const size_q = quantizeSize(font.size_px * scale);
                if (size_q == 0) continue;
                const snap = font.snapsAdvance();
                if (!have_last or !std.meta.eql(last_font, font)) {
                    last_font = font;
                    have_last = true;
                    ascent = self.raster.ascent(font, scale);
                }
                const baseline = @floor(draw.rect_y * scale) + @round(ascent);
                const base_x = if (snap) @floor(draw.rect_x * scale) else draw.rect_x * scale;
                const clip = deviceClip(draw, scale);
                const color = packColor(draw.color);

                const run = self.runFor(draw.content, font) orelse continue;
                const glyphs = self.run_glyphs.items[run.off..][0..run.len];
                // The atlas entry resolved last frame is reused while its page
                // generation (and the glyph's subpixel bin) is unchanged.
                const entries = self.run_entries.items[run.off..][0..run.len];
                for (glyphs, entries) |g, *cached| {
                    self.emitGlyph(layer, draw.content, font, g, cached, base_x + g.x * scale, baseline + @round(g.y * scale), size_q, snap, color, clip);
                }
            }
        }

        // ── Shaped-run cache ───────────────────────────────────────

        fn clearRuns(self: *Self) void {
            self.memo_prev.clearRetainingCapacity();
            for (self.runs) |*r| r.used = false;
            self.run_count = 0;
            self.run_glyphs.clearRetainingCapacity();
            self.run_entries.clearRetainingCapacity();
            self.run_text.clearRetainingCapacity();
        }

        /// Everything that shapes a draw's instances, mixed into one 64-bit signature
        /// (a collision would show last frame's glyphs for one frame: 2^-64 odds).
        fn drawSig(draw: teak.TextDraw, layer: usize) u64 {
            const f = draw.font;
            const words = [_]u32{
                @bitCast(draw.rect_x),   @bitCast(draw.rect_y),      @bitCast(draw.rect_w),
                @bitCast(draw.rect_h),   @bitCast(draw.clip_x),      @bitCast(draw.clip_y),
                @bitCast(draw.clip_w),   @bitCast(draw.clip_h),      @bitCast(draw.color[0]),
                @bitCast(draw.color[1]), @bitCast(draw.color[2]),    @bitCast(draw.color[3]),
                @bitCast(f.size_px),     @bitCast(f.letter_spacing),
                @as(u32, @backingInt(f.family)) | (@as(u32, @backingInt(f.weight)) << 8) |
                    (@as(u32, if (f.snap_advance) |v| @intFromBool(v) + 1 else 0) << 16) | (@as(u32, @intCast(layer)) << 24),
            };
            return std.hash.Wyhash.hash(0x7ea4, std.mem.sliceAsBytes(&words)) ^ std.hash.Wyhash.hash(1, draw.content);
        }

        /// Copy a memoised draw's instances from last frame's lists. False when the
        /// atlas page they sit in has since been reset (the draw is rebuilt).
        fn reuse(self: *Self, m: *Memo) bool {
            if (m.count == 0) return true;
            if (m.page >= self.prev_insts.items.len or self.atlas.pageGen(m.page) != m.gen) return false;
            const src = self.prev_insts.items[m.page].list[m.layer].items;
            if (m.start + m.count > src.len) return false;
            while (self.insts.items.len <= m.page) self.insts.append(self.gpa, .{}) catch return false;
            const dst = &self.insts.items[m.page].list[m.layer];
            const new_start: u32 = @intCast(dst.items.len);
            dst.appendSlice(self.gpa, src[m.start..][0..m.count]) catch return false;
            m.start = new_start;
            self.atlas.pinPage(m.page);
            return true;
        }

        fn runHash(text: []const u8, font: teak.FontSpec) u64 {
            const bits: u64 = @as(u64, @as(u32, @bitCast(font.size_px))) |
                (@as(u64, @as(u32, @bitCast(font.letter_spacing))) << 32);
            const tags: u64 = @as(u64, @backingInt(font.family)) | (@as(u64, @backingInt(font.weight)) << 8) |
                (@as(u64, if (font.snap_advance) |v| @intFromBool(v) + 1 else 0) << 16) |
                (@as(u64, @intFromBool(font.scalable)) << 24);
            return std.hash.Wyhash.hash(bits ^ std.math.rotl(u64, tags, 40), text);
        }

        fn sameFont(a: teak.FontSpec, b: teak.FontSpec) bool {
            return a.size_px == b.size_px and a.family == b.family and a.weight == b.weight and
                a.letter_spacing == b.letter_spacing and a.snap_advance == b.snap_advance and a.scalable == b.scalable;
        }

        /// Glyphs of `text` in `font` with run-relative logical x positions
        /// (summed across shaper chunks). Cached across frames; valid until the next
        /// `runFor`.
        fn runFor(self: *Self, text: []const u8, font: teak.FontSpec) ?RunSpan {
            if (text.len == 0) return .{ .off = 0, .len = 0 };
            if (comptime !run_cache) {
                // No cross-frame cache: shape into the pool, reused by the next draw.
                self.run_glyphs.clearRetainingCapacity();
                self.run_entries.clearRetainingCapacity();
                return self.shapeInto(text, font);
            }
            const h = runHash(text, font);
            const mask = self.runs.len - 1;
            var i: usize = @intCast(h & mask);
            while (self.runs[i].used) : (i = (i + 1) & mask) {
                const r = &self.runs[i];
                if (r.hash == h and r.text_len == text.len and sameFont(r.font, font) and
                    std.mem.eql(u8, self.run_text.items[r.text_off..][0..r.text_len], text))
                {
                    return .{ .off = r.glyph_off, .len = r.glyph_len };
                }
            }
            // Miss: shape, then record.
            if (self.run_glyphs.items.len > max_pool_glyphs or self.run_text.items.len > max_pool_text or
                (self.run_count + 1) * 2 > self.runs.len)
            {
                if ((self.run_count + 1) * 2 > self.runs.len and self.run_glyphs.items.len <= max_pool_glyphs and self.run_text.items.len <= max_pool_text) {
                    self.growRuns() catch return null;
                } else self.clearRuns();
                return self.runFor(text, font);
            }
            const placed = self.shapeInto(text, font) orelse return null;
            const goff = placed.off;
            const toff = self.run_text.items.len;
            self.run_text.appendSlice(self.gpa, text) catch return null;
            self.runs[i] = .{
                .hash = h,
                .text_off = @intCast(toff),
                .text_len = @intCast(text.len),
                .glyph_off = @intCast(goff),
                .glyph_len = @intCast(placed.len),
                .width = 0,
                .font = font,
                .used = true,
            };
            self.run_count += 1;
            return placed;
        }

        /// Shape `text` and append its glyphs (run-relative logical x, summed across
        /// shaper chunks) to the pool.
        fn shapeInto(self: *Self, text: []const u8, font: teak.FontSpec) ?RunSpan {
            const goff = self.run_glyphs.items.len;
            var buf: [128]teak.ShapedGlyph = undefined;
            var pos: usize = 0;
            var run_x: f32 = 0;
            while (pos < text.len) {
                const res = self.raster.shape(text[pos..], font, &buf);
                if (res.consumed == 0) break;
                self.run_glyphs.ensureUnusedCapacity(self.gpa, res.count) catch return null;
                self.run_entries.ensureUnusedCapacity(self.gpa, res.count) catch return null;
                for (buf[0..res.count]) |g| {
                    self.run_entries.appendAssumeCapacity(null);
                    var gg = g;
                    gg.x += run_x;
                    gg.cluster += @intCast(pos);
                    self.run_glyphs.appendAssumeCapacity(gg);
                }
                run_x += res.width;
                pos += res.consumed;
            }
            return .{ .off = goff, .len = self.run_glyphs.items.len - goff };
        }

        fn growRuns(self: *Self) !void {
            const old = self.runs;
            const fresh = try self.gpa.alloc(Run, old.len * 2);
            for (fresh) |*r| r.used = false;
            const mask = fresh.len - 1;
            for (old) |r| {
                if (!r.used) continue;
                var i: usize = @intCast(r.hash & mask);
                while (fresh[i].used) i = (i + 1) & mask;
                fresh[i] = r;
            }
            self.runs = fresh;
            self.gpa.free(old);
        }

        // ── Emission ───────────────────────────────────────────────

        fn emitGlyph(
            self: *Self,
            layer: usize,
            text: []const u8,
            font: teak.FontSpec,
            g: teak.ShapedGlyph,
            cached: ?*?glyph_atlas.Entry,
            pen_x: f32,
            baseline: f32,
            size_q: u16,
            snap: bool,
            color: u32,
            clip: DeviceClip,
        ) void {
            if (font.scalable and g.glyph != 0 and @hasDecl(Raster, "rasterizeSdf")) {
                return self.emitSdf(layer, font, g, pen_x, baseline, color, clip);
            }
            const fx = @floor(pen_x);
            const bin: u2 = if (snap) 0 else @intCast(@min(3, @as(u32, @intFromFloat((pen_x - fx) * 4))));
            var key: glyph_atlas.GlyphKey = .{ .face = g.face, .glyph = g.glyph, .size_q = size_q, .bin = bin };
            if (cached) |c| {
                // Fallback clusters are always bin 0; other glyphs must match this pen's bin.
                if (c.*) |ce| {
                    if ((ce.key.face == cluster_face or ce.key.bin == bin) and self.atlas.stillValid(&ce)) {
                        self.atlas.touch(&ce);
                        self.appendInstance(layer, ce, fx, baseline, color, clip);
                        return;
                    }
                }
            }
            var cluster_cp: u21 = 0;
            if ((@hasDecl(Raster, "rasterizeCluster") or @hasDecl(Raster, "rasterizeColor")) and g.glyph == 0 and g.cluster < text.len) {
                const d = decodeAt(text, g.cluster);
                if (@hasDecl(Raster, "rasterizeColor") and isColorCodepoint(d)) {
                    return self.emitColor(layer, font, d, fx, baseline, size_q, color, clip);
                }
                if (@hasDecl(Raster, "rasterizeCluster") and d != 0xFFFD and d != ' ') {
                    cluster_cp = d;
                    const id = self.clusterId(d) orelse return;
                    key = .{ .face = cluster_face, .glyph = id, .size_q = size_q, .bin = 0 };
                }
            }
            const e = self.atlas.lookup(key) orelse self.pack(key, font, cluster_cp) orelse return;
            if (cached) |c| c.* = e;
            self.appendInstance(layer, e, fx, baseline, color, clip);
        }

        /// A colour glyph (emoji): the platform rasterizes the cluster to RGBA once per size; the
        /// shader draws the texels as they are (instance mode 2).
        fn emitColor(
            self: *Self,
            layer: usize,
            font: teak.FontSpec,
            cp: u21,
            fx: f32,
            baseline: f32,
            size_q: u16,
            color: u32,
            clip: DeviceClip,
        ) void {
            const id = self.clusterId(cp) orelse return;
            const key: glyph_atlas.GlyphKey = .{ .face = cluster_face, .glyph = id, .size_q = size_q, .bin = 0, .mode = 2 };
            const e = self.catlas.lookup(key) orelse self.packColorGlyph(key, font, cp) orelse return;
            if (e.rect.w == 0 or e.rect.h == 0) return;
            const gx = fx + @as(f32, @floatFromInt(e.bearing_x));
            const gy = baseline + @as(f32, @floatFromInt(e.bearing_y));
            const gw: f32 = @floatFromInt(e.rect.w);
            const gh: f32 = @floatFromInt(e.rect.h);
            if (gx + gw <= clip.x0 or gy + gh <= clip.y0 or gx >= clip.x1 or gy >= clip.y1) return;
            const inside = gx >= clip.x0 and gy >= clip.y0 and gx + gw <= clip.x1 and gy + gh <= clip.y1;
            while (self.cinsts.items.len <= e.page) {
                self.cinsts.append(self.gpa, .{}) catch return;
            }
            self.cinsts.items[e.page].list[layer].append(self.gpa, .{
                .x = gx,
                .y = gy,
                .w = e.rect.w,
                .h = e.rect.h,
                .u = e.rect.x,
                .v = e.rect.y,
                .color = color, // alpha tints the emoji (fades); rgb is ignored
                .clip_xy = if (inside) .{ 0, 0 } else clip.xy,
                .clip_wh = if (inside) .{ 0, 0 } else clip.wh,
                .flags = 2, // mode 2: RGBA texels
            }) catch return;
        }

        fn packColorGlyph(self: *Self, key: glyph_atlas.GlyphKey, font: teak.FontSpec, cp: u21) ?glyph_atlas.Entry {
            const size_px = @as(f32, @floatFromInt(key.size_q)) / 4.0;
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8) catch 0;
            const bmp = self.raster.rasterizeColor(utf8[0..n], font, size_px) orelse {
                _ = self.catlas.insert(key, 0, 0, 0, 0) catch {};
                return null;
            };
            const too_big = bmp.width > atlas_dim - 2 or bmp.height > atlas_dim - 2;
            const w: u16 = if (too_big) 0 else @intCast(bmp.width);
            const h: u16 = if (too_big) 0 else @intCast(bmp.height);
            const bx: i16 = @intCast(std.math.clamp(bmp.bearing_x, -32768, 32767));
            const by: i16 = @intCast(std.math.clamp(bmp.bearing_y, -32768, 32767));
            const e = self.catlas.insert(key, w, h, bx, by) catch |err| {
                if (err == error.AllPagesPinned) self.dropped += 1;
                return null;
            };
            if (w == 0 or h == 0) return e;
            while (self.cpages.items.len <= e.page) {
                const buf = self.gpa.alloc(u8, atlas_dim * atlas_dim * 4) catch return null;
                @memset(buf, 0);
                self.cpages.append(self.gpa, buf) catch {
                    self.gpa.free(buf);
                    return null;
                };
            }
            const staging = self.cpages.items[e.page];
            const x: usize = e.rect.x;
            const y: usize = e.rect.y;
            for (y - 1..y + h + 1) |row| @memset(staging[(row * atlas_dim + x - 1) * 4 ..][0 .. (w + 2) * 4], 0);
            for (0..h) |row| @memcpy(staging[((y + row) * atlas_dim + x) * 4 ..][0 .. w * 4], bmp.pixels[row * w * 4 ..][0 .. w * 4]);
            return e;
        }

        /// A scalable glyph: one distance-field entry (`mode = 1`, fixed source size)
        /// drawn at `font.size_px * scale / sdf_em` times its stored size, at an exact
        /// (unsnapped) position so zooming and panning stay smooth.
        fn emitSdf(
            self: *Self,
            layer: usize,
            font: teak.FontSpec,
            g: teak.ShapedGlyph,
            pen_x: f32,
            baseline: f32,
            color: u32,
            clip: DeviceClip,
        ) void {
            const key: glyph_atlas.GlyphKey = .{ .face = g.face, .glyph = g.glyph, .size_q = quantizeSize(Raster.sdf_em), .bin = 0, .mode = 1 };
            const e = self.atlas.lookup(key) orelse self.pack(key, font, 0) orelse return;
            if (e.rect.w == 0 or e.rect.h == 0) return;
            const k_q: u32 = @intFromFloat(std.math.clamp(@round(font.size_px * self.scale / Raster.sdf_em * 256), 0, 65535));
            if (k_q == 0) return;
            const k = @as(f32, @floatFromInt(k_q)) / 256;
            const gx = pen_x + @as(f32, @floatFromInt(e.bearing_x)) * k;
            const gy = baseline + @as(f32, @floatFromInt(e.bearing_y)) * k;
            const gw = @as(f32, @floatFromInt(e.rect.w)) * k;
            const gh = @as(f32, @floatFromInt(e.rect.h)) * k;
            if (gx + gw <= clip.x0 or gy + gh <= clip.y0 or gx >= clip.x1 or gy >= clip.y1) return;
            const inside = gx >= clip.x0 and gy >= clip.y0 and gx + gw <= clip.x1 and gy + gh <= clip.y1;
            while (self.insts.items.len <= e.page) {
                self.insts.append(self.gpa, .{}) catch return;
            }
            self.insts.items[e.page].list[layer].append(self.gpa, .{
                .x = gx,
                .y = gy,
                .w = e.rect.w,
                .h = e.rect.h,
                .u = e.rect.x,
                .v = e.rect.y,
                .color = color,
                .clip_xy = if (inside) .{ 0, 0 } else clip.xy,
                .clip_wh = if (inside) .{ 0, 0 } else clip.wh,
                // bits 0-1: mode 1 (SDF); bits 16-31: quad scale in 1/256 units.
                .flags = 1 | (k_q << 16),
            }) catch return;
        }

        fn appendInstance(self: *Self, layer: usize, e: glyph_atlas.Entry, fx: f32, baseline: f32, color: u32, clip: DeviceClip) void {
            if (e.rect.w == 0 or e.rect.h == 0) return;

            const gx = fx + @as(f32, @floatFromInt(e.bearing_x));
            const gy = baseline + @as(f32, @floatFromInt(e.bearing_y));
            const gw: f32 = @floatFromInt(e.rect.w);
            const gh: f32 = @floatFromInt(e.rect.h);
            if (gx + gw <= clip.x0 or gy + gh <= clip.y0 or gx >= clip.x1 or gy >= clip.y1) return;
            const inside = gx >= clip.x0 and gy >= clip.y0 and gx + gw <= clip.x1 and gy + gh <= clip.y1;

            while (self.insts.items.len <= e.page) {
                self.insts.append(self.gpa, .{}) catch return;
            }
            const lst = &self.insts.items[e.page].list[layer];
            if (comptime run_cache) {
                if (self.cur_count == 0) {
                    self.cur_page = e.page;
                    self.cur_layer = @intCast(layer);
                    self.cur_start = @intCast(lst.items.len);
                } else if (self.cur_page != e.page or self.cur_layer != layer) self.cur_multi = true;
                self.cur_count += 1;
            }
            lst.append(self.gpa, .{
                .x = gx,
                .y = gy,
                .w = e.rect.w,
                .h = e.rect.h,
                .u = e.rect.x,
                .v = e.rect.y,
                .color = color,
                // A glyph fully inside its clip skips the fragment test.
                .clip_xy = if (inside) .{ 0, 0 } else clip.xy,
                .clip_wh = if (inside) .{ 0, 0 } else clip.wh,
            }) catch return;
        }

        /// Synthetic glyph id of a fallback code point (1-based, stable). A
        /// recently seen code point is found by scanning backwards: the working
        /// set of missing glyphs in one frame is small, and misses only happen once.
        fn clusterId(self: *Self, cp: u21) ?u16 {
            const cps = self.cluster_cps.items;
            var i = cps.len;
            while (i > 0) {
                i -= 1;
                if (cps[i] == cp) return @intCast(i + 1);
            }
            if (cps.len >= std.math.maxInt(u16)) return null;
            self.cluster_cps.append(self.gpa, cp) catch return null;
            return @intCast(cps.len + 1);
        }

        /// Rasterize `key`'s glyph and place it in the atlas (staging copy + dirty
        /// rect). Null when the glyph cannot be shown this frame; blank and
        /// unrasterizable glyphs are cached as empty so they are not retried.
        fn pack(self: *Self, key: glyph_atlas.GlyphKey, font: teak.FontSpec, cluster_cp: u21) ?glyph_atlas.Entry {
            const size_px = @as(f32, @floatFromInt(key.size_q)) / 4.0;
            const bmp = blk: {
                if (@hasDecl(Raster, "rasterizeSdf") and key.mode == 1) break :blk self.raster.rasterizeSdf(key.face, key.glyph);
                if (@hasDecl(Raster, "rasterizeCluster") and key.face == cluster_face) {
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cluster_cp, &utf8) catch 0;
                    break :blk self.raster.rasterizeCluster(utf8[0..n], font, size_px);
                }
                break :blk self.raster.rasterizeGlyph(key.face, key.glyph, size_px, key.bin);
            } orelse {
                _ = self.atlas.insert(key, 0, 0, 0, 0) catch {};
                return null;
            };
            const too_big = bmp.width > atlas_dim - 2 or bmp.height > atlas_dim - 2;
            const w: u16 = if (too_big) 0 else @intCast(bmp.width);
            const h: u16 = if (too_big) 0 else @intCast(bmp.height);
            const bx: i16 = @intCast(std.math.clamp(bmp.bearing_x, -32768, 32767));
            const by: i16 = @intCast(std.math.clamp(bmp.bearing_y, -32768, 32767));
            const e = self.atlas.insert(key, w, h, bx, by) catch |err| {
                if (err == error.AllPagesPinned) self.dropped += 1;
                return null;
            };
            if (w == 0 or h == 0) return e;
            if (!self.ensurePage(e.page)) return null;
            // Zero the padded cell, then copy the glyph rows into it.
            const staging = self.pages.items[e.page];
            const x: usize = e.rect.x;
            const y: usize = e.rect.y;
            for (y - 1..y + h + 1) |row| @memset(staging[row * atlas_dim + x - 1 ..][0 .. w + 2], 0);
            for (0..h) |row| @memcpy(staging[(y + row) * atlas_dim + x ..][0..w], bmp.pixels[row * w ..][0..w]);
            return e;
        }

        fn ensurePage(self: *Self, page: u8) bool {
            while (self.pages.items.len <= page) {
                const buf = self.gpa.alloc(u8, atlas_dim * atlas_dim) catch return false;
                @memset(buf, 0);
                self.pages.append(self.gpa, buf) catch {
                    self.gpa.free(buf);
                    return false;
                };
            }
            return true;
        }
    };
}

fn decodeAt(text: []const u8, i: usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 0xFFFD;
    if (i + n > text.len) return 0xFFFD;
    return std.unicode.utf8Decode(text[i .. i + n]) catch 0xFFFD;
}

/// Code points drawn in colour when the platform can (emoji and pictographs).
pub fn isColorCodepoint(cp: u21) bool {
    return (cp >= 0x1F300 and cp <= 0x1FAFF) or (cp >= 0x1F000 and cp <= 0x1F2FF) or
        cp == 0x2B50 or cp == 0x2B55 or cp == 0x2705 or cp == 0x274C or cp == 0x2764;
}

/// Glyph size in quarter pixels (the atlas key unit); 0 for non-drawable sizes.
pub fn quantizeSize(size_px: f32) u16 {
    if (!(size_px > 0)) return 0;
    return @intFromFloat(@min(@round(size_px * 4), 65535));
}

/// RGBA8 in memory order r, g, b, a (read back as one word by the shader).
pub fn packColor(color: [4]f32) u32 {
    var out: u32 = 0;
    inline for (0..4) |i| {
        const v: u32 = @intFromFloat(@round(std.math.clamp(color[i], 0, 1) * 255));
        out |= v << (8 * i);
    }
    return out;
}

fn deviceClip(draw: teak.TextDraw, scale: f32) DeviceClip {
    const lo: f32 = -32768;
    const hi: f32 = 32767;
    const x0 = std.math.clamp(@floor(draw.clip_x * scale), lo, hi);
    const y0 = std.math.clamp(@floor(draw.clip_y * scale), lo, hi);
    const x1 = std.math.clamp(@ceil((draw.clip_x + draw.clip_w) * scale), lo, hi);
    const y1 = std.math.clamp(@ceil((draw.clip_y + draw.clip_h) * scale), lo, hi);
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x1,
        .y1 = y1,
        .xy = .{ @intFromFloat(x0), @intFromFloat(y0) },
        .wh = .{ @intFromFloat(@max(x1 - x0, 1)), @intFromFloat(@max(y1 - y0, 1)) },
    };
}

// ── Tests ──────────────────────────────────────────────────────────

/// 6-px-wide boxes, one glyph per byte.
const FakeRaster = struct {
    const Bitmap = struct { pixels: []const u8, width: u32, height: u32, bearing_x: i32, bearing_y: i32 };
    var px: [16]u8 = @splat(255);
    pub fn shape(_: *FakeRaster, text: []const u8, _: teak.FontSpec, out: []teak.ShapedGlyph) teak.ShapeResult {
        const n = @min(text.len, out.len);
        for (0..n) |i| out[i] = .{ .glyph = text[i], .face = 0, .cluster = @intCast(i), .x = @as(f32, @floatFromInt(i)) * 6, .advance = 6 };
        return .{ .count = n, .width = @as(f32, @floatFromInt(n)) * 6, .consumed = n };
    }
    pub fn ascent(_: *FakeRaster, _: teak.FontSpec, _: f32) f32 {
        return 8;
    }
    pub fn rasterizeGlyph(_: *FakeRaster, _: u16, _: u16, _: f32, _: u2) ?Bitmap {
        return .{ .pixels = &px, .width = 4, .height = 4, .bearing_x = 0, .bearing_y = -4 };
    }
};

fn testDraw(text: []const u8, x: f32) teak.TextDraw {
    return .{ .rect_x = x, .rect_y = 10, .rect_w = 100, .rect_h = 12, .content = text, .font = .{ .size_px = 10 }, .color = .{ 1, 1, 1, 1 }, .clip_x = 0, .clip_y = 0, .clip_w = 500, .clip_h = 500 };
}

test "stage: unchanged draws replay last frame's instances; changed ones are rebuilt" {
    const gpa = std.testing.allocator;
    var st = try TextStage(FakeRaster).init(gpa, .{}, 2, 1);
    defer st.deinit();

    var draws = [_]teak.TextDraw{ testDraw("abc", 0), testDraw("xy", 50), testDraw("hello", 90) };
    st.stage(&draws, draws.len);
    const first = try gpa.dupe(GlyphInstance, st.insts.items[0].list[0].items);
    defer gpa.free(first);
    try std.testing.expectEqual(@as(usize, 10), first.len);

    // Frame 2: identical draws come from the memo; the result is byte-identical.
    st.stage(&draws, draws.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(first), std.mem.sliceAsBytes(st.insts.items[0].list[0].items));

    // Frame 3: one draw changes; the others still match a from-scratch stage.
    draws[1] = testDraw("xyz", 50);
    st.stage(&draws, draws.len);
    var fresh = try TextStage(FakeRaster).init(gpa, .{}, 2, 1);
    defer fresh.deinit();
    fresh.stage(&draws, draws.len);
    // Atlas cells depend on packing order, so compare geometry, colour and clip only.
    const a = fresh.insts.items[0].list[0].items;
    const b = st.insts.items[0].list[0].items;
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        var xn = x;
        var yn = y;
        xn.u = 0;
        xn.v = 0;
        yn.u = 0;
        yn.v = 0;
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&xn), std.mem.asBytes(&yn));
    }
}
