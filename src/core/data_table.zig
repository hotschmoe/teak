//! `DataTable`: a virtualized, sortable, resizable, selectable table for large
//! row counts (100k rows scroll at the display rate).
//!
//! Everything lives in the app's Model, per HARDLINE §1:
//!
//!   * `order`  the display -> data permutation (a stable sort over indices, so
//!              the app's rows are never moved) and its inverse `rank`;
//!   * `widths` column widths (header-edge drag resizes them);
//!   * selection (a bitset by *data* row, so it survives re-sorting), the
//!     keyboard cursor and range anchor;
//!   * scroll position (`Scroller`: smooth wheel + fling), viewport size, and the
//!     modifier keys the last click should see (`modsMsg`).
//!
//! The rows themselves are NOT in the Model: the app passes a `src` value with
//!
//!     fn cell(src, arena: Allocator, col: u8, row: u32) []const u8   // text of one cell
//!     fn compare(src, col: u8, a: u32, b: u32) std.math.Order        // for sorting (a, b are data rows)
//!
//! `update` takes the `src` for sorting; `view` for cell text. `view` emits only
//! the visible rows (a `push_virtual_list` claims the full height so the scrollbar
//! and clamping are right), so cost per frame is independent of the row count.
//!
//! Wiring (see examples/tables):
//!
//!     // Msg:   table: Table.Msg
//!     // update: .table => |t| Table.update(&m.table, t, Rows{ .data = m.rows })
//!     // hooks: scrollMsg(id == TABLE_ID) -> .wheel, scrollLayoutMsg -> .viewport,
//!     //        canvasMsg -> Table.gripMsg, modsMsg -> .mods, keySpecialMsg -> Table.keyMsg,
//!     //        animationMsg -> .frame, subscribe -> animation_frame while Table.animating
//!
//! Cell text is cut with an ellipsis to the column's width in *characters*
//! (`ViewOpts.char_w`), so use a monospace font; the cut respects UTF-8.

const std = @import("std");
const cmd = @import("cmd.zig");
const table = @import("table.zig");
const scroller = @import("scroller.zig");
const pointer = @import("pointer.zig");
const keys = @import("../input/keys.zig");
const text_mod = @import("text.zig");

pub const Align = table.CellAlign;

/// One column. `width` is the initial width in px; the live width is in the Model.
pub const Column = struct {
    title: []const u8 = "",
    width: f32 = 120,
    min_width: f32 = 36,
    cell_align: Align = .left,
    sortable: bool = true,
};

pub const Config = struct {
    max_rows: usize = 131_072,
    max_cols: usize = 16,
};

/// Keyboard commands (`keyMsg` maps `SpecialKey`s to these).
pub const Key = enum { up, down, page_up, page_down, home, end, select_all, clear };

/// Narrowest header-edge grab handle, px.
pub const grip_w: f32 = 6;

