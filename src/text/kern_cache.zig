//! See SRC.md, src/text/kern_cache.zig.
const std = @import("std");
const teak = @import("teak");
const assert = teak.assert;
const face = @import("face.zig");

const Slot = struct { key: u64, value: i32 };
const key_used: u64 = 1 << 48;
const slots_max: u32 = 1 << 20;

pub const KernCache = struct {
    slots: []Slot,
    shift: u6,
    evicted: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, slot_count: u32) error{OutOfMemory}!KernCache {
        assert(std.math.isPowerOfTwo(slot_count));
        assert(slot_count >= 2 and slot_count <= slots_max);
        const slots = try allocator.alloc(Slot, slot_count);
        @memset(slots, .{ .key = 0, .value = 0 });
        const shift: u6 = @intCast(@as(u32, 64) - std.math.log2_int(u32, slot_count));
        return .{ .slots = slots, .shift = shift };
    }

    pub fn deinit(self: *KernCache, allocator: std.mem.Allocator) void {
        assert(self.slots.len >= 2);
        allocator.free(self.slots);
        self.slots = &.{};
        assert(self.slots.len == 0);
    }

    pub fn reset(self: *KernCache) void {
        assert(self.slots.len >= 2);
        @memset(self.slots, .{ .key = 0, .value = 0 });
        assert(self.slots[0].key == 0 and self.slots[self.slots.len - 1].key == 0);
    }

    /// Kerning of (`left`, `right`) in `font` (table index `face_id`), in font units.
    pub fn units(
        self: *KernCache,
        font: *const face.Font,
        face_id: u16,
        left: u16,
        right: u16,
    ) i32 {
        const key: u64 = key_used | (@as(u64, face_id) << 32) | (@as(u64, left) << 16) | right;
        const index: usize = @intCast((key *% 0x9E3779B97F4A7C15) >> self.shift);
        assert(index < self.slots.len);
        const slot = &self.slots[index];
        if (slot.key == key) return slot.value;
        const value = font.kernUnits(left, right);
        if (slot.key != 0) self.evicted += 1;
        slot.* = .{ .key = key, .value = value };
        assert(slot.key != 0);
        return value;
    }
};
