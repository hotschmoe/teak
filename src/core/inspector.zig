//! Dev inspector panel: the widget tree, the hovered widget's rect + style
//! dump, the last Msgs and frame timings, drawn as an overlay over the app.
//! `teak.run` appends it after the app's `view` when the inspector is on
//! (`TEAK_INSPECT=1`, the F12 hotkey, or the control channel's `inspect`
//! command). Extends `debug_overlay.zig`'s idea (cmd + rect dump) into a
//! panel an agent or a human can use to see why a layout looks the way it does.
//!
//! ## Where this sits (HARDLINE)
//!
//! `appendInspector` is a pure function of its arguments: the previous frame's
//! cmds + rects, the hover/focus indices, the Msg texts and the timings the
//! loop measured, all handed in as data. It formats everything into the
//! frame's own arena and emits ordinary `push_overlay` cmds, so layout,
//! hit-test, render and the frame-diff treat it like any other overlay. It
//! reads no clock and holds no state. Whether it is shown, and the Msg ring
//! and timings it displays, are loop bookkeeping owned by `run.zig` (like
//! `press_target`): presentation data that never reaches `update` or `view`
//! and is safely losable. See docs/features/agent-driver.md.

const std = @import("std");
const layout = @import("../layout/engine.zig");
const a11y = @import("../input/a11y.zig");
const text_mod = @import("text.zig");

const Rect = layout.Rect;

/// How long the loop's passes took last frame, in milliseconds (measured by
/// `run.zig`; the inspector only displays them).
pub const Timings = struct {
    view_ms: f32 = 0,
    layout_ms: f32 = 0,
    render_ms: f32 = 0,
};

pub const Opts = struct {
    /// Panel width (clamped to 60% of the window).
    width: f32 = 460,
    font: text_mod.FontSpec = .{ .size_px = 11, .family = .mono },
    fg: [4]f32 = .{ 0.9, 0.92, 0.95, 1 },
    dim: [4]f32 = .{ 0.55, 0.6, 0.68, 1 },
    accent: [4]f32 = .{ 0.4, 0.7, 1.0, 1 },
    bg: [4]f32 = .{ 0.04, 0.045, 0.06, 0.94 },
    /// Widget-tree lines shown (the rest is summarized).
    max_tree_lines: usize = 12,
    /// Style-dump lines for the hovered cmd.
    max_style_lines: usize = 5,
    /// Characters per line before clipping.
    max_cols: usize = 66,
};

/// Everything the inspector shows, as data.
pub const Data = struct {
    window_w: f32,
    window_h: f32,
    frame: u32,
    /// Hovered / focused cmd index into the cmds passed alongside (null: none).
    hover_index: ?usize = null,
    focus_index: ?usize = null,
    /// The Msgs to list, oldest first (formatted text; copied into the arena).
    msgs: []const []const u8 = &.{},
    timings: Timings = .{},
};