pub fn DataTable(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        pub const max_rows = cfg.max_rows;
        pub const max_cols = cfg.max_cols;
        const words = (cfg.max_rows + 63) / 64;

        pub const Model = struct {
            n_rows: u32 = 0,
            /// display index -> data row
            order: [max_rows]u32 = undefined,
            /// data row -> display index
            rank: [max_rows]u32 = undefined,
            sort_col: ?u8 = null,
            sort_desc: bool = false,
            widths: [max_cols]f32 = @splat(120),
            /// Selected data rows.
            sel: [words]u64 = @splat(0),
            sel_count: u32 = 0,
            /// Data row of the keyboard cursor / range anchor (valid when `has_cursor`).
            cursor: u32 = 0,
            anchor: u32 = 0,
            has_cursor: bool = false,
            /// The table has keyboard focus (set by a click in it, cleared by `blur`).
            focused: bool = false,
            mods: pointer.Modifiers = .{},
            sc: scroller.Scroller = .{},
            view_w: f32 = 0,
            view_h: f32 = 0,
            /// Row height the last `view` used, so keyboard reveal / paging match it.
            row_h: f32 = 22,

            /// Replace the row set: identity order, nothing selected, scroll at the top.
            pub fn setRows(self: *Model, n: usize) void {
                const count: u32 = @intCast(@min(n, max_rows));
                self.n_rows = count;
                for (0..count) |i| {
                    self.order[i] = @intCast(i);
                    self.rank[i] = @intCast(i);
                }
                self.sort_col = null;
                self.sort_desc = false;
                self.clearSelection();
                self.has_cursor = false;
                self.sc = .{};
            }

            /// Set column widths from the column definitions.
            pub fn setColumns(self: *Model, cols: []const Column) void {
                for (cols, 0..) |c, i| if (i < max_cols) {
                    self.widths[i] = c.width;
                };
            }

            pub fn isSelected(self: *const Model, row: u32) bool {
                return (self.sel[row >> 6] >> @intCast(row & 63)) & 1 != 0;
            }

            fn setBit(self: *Model, row: u32, on: bool) void {
                const was = self.isSelected(row);
                if (was == on) return;
                const bit = @as(u64, 1) << @intCast(row & 63);
                if (on) {
                    self.sel[row >> 6] |= bit;
                    self.sel_count += 1;
                } else {
                    self.sel[row >> 6] &= ~bit;
                    self.sel_count -= 1;
                }
            }

            pub fn clearSelection(self: *Model) void {
                @memset(&self.sel, 0);
                self.sel_count = 0;
            }

            /// Display index of the cursor row, if any.
            pub fn cursorDisplay(self: *const Model) ?u32 {
                return if (self.has_cursor and self.n_rows > 0) self.rank[self.cursor] else null;
            }

            /// The selected data rows in display order, written to `out`; returns the count
            /// (truncated to `out.len`).
            pub fn selectedRows(self: *const Model, out: []u32) usize {
                var n: usize = 0;
                for (self.order[0..self.n_rows]) |r| {
                    if (n == out.len) break;
                    if (self.isSelected(r)) {
                        out[n] = r;
                        n += 1;
                    }
                }
                return n;
            }

            /// Whether the scroller still needs frame time.
            pub fn animating(self: *const Model) bool {
                return self.sc.animating();
            }
        };

        pub const Msg = union(enum) {
            /// Header click: sort by this column (asc, then desc, then off).
            sort: u8,
            /// Header-edge drag: widen / narrow a column.
            grip: struct { col: u8, dx: f32 },
            /// Click on a body row (display index); `Model.mods` says how.
            row: u32,
            /// Keyboard command.
            key: Key,
            /// Wheel delta (px, positive = down).
            wheel: f32,
            /// Scroll region viewport + content size (from `scrollLayoutMsg`).
            viewport: struct { vw: f32, vh: f32, cw: f32, ch: f32 },
            /// Modifier keys changed (from `modsMsg`).
            mods: pointer.Modifiers,
            /// Frame time in ms while `animating` (from `animationMsg`).
            frame: u32,
            /// Click outside / Escape-like: drop keyboard focus.
            blur,
        };

        /// Apply a message. `src` supplies `compare` for `.sort`; any `src` works otherwise.
        pub fn update(m: *Model, msg: Msg, src: anytype) void {
            switch (msg) {
                .sort => |c| sortBy(m, c, src),
                .grip => |g| if (g.col < max_cols) {
                    m.widths[g.col] = @max(min_grip_width, m.widths[g.col] + g.dx);
                },
                .row => |disp| clickRow(m, disp),
                .key => |k| keyCommand(m, k),
                .wheel => |dy| m.sc.wheel(dy),
                .viewport => |v| {
                    m.view_w = v.vw;
                    m.view_h = v.vh;
                    m.sc.setExtent(v.vh, v.ch);
                },
                .mods => |mm| m.mods = mm,
                .frame => |dt| m.sc.step(dt),
                .blur => m.focused = false,
            }
        }

        const min_grip_width: f32 = 24;

        fn sortBy(m: *Model, col: u8, src: anytype) void {
            if (m.sort_col != null and m.sort_col.? == col) {
                if (!m.sort_desc) {
                    m.sort_desc = true;
                } else {
                    m.sort_col = null;
                    m.sort_desc = false;
                }
            } else {
                m.sort_col = col;
                m.sort_desc = false;
            }
            const n = m.n_rows;
            for (0..n) |i| m.order[i] = @intCast(i);
            if (m.sort_col) |c| {
                const Ctx = struct {
                    src: @TypeOf(src),
                    col: u8,
                    desc: bool,
                    fn less(ctx: @This(), a: u32, b: u32) bool {
                        const o = ctx.src.compare(ctx.col, a, b);
                        return if (ctx.desc) o == .gt else o == .lt;
                    }
                };
                // Stable: equal rows keep their data order in either direction.
                std.sort.block(u32, m.order[0..n], Ctx{ .src = src, .col = c, .desc = m.sort_desc }, Ctx.less);
            }
            for (0..n) |i| m.rank[m.order[i]] = @intCast(i);
            if (m.cursorDisplay()) |d| reveal(m, d);
        }

        fn clickRow(m: *Model, disp: u32) void {
            if (disp >= m.n_rows) return;
            m.focused = true;
            const row = m.order[disp];
            if (m.mods.shift and m.has_cursor) {
                // Range from the anchor to the clicked row (Ctrl keeps the rest).
                if (!m.mods.ctrl) m.clearSelection();
                selectRange(m, m.rank[m.anchor], disp);
                m.cursor = row;
            } else if (m.mods.ctrl) {
                m.setBit(row, !m.isSelected(row));
                m.cursor = row;
                m.anchor = row;
                m.has_cursor = true;
            } else {
                m.clearSelection();
                m.setBit(row, true);
                m.cursor = row;
                m.anchor = row;
                m.has_cursor = true;
            }
        }

        fn selectRange(m: *Model, a: u32, b: u32) void {
            const lo = @min(a, b);
            const hi = @max(a, b);
            for (m.order[lo .. hi + 1]) |r| m.setBit(r, true);
        }

        fn visibleRows(m: *const Model) u32 {
            return @intFromFloat(@max(1, @floor(m.view_h / m.row_h)));
        }

        fn keyCommand(m: *Model, k: Key) void {
            if (m.n_rows == 0) return;
            if (k == .select_all) {
                @memset(&m.sel, 0);
                m.sel_count = 0;
                for (m.order[0..m.n_rows]) |r| m.setBit(r, true);
                return;
            }
            if (k == .clear) {
                m.clearSelection();
                return;
            }
            const last = m.n_rows - 1;
            const cur: u32 = m.cursorDisplay() orelse 0;
            const target: u32 = switch (k) {
                .up => if (m.has_cursor) cur -| 1 else 0,
                .down => if (m.has_cursor) @min(cur + 1, last) else 0,
                .page_up => cur -| visibleRows(m),
                .page_down => @min(cur + visibleRows(m), last),
                .home => 0,
                .end => last,
                else => cur,
            };
            const row = m.order[target];
            if (m.mods.shift and m.has_cursor) {
                if (!m.mods.ctrl) m.clearSelection();
                selectRange(m, m.rank[m.anchor], target);
            } else if (!m.mods.ctrl) {
                m.clearSelection();
                m.setBit(row, true);
                m.anchor = row;
            }
            m.cursor = row;
            m.has_cursor = true;
            reveal(m, target);
        }

        /// Scroll so display row `disp` is fully visible.
        pub fn reveal(m: *Model, disp: u32) void {
            const top = @as(f32, @floatFromInt(disp)) * m.row_h;
            const bottom = top + m.row_h;
            if (top < m.sc.pos) {
                m.sc.jumpTo(top);
            } else if (bottom > m.sc.pos + m.view_h) {
                m.sc.jumpTo(bottom - m.view_h);
            }
        }

        /// Map a key to a table command, or null. The app calls it from `keySpecialMsg`
        /// when `model.table.focused`.
        pub fn keyMsg(k: keys.SpecialKey, mods: pointer.Modifiers) ?Msg {
            return switch (k) {
                .up, .shift_up => .{ .key = .up },
                .down, .shift_down => .{ .key = .down },
                .page_up => .{ .key = .page_up },
                .page_down => .{ .key = .page_down },
                .home, .shift_home, .ctrl_home, .ctrl_shift_home => .{ .key = .home },
                .end, .shift_end, .ctrl_end, .ctrl_shift_end => .{ .key = .end },
                .ctrl_a => .{ .key = .select_all },
                .escape => if (mods.shift) null else .{ .key = .clear },
                else => null,
            };
        }

        /// Map a header-grip canvas event to `.grip` (the canvas id is `grip_base + col`).
        pub fn gripMsg(ev: pointer.CanvasEvent, grip_base: u32) ?Msg {
            if (ev.id < grip_base or ev.id >= grip_base + max_cols) return null;
            if (ev.kind != .move or !ev.buttons.left or ev.dx == 0) return null;
            return .{ .grip = .{ .col = @intCast(ev.id - grip_base), .dx = ev.dx } };
        }

        // ── View ───────────────────────────────────────────────────

        pub const ViewOpts = struct {
            /// `ScrollStyle.id` of the body (wheel + layout reports). Non-zero.
            id: u32,
            /// Header-grip canvas ids are `grip_base + col`.
            grip_base: u32,
            row_h: f32 = 22,
            header_h: f32 = 26,
            font: text_mod.FontSpec = .{ .size_px = 13, .family = .mono },
            /// Advance of one character of `font` (monospace), for ellipsis fitting.
            char_w: f32 = 8,
            /// Horizontal cell padding.
            pad_x: f32 = 8,
            /// Body viewport height; 0 = flex (fill the parent).
            height: f32 = 0,
            zebra: bool = true,
            /// Rows emitted beyond the viewport on each side.
            overscan: u32 = 2,
            /// Rows to emit before the first layout reports the viewport height.
            initial_rows: u32 = 40,
        };

        /// Total width of the columns, px.
        pub fn totalWidth(m: *const Model, cols: []const Column) f32 {
            var w: f32 = 0;
            for (cols, 0..) |_, i| w += m.widths[i];
            return w;
        }

        /// First display row and one-past-last the view would emit.
        pub fn window(m: *const Model, opts: ViewOpts) struct { first: u32, end: u32 } {
            if (m.n_rows == 0) return .{ .first = 0, .end = 0 };
            const first_f = @floor(m.sc.pos / opts.row_h);
            const first: u32 = @intFromFloat(@max(0, first_f));
            const first_o = first -| opts.overscan;
            const span: u32 = if (m.view_h > 0)
                @as(u32, @intFromFloat(@ceil(m.view_h / opts.row_h))) + 1
            else
                opts.initial_rows;
            const end = @min(m.n_rows, first + span + opts.overscan);
            return .{ .first = @min(first_o, m.n_rows), .end = end };
        }

        /// Emit the table: sticky header (outside the scroll) + virtualized body.
        /// `msgs` supplies `sort(col: u8)` and `row(display: u32)` as the app's Msg values.
        pub fn view(m: *const Model, cb: anytype, cols: []const Column, src: anytype, msgs: anytype, opts: ViewOpts) void {
            const pal = cb.theme.palette;
            const arena = cb.arena.allocator();

            cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .flex = if (opts.height > 0) 0 else 1 });

            // Header: sticky because it is not inside the scroll region.
            cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .height = opts.header_h, .bg = pal.bg_raised });
            for (cols, 0..) |col, i| {
                const w = m.widths[i];
                cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .width = w, .height = opts.header_h });
                var title = col.title;
                if (m.sort_col != null and m.sort_col.? == i) {
                    title = std.fmt.allocPrint(arena, "{s} {s}", .{ col.title, if (m.sort_desc) "\u{25BC}" else "\u{25B2}" }) catch col.title;
                }
                title = ellipsize(arena, title, charsFor(w - grip_w, opts));
                var hs = cb.theme.button;
                hs.bg = pal.bg_raised;
                hs.hover_bg = pal.bg_hover;
                hs.fg = pal.fg_muted;
                hs.h_padding = opts.pad_x;
                hs.min_width = @max(0, w - grip_w);
                hs.height = opts.header_h;
                hs.label_align = labelAlign(col.cell_align);
                if (col.sortable) {
                    cb.buttonStyled(msgs.sort(@intCast(i)), title, hs);
                } else {
                    cb.textStyled(title, opts.font, pal.fg_muted);
                }
                // The resize grip: a thin interactive canvas on the column's right edge.
                const prims = arena.alloc(cmd.CanvasPrimitive, 1) catch return;
                prims[0] = .{ .vline = .{ .x = grip_w / 2, .color = pal.border, .thickness = 1 } };
                cb.canvasInteractive(.{ .width = grip_w, .height = opts.header_h }, prims, opts.grip_base + @as(u32, @intCast(i)), "resize column");
                cb.popGroup();
            }
            cb.popGroup();
            cb.dividerStyled(.{ .thickness = 1, .color = pal.border });

            // Body.
            cb.pushScroll(.{
                .direction = .vertical,
                .padding = 0,
                .gap = 0,
                .id = opts.id,
                .flex = if (opts.height > 0) 0 else 1,
                .height = opts.height,
                .align_cross = .start,
                .scroll_y = m.sc.pos,
            });
            const win = window(m, opts);
            cb.pushVirtualList(.{
                .total_count = m.n_rows,
                .item_extent = opts.row_h,
                .visible_start = win.first,
                .visible_end = win.end,
            });
            var disp = win.first;
            while (disp < win.end) : (disp += 1) {
                const row = m.order[disp];
                const selected = m.isSelected(row);
                const is_cursor = m.focused and m.has_cursor and m.cursor == row;
                const bg = rowColor(pal, selected, is_cursor, opts.zebra and disp % 2 == 1);
                cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .height = opts.row_h });
                for (cols, 0..) |col, i| {
                    const w = m.widths[i];
                    var bs = cb.theme.button;
                    bs.bg = bg;
                    // No per-cell hover: a lone lit cell reads as a bug; the row colours carry the state.
                    bs.hover_bg = bg;
                    bs.press_bg = bg;
                    bs.fg = pal.fg;
                    bs.h_padding = opts.pad_x;
                    bs.min_width = w;
                    bs.height = opts.row_h;
                    bs.label_align = labelAlign(col.cell_align);
                    const label = ellipsize(arena, src.cell(arena, @intCast(i), row), charsFor(w, opts));
                    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .width = w, .height = opts.row_h });
                    cb.buttonStyled(msgs.row(disp), label, bs);
                    cb.popGroup();
                }
                cb.popGroup();
            }
            cb.popVirtualList();
            cb.popScroll();
            cb.popGroup();
        }

        fn rowColor(pal: anytype, selected: bool, cursor: bool, odd: bool) [4]f32 {
            if (selected) return mix(pal.bg_panel, pal.accent, if (cursor) 0.55 else 0.35);
            if (cursor) return mix(pal.bg_panel, pal.accent, 0.18);
            return if (odd) pal.bg_raised else pal.bg_panel;
        }
    };
}

