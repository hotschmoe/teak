//! See SRC.md, src/sim/metrics.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const text = @import("../core/text.zig");
const unicode = @import("../core/unicode.zig");

pub fn Metrics(comptime Font: type) type {
    assert(@hasDecl(Font, "fromBytes"));
    assert(@hasDecl(Font, "advanceUnits"));
    return struct {
        const Self = @This();
        face: Font,

        pub fn init() !Self {
            const bytes = @embedFile("../text/fonts/IBMPlexMonoDefault.ttf");
            assert(bytes.len > 12);
            const face = try Font.fromBytes(bytes);
            assert(face.allocator == null);
            return .{ .face = face };
        }

        pub fn measure(self: *Self, bytes: []const u8, font: text.FontSpec) text.TextMetrics {
            assert(font.size_px > 0);
            assert(std.math.isFinite(font.size_px));
            const scale = self.face.scaleForEm(font.size_px);
            var width: f32 = 0;
            var offset: usize = 0;
            for (0..bytes.len) |_| {
                if (offset == bytes.len) break;
                const decoded = unicode.utf8DecodeLossy(bytes, offset);
                offset += decoded.len;
                const glyph = self.face.glyphIndex(decoded.cp);
                var advance = @as(f32, @floatFromInt(self.face.advanceUnits(glyph))) * scale;
                if (font.snap_advance orelse true) advance = @round(advance);
                width += advance + font.letter_spacing;
            }
            const vertical = self.face.vMetrics(font.size_px);
            assert(offset == bytes.len);
            return .{
                .width = width,
                .height = vertical.ascent + vertical.descent,
                .ascent = vertical.ascent,
                .descent = vertical.descent,
            };
        }
    };
}
