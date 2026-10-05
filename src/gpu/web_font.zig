//! CSS font strings for the web backends. The Host (measuring) and the Gpu
//! (rasterizing) both build their canvas `font` from here, so they cannot
//! disagree about family, weight or size.
//!
//! The families come from `teak.linkWebWgpu(.{ .fonts = ... })` through the
//! generated `teak-fonts` module: a slot with a registered family becomes
//! `"<family>", <generic>`, otherwise just the CSS generic family.

const std = @import("std");
const teak = @import("teak");
const fonts = @import("teak-fonts");

/// Longest string `css` can produce for a family list this long.
pub const css_buf_len = 192;

/// The family list of a slot, e.g. `"IBM Plex Mono", monospace`.
pub fn familyList(comptime family: teak.FontFamily) []const u8 {
    const generic = switch (family) {
        .sans => "sans-serif",
        .serif => "serif",
        .mono => "monospace",
    };
    const registered = @field(fonts, @tagName(family));
    return if (registered.len == 0) generic else "\"" ++ registered ++ "\", " ++ generic;
}

/// CSS `font-weight` of a weight.
pub fn cssWeight(w: teak.FontWeight) u16 {
    return switch (w) {
        .regular => 400,
        .medium => 500,
        .bold => 700,
    };
}

/// The canvas `font` for `font`, e.g. `500 13px "IBM Plex Mono", monospace`.
/// Letter spacing is not part of it (it is a separate canvas property).
pub fn css(buf: *[css_buf_len]u8, font: teak.FontSpec) []const u8 {
    const list = switch (font.family) {
        inline else => |f| comptime familyList(f),
    };
    return std.fmt.bufPrint(buf, "{d} {d}px {s}", .{ cssWeight(font.weight), font.size_px, list }) catch "14px monospace";
}

test "a registered family leads the list, the generic family follows" {
    try std.testing.expectEqualStrings("\"Test Mono\", monospace", comptime familyList(.mono));
    try std.testing.expectEqualStrings("sans-serif", comptime familyList(.sans));
    try std.testing.expectEqualStrings("serif", comptime familyList(.serif));
}

test "css carries weight, size and family" {
    var buf: [css_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("400 13px \"Test Mono\", monospace", css(&buf, .{ .size_px = 13, .family = .mono }));
    try std.testing.expectEqualStrings("700 16px \"Test Mono\", monospace", css(&buf, .{ .size_px = 16, .family = .mono, .weight = .bold }));
    try std.testing.expectEqualStrings("500 14.5px sans-serif", css(&buf, .{ .size_px = 14.5, .weight = .medium }));
}
