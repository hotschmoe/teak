//! Face-table tests for the native text backend, against the real IBM Plex
//! Mono files (registered through anonymous build imports, so no system font
//! is needed). IBM Plex Mono is monospaced at 600 units per 1000 em, which
//! makes the expected widths exact.

const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");

const regular = @embedFile("plex-regular");
const medium = @embedFile("plex-medium");
const bold = @embedFile("plex-bold");

fn registerAll() !void {
    try text.registerFace(.mono, .regular, regular);
    try text.registerFace(.mono, .medium, medium);
    try text.registerFace(.mono, .bold, bold);
}

fn inkTotal(rast: *text.StbttRasterizer, weight: teak.FontWeight) !u64 {
    const bmp = rast.rasterize("MMMM", .{ .size_px = 24, .family = .mono, .weight = weight }, .{ 1, 1, 1, 1 }, 96, 32) orelse
        return error.RasterizeFailed;
    var sum: u64 = 0;
    var i: usize = 3;
    while (i < bmp.pixels.len) : (i += 4) sum += bmp.pixels[i];
    return sum;
}

test "every weight advances 0.6 em per character, whatever the glyph" {
    defer text.releaseFaces();
    try registerAll();
    for ([_]teak.FontWeight{ .regular, .medium, .bold }) |w| {
        for ([_][]const u8{ "iiiiiiiiii", "WWWWWWWWWW", "0123456789" }) |run| {
            const m = text.measure(run, .{ .size_px = 20, .family = .mono, .weight = w });
            try std.testing.expectApproxEqAbs(@as(f32, 10 * 0.6 * 20), m.width, 0.01);
        }
    }
}

test "letter spacing adds to every character, the last included" {
    defer text.releaseFaces();
    try registerAll();
    const plain = text.measure("abcd", .{ .size_px = 20, .family = .mono }).width;
    const spaced = text.measure("abcd", .{ .size_px = 20, .family = .mono, .letter_spacing = 1.5 }).width;
    try std.testing.expectApproxEqAbs(plain + 6, spaced, 0.001);
}

test "bold paints more ink than regular (the rasterizer picks the face by weight)" {
    defer text.releaseFaces();
    try registerAll();
    var rast = try text.StbttRasterizer.init(std.testing.allocator);
    defer rast.deinit();
    const r = try inkTotal(&rast, .regular);
    const m = try inkTotal(&rast, .medium);
    const b = try inkTotal(&rast, .bold);
    try std.testing.expect(r > 0);
    try std.testing.expect(m > r);
    try std.testing.expect(b > m);
}

test "a weight that is not registered takes the nearest one, the lighter on a tie" {
    defer text.releaseFaces();
    try text.registerFace(.mono, .regular, regular);
    try text.registerFace(.mono, .bold, bold);
    try std.testing.expectEqual(text.faceFor(.mono, .regular), text.faceFor(.mono, .medium));
    try std.testing.expect(text.faceFor(.mono, .bold) != text.faceFor(.mono, .regular));

    text.releaseFaces();
    try text.registerFace(.mono, .bold, bold);
    try std.testing.expectEqual(text.faceFor(.mono, .bold), text.faceFor(.mono, .regular));
}

test "garbage bytes are rejected" {
    defer text.releaseFaces();
    try std.testing.expectError(error.FontInitFailed, text.registerFace(.mono, .regular, "not a font"));
}