/// Append the inspector overlay to `cb`. `cmds` / `rects` are the frame the
/// user is looking at WITHOUT any inspector cmds (pass the app-only prefix);
/// they may belong to another buffer than `cb`.
pub fn appendInspector(cb: anytype, cmds: anytype, rects: []const Rect, data: Data, opts: Opts) void {
    const arena = cb.arena.allocator();

    var lines: std.ArrayList(Line) = .empty;
    const add = struct {
        fn f(a: std.mem.Allocator, l: *std.ArrayList(Line), color: [4]f32, comptime fmt: []const u8, args: anytype, cols: usize) void {
            const s = std.fmt.allocPrint(a, fmt, args) catch return;
            l.append(a, .{ .text = s[0..@min(s.len, cols)], .color = color }) catch return;
        }
    }.f;

    add(arena, &lines, opts.accent, "TEAK INSPECTOR   frame {d}   {d} cmds   {d:.0}x{d:.0}", .{ data.frame, cmds.len, data.window_w, data.window_h }, opts.max_cols);
    add(arena, &lines, opts.fg, "view {d:.2}ms  layout {d:.2}ms  render {d:.2}ms", .{ data.timings.view_ms, data.timings.layout_ms, data.timings.render_ms }, opts.max_cols);

    // Hovered widget.
    var highlight: ?Rect = null;
    add(arena, &lines, opts.accent, "-- hover --", .{}, opts.max_cols);
    if (data.hover_index) |hi| if (hi < cmds.len and hi < rects.len) {
        const r = rects[hi];
        highlight = r;
        add(arena, &lines, opts.fg, "#{d} {s} ({d:.0},{d:.0},{d:.0},{d:.0})", .{ hi, @tagName(std.meta.activeTag(cmds[hi])), r.x, r.y, r.w, r.h }, opts.max_cols);
        dumpStyle(arena, &lines, cmds[hi], opts);
    } else {
        add(arena, &lines, opts.dim, "(nothing)", .{}, opts.max_cols);
    } else {
        add(arena, &lines, opts.dim, "(nothing)", .{}, opts.max_cols);
    }

    // Widget tree (a11y roles: what a screen reader would see).
    add(arena, &lines, opts.accent, "-- tree --", .{}, opts.max_cols);
    if (a11y.buildTree(arena, cmds, rects, data.focus_index)) |nodes| {
        var shown: usize = 0;
        for (nodes) |n| {
            switch (n.role) {
                .group, .scroll, .divider => continue, // structure, not content
                else => {},
            }
            if (shown == opts.max_tree_lines) {
                add(arena, &lines, opts.dim, "... {d} more", .{countRemaining(nodes, shown)}, opts.max_cols);
                break;
            }
            const mark: []const u8 = if (n.focused) "*" else " ";
            add(arena, &lines, if (n.focused) opts.accent else opts.fg, "{s}{s} \"{s}\" ({d:.0},{d:.0},{d:.0},{d:.0})", .{
                mark,       @tagName(n.role), clip(n.label, 22),
                n.bounds.x, n.bounds.y,       n.bounds.w,
                n.bounds.h,
            }, opts.max_cols);
            shown += 1;
        }
    } else |_| {}

    // Msgs.
    add(arena, &lines, opts.accent, "-- last {d} msgs --", .{data.msgs.len}, opts.max_cols);
    if (data.msgs.len == 0) add(arena, &lines, opts.dim, "(none yet)", .{}, opts.max_cols);
    for (data.msgs) |m| add(arena, &lines, opts.fg, "{s}", .{m}, opts.max_cols);

    // Emit. The highlight goes first so the panel paints above it.
    if (highlight) |r| {
        cb.pushOverlay(.{
            .x = r.x,
            .y = r.y,
            .width = @max(r.w, 1),
            .height = @max(r.h, 1),
            .padding = 0,
            .backdrop = .{ 0.3, 0.6, 1.0, 0.16 },
            .border = .{ 0.4, 0.75, 1.0, 0.95 },
            .border_width = 1,
        });
        cb.popOverlay();
    }
    const w = @min(opts.width, data.window_w * 0.6);
    cb.pushOverlay(.{
        .x = @max(data.window_w - w - 8, 0),
        .y = 8,
        .width = w,
        .padding = 8,
        .gap = 1,
        .backdrop = opts.bg,
        .border = .{ 0.3, 0.45, 0.65, 1 },
    });
    for (lines.items) |l| cb.textStyled(l.text, opts.font, l.color);
    cb.popOverlay();
}

const Line = struct { text: []const u8, color: [4]f32 };

fn clip(s: []const u8, n: usize) []const u8 {
    return s[0..@min(s.len, n)];
}

fn countRemaining(nodes: []const a11y.A11yNode, shown: usize) usize {
    var n: usize = 0;
    for (nodes) |node| switch (node.role) {
        .group, .scroll, .divider => {},
        else => n += 1,
    };
    return n - shown;
}

/// The hovered cmd's payload struct, formatted and wrapped into a few lines.
fn dumpStyle(arena: std.mem.Allocator, lines: *std.ArrayList(Line), c: anytype, opts: Opts) void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    switch (c) {
        inline else => |payload| fmtValue(&aw.writer, payload) catch return,
    }
    const s = aw.written();
    var off: usize = 0;
    var n: usize = 0;
    while (off < s.len and n < opts.max_style_lines) : (n += 1) {
        const end = @min(off + opts.max_cols - 2, s.len);
        lines.append(arena, .{ .text = std.fmt.allocPrint(arena, "  {s}", .{s[off..end]}) catch return, .color = opts.dim }) catch return;
        off = end;
    }
    if (off < s.len) lines.append(arena, .{ .text = "  ...", .color = opts.dim }) catch {};
}

