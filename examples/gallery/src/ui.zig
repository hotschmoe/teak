//! Small view helpers shared by the pages.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");

pub const Msg = model.Msg;

pub const menu_h: f32 = 28;
pub const status_h: f32 = 24;
pub const sidebar_w: f32 = 176;
pub const pad: f32 = 16;
/// Fixed heights, so anchored overlays land on the same pixels whatever the
/// font's line height is (native stb metrics differ from the browser's).
pub const heading_h: f32 = 20;
pub const card_pad: f32 = 10;
pub const card_gap: f32 = 6;
/// Height the page title takes (heading + the gap under it).
pub const title_h: f32 = heading_h + 12;

/// Where page content begins in window coordinates (used to anchor overlays).
pub const content_x: f32 = sidebar_w + pad;
pub const content_y: f32 = menu_h + pad + title_h;

pub fn fmt(cb: anytype, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(cb.arena.allocator(), f, args) catch "";
}

/// Open a bordered card with a heading. `width` / `height` 0 = measured.
pub fn card(cb: anytype, title: []const u8, width: f32, height: f32) void {
    var g = cb.theme.card;
    g.width = width;
    g.height = height;
    g.align_cross = .stretch;
    g.padding = card_pad;
    g.gap = card_gap;
    cb.pushGroup(g);
    heading(cb, title);
}

/// A heading in a fixed-height box.
pub fn heading(cb: anytype, title: []const u8) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .height = heading_h, .align_cross = .center });
    cb.heading(title);
    cb.popGroup();
}

/// Window-space y of the first widget in a card that opens at `top`.
pub fn cardBodyY(top: f32) f32 {
    return top + card_pad + heading_h + card_gap;
}

pub fn endCard(cb: anytype) void {
    cb.popGroup();
}

/// A horizontal row with a small gap.
pub fn row(cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 10, .align_cross = .center });
}

pub fn endRow(cb: anytype) void {
    cb.popGroup();
}
