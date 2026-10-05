//! Overlay layering shared by the GPU backends (HARDLINE §2 hatch 5: two
//! levels, base z=0 and overlay z=1).
//!
//! `render.buildFrame` reports `OverlaySplit`: how many vertices / text /
//! image / scene draws the base layer produced. Backends stage their own
//! records (some input draws are skipped), so they cannot reuse those
//! counts as indices into their staged lists; `Marker` finds the staged
//! record index at which the overlay begins while a staging loop walks the
//! input draws. `Range` then turns the split point into the two draw
//! ranges of a list, so the main pass can draw base solids, images, scene
//! composites and text first and the overlay's after.

const std = @import("std");

/// Tracks the first staged record that comes from an overlay-layer input.
pub const Marker = struct {
    /// Input index where the overlay layer starts (`draws.len` = none).
    start: usize,
    rec: ?usize = null,

    /// Call at the top of every loop iteration, before the draw may be skipped.
    pub fn visit(self: *Marker, input_index: usize, staged_so_far: usize) void {
        if (self.rec == null and input_index >= self.start) self.rec = staged_so_far;
    }

    /// Staged index of the first overlay record (the staged count if no
    /// overlay draw survived staging).
    pub fn finish(self: Marker, staged_total: usize) usize {
        return @min(self.rec orelse staged_total, staged_total);
    }
};

/// A staged list divided into its base and overlay halves.
pub const Range = struct {
    base_end: usize,
    total: usize,

    pub fn of(overlay_start: usize, total: usize) Range {
        return .{ .base_end = @min(overlay_start, total), .total = total };
    }

    pub fn base(self: Range) struct { usize, usize } {
        return .{ 0, self.base_end };
    }

    pub fn overlay(self: Range) struct { usize, usize } {
        return .{ self.base_end, self.total };
    }
};

test "Marker finds the first staged record of the overlay layer" {
    // Inputs: 0,1 base (1 skipped), 2,3 overlay (2 skipped).
    var m: Marker = .{ .start = 2 };
    var staged: usize = 0;
    for (0..4) |i| {
        m.visit(i, staged);
        const skipped = i == 1 or i == 2;
        if (!skipped) staged += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), m.finish(staged)); // base staged 1 record; overlay starts at 1
}

test "Marker with no overlay inputs, or a split past the end, reports the total" {
    var none: Marker = .{ .start = 10 };
    for (0..3) |i| none.visit(i, i);
    try std.testing.expectEqual(@as(usize, 3), none.finish(3));
    var empty: Marker = .{ .start = 0 };
    try std.testing.expectEqual(@as(usize, 0), empty.finish(0));
}

test "Range splits a list into base and overlay halves" {
    const r = Range.of(3, 5);
    try std.testing.expectEqual(@as(usize, 0), r.base()[0]);
    try std.testing.expectEqual(@as(usize, 3), r.base()[1]);
    try std.testing.expectEqual(@as(usize, 3), r.overlay()[0]);
    try std.testing.expectEqual(@as(usize, 5), r.overlay()[1]);
    // A split beyond the list length clamps: everything is base.
    const all = Range.of(99, 5);
    try std.testing.expectEqual(@as(usize, 5), all.base()[1]);
    try std.testing.expectEqual(all.overlay()[0], all.overlay()[1]);
}
