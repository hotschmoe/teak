//! Fonts example: IBM Plex Mono at three weights, with tracking, on every
//! backend. The web build ships the TTFs through `linkWebWgpu(.{ .fonts })`;
//! the native build embeds the same files and registers them with
//! `Host.registerFont`. Text in `.mono` then measures and draws with the
//! real face: every line below has the same number of characters, so the
//! right edges line up exactly when the grid is exact.

const std = @import("std");
const teak = @import("teak");

pub const Msg = union(enum) { none };
pub const Model = struct {};

pub fn update(_: *Model, _: Msg) void {}

const ruler = "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789";

fn mono(size: f32, weight: teak.FontWeight, spacing: f32) teak.FontSpec {
    return .{ .size_px = size, .family = .mono, .weight = weight, .letter_spacing = spacing };
}

fn line(cb: anytype, font: teak.FontSpec, content: []const u8) void {
    cb.textStyled(content, font, .{ 0.92, 0.92, 0.95, 1 });
}

pub fn view(_: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 24, .gap = 6 });
    line(cb, mono(22, .bold, 0), "IBM Plex Mono  regular / medium / bold");
    cb.divider();
    line(cb, mono(13, .regular, 0), "regular 400  " ++ ruler);
    line(cb, mono(13, .medium, 0), "medium  500  " ++ ruler);
    line(cb, mono(13, .bold, 0), "bold    700  " ++ ruler);
    cb.divider();
    line(cb, mono(13, .regular, 0), "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii");
    line(cb, mono(13, .regular, 0), "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW");
    cb.divider();
    line(cb, mono(13, .regular, 0), "tracking 0   Quick brown fox 0123456789");
    line(cb, mono(13, .regular, 2), "tracking 2   Quick brown fox 0123456789");
    line(cb, mono(13, .bold, 4), "TRACKING 4   QUICK BROWN FOX");
    cb.divider();
    line(cb, mono(10, .regular, 0), "10px: The quick brown fox jumps over the lazy dog 0123456789");
    line(cb, mono(16, .medium, 0), "16px: The quick brown fox jumps over");
    line(cb, mono(20, .regular, 0), "20px: The quick brown fox");
    cb.divider();
    // No shipped face has these: the web build rasterizes them with canvas 2D
    // (the browser's own fonts); native draws the face's missing-glyph box.
    line(cb, mono(16, .regular, 0), "fallback: \u{6F22}\u{5B57} \u{304B}\u{306A} \u{D55C}\u{AE00}");
    cb.popGroup();
}

test "the view is balanced" {
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    view(&.{}, &cb);
    try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
}
