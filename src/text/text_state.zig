//! See SRC.md, src/text/text_state.zig.
const std = @import("std");
const teak = @import("teak");
const assert = teak.assert;
const face = @import("face.zig");
const fallback = @import("fallback.zig");
const measure = @import("measure.zig");
const kern_cache = @import("kern_cache.zig");

const use_harfbuzz = @import("text_options").harfbuzz;
const HbState = if (use_harfbuzz) @import("hb_shaper.zig").Hb else struct {};
const small = @import("builtin").cpu.arch.isWasm();
const slots_max: u32 = 1 << 20;

pub const Limits = struct {
    kern_slots: u32 = 8192,
    measure_slots: u32 = if (small) 1024 else 4096,

    pub fn valid(self: Limits) bool {
        return slot_count_ok(self.kern_slots) and slot_count_ok(self.measure_slots);
    }
};

fn slot_count_ok(count: u32) bool {
    return count >= 2 and count <= slots_max and std.math.isPowerOfTwo(count);
}

/// What a limit skipped or evicted since `open`. All zero on a run that never reached one.
pub const Report = struct {
    kern_evicted: u64 = 0,
    measure_evicted: u64 = 0,
    measure_bypassed: u64 = 0,
    fallback_refused: u64 = 0,
    rtl_unordered: u64 = 0,
    hb_skipped: u64 = 0,

    /// True when a result was worse than asked for (not merely slower): an RTL run left in
    /// logical order, a HarfBuzz run unshaped, a refused fallback face.
    pub fn degraded(self: Report) bool {
        return (self.fallback_refused +| self.rtl_unordered +| self.hb_skipped) != 0;
    }

    pub fn any(self: Report) bool {
        return (self.kern_evicted +| self.measure_evicted +| self.measure_bypassed +|
            self.fallback_refused +| self.rtl_unordered +| self.hb_skipped) != 0;
    }
};

pub const OpenError = error{ OutOfMemory, LimitsInvalid };

/// The face table, fallback chain, shaping caches and measurement cache of one
/// text path. Owned by the Host, lent to the Gpu; two of them share nothing.
pub const TextState = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    faces: face.Registry = .{},
    chain: fallback.Chain = .{},
    kern: kern_cache.KernCache,
    measure: measure.Cache,
    hb: HbState = .{},
    counts: Report = .{},

    /// Allocates every buffer for `limits` once; nothing allocates afterwards except
    /// system fonts loaded on demand (owned, freed by `close`).
    pub fn open(allocator: std.mem.Allocator, limits: Limits) OpenError!*TextState {
        if (!limits.valid()) return error.LimitsInvalid;
        const self = try allocator.create(TextState);
        errdefer allocator.destroy(self);
        var kern = try kern_cache.KernCache.init(allocator, limits.kern_slots);
        errdefer kern.deinit(allocator);
        var cache = try measure.Cache.init(allocator, limits.measure_slots);
        errdefer cache.deinit(allocator);
        self.* = .{ .allocator = allocator, .limits = limits, .kern = kern, .measure = cache };
        assert(self.faces.epoch == 1);
        assert(self.kern.slots.len == limits.kern_slots);
        assert(!self.report().any());
        return self;
    }

    /// Frees fonts it loaded and every buffer, then the state itself. A warning when a limit
    /// degraded a result, a debug line when only a cache evicted or bypassed.
    pub fn close(self: *TextState) void {
        assert(self.kern.slots.len >= 2 and self.measure.slots.len >= 2);
        const counts = self.report();
        if (counts.degraded()) {
            std.log.warn("teak text limit: refused {d}, unordered {d}, skipped {d}", .{
                counts.fallback_refused, counts.rtl_unordered, counts.hb_skipped,
            });
        } else if (counts.any()) {
            std.log.debug("teak text: evicted {d} kerning, {d} measure, bypassed {d}", .{
                counts.kern_evicted, counts.measure_evicted, counts.measure_bypassed,
            });
        }
        face.releaseFaces(self);
        assert(self.faces.fallback == null and !self.faces.fallback_tried);
        if (use_harfbuzz) self.hb.deinit();
        self.kern.deinit(self.allocator);
        self.measure.deinit(self.allocator);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    /// The `teak.TextMeasurer` over this state: what a Host returns from `textMeasurer`.
    pub fn measurer(self: *TextState) teak.TextMeasurer {
        assert(self.measure.slots.len >= 2);
        assert(self.limits.valid());
        const Thunk = struct {
            fn call(ctx: *anyopaque, bytes: []const u8, font: teak.FontSpec) teak.TextMetrics {
                const owner: *TextState = @ptrCast(@alignCast(ctx));
                assert(owner.measure.slots.len >= 2);
                assert(owner.faces.epoch >= 1);
                return measure.measure(owner, bytes, font);
            }
        };
        return .{ .ctx = self, .measure_fn = &Thunk.call };
    }

    pub fn report(self: *const TextState) Report {
        var counts = self.counts;
        counts.kern_evicted = self.kern.evicted;
        counts.measure_evicted = self.measure.evicted;
        counts.measure_bypassed = self.measure.bypassed;
        if (use_harfbuzz) counts.hb_skipped = self.hb.skipped;
        assert(self.counts.kern_evicted == 0 and self.counts.measure_evicted == 0);
        assert(self.kern.slots.len >= 2);
        return counts;
    }

    /// Call after any change to the face table: drops every cache derived from it.
    pub fn faces_changed(self: *TextState) void {
        assert(self.faces.epoch < std.math.maxInt(u64));
        self.faces.epoch += 1;
        self.kern.reset();
        self.measure.reset();
        if (use_harfbuzz) self.hb.dropSlots();
        assert(self.faces.epoch > 1);
    }
};