fn labelAlign(a: Align) cmd.TextAlign {
    return switch (a) {
        .left => .start,
        .center => .center,
        .right => .end,
    };
}

fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, 1 };
}

/// Characters that fit in a cell of `w` px (at least 1).
fn charsFor(w: f32, opts: anytype) usize {
    const inner = w - 2 * opts.pad_x;
    return if (inner < opts.char_w) 1 else @intFromFloat(@floor(inner / opts.char_w));
}

/// `s` cut to `max_chars` UTF-8 code points, ending in an ellipsis when it was cut.
pub fn ellipsize(arena: std.mem.Allocator, s: []const u8, max_chars: usize) []const u8 {
    if (table.columns(s) <= max_chars) return s;
    if (max_chars == 0) return "";
    const keep = table.prefixBytes(s, max_chars - 1);
    const out = arena.alloc(u8, keep + table.ELLIPSIS.len) catch return s[0..keep];
    @memcpy(out[0..keep], s[0..keep]);
    @memcpy(out[keep..], table.ELLIPSIS);
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const T = DataTable(.{ .max_rows = 256, .max_cols = 4 });

const TestRows = struct {
    vals: []const i32,
    names: []const []const u8,
    pub fn cell(self: TestRows, arena: std.mem.Allocator, col: u8, row: u32) []const u8 {
        return if (col == 0) self.names[row] else std.fmt.allocPrint(arena, "{d}", .{self.vals[row]}) catch "?";
    }
    pub fn compare(self: TestRows, col: u8, a: u32, b: u32) std.math.Order {
        return if (col == 0) std.mem.order(u8, self.names[a], self.names[b]) else std.math.order(self.vals[a], self.vals[b]);
    }
};

const vals = [_]i32{ 30, 10, 20, 10, 40 };
const names = [_][]const u8{ "e", "d", "c", "b", "a" };
const src_rows: TestRows = .{ .vals = &vals, .names = &names };

fn fresh(m: *T.Model) void {
    m.* = .{};
    m.setRows(5);
    m.view_h = 66; // three rows at 22
    m.row_h = 22;
}

test "sort: ascending, descending, off; stable on ties; selection follows the data row" {
    var m: T.Model = undefined;
    fresh(&m);
    T.update(&m, .{ .row = 4 }, src_rows); // select data row 4 (value 40)
    T.update(&m, .{ .sort = 1 }, src_rows);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 2, 0, 4 }, m.order[0..5]); // 10,10,20,30,40; ties keep data order
    try testing.expect(m.isSelected(4));
    try testing.expectEqual(@as(?u32, 4), m.cursorDisplay());
    for (0..5) |d| try testing.expectEqual(@as(u32, @intCast(d)), m.rank[m.order[d]]);
    T.update(&m, .{ .sort = 1 }, src_rows);
    try testing.expectEqualSlices(u32, &.{ 4, 0, 2, 1, 3 }, m.order[0..5]); // desc, ties still in data order
    T.update(&m, .{ .sort = 1 }, src_rows);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, m.order[0..5]);
    try testing.expectEqual(@as(?u8, null), m.sort_col);
    T.update(&m, .{ .sort = 0 }, src_rows); // by name asc: a b c d e = rows 4 3 2 1 0
    try testing.expectEqualSlices(u32, &.{ 4, 3, 2, 1, 0 }, m.order[0..5]);
}

