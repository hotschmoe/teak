//! teak.snapshot — LLM-readable serialization of a rendered frame.
//!
//! A Teak frame is fully described by the `[]Cmd` + `[]Rect` (+ optional
//! `TransientState`) triple: the command buffer is what `view` emitted,
//! the rects are what layout resolved, and the transient state is the
//! hover/press/focus overlay. That triple already IS the ground truth of
//! what's on screen — this module serializes it to text so an agent can
//! "see" the GUI as data instead of a screenshot.
//!
//! Design goals (all load-bearing):
//!   - **Pure & deterministic.** No pointers, no timestamps, no clock
//!     reads. The same triple always serializes to the same bytes, so a
//!     golden test is stable across runs and machines. Any time-varying
//!     header data (frame counter, last-msg name) is caller-supplied.
//!   - **Grep-able.** One line per cmd, `tag (x,y,w,h) payload`. An agent
//!     locates any widget with a single grep for its label/tag.
//!   - **Small diffs.** State changes (a checkbox toggling, a cursor
//!     moving, hover shifting) show up as one-line diffs. Indentation
//!     (two spaces per container depth) makes structure visible without
//!     emitting noisy `pop_*` lines.
//!
//! Lives in core: no platform/gpu imports, allocation only through the
//! caller-provided writer/allocator. Pairs with `teak.monoMeasurer` so a
//! view can be laid out and snapshotted with no Host (see
//! `docs/features/snapshot.md` for the golden-test recipe).

const std = @import("std");
const layout = @import("../layout/engine.zig");
const transient_mod = @import("transient.zig");

const Rect = layout.Rect;
const TransientState = transient_mod.TransientState;


/// Optional header printed once above the cmd lines. Every field is
/// caller-supplied data — this module never reads a clock or a global,
/// so passing a header keeps the output deterministic for a fixed frame.
pub const Header = struct {
    /// Window size in pixels (rounded to integers on output).
    window_w: f32 = 0,
    window_h: f32 = 0,
    /// Frame counter, as the host tracks it. Snapshot never advances it.
    frame: u32 = 0,
    /// Name of the last dispatched Msg (e.g. `@tagName` of the tag).
    /// Empty string prints as `last_msg=`.
    last_msg: []const u8 = "",
};

pub const SnapshotOptions = struct {
    /// When set, `[hover]` / `[press]` / `[focus]` markers are appended to
    /// the cmd whose index matches `hover_index` / `press_index` /
    /// `focus_index`. This is the ONLY source of those markers — a
    /// text_input shows `[focus]` iff `focus_index` points at it.
    transient: ?*const TransientState = null,
    /// Optional header line (window size, frame counter, last-msg name).
    header: ?Header = null,
};


/// Serialize the frame `cmds` + `rects` to `writer`. `cmds` is any slice
/// of `Cmd(Msg)` — taken as `anytype` like the layout passes, since only
/// Msg-independent fields are read. `rects[i]` is the resolved rect for
/// `cmds[i]`; a short `rects` slice yields zero-rects for the tail rather
/// than erroring (mirrors the layout/render pairing contract).
///
/// Output shape (one line per non-pop cmd, two-space indent per open
/// container):
///
///     group (0,0,800,600) vertical
///       button (16,16,60,36) "+"
///       text (16,60,80,20) "Count: 0"
pub fn write(writer: anytype, cmds: anytype, rects: []const Rect, opts: SnapshotOptions) !void {
    if (opts.header) |h| {
        try writer.print("window={d}x{d} frame={d} last_msg={s}\n", .{
            ri(h.window_w), ri(h.window_h), h.frame, h.last_msg,
        });
    }

    var depth: usize = 0;
    for (cmds, 0..) |c, i| {
        // Closing cmds carry no rect worth showing — they only dedent.
        switch (c) {
            .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => {
                if (depth > 0) depth -= 1;
                continue;
            },
            .push_group, .push_grid, .push_scroll, .push_overlay, .push_virtual_list => {},
            .text, .rich_text, .image, .divider, .button, .text_input, .text_area, .checkbox, .radio, .slider, .canvas, .scene3d => {},
        }

        try writeIndent(writer, depth);
        const r = if (i < rects.len) rects[i] else Rect{};
        try writeCmd(writer, c, r);
        try writeMarkers(writer, opts.transient, i);
        try writer.writeByte('\n');

        switch (c) {
            .push_group, .push_grid, .push_scroll, .push_overlay, .push_virtual_list => depth += 1,
            .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => unreachable, // skipped above
            .text, .rich_text, .image, .divider, .button, .text_input, .text_area, .checkbox, .radio, .slider, .canvas, .scene3d => {},
        }
    }
}

/// Allocate a snapshot string. Caller owns the returned slice. Convenience
/// over `write` for tests and one-off dumps.
pub fn snapshotAlloc(
    allocator: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    opts: SnapshotOptions,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try write(&aw.writer, cmds, rects, opts);
    return aw.toOwnedSlice();
}

