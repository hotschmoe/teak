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
//! Cell text that does not fit its column is cut with an ellipsis at the pixel
//! (`ButtonStyle.ellipsis`, any font); header cells are cut the same way.
//!
//! Type-to-search: printable keys (`charMsg`) select the first row whose cell in the
//! sort column (column 0 when unsorted) starts with what was typed, case-insensitively;
//! any navigation, click, sort or Escape starts a new search.

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
            /// Type-to-search buffer (ASCII).
            search: [24]u8 = undefined,
            search_len: u8 = 0,
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

            /// Re-apply the current sort (`sort_col` / `sort_desc` unchanged)
            /// after the row DATA changed but the row count did not, e.g. a
            /// re-solve. Selection and cursor are keyed by data row, so they
            /// stay on the same rows; the scroll position is kept. Cost: one
            /// stable sort, so call it once per data change, not per frame.
            /// No-op when unsorted. Same as `update(m, .resort, src)`.
            pub fn resort(self: *Model, src: anytype) void {
                applySort(self, src);
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
            /// A typed character (type-to-search); see `charMsg`.
            char: u8,
            /// Click outside / Escape-like: drop keyboard focus.
            blur,
            /// Re-apply the current sort after the row data changed (see `Model.resort`).
            resort,
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
                .char => |ch| typeAhead(m, ch, src),
                .blur => {
                    m.focused = false;
                    m.search_len = 0;
                },
                .resort => applySort(m, src),
            }
        }

        /// The text typed so far for type-to-search.
        pub fn searchText(m: *const Model) []const u8 {
            return m.search[0..m.search_len];
        }

        fn typeAhead(m: *Model, ch: u8, src: anytype) void {
            if (m.n_rows == 0 or ch < 0x20 or ch == 0x7f) return;
            if (m.search_len >= m.search.len) return;
            m.search[m.search_len] = ch;
            m.search_len += 1;
            const col: u8 = m.sort_col orelse 0;
            const n = m.n_rows;
            // A new search starts after the cursor; extending a prefix may stay on the current row.
            const here: u32 = m.cursorDisplay() orelse 0;
            const begin: u32 = if (m.search_len == 1 and m.has_cursor) (here + 1) % n else here;
            var buf: [256]u8 = undefined;
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const disp = (begin + k) % n;
                const row = m.order[disp];
                var fba = std.heap.FixedBufferAllocator.init(&buf);
                const cell = src.cell(fba.allocator(), col, row);
                if (startsWithFold(cell, m.search[0..m.search_len])) {
                    m.clearSelection();
                    m.setBit(row, true);
                    m.cursor = row;
                    m.anchor = row;
                    m.has_cursor = true;
                    m.focused = true;
                    reveal(m, disp);
                    return;
                }
            }
        }

        const min_grip_width: f32 = 24;

        fn sortBy(m: *Model, col: u8, src: anytype) void {
            m.search_len = 0;
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
            applySort(m, src);
            if (m.cursorDisplay()) |d| reveal(m, d);
        }

        /// Rebuild `order` / `rank` for the current `sort_col` / `sort_desc`.
        fn applySort(m: *Model, src: anytype) void {
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
        }

        fn clickRow(m: *Model, disp: u32) void {
            if (disp >= m.n_rows) return;
            m.search_len = 0;
            m.focused = true;
            const row = m.order[disp];
            if (m.mods.shift and m.has_cursor) {
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
            m.search_len = 0;
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

        /// Map a typed character to a search message (printable ASCII only). The app calls it from
        /// `keyCharMsg` when `model.table.focused`.
        pub fn charMsg(c: u8) ?Msg {
            return if (c >= 0x20 and c < 0x7f) .{ .char = c } else null;
        }

        /// Map a header-grip canvas event to `.grip` (the canvas id is `grip_base + col`).
        pub fn gripMsg(ev: pointer.CanvasEvent, grip_base: u32) ?Msg {
            if (ev.id < grip_base or ev.id >= grip_base + max_cols) return null;
            if (ev.kind != .move or !ev.buttons.left or ev.dx == 0) return null;
            return .{ .grip = .{ .col = @intCast(ev.id - grip_base), .dx = ev.dx } };
        }


        pub const ViewOpts = struct {
            /// `ScrollStyle.id` of the body (wheel + layout reports). Non-zero.
            id: u32,
            /// Header-grip canvas ids are `grip_base + col`.
            grip_base: u32,
            row_h: f32 = 22,
            header_h: f32 = 26,
            font: text_mod.FontSpec = .{ .size_px = 13, .family = .mono },
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

            cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .height = opts.header_h, .bg = pal.bg_raised });
            for (cols, 0..) |col, i| {
                const w = m.widths[i];
                cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .width = w, .height = opts.header_h });
                var title = col.title;
                if (m.sort_col != null and m.sort_col.? == i) {
                    title = std.fmt.allocPrint(arena, "{s} {s}", .{ col.title, if (m.sort_desc) "\u{25BC}" else "\u{25B2}" }) catch col.title;
                }
                var hs = cb.theme.button;
                hs.bg = pal.bg_raised;
                hs.hover_bg = pal.bg_hover;
                hs.fg = pal.fg_muted;
                hs.h_padding = opts.pad_x;
                hs.min_width = @max(0, w - grip_w);
                hs.height = opts.header_h;
                hs.label_align = labelAlign(col.cell_align);
                hs.ellipsis = true;
                if (col.sortable) {
                    cb.buttonStyled(msgs.sort(@intCast(i)), title, hs);
                } else {
                    cb.textStyled(title, opts.font, pal.fg_muted);
                }
                const prims = arena.alloc(cmd.CanvasPrimitive, 1) catch return;
                prims[0] = .{ .vline = .{ .x = grip_w / 2, .color = pal.border, .thickness = 1 } };
                cb.canvasInteractive(.{ .width = grip_w, .height = opts.header_h }, prims, opts.grip_base + @as(u32, @intCast(i)), "resize column");
                cb.popGroup();
            }
            cb.popGroup();
            cb.dividerStyled(.{ .thickness = 1, .color = pal.border });

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
            var stop_disp = win.first;
            if (m.has_cursor) {
                var d = win.first;
                while (d < win.end) : (d += 1) if (m.order[d] == m.cursor) {
                    stop_disp = d;
                    break;
                };
            }
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
                    bs.hover_bg = bg;
                    bs.press_bg = bg;
                    bs.fg = pal.fg;
                    bs.h_padding = opts.pad_x;
                    bs.min_width = w;
                    bs.height = opts.row_h;
                    bs.label_align = labelAlign(col.cell_align);
                    bs.ellipsis = true; // cut at the pixel with U+2026 by the renderer
                    const label = src.cell(arena, @intCast(i), row);
                    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .width = w, .height = opts.row_h });
                    cb.buttonNav(msgs.row(disp), label, bs, .{ .tab_stop = disp == stop_disp and i == 0 });
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

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, s[0..prefix.len]) |p, c| if (std.ascii.toLower(p) != std.ascii.toLower(c)) return false;
    return true;
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