test "selection: click, ctrl-toggle, shift-range" {
    var m: T.Model = undefined;
    fresh(&m);
    T.update(&m, .{ .row = 1 }, src_rows);
    try testing.expectEqual(@as(u32, 1), m.sel_count);
    T.update(&m, .{ .mods = .{ .ctrl = true } }, src_rows);
    T.update(&m, .{ .row = 3 }, src_rows);
    try testing.expectEqual(@as(u32, 2), m.sel_count);
    try testing.expect(m.isSelected(1) and m.isSelected(3));
    T.update(&m, .{ .row = 3 }, src_rows); // ctrl-click again deselects
    try testing.expect(!m.isSelected(3));
    T.update(&m, .{ .mods = .{ .shift = true } }, src_rows);
    T.update(&m, .{ .row = 4 }, src_rows); // anchor is row 3? ctrl-click set anchor to 3; range 3..4
    try testing.expect(m.isSelected(3) and m.isSelected(4) and !m.isSelected(1));
    T.update(&m, .{ .mods = .{} }, src_rows);
    T.update(&m, .{ .row = 0 }, src_rows);
    try testing.expectEqual(@as(u32, 1), m.sel_count);
    var out: [8]u32 = undefined;
    try testing.expectEqual(@as(usize, 1), m.selectedRows(&out));
    try testing.expectEqual(@as(u32, 0), out[0]);
}