/// Compact one-line rendering of a Msg (or any value): `.tag(payload)` for
/// unions, quoted text for byte slices, `.{ .f = v }` for structs.
pub fn fmtValue(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .@"union" => switch (v) {
            inline else => |payload, tag| {
                try w.print(".{s}", .{@tagName(tag)});
                if (@TypeOf(payload) != void) {
                    try w.writeByte('(');
                    try fmtValue(w, payload);
                    try w.writeByte(')');
                }
            },
        },
        .@"struct" => {
            try w.writeAll(".{");
            inline for (comptime std.meta.fieldNames(T), 0..) |name, i| {
                if (i > 0) try w.writeByte(',');
                try w.print(" .{s} = ", .{name});
                try fmtValue(w, @field(v, name));
            }
            try w.writeAll(" }");
        },
        .optional => if (v) |p| try fmtValue(w, p) else try w.writeAll("null"),
        .@"enum" => try w.print(".{s}", .{@tagName(v)}),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try w.print("\"{s}\"", .{v});
            } else if (p.size == .slice) {
                try w.print("[{d} items]", .{v.len});
            } else try w.writeAll("*");
        },
        .array => |a| {
            if (a.child == u8) {
                try w.print("\"{s}\"", .{&v});
            } else if (@typeInfo(a.child) == .float or @typeInfo(a.child) == .int) {
                try w.writeByte('[');
                for (v, 0..) |e, i| {
                    if (i > 0) try w.writeByte(',');
                    try fmtValue(w, e);
                }
                try w.writeByte(']');
            } else try w.print("[{d} items]", .{v.len});
        },
        .void => {},
        .int => if (T == u8 and v >= 0x20 and v < 0x7f)
            try w.print("{d} '{c}'", .{ v, v })
        else
            try w.print("{d}", .{v}),
        .float => try w.print("{d}", .{v}),
        else => try w.print("{any}", .{v}),
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd_mod = @import("cmd.zig");

test "fmtValue renders unions, strings, structs, arrays and optionals" {
    const Msg = union(enum) {
        inc,
        add: []const u8,
        move: struct { x: f32, y: f32 },
        pick: ?u32,
        color: [4]f32,
        ch: u8,
    };
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fmtValue(&w, Msg{ .inc = {} });
    try std.testing.expectEqualStrings(".inc", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fmtValue(&w, Msg{ .add = "milk" });
    try std.testing.expectEqualStrings(".add(\"milk\")", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fmtValue(&w, Msg{ .move = .{ .x = 1.5, .y = 2 } });
    try std.testing.expectEqualStrings(".move(.{ .x = 1.5, .y = 2 })", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fmtValue(&w, Msg{ .pick = null });
    try std.testing.expectEqualStrings(".pick(null)", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fmtValue(&w, Msg{ .color = .{ 1, 0.5, 0, 1 } });
    try std.testing.expectEqualStrings(".color([1,0.5,0,1])", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fmtValue(&w, Msg{ .ch = 'm' });
    try std.testing.expectEqualStrings(".ch(109 'm')", w.buffered());
}

test "appendInspector: highlight + panel overlays with the hovered cmd, tree and msgs" {
    const testing = std.testing;
    const Msg = union(enum) { go, other };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{});
    cb.text("Title");
    cb.button(.go, "Go");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const n = cb.cmds.items.len;
    layout.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var panel = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer panel.deinit();
    appendInspector(&panel, cb.cmds.items, rects[0..n], .{
        .window_w = 800,
        .window_h = 600,
        .frame = 7,
        .hover_index = 2, // the button
        .msgs = &.{ ".go", ".other" },
        .timings = .{ .view_ms = 0.25 },
    }, .{});

    var overlays: usize = 0;
    var saw_hover = false;
    var saw_tree = false;
    var saw_msg = false;
    var saw_timing = false;
    for (panel.cmds.items) |c| switch (c) {
        .push_overlay => overlays += 1,
        .text => |t| {
            if (std.mem.indexOf(u8, t.content, "#2 button") != null) saw_hover = true;
            if (std.mem.indexOf(u8, t.content, "button \"Go\"") != null) saw_tree = true;
            if (std.mem.eql(u8, t.content, ".other")) saw_msg = true;
            if (std.mem.indexOf(u8, t.content, "view 0.25ms") != null) saw_timing = true;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), overlays); // highlight + panel
    try testing.expect(saw_hover and saw_tree and saw_msg and saw_timing);
    try testing.expectEqual(.pop_overlay, std.meta.activeTag(panel.cmds.items[panel.cmds.items.len - 1]));
}

test "appendInspector without a hover emits only the panel" {
    const testing = std.testing;
    const Msg = union(enum) { go };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{});
    cb.text("x");
    cb.popGroup();
    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..3], cb.cmds.items, 100, 100, text_mod.monoMeasurer());

    var panel = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer panel.deinit();
    appendInspector(&panel, cb.cmds.items, rects[0..3], .{ .window_w = 100, .window_h = 100, .frame = 0 }, .{});
    var overlays: usize = 0;
    for (panel.cmds.items) |c| if (c == .push_overlay) {
        overlays += 1;
    };
    try testing.expectEqual(@as(usize, 1), overlays);
}
