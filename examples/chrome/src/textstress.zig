//! Text stress app for the glyph-atlas path: a grid of `cols x rows` short
//! mono runs ("r12c3"), one button per row. `zig build shot -- out.png --stress N`
//! renders N runs and reports the warm frame CPU time.

const std = @import("std");
const teak = @import("teak");

pub const Model = struct { cols: usize = 16, rows: usize = 40, size_px: f32 = 11, tick: u32 = 0 };
pub const Msg = union(enum) { noop };

pub fn update(m: *Model, msg: Msg) void {
    _ = m;
    switch (msg) {
        .noop => {},
    }
}

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 4, .gap = 0 });
    cb.text(std.fmt.allocPrint(cb.arena.allocator(), "tick {d}", .{m.tick}) catch "t");
    for (0..m.rows) |r| {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4 });
        for (0..m.cols) |c| {
            const s = std.fmt.allocPrint(cb.arena.allocator(), "r{d}c{d}", .{ r, c }) catch "x";
            cb.textStyled(s, .{ .size_px = m.size_px, .family = .mono }, .{ 0.9, 0.9, 0.9, 1 });
        }
        cb.popGroup();
    }
    cb.popGroup();
}
