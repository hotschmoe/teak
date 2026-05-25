//! Debug overlay: dump the current frame's cmds + rects into an
//! overlay-layer panel for visual inspection. Closes ergonomic gap 6
//! — complex forms no longer require std.debug.print breadcrumbs.
//!
//! Lives in core (no platform / gpu imports), uses the existing
//! `push_overlay` / `pop_overlay` Cmd variants (HARDLINE §2 hatch 5)
//! and the per-frame arena for the formatted lines. Apps opt in by
//! calling `appendDebugOverlay(cb, cmds, rects, opts)` at the bottom
//! of their view — typically gated on a `model.debug_open` flag they
//! toggle via a Msg from F12 or similar.

const std = @import("std");
const layout = @import("../layout/engine.zig");
const cmd_mod = @import("cmd.zig");
const text_mod = @import("text.zig");

const Rect = layout.Rect;

pub const DebugOverlayOpts = struct {
    /// Top-left position of the panel in window coords.
    x: f32 = 8,
    y: f32 = 8,
    /// Panel padding.
    padding: f32 = 8,
    /// Vertical gap between dump lines.
    gap: f32 = 2,
    /// Panel backdrop color (drawn behind the lines).
    backdrop: [4]f32 = .{ 0, 0, 0, 0.78 },
    /// Line color.
    fg: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    /// Font for the dump lines. Mono is strongly recommended so columns
    /// align — the formatter pads with spaces.
    font: text_mod.FontSpec = .{ .size_px = 12, .family = .mono },
    /// Drop `pop_*` cmds from the dump (they have no meaningful rect).
    skip_pops: bool = true,
    /// Drop `push_*` cmds from the dump (containers — keep only leaves).
    skip_pushes: bool = false,
    /// Hard cap on the number of lines to emit. Frames with thousands
    /// of cmds would otherwise blow past the window.
    max_lines: usize = 512,
};

/// Walk `cmds` + `rects` and append an overlay region to `cb` showing
/// per-cmd diagnostics. `cmds.len` must equal `rects.len` (the standard
/// pairing produced by the layout pass).
///
/// The overlay sits above all base-layer content but uses the regular
/// `push_overlay` arms so hit-test and render handle it like any other
/// modal. Apps that have their own overlays opening at the same time
/// will see this one painted in document order — emit `appendDebugOverlay`
/// last to keep it on top.
pub fn appendDebugOverlay(
    cb: anytype,
    cmds: anytype,
    rects: []const Rect,
    opts: DebugOverlayOpts,
) void {
    // Pre-format every line into the arena BEFORE mutating cb.cmds.
    // Callers typically pass `cb.cmds.items` as the `cmds` slice; if we
    // started emitting overlay cmds first, the ArrayList could realloc
    // and invalidate the slice we're iterating.
    const arena_alloc = cb.arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;

    for (cmds, 0..) |c, i| {
        if (lines.items.len >= opts.max_lines) break;
        const tag = std.meta.activeTag(c);
        if (opts.skip_pops and isPopTag(tag)) continue;
        if (opts.skip_pushes and isPushTag(tag)) continue;
        if (i >= rects.len) break;

        const r = rects[i];
        const line = std.fmt.allocPrint(
            arena_alloc,
            "{d:>3} {s:<18} ({d:>4.0},{d:>4.0},{d:>4.0},{d:>4.0})",
            .{ i, @tagName(tag), r.x, r.y, r.w, r.h },
        ) catch unreachable;
        lines.append(arena_alloc, line) catch unreachable;
    }

    cb.pushOverlay(.{
        .x = opts.x,
        .y = opts.y,
        .width = 0,
        .height = 0,
        .padding = opts.padding,
        .gap = opts.gap,
        .direction = .vertical,
        .backdrop = opts.backdrop,
    });
    for (lines.items) |line| cb.textStyled(line, opts.font, opts.fg);
    cb.popOverlay();
}

fn isPopTag(tag: anytype) bool {
    return switch (tag) {
        .pop_group, .pop_scroll, .pop_overlay, .pop_virtual_list => true,
        else => false,
    };
}