test "keyboard: arrows, paging, home/end, shift-extend, select all, reveal" {
    var m: T.Model = undefined;
    m = .{};
    m.setRows(100);
    m.row_h = 22;
    m.view_h = 110; // 5 rows
    m.sc.setExtent(110, 2200);
    T.update(&m, .{ .key = .down }, src_rows);
    try testing.expectEqual(@as(?u32, 0), m.cursorDisplay()); // first key press lands on row 0
    T.update(&m, .{ .key = .down }, src_rows);
    T.update(&m, .{ .key = .down }, src_rows);
    try testing.expectEqual(@as(?u32, 2), m.cursorDisplay());
    T.update(&m, .{ .key = .page_down }, src_rows);
    try testing.expectEqual(@as(?u32, 7), m.cursorDisplay());
    try testing.expect(m.sc.pos + m.view_h >= 8 * 22); // revealed
    T.update(&m, .{ .key = .end }, src_rows);
    try testing.expectEqual(@as(?u32, 99), m.cursorDisplay());
    try testing.expectEqual(@as(f32, 2200 - 110), m.sc.pos);
    T.update(&m, .{ .key = .home }, src_rows);
    try testing.expectEqual(@as(f32, 0), m.sc.pos);
    T.update(&m, .{ .mods = .{ .shift = true } }, src_rows);
    T.update(&m, .{ .key = .page_down }, src_rows);
    try testing.expectEqual(@as(u32, 6), m.sel_count); // rows 0..5
    T.update(&m, .{ .mods = .{} }, src_rows);
    T.update(&m, .{ .key = .select_all }, src_rows);
    try testing.expectEqual(@as(u32, 100), m.sel_count);
    T.update(&m, .{ .key = .clear }, src_rows);
    try testing.expectEqual(@as(u32, 0), m.sel_count);
}

