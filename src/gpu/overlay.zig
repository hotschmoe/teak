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