/// Golden-test helper, styled after `std.testing.expectEqualStrings`: on
/// mismatch it prints a readable diff and fails the test. This is the
/// canonical way to golden-test a view headlessly —
/// view → layout (monoMeasurer) → `expectSnapshot`.
pub fn expectSnapshot(
    cmds: anytype,
    rects: []const Rect,
    opts: SnapshotOptions,
    expected: []const u8,
) !void {
    const actual = try snapshotAlloc(std.testing.allocator, cmds, rects, opts);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}


fn writeCmd(writer: anytype, c: anytype, r: Rect) !void {
    switch (c) {
        .push_group => |g| {
            try writer.writeAll("group ");
            try writeRect(writer, r);
            try writer.print(" {s}", .{@tagName(g.direction)});
            if (g.bg != null) try writer.writeAll(" bg");
            if (g.border != null) try writer.writeAll(" border");
        },
        .push_grid => |g| {
            try writer.writeAll("grid ");
            try writeRect(writer, r);
            try writer.print(" cols={d}", .{g.columnCount()});
            if (g.bg != null) try writer.writeAll(" bg");
            if (g.border != null) try writer.writeAll(" border");
        },
        .push_scroll => |s| {
            try writer.writeAll("scroll ");
            try writeRect(writer, r);
            try writer.print(" {s}", .{@tagName(s.direction)});
            if (s.scroll_x != 0) try writer.print(" scroll_x={d}", .{ri(s.scroll_x)});
            if (s.scroll_y != 0) try writer.print(" scroll_y={d}", .{ri(s.scroll_y)});
            if (s.id != 0) try writer.print(" id={d}", .{s.id});
        },
        .push_overlay => |o| {
            try writer.writeAll("overlay ");
            try writeRect(writer, r);
            // Overlays are the single non-base z-layer (HARDLINE §2 hatch 5).
            try writer.writeAll(" layer=1");
            if (o.modal) try writer.writeAll(" [modal]");
            if (o.shadow != null) try writer.writeAll(" shadow");
        },
        .push_virtual_list => |v| {
            try writer.writeAll("virtual_list ");
            try writeRect(writer, r);
            try writer.print(" total={d} extent={d} visible=[{d},{d})", .{
                v.total_count, ri(v.item_extent), v.visible_start, v.visible_end,
            });
        },
        .text => |t| {
            try writer.writeAll("text ");
            try writeRect(writer, r);
            try writer.writeByte(' ');
            try writeQuoted(writer, t.content);
            if (t.wrap != .none) try writer.print(" wrap={s}", .{@tagName(t.wrap)});
            if (t.max_lines != 0) try writer.print(" max_lines={d}", .{t.max_lines});
            if (t.text_align != .start) try writer.print(" align={s}", .{@tagName(t.text_align)});
        },
        .rich_text => |rt| {
            // Flattened text = the full content string; spans index into it.
            try writer.writeAll("rich_text ");
            try writeRect(writer, r);
            try writer.writeByte(' ');
            try writeQuoted(writer, rt.content);
            if (rt.wrap != .none) try writer.print(" wrap={s}", .{@tagName(rt.wrap)});
            if (rt.max_lines != 0) try writer.print(" max_lines={d}", .{rt.max_lines});
            if (rt.text_align != .start) try writer.print(" align={s}", .{@tagName(rt.text_align)});
        },
        .image => |img| {
            try writer.writeAll("image ");
            try writeRect(writer, r);
            try writer.print(" handle={d}", .{img.handle});
        },
        .button => |b| {
            try writer.writeAll("button ");
            try writeRect(writer, r);
            try writer.writeByte(' ');
            try writeQuoted(writer, b.label);
            if (b.underline) |u| try writer.print(" underline={d}", .{u});
            if (b.disabled) try writer.writeAll(" [disabled]");
        },
        .text_input => |ti| {
            try writer.writeAll("text_input ");
            try writeRect(writer, r);
            try writer.writeByte(' ');
            try writeQuoted(writer, ti.content);
            try writer.print(" cursor={d}", .{ti.cursor});
            if (ti.selection_anchor) |a| {
                const lo = @min(a, ti.cursor);
                const hi = @max(a, ti.cursor);
                if (lo != hi) try writer.print(" sel=[{d},{d})", .{ lo, hi });
            }
            if (ti.disabled) try writer.writeAll(" [disabled]");
        },
        .text_area => |ta| {
            try writer.writeAll("text_area ");
            try writeRect(writer, r);
            try writer.print(" id={d} ", .{ta.id});
            try writeQuoted(writer, ta.content);
            try writer.print(" cursor={d}", .{ta.cursor});
            if (ta.selection_anchor) |a| {
                const lo = @min(a, ta.cursor);
                const hi = @max(a, ta.cursor);
                if (lo != hi) try writer.print(" sel=[{d},{d})", .{ lo, hi });
            }
            if (ta.scroll_x != 0 or ta.scroll_y != 0) try writer.print(" scroll=({d},{d})", .{ ri(ta.scroll_x), ri(ta.scroll_y) });
            if (ta.wrap != .word) try writer.print(" wrap={s}", .{@tagName(ta.wrap)});
            if (ta.disabled) try writer.writeAll(" [disabled]");
        },
        .checkbox => |cbx| {
            try writer.writeAll("checkbox ");
            try writeRect(writer, r);
            try writer.print(" {s} ", .{if (cbx.checked) "[x]" else "[ ]"});
            try writeQuoted(writer, cbx.label);
        },
        .radio => |rd| {
            try writer.writeAll("radio ");
            try writeRect(writer, r);
            try writer.print(" {s} ", .{if (rd.selected) "(o)" else "( )"});
            try writeQuoted(writer, rd.label);
        },
        .slider => |sl| {
            try writer.writeAll("slider ");
            try writeRect(writer, r);
            try writer.print(" value={d:.2}", .{sl.value});
        },
        .divider => {
            try writer.writeAll("divider ");
            try writeRect(writer, r);
        },
        .canvas => |cv| {
            try writer.writeAll("canvas ");
            try writeRect(writer, r);
            try writer.print(" prims={d}", .{cv.primitives.len});
            const xf = cv.style.transform;
            if (!xf.isIdentity()) try writer.print(" xf=({d:.3},{d:.3},{d:.1},{d:.1})", .{ xf.sx, xf.sy, xf.tx, xf.ty });
            if (cv.style.antialias) try writer.writeAll(" aa");
            if (cv.id != 0) try writer.print(" id={d}", .{cv.id});
            if (cv.pointer) try writer.writeAll(" pointer");
            if (cv.label.len > 0) {
                try writer.writeByte(' ');
                try writeQuoted(writer, cv.label);
            }
        },
        .scene3d => |sc| {
            try writer.writeAll("scene3d ");
            try writeRect(writer, r);
            try writer.print(" mesh={d} key={d}", .{ sc.mesh, sc.key });
            if (sc.id != 0) try writer.print(" id={d}", .{sc.id});
            if (sc.view.items.len > 0) try writer.print(" items={d}", .{sc.view.items.len});
            if (sc.view.grid != null) try writer.writeAll(" grid");
            if (sc.view.cut != null) try writer.writeAll(" cut");
            if (sc.view.gizmo != null) try writer.writeAll(" gizmo");
            if (sc.view.material == .flat) try writer.writeAll(" flat");
            if (sc.pointer) try writer.writeAll(" pointer");
            if (sc.label.len > 0) {
                try writer.writeByte(' ');
                try writeQuoted(writer, sc.label);
            }
        },
        // Pop cmds are handled before writeCmd is ever called.
        .pop_group, .pop_grid, .pop_scroll, .pop_overlay, .pop_virtual_list => unreachable,
    }
}


