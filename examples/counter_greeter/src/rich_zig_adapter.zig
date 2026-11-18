//! Adapter between rich_zig's `Text` (terminal-oriented styled text)
//! and teak's `RichTextCmd` (GPU-rendered mixed runs).
//!
//! We use rich_zig only for its **parser**: the markup syntax
//! `[bold red]important[/]` is a nice authoring format and rich_zig
//! already turns it into (range, style) spans. We map each rich_zig
//! `Span` onto a teak `RichTextSpan` with:
//!
//! - color: `Style.color.getTriplet()` → `[4]f32` (RGB + alpha 1)
//! - bold/italic: bits from `Style.attributes`
//! - font: caller-supplied default size; family stays `.sans` because
//!   rich_zig doesn't track font families (it's a TTY library).
//!
//! Slices returned in `RichTextSpans` are allocated from the caller's
//! arena. The plain text slice points into rich_zig's `Text.plain`
//! which is owned by the rich_zig Text — the caller must keep the
//! `Text` alive until the corresponding `RichTextCmd` is processed
//! (typically: build it in the per-frame arena and free at frame end).

const std = @import("std");
const rich = @import("rich_zig");
const teak = @import("teak");

pub const StyleAttribute = rich.StyleAttribute;

const ATTR_BOLD_MASK: u16 = 1 << @backingInt(StyleAttribute.bold);
const ATTR_ITALIC_MASK: u16 = 1 << @backingInt(StyleAttribute.italic);

/// Convert rich_zig's Color → teak's [4]f32 RGBA (sRGB).
/// Unsupported color types (.default) fall back to the supplied default.
pub fn colorToRgba(color: ?rich.Color, default: [4]f32) [4]f32 {
    const c = color orelse return default;
    if (c.color_type == .default) return default;
    const t = c.getTriplet() orelse return default;
    return .{
        @as(f32, @floatFromInt(t.r)) / 255.0,
        @as(f32, @floatFromInt(t.g)) / 255.0,
        @as(f32, @floatFromInt(t.b)) / 255.0,
        1.0,
    };
}

/// Build a `RichTextCmd` from a markup string. Allocates the spans
/// slice from `arena` so the lifetime matches the per-frame CmdBuffer.
///
/// `default_color` / `default_font` are used for any byte not covered
/// by a span (whitespace, unstyled runs, ...).
///
/// Returns the cmd; caller emits it via `cb.richTextStyled(...)`.
pub fn buildRichText(
    arena: std.mem.Allocator,
    markup: []const u8,
    default_color: [4]f32,
    default_font: teak.FontSpec,
) !teak.RichTextCmd {
    const text = try rich.Text.fromMarkup(arena, markup);
    // The frame arena owns the buffer borrowed by the emitted slices.

    const teak_spans = try arena.alloc(teak.RichTextSpan, text.spans.len);
    for (text.spans, 0..) |sp, i| {
        const attrs_active = sp.style.attributes & sp.style.set_attributes;
        teak_spans[i] = .{
            .start = @intCast(sp.start),
            .end = @intCast(sp.end),
            .color = colorToRgba(sp.style.color, default_color),
            .font = default_font,
            .bold = (attrs_active & ATTR_BOLD_MASK) != 0,
            .italic = (attrs_active & ATTR_ITALIC_MASK) != 0,
        };
    }

    return .{
        .content = text.plain,
        .spans = teak_spans,
        .default_color = default_color,
        .default_font = default_font,
    };
}