test "grip resizes within limits; keyMsg and gripMsg map inputs" {
    var m: T.Model = .{};
    m.setRows(1);
    T.update(&m, .{ .grip = .{ .col = 1, .dx = 30 } }, src_rows);
    try testing.expectEqual(@as(f32, 150), m.widths[1]);
    T.update(&m, .{ .grip = .{ .col = 1, .dx = -500 } }, src_rows);
    try testing.expectEqual(@as(f32, 24), m.widths[1]);
    try testing.expectEqual(T.Msg{ .key = .page_up }, T.keyMsg(.page_up, .{}).?);
    try testing.expect(T.keyMsg(.tab, .{}) == null);
    const ev = pointer.CanvasEvent{ .id = 903, .kind = .move, .dx = 4, .buttons = .{ .left = true } };
    const g = T.gripMsg(ev, 900).?;
    try testing.expectEqual(@as(u8, 3), g.grip.col);
    try testing.expect(T.gripMsg(.{ .id = 903, .kind = .move, .dx = 4 }, 900) == null); // no button held
    try testing.expect(T.gripMsg(.{ .id = 50, .kind = .move, .dx = 4, .buttons = .{ .left = true } }, 900) == null);
}

test "window: emits only the viewport plus overscan, whatever the row count" {
    var m: T.Model = .{};
    m.setRows(256);
    m.view_h = 100;
    m.sc.setExtent(100, 256 * 22);
    m.sc.jumpTo(22 * 100 + 5);
    const w = T.window(&m, .{ .id = 1, .grip_base = 900 });
    try testing.expectEqual(@as(u32, 98), w.first);
    try testing.expect(w.end - w.first <= 12);
    try testing.expect(w.end > 100);
}