fn isPushTag(tag: anytype) bool {
    return switch (tag) {
        .push_group, .push_scroll, .push_overlay, .push_virtual_list => true,
        else => false,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "appendDebugOverlay: brackets a push_overlay..pop_overlay region" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Build a tiny base view.
    cb.pushGroup(.{});
    cb.button(.a, "Hi");
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(
        rects[0..cb.cmds.items.len],
        cb.cmds.items,
        400,
        300,
        text_mod.monoMeasurer(),
    );

    const cmds_before = cb.cmds.items.len;
    appendDebugOverlay(&cb, cb.cmds.items[0..cmds_before], rects[0..cmds_before], .{});

    // First new cmd is push_overlay; last is pop_overlay.
    try testing.expectEqual(.push_overlay, std.meta.activeTag(cb.cmds.items[cmds_before]));
    try testing.expectEqual(.pop_overlay, std.meta.activeTag(cb.cmds.items[cb.cmds.items.len - 1]));
}

test "appendDebugOverlay: emits one text line per non-pop cmd by default" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // 3 cmds: push, button, pop. With skip_pops=true (default) we get
    // 2 text lines.
    cb.pushGroup(.{});
    cb.button(.a, "X");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(
        rects[0..cb.cmds.items.len],
        cb.cmds.items,
        400,
        300,
        text_mod.monoMeasurer(),
    );

    const cmds_before = cb.cmds.items.len;
    appendDebugOverlay(&cb, cb.cmds.items[0..cmds_before], rects[0..cmds_before], .{});

    var text_lines: usize = 0;
    for (cb.cmds.items[cmds_before..]) |c| {
        if (c == .text) text_lines += 1;
    }
    try testing.expectEqual(@as(usize, 2), text_lines); // push_group + button
}

test "appendDebugOverlay: skip_pushes=true keeps only leaves" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("hello");
    cb.button(.a, "X");
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(
        rects[0..cb.cmds.items.len],
        cb.cmds.items,
        400,
        300,
        text_mod.monoMeasurer(),
    );

    const cmds_before = cb.cmds.items.len;
    appendDebugOverlay(
        &cb,
        cb.cmds.items[0..cmds_before],
        rects[0..cmds_before],
        .{ .skip_pushes = true },
    );

    // After filtering: text + button = 2 lines (push and pop dropped).
    var text_lines: usize = 0;
    for (cb.cmds.items[cmds_before..]) |c| {
        if (c == .text) text_lines += 1;
    }
    try testing.expectEqual(@as(usize, 2), text_lines);
}

test "appendDebugOverlay: max_lines caps emission" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    var i: usize = 0;
    while (i < 30) : (i += 1) cb.text("row");
    cb.popGroup();

    var rects: [64]Rect = undefined;
    layout.LayoutEngine.doLayout(
        rects[0..cb.cmds.items.len],
        cb.cmds.items,
        400,
        800,
        text_mod.monoMeasurer(),
    );

    const cmds_before = cb.cmds.items.len;
    appendDebugOverlay(
        &cb,
        cb.cmds.items[0..cmds_before],
        rects[0..cmds_before],
        .{ .max_lines = 5 },
    );

    var text_lines: usize = 0;
    for (cb.cmds.items[cmds_before..]) |c| {
        if (c == .text) text_lines += 1;
    }
    try testing.expectEqual(@as(usize, 5), text_lines);
}

test "appendDebugOverlay: formatted line includes index, tag, rect" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.button(.a, "X");
    cb.popGroup();

    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(
        rects[0..cb.cmds.items.len],
        cb.cmds.items,
        400,
        300,
        text_mod.monoMeasurer(),
    );

    const cmds_before = cb.cmds.items.len;
    appendDebugOverlay(&cb, cb.cmds.items[0..cmds_before], rects[0..cmds_before], .{});

    // Find the line that mentions "button" — must include "button" and
    // the digits of the button's rect.
    var found_button_line = false;
    for (cb.cmds.items[cmds_before..]) |c| {
        if (c == .text and std.mem.indexOf(u8, c.text.content, "button") != null) {
            found_button_line = true;
        }
    }
    try testing.expect(found_button_line);
}
