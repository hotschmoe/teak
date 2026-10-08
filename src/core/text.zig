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

pub const FontWeight = enum(u8) { regular, medium, bold };

/// A font request. Backends map it to a face: `weight` and `letter_spacing`
/// are interpreted by the backend and ignored by one that cannot honor them
/// (web: CSS `font-weight` + canvas `letterSpacing`; native: face selection).
/// Both take part in the glyph-cache key, so changing them re-rasterizes.
pub const FontSpec = struct {
    size_px: f32 = 14,
    family: FontFamily = .sans,
    weight: FontWeight = .regular,
    /// Extra advance after every glyph, in pixels (tracking). Layout adds
    /// it per byte in `monoMeasurer`; real measurers add it per glyph.
    letter_spacing: f32 = 0,
    /// Round every glyph advance to a whole pixel (crisp terminal-grid text).
    /// Applied identically by the shaper, the measurer and the rasterizer.
    /// null = the family default: on for `.mono`, off otherwise. Snapped text
    /// also uses one subpixel bin, so every glyph lands on the pixel grid.
    snap_advance: ?bool = null,
    /// The text is one right-to-left run (an odd bidi level, see `bidi_text`):
    /// shapers return it in visual order, mirrored where the script requires.
    /// Set by the renderer per run, not by apps.
    rtl: bool = false,
    /// A hint that this text changes size continuously (zoomable canvases,
    /// animated scale): its glyphs are rasterized ONCE as signed distance
    /// fields and drawn at any size, instead of once per `size_px`. Crisp from
    /// well below 1x to 8x+ with no re-rasterization. Costs a little at small sizes
    /// (a distance field is softer than a hinted bitmap at 12-16 px), so leave it
    /// off for UI text. Ignored by backends without an SDF rasterizer.
    scalable: bool = false,

    /// The resolved `snap_advance` (see the field).
    pub fn snapsAdvance(self: FontSpec) bool {
        return self.snap_advance orelse (self.family == .mono);
    }
};

pub const DEFAULT_FONT: FontSpec = .{};

pub const RichTextSpan = struct {
    /// Byte start in the rich_text's content (UTF-8). Spans must be
    /// non-overlapping and sorted by start.
    start: u32,
    /// Byte end (exclusive).
    end: u32,
    color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    font: FontSpec = DEFAULT_FONT,
    /// Set on the rendered TextDraw so the text pass can pick a
    /// bold/italic font face. The Host's text measurer is expected to
    /// consult these — for now they're advisory (current GDI host
    /// always picks Regular).
    bold: bool = false,
    italic: bool = false,
};

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

/// One positioned glyph produced by a `Shaper`. Plain data, logical order.
pub const ShapedGlyph = extern struct {
    /// Glyph id in `face`.
    glyph: u16,
    /// Face-table index (fallback already resolved).
    face: u16,
    /// Byte offset in the source text where this glyph's cluster starts.
    cluster: u32,
    /// Pen x BEFORE this glyph, logical px, run-relative (includes kerning + letter_spacing).
    x: f32,
    /// Advance in logical px, kerning with the next glyph and letter_spacing included,
    /// so `sum(advance) == ShapeResult.width`.
    advance: f32,
    /// Vertical offset from the baseline in logical px, positive down (mark
    /// attachment from a complex-script shaper; 0 for the built-in shaper).
    y: f32 = 0,
};

pub const ShapeResult = struct {
    /// Glyphs written to `out`.
    count: usize,
    /// Sum of the written advances, logical px.
    width: f32,
    /// Source bytes covered. Less than `text.len` only when `out` filled up;
    /// the caller continues from here (always a cluster boundary).
    consumed: usize,
};

/// Interface value (like `TextMeasurer`) through which core reaches a shaper.
/// No allocation; data in, data out.
pub const Shaper = struct {
    ctx: *anyopaque,
    shape_fn: *const fn (ctx: *anyopaque, text: []const u8, font: FontSpec, out: []ShapedGlyph) ShapeResult,

    pub fn shape(self: Shaper, text: []const u8, font: FontSpec, out: []ShapedGlyph) ShapeResult {
        return self.shape_fn(self.ctx, text, font, out);
    }
};

/// Opaque GPU texture token. Backends map this to their real resource
/// (wgpu-native `WGPUTexture`, zunk `zgpu.Texture`, etc.). Framework
/// code above the GPU layer never unpacks it.
pub const TextureHandle = u32;
pub const TEXTURE_HANDLE_NONE: TextureHandle = 0;

/// Render-pass output for one run of text. The GPU backend consumes
/// these in `uploadText` — rasterizes (cached) via `rasterizeText`,
/// emits 6 textured vertices per draw, records draw metadata for the
/// text pass. `clip` carries the scroll-clip rect at emit time so
/// offscreen text draws can be dropped before rasterization.
pub const TextDraw = struct {
    rect_x: f32,
    rect_y: f32,
    rect_w: f32,
    rect_h: f32,
    content: []const u8,
    font: FontSpec,
    color: [4]f32,
    clip_x: f32,
    clip_y: f32,
    clip_w: f32,
    clip_h: f32,
};

/// Stateless 10-px-per-byte (plus `letter_spacing`), 20-px-line-height measurer. Used by CLI
/// canaries that run layout without a Host, and by tests that assert
/// on these exact pre-glyph-metrics numbers. Not a production
/// measurer — real platforms return glyph-accurate metrics via their
/// Host's `textMeasurer()`.
pub fn monoMeasurer() TextMeasurer {
    const S = struct {
        fn measure(_: *anyopaque, t: []const u8, font: FontSpec) TextMetrics {
            return .{
                .width = @as(f32, @floatFromInt(t.len)) * (10 + font.letter_spacing),
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

test "monoMeasurer adds letter_spacing per byte" {
    const m = monoMeasurer();
    try std.testing.expectEqual(@as(f32, 30), m.measure("abc", .{}).width);
    try std.testing.expectEqual(@as(f32, 36), m.measure("abc", .{ .letter_spacing = 2 }).width);
    // Weight does not change the stub's metrics.
    try std.testing.expectEqual(@as(f32, 30), m.measure("abc", .{ .weight = .bold }).width);
}

test "DEFAULT_FONT is sans 14px" {
    try std.testing.expectEqual(FontFamily.sans, DEFAULT_FONT.family);
    try std.testing.expectEqual(@as(f32, 14), DEFAULT_FONT.size_px);
}
