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

const ATTR_BOLD_MASK: u16 = 1 << @intFromEnum(StyleAttribute.bold);
const ATTR_ITALIC_MASK: u16 = 1 << @intFromEnum(StyleAttribute.italic);

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
    // Note: `text` owns `plain` (owns_plain=true). We DON'T deinit it
    // here — the caller's arena reset frees the allocation in bulk.
    // If we deinit'd, the slices below would dangle.

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

// ── Tests ──────────────────────────────────────────────────────────

test "colorToRgba: default falls back" {
    const out = colorToRgba(null, .{ 0.5, 0.5, 0.5, 1.0 });
    try std.testing.expectEqual(@as(f32, 0.5), out[0]);
}

test "colorToRgba: standard red maps to its triplet" {
    const out = colorToRgba(rich.Color.red, .{ 0, 0, 0, 1 });
    // Standard red is ANSI color 1 — triplet approximately (170, 0, 0)
    // in rich_zig's table. We just assert R is dominant and >> G/B.
    try std.testing.expect(out[0] > 0.5);
    try std.testing.expect(out[1] < 0.3);
    try std.testing.expect(out[2] < 0.3);
    try std.testing.expectEqual(@as(f32, 1.0), out[3]);
}

test "buildRichText: parses markup into spans + plain" {
    const arena = std.testing.allocator;
    var heap = std.heap.ArenaAllocator.init(arena);
    defer heap.deinit();

    const cmd = try buildRichText(
        heap.allocator(),
        "[bold]Hello[/] [red]world[/]",
        .{ 1, 1, 1, 1 },
        .{},
    );
    // Plain string strips the markup tags.
    try std.testing.expectEqualStrings("Hello world", cmd.content);
    // Two styled runs: bold "Hello" + red "world".
    try std.testing.expectEqual(@as(usize, 2), cmd.spans.len);
    try std.testing.expectEqual(@as(u32, 0), cmd.spans[0].start);
    try std.testing.expectEqual(@as(u32, 5), cmd.spans[0].end);
    try std.testing.expect(cmd.spans[0].bold);
    try std.testing.expectEqual(@as(u32, 6), cmd.spans[1].start);
    try std.testing.expectEqual(@as(u32, 11), cmd.spans[1].end);
    try std.testing.expect(!cmd.spans[1].bold);
    try std.testing.expect(cmd.spans[1].color[0] > 0.5); // red-ish
}