test "ellipsize cuts on a code-point boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("short", ellipsize(a, "short", 8));
    try testing.expectEqualStrings("abcd\u{2026}", ellipsize(a, "abcdefghij", 5));
    try testing.expectEqualStrings("\u{3042}\u{3044}\u{2026}", ellipsize(a, "\u{3042}\u{3044}\u{3046}\u{3048}\u{304A}", 3));
}

test "view: header + only the visible rows, balanced, with sort arrow and selection colour" {
    const AppMsg = union(enum) { sort: u8, row: u32 };
    const msgs = struct {
        pub fn sort(c: u8) AppMsg {
            return .{ .sort = c };
        }
        pub fn row(d: u32) AppMsg {
            return .{ .row = d };
        }
    };
    var m: T.Model = undefined;
    fresh(&m);
    T.update(&m, .{ .sort = 1 }, src_rows);
    T.update(&m, .{ .row = 0 }, src_rows);
    var cb = cmd.CmdBuffer(AppMsg).init(testing.allocator);
    defer cb.deinit();
    const cols = [_]Column{ .{ .title = "Name", .width = 100 }, .{ .title = "Value", .width = 80, .cell_align = .right } };
    T.view(&m, &cb, &cols, src_rows, msgs, .{ .id = 7, .grip_base = 900 });
    try testing.expect(cmd.validateBalance(cb.cmds.items) == null);
    var labels: usize = 0;
    var arrow = false;
    for (cb.cmds.items) |c| switch (c) {
        .button => |b| {
            labels += 1;
            if (std.mem.indexOf(u8, b.label, "\u{25B2}") != null) arrow = true;
        },
        else => {},
    };
    try testing.expect(arrow);
    try testing.expectEqual(@as(usize, 2 + 5 * 2), labels); // 2 header buttons + 5 rows x 2 cells
}
