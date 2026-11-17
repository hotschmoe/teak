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

/// Growable counterpart of `SlotTable` for caches whose size the app, not
/// the backend, decides (images). Same handle contract (`slot index + 1`,
/// 0 is none, freed slots are reused, no generation). Storage grows on
/// demand up to `max_slots`; `insert` returns null only at that ceiling or
/// on allocator failure. There is deliberately no eviction: handles are
/// app-owned (`releaseImage`), and evicting a live texture would leave the
/// app holding a handle that silently draws nothing.
pub fn GrowSlotTable(comptime Entry: type, comptime max_slots: u32) type {
    return struct {
        const Self = @This();

        slots: std.ArrayList(?Entry) = .empty,
        /// Freed slot indices, reused LIFO.
        free: std.ArrayList(u32) = .empty,
        live: u32 = 0,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.slots.deinit(gpa);
            self.free.deinit(gpa);
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, entry: Entry) ?u32 {
            if (self.free.pop()) |i| {
                self.slots.items[i] = entry;
                self.live += 1;
                return i + 1;
            }
            if (self.slots.items.len >= max_slots) return null;
            self.slots.append(gpa, entry) catch return null;
            self.live += 1;
            return @intCast(self.slots.items.len);
        }

        pub fn get(self: *Self, handle: u32) ?*Entry {
            if (handle == 0 or handle > self.slots.items.len) return null;
            return if (self.slots.items[handle - 1]) |*e| e else null;
        }

        /// Free the slot and return its entry so the caller can release
        /// the GPU objects it owned.
        pub fn remove(self: *Self, gpa: std.mem.Allocator, handle: u32) ?Entry {
            const e = self.get(handle) orelse return null;
            const out = e.*;
            self.slots.items[handle - 1] = null;
            self.free.append(gpa, handle - 1) catch {}; // slot leaks until teardown
            self.live -= 1;
            return out;
        }

        /// Visit every live entry (for teardown).
        pub fn iterator(self: *Self) Iterator {
            return .{ .table = self, .next_index = 0 };
        }

        pub const Iterator = struct {
            table: *Self,
            next_index: usize,

            pub fn next(it: *Iterator) ?*Entry {
                while (it.next_index < it.table.slots.items.len) {
                    const i = it.next_index;
                    it.next_index += 1;
                    if (it.table.slots.items[i]) |*e| return e;
                }
                return null;
            }
        };
    };
}