/// Round a float to the nearest integer for stable, diff-friendly output.
/// Sub-pixel jitter never changes the serialized bytes.
///
/// Hardened against non-finite / out-of-range inputs: a NaN or ±inf rect
/// coordinate (e.g. from a degenerate layout) must NOT panic here —
/// snapshot is a diagnostic sink and `run` advertises it as
/// never-crashing. `@intFromFloat` is UB / a checked panic for ±inf, NaN,
/// or magnitudes past the i64 range, so guard both before converting.
fn ri(v: f32) i64 {
    if (!std.math.isFinite(v)) return 0;
    // 2^62 is exactly representable and keeps @round(clamped) safely inside
    // the i64 range; real pixel coordinates never approach it.
    const limit: f32 = 0x1p62;
    return @intFromFloat(@round(std.math.clamp(v, -limit, limit)));
}

fn writeRect(writer: anytype, r: Rect) !void {
    try writer.print("({d},{d},{d},{d})", .{ ri(r.x), ri(r.y), ri(r.w), ri(r.h) });
}

fn writeIndent(writer: anytype, depth: usize) !void {
    var n = depth;
    while (n > 0) : (n -= 1) try writer.writeAll("  ");
}

/// Append transient markers for cmd `i`, in a fixed order so output stays
/// deterministic: `[hover]` then `[press]` then `[focus]`.
fn writeMarkers(writer: anytype, transient: ?*const TransientState, i: usize) !void {
    const t = transient orelse return;
    if (t.hover_index == i) try writer.writeAll(" [hover]");
    if (t.press_index == i) try writer.writeAll(" [press]");
    if (t.focus_index == i) try writer.writeAll(" [focus]");
}

/// Write `s` as a double-quoted string with control chars escaped so a
/// multi-line label can't break the one-line-per-cmd invariant.
fn writeQuoted(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}


const cmd = @import("cmd.zig");
const text = @import("text.zig");

/// Lay out `cb`'s buffer with the mono stub measurer into `rects` and
/// return the used slice — the standard headless view→layout step.
fn layoutInto(rects: []Rect, cmds: anytype, w: f32, h: f32) []const Rect {
    layout.LayoutEngine.doLayout(rects[0..cmds.len], cmds, w, h, text.monoMeasurer());
    return rects[0..cmds.len];
}























