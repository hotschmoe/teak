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

// ── Options ────────────────────────────────────────────────────────

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

// ── Public API ─────────────────────────────────────────────────────

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
            .pop_group, .pop_scroll, .pop_overlay, .pop_virtual_list => {
                if (depth > 0) depth -= 1;
                continue;
            },
            else => {},
        }

        try writeIndent(writer, depth);
        const r = if (i < rects.len) rects[i] else Rect{};
        try writeCmd(writer, c, r);
        try writeMarkers(writer, opts.transient, i);
        try writer.writeByte('\n');

        switch (c) {
            .push_group, .push_scroll, .push_overlay, .push_virtual_list => depth += 1,
            else => {},
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

// ── Per-cmd formatting ─────────────────────────────────────────────

fn writeCmd(writer: anytype, c: anytype, r: Rect) !void {
    switch (c) {
        .push_group => |g| {
            try writer.writeAll("group ");
            try writeRect(writer, r);
            try writer.print(" {s}", .{@tagName(g.direction)});
            if (g.bg != null) try writer.writeAll(" bg");
        },
        .push_scroll => |s| {
            try writer.writeAll("scroll ");
            try writeRect(writer, r);
            try writer.print(" {s}", .{@tagName(s.direction)});
            if (s.scroll_x != 0) try writer.print(" scroll_x={d}", .{ri(s.scroll_x)});
            if (s.scroll_y != 0) try writer.print(" scroll_y={d}", .{ri(s.scroll_y)});
        },
        .push_overlay => |o| {
            try writer.writeAll("overlay ");
            try writeRect(writer, r);
            // Overlays are the single non-base z-layer (HARDLINE §2 hatch 5).
            try writer.writeAll(" layer=1");
            if (o.modal) try writer.writeAll(" [modal]");
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
        },
        .rich_text => |rt| {
            // Flattened text = the full content string; spans index into it.
            try writer.writeAll("rich_text ");
            try writeRect(writer, r);
            try writer.writeByte(' ');
            try writeQuoted(writer, rt.content);
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
        // Pop cmds are handled before writeCmd is ever called.
        .pop_group, .pop_scroll, .pop_overlay, .pop_virtual_list => unreachable,
    }
}

// ── Helpers ────────────────────────────────────────────────────────

/// Round a float to the nearest integer for stable, diff-friendly output.
/// Sub-pixel jitter never changes the serialized bytes.
fn ri(v: f32) i64 {
    return @intFromFloat(@round(v));
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

// ── Tests ──────────────────────────────────────────────────────────

const cmd = @import("cmd.zig");
const text = @import("text.zig");

/// Lay out `cb`'s buffer with the mono stub measurer into `rects` and
/// return the used slice — the standard headless view→layout step.
fn layoutInto(rects: []Rect, cmds: anytype, w: f32, h: f32) []const Rect {
    layout.LayoutEngine.doLayout(rects[0..cmds.len], cmds, w, h, text.monoMeasurer());
    return rects[0..cmds.len];
}

test "snapshot: simple counter view — grep-able, indented" {
    const Msg = union(enum) { inc, dec };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.text("Count: 0");
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.button(.inc, "+");
    cb.button(.dec, "-");
    cb.popGroup();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 800, 600);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,800,600) vertical
        \\  text (0,0,80,20) "Count: 0"
        \\  group (0,20,120,36) horizontal
        \\    button (0,20,60,36) "+"
        \\    button (60,20,60,36) "-"
        \\
    );
}

test "snapshot: header line is caller-supplied + deterministic" {
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.text("hi");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    try expectSnapshot(cb.cmds.items, rs, .{ .header = .{
        .window_w = 400,
        .window_h = 300,
        .frame = 42,
        .last_msg = "increment",
    } },
        \\window=400x300 frame=42 last_msg=increment
        \\group (0,0,400,300) vertical
        \\  text (0,0,20,20) "hi"
        \\
    );
}

test "snapshot: button disabled flag renders" {
    const Msg = union(enum) { go };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.buttonDisabled(.go, "Add");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,400,300) vertical
        \\  button (0,0,60,36) "Add" [disabled]
        \\
    );
}

test "snapshot: text_input with cursor, selection, disabled, focus marker" {
    const Msg = union(enum) { focus };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.textInputSelected(.focus, "hello", 5, 1, cb.theme.text_input);
    cb.textInputDisabled(.focus, "off", 0);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    var ts: TransientState = .{};
    ts.focus_index = 1; // the first text_input

    try expectSnapshot(cb.cmds.items, rs, .{ .transient = &ts },
        \\group (0,0,400,300) vertical
        \\  text_input (0,0,400,150) "hello" cursor=5 sel=[1,5) [focus]
        \\  text_input (0,150,400,150) "off" cursor=0 [disabled]
        \\
    );
}

test "snapshot: checkbox + radio checked-state glyphs" {
    const Msg = union(enum) { t, r };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.checkbox(.t, true, "on");
    cb.checkbox(.t, false, "off");
    cb.radio(.r, true, "sel");
    cb.radio(.r, false, "unsel");
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,400,300) vertical
        \\  checkbox (0,0,46,20) [x] "on"
        \\  checkbox (0,20,56,20) [ ] "off"
        \\  radio (0,40,56,20) (o) "sel"
        \\  radio (0,60,76,20) ( ) "unsel"
        \\
    );
}

