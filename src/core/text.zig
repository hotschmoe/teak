//! Text measurement and rasterization types.
//!
//! Lives in core (not platform/ or gpu/) so layout/ and render/ can
//! import without violating HARDLINE §3. The `TextMeasurer` vtable is
//! how core reaches platform-owned font metrics — same role as
//! `validateHost` / `validateGpu`, just at runtime instead of comptime.
//!
//! It is NOT a Cmd fn-pointer (HARDLINE §3 forbids those); a Cmd variant
//! carries data, a measurer is an interface value. Distinct categories.

const std = @import("std");

pub const FontFamily = enum(u8) { sans, serif, mono };

pub const FontSpec = struct {
    size_px: f32 = 14,
    family: FontFamily = .sans,
};

pub const DEFAULT_FONT: FontSpec = .{};

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
};

pub const TextMeasurer = struct {
    ctx: *anyopaque,
    measure_fn: *const fn (ctx: *anyopaque, text: []const u8, font: FontSpec) TextMetrics,

    pub fn measure(self: TextMeasurer, text: []const u8, font: FontSpec) TextMetrics {
        return self.measure_fn(self.ctx, text, font);
    }

    /// Width of `text[0..byte_prefix]`. Used for text-input cursor
    /// placement. `byte_prefix == 0` short-circuits to zero width to
    /// avoid measuring an empty slice.
    pub fn prefixWidth(self: TextMeasurer, text: []const u8, font: FontSpec, byte_prefix: usize) f32 {
        if (byte_prefix == 0) return 0;
        return self.measure(text[0..byte_prefix], font).width;
    }
};

/// Opaque GPU texture token. Backends map this to their real resource
/// (wgpu-native `WGPUTexture`, zunk `zgpu.Texture`, etc.). Framework
/// code above the GPU layer never unpacks it.
pub const TextureHandle = u32;
pub const TEXTURE_HANDLE_NONE: TextureHandle = 0;

/// Stateless 10-px-per-byte, 20-px-line-height measurer. Used by CLI
/// canaries that run layout without a Host, and by tests whose
/// assertions were written against the pre-WS1 `CHAR_WIDTH` constant.
/// Not a production measurer — real platforms return glyph-accurate
/// metrics via their Host's `textMeasurer()`.
pub fn monoMeasurer() TextMeasurer {
    const S = struct {
        fn measure(_: *anyopaque, t: []const u8, _: FontSpec) TextMetrics {
            return .{
                .width = @as(f32, @floatFromInt(t.len)) * 10,
                .height = 20,
                .ascent = 15,
                .descent = 5,
            };
        }
    };
    return .{ .ctx = undefined, .measure_fn = &S.measure };
}

// ── Tests ──────────────────────────────────────────────────────────

fn testMeasure(_: *anyopaque, text: []const u8, font: FontSpec) TextMetrics {
    return .{
        .width = @as(f32, @floatFromInt(text.len)) * font.size_px,
        .height = font.size_px,
        .ascent = font.size_px * 0.75,
        .descent = font.size_px * 0.25,
    };
}

test "TextMeasurer.measure dispatches through the vtable" {
    var ctx: u8 = 0;
    const m: TextMeasurer = .{ .ctx = @ptrCast(&ctx), .measure_fn = testMeasure };
    const r = m.measure("abc", .{ .size_px = 10 });
    try std.testing.expectEqual(@as(f32, 30), r.width);
    try std.testing.expectEqual(@as(f32, 10), r.height);
}

test "TextMeasurer.prefixWidth short-circuits empty prefix" {
    var ctx: u8 = 0;
    const m: TextMeasurer = .{ .ctx = @ptrCast(&ctx), .measure_fn = testMeasure };
    try std.testing.expectEqual(@as(f32, 0), m.prefixWidth("hello", .{ .size_px = 10 }, 0));
    try std.testing.expectEqual(@as(f32, 20), m.prefixWidth("hello", .{ .size_px = 10 }, 2));
}

test "DEFAULT_FONT is sans 14px" {
    try std.testing.expectEqual(FontFamily.sans, DEFAULT_FONT.family);
    try std.testing.expectEqual(@as(f32, 14), DEFAULT_FONT.size_px);
}
