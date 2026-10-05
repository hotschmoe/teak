//! Fixed-capacity slot table behind the GPU backends' app-owned resource
//! caches (images, meshes). Handles are `slot index + 1`, so 0 stays the
//! "none" sentinel shared with `TextureHandle` / `MeshHandle`. A released
//! slot is reused by the next insert; handles carry no generation, so the
//! owner (the run loop's resource hook) must not use a handle after
//! releasing it.

const std = @import("std");

pub fn SlotTable(comptime Entry: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        entries: [capacity]Entry = undefined,
        used: [capacity]bool = @splat(false),

        /// Store `entry` in the first free slot; null when full.
        pub fn insert(self: *Self, entry: Entry) ?u32 {
            for (&self.used, 0..) |*u, i| {
                if (u.*) continue;
                u.* = true;
                self.entries[i] = entry;
                return @intCast(i + 1);
            }
            return null;
        }

        pub fn get(self: *Self, handle: u32) ?*Entry {
            if (handle == 0 or handle > capacity) return null;
            const i = handle - 1;
            return if (self.used[i]) &self.entries[i] else null;
        }

        /// Free the slot and return its entry so the caller can release
        /// the GPU objects it owned.
        pub fn remove(self: *Self, handle: u32) ?Entry {
            const e = self.get(handle) orelse return null;
            self.used[handle - 1] = false;
            return e.*;
        }

        /// Visit every live entry (for teardown).
        pub fn iterator(self: *Self) Iterator {
            return .{ .table = self, .next_index = 0 };
        }

        pub const Iterator = struct {
            table: *Self,
            next_index: usize,

            pub fn next(it: *Iterator) ?*Entry {
                while (it.next_index < capacity) {
                    const i = it.next_index;
                    it.next_index += 1;
                    if (it.table.used[i]) return &it.table.entries[i];
                }
                return null;
            }
        };
    };
}

test "insert hands out slot+1 handles and reuses freed slots" {
    var t: SlotTable(u32, 2) = .{};
    const a = t.insert(10).?;
    const b = t.insert(20).?;
    try std.testing.expectEqual(@as(u32, 1), a);
    try std.testing.expectEqual(@as(u32, 2), b);
    try std.testing.expect(t.insert(30) == null); // full

    try std.testing.expectEqual(@as(?u32, 10), t.remove(a));
    try std.testing.expect(t.get(a) == null);
    try std.testing.expectEqual(@as(u32, 1), t.insert(40).?);
    try std.testing.expectEqual(@as(u32, 40), t.get(1).?.*);
}

test "get rejects the none handle, out-of-range, and double remove" {
    var t: SlotTable(u8, 4) = .{};
    try std.testing.expect(t.get(0) == null);
    try std.testing.expect(t.get(5) == null);
    const h = t.insert(7).?;
    try std.testing.expect(t.remove(h) != null);
    try std.testing.expect(t.remove(h) == null);
}

test "iterator visits only live entries" {
    var t: SlotTable(u32, 4) = .{};
    _ = t.insert(1);
    const mid = t.insert(2).?;
    _ = t.insert(3);
    _ = t.remove(mid);
    var it = t.iterator();
    var sum: u32 = 0;
    while (it.next()) |e| sum += e.*;
    try std.testing.expectEqual(@as(u32, 4), sum);
}