test "snapshot: slider value formats to 2 decimals" {
    const Msg = union(enum) { grab };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.slider(.grab, 0.5);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 100);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,400,100) horizontal
        \\  slider (0,0,400,100) value=0.50
        \\
    );
}

test "snapshot: divider" {
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.text("top");
    cb.divider();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 300, 200);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,300,200) vertical
        \\  text (0,0,30,20) "top"
        \\  divider (0,20,300,1)
        \\
    );
}

test "snapshot: overlay marked with layer + [modal]" {
    const Msg = union(enum) { close };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.close, "x");
    cb.pushOverlay(.{ .x = 10, .y = 20, .width = 100, .height = 50, .padding = 0, .modal = true });
    cb.text("tip");
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,400,300) vertical
        \\  button (0,0,60,36) "x"
        \\  overlay (10,20,100,50) layer=1 [modal]
        \\    text (10,20,30,20) "tip"
        \\
    );
}

test "snapshot: scroll shows offsets; virtual_list shows totals" {
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 0, .width = 200, .height = 100, .scroll_y = 24 });
    cb.pushVirtualList(.{ .direction = .vertical, .total_count = 1000, .item_extent = 24, .visible_start = 1, .visible_end = 3 });
    cb.text("row 1");
    cb.text("row 2");
    cb.popVirtualList();
    cb.popScroll();

    var rects: [16]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\scroll (0,0,200,100) vertical scroll_y=24
        \\  virtual_list (0,-24,50,24000) total=1000 extent=24 visible=[1,3)
        \\    text (0,0,50,20) "row 1"
        \\    text (0,20,50,20) "row 2"
        \\
    );
}

test "snapshot: image + rich_text flattened" {
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.image(7, .{ .width = 64, .height = 48 });
    cb.mixedText(&.{
        .{ .text = "Length: " },
        .{ .text = "42.0", .font = .{ .size_px = 14, .family = .mono } },
    });
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    try expectSnapshot(cb.cmds.items, rs, .{},
        \\group (0,0,400,300) vertical
        \\  image (0,0,64,48) handle=7
        \\  rich_text (0,48,120,20) "Length: 42.0"
        \\
    );
}

test "snapshot: hover + press markers by cmd index" {
    const Msg = union(enum) { a, b };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.button(.a, "A");
    cb.button(.b, "B");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 100);

    var ts: TransientState = .{};
    ts.hover_index = 1; // button A
    ts.press_index = 2; // button B

    try expectSnapshot(cb.cmds.items, rs, .{ .transient = &ts },
        \\group (0,0,400,100) horizontal
        \\  button (0,0,60,36) "A" [hover]
        \\  button (60,0,60,36) "B" [press]
        \\
    );
}

test "snapshot: quoting escapes control chars, keeps one line per cmd" {
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.text("a\"b\tc\nd");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 400, 300);

    const out = try snapshotAlloc(std.testing.allocator, cb.cmds.items, rs, .{});
    defer std.testing.allocator.free(out);

    // The embedded newline is escaped, so the whole text cmd is one line.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"a\\\"b\\tc\\nd\"") != null);
    // Exactly two '\n' terminators: the group line and the text line.
    var newlines: usize = 0;
    for (out) |ch| {
        if (ch == '\n') newlines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), newlines);
}

test "snapshot: deterministic — two runs byte-identical" {
    const Msg = union(enum) { inc };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 8, .gap = 4 });
    cb.text("Count: 3");
    cb.button(.inc, "Increment");
    cb.checkbox(.inc, true, "auto");
    cb.slider(.inc, 0.33);
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 640, 480);

    const a = try snapshotAlloc(std.testing.allocator, cb.cmds.items, rs, .{});
    defer std.testing.allocator.free(a);
    const b = try snapshotAlloc(std.testing.allocator, cb.cmds.items, rs, .{});
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
}

test "snapshot: short rects slice yields zero-rects for the tail (no error)" {
    const Msg = union(enum) { a };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.text("x");
    cb.text("y");

    // Deliberately pass an empty rects slice — every cmd falls back to a
    // zero rect rather than reading out of bounds.
    try expectSnapshot(cb.cmds.items, &.{}, .{},
        \\text (0,0,0,0) "x"
        \\text (0,0,0,0) "y"
        \\
    );
}

test "snapshot: realistic composed view golden" {
    const Msg = union(enum) { help, inc, dec, focus };
    var cb = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 8, .gap = 8 });
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8 });
    cb.button(.help, "Help");
    cb.button(.inc, "+");
    cb.button(.dec, "-");
    cb.popGroup();
    cb.text("Count: 0");
    cb.textInput(.focus, "name", 4);
    cb.popGroup();

    var rects: [32]Rect = undefined;
    const rs = layoutInto(&rects, cb.cmds.items, 800, 600);

    try expectSnapshot(cb.cmds.items, rs, .{ .header = .{
        .window_w = 800,
        .window_h = 600,
        .frame = 1,
        .last_msg = "inc",
    } },
        \\window=800x600 frame=1 last_msg=inc
        \\group (0,0,800,600) vertical
        \\  group (8,8,196,36) horizontal
        \\    button (8,8,60,36) "Help"
        \\    button (76,8,60,36) "+"
        \\    button (144,8,60,36) "-"
        \\  text (8,52,80,20) "Count: 0"
        \\  text_input (8,80,784,512) "name" cursor=4
        \\
    );
}
