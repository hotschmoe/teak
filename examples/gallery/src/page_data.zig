//! Page 3: data display - Table, tree, virtual list (10,000 rows), chart.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;
const Msg = model.Msg;

pub const list_id: u32 = 7;
pub const note_id: u32 = 8;

const Part = struct { name: []const u8, qty: u32, len_mm: f32 };
const parts = [_]Part{
    .{ .name = "BRACKET-L-100", .qty = 4, .len_mm = 100.0 },
    .{ .name = "BASE-PLATE", .qty = 1, .len_mm = 240.5 },
    .{ .name = "SPACER-M6", .qty = 12, .len_mm = 8.0 },
    .{ .name = "GUSSET-45-DEG", .qty = 2, .len_mm = 64.25 },
    .{ .name = "BOLT-M6X20", .qty = 24, .len_mm = 20.0 },
    .{ .name = "WASHER-M6", .qty = 48, .len_mm = 1.6 },
};

const parts_table: teak.Table = .{
    .columns = &.{
        .{ .title = "PART", .chars = 15 },
        .{ .title = "QTY", .chars = 3, .cell_align = .right },
        .{ .title = "LEN MM", .chars = 7, .cell_align = .right },
    },
};

const Node = struct { name: []const u8, depth: u8, folder: bool };
/// Pre-order; a node shows iff every ancestor is expanded (`Model.tree_open`).
const nodes = [model.tree_len]Node{
    .{ .name = "src", .depth = 0, .folder = true },
    .{ .name = "core", .depth = 1, .folder = true },
    .{ .name = "cmd.zig", .depth = 2, .folder = false },
    .{ .name = "theme.zig", .depth = 2, .folder = false },
    .{ .name = "layout", .depth = 1, .folder = true },
    .{ .name = "engine.zig", .depth = 2, .folder = false },
    .{ .name = "input", .depth = 1, .folder = true },
    .{ .name = "hit_test.zig", .depth = 2, .folder = false },
    .{ .name = "examples", .depth = 0, .folder = true },
    .{ .name = "gallery", .depth = 1, .folder = true },
    .{ .name = "app.zig", .depth = 2, .folder = false },
    .{ .name = "todo", .depth = 1, .folder = false },
    .{ .name = "docs", .depth = 0, .folder = true },
    .{ .name = "HARDLINE.md", .depth = 1, .folder = false },
};

pub fn view(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    // Column 1: table + tree.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 360, .align_cross = .stretch });
    ui.card(cb, "Table (fixed-column monospace)", 0, 0);
    cb.pushGroup(.{ .padding = 1, .gap = 0, .border = pal.border, .align_cross = .stretch });
    // The header must use the row font's size (bold is fine: monospace advances match),
    // or its columns drift away from the cells below.
    var head_font = cb.theme.typography.mono;
    head_font.weight = .bold;
    parts_table.header(cb, .{ .font = head_font, .color = pal.bg, .bg = pal.fg });
    for (parts, 0..) |p, i| {
        const qty = ui.fmt(cb, "{d}", .{p.qty});
        const len = ui.fmt(cb, "{d:.2}", .{p.len_mm});
        const picked = m.row_sel == i;
        parts_table.row(cb, &.{ p.name, qty, len }, .{
            .font = cb.theme.typography.mono,
            .color = if (picked) pal.bg else pal.fg,
            .bg = if (picked) pal.fg else null,
            .rule = pal.border,
        });
    }
    cb.popGroup();
    ui.row(cb);
    const n: u8 = parts.len;
    cb.button(.{ .row_pick = if (m.row_sel == 0) n - 1 else m.row_sel - 1 }, "< Prev");
    cb.button(.{ .row_pick = if (m.row_sel + 1 >= n) 0 else m.row_sel + 1 }, "Next >");
    ui.endRow(cb);
    ui.endCard(cb);

    ui.card(cb, "Tree", 0, 0);
    tree(m, cb);
    ui.endCard(cb);
    cb.popGroup();

    // Column 2: virtual list.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 300, .align_cross = .stretch });
    ui.card(cb, "Virtual list (10,000 rows)", 0, 0);
    virtualList(m, cb);
    cb.textMuted(ui.fmt(cb, "top row {d}  scroll {d:.0}px", .{ @as(u32, @intFromFloat(m.list_scroll / model.list_row_h)) + 1, m.list_scroll }));
    ui.endCard(cb);
    cb.popGroup();

    // Column 3: chart.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 380, .align_cross = .stretch });
    ui.card(cb, "Line chart (canvas)", 0, 0);
    const prims = teak.chart.lineChartPrimitives(cb.arena.allocator(), &m.series, .{
        .width = 340,
        .height = 150,
        .min = 0,
        .max = 1,
        .line_color = pal.accent,
        .grid_color = pal.fg_muted,
        .line_thickness = 2,
    });
    cb.canvasLabeled(.{ .width = 340, .height = 150, .bg = pal.bg_sunken }, prims, "line chart");
    ui.row(cb);
    cb.button(.chart_run, if (m.chart_on) "Live: on" else "Live: off");
    cb.textMuted(ui.fmt(cb, "{d} samples", .{model.series_len + m.chart_t}));
    ui.endRow(cb);
    ui.endCard(cb);

    ui.card(cb, "Scroll region", 0, 0);
    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 2, .height = 120, .scroll_y = m.note_scroll, .id = note_id, .align_cross = .stretch });
    for (notes) |line| cb.text(line);
    cb.popScroll();
    cb.textMuted(ui.fmt(cb, "wheel to scroll: {d:.0} / {d:.0}", .{ m.note_scroll, @max(0, m.note_content - m.note_viewport) }));
    ui.endCard(cb);
    cb.popGroup();

    cb.popGroup();
}

const notes = [_][]const u8{
    "A ScrollStyle with an id gets the",
    "wheel through scrollMsg; its size",
    "comes back through scrollLayoutMsg.",
    "The offset lives in the Model:",
    "no hidden widget state.",
    "A virtual list adds windowing: only",
    "the visible rows are emitted, so",
    "ten thousand rows cost the same",
    "as ten. Clipping is applied by",
    "layout, hit-test and render alike.",
};

fn tree(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    var hide_below: ?u8 = null; // depth of the collapsed ancestor we are inside
    // The tree is one Tab stop (its first row); arrows move the keyboard focus between rows,
    // Enter / Space toggle a folder.
    var first_row = true;
    for (nodes, 0..) |node, i| {
        if (hide_below) |d| {
            if (node.depth > d) continue;
            hide_below = null;
        }
        var st = cb.theme.button;
        st.label_align = .start;
        st.border = null;
        st.bg = .{ 0, 0, 0, 0 };
        st.height = 22;
        st.h_padding = 4;
        const open = m.tree_open[i];
        const indent = "      ";
        const lead = indent[0 .. @as(usize, node.depth) * 2];
        const mark: []const u8 = if (!node.folder) "  " else if (open) "v " else "> ";
        const label = ui.fmt(cb, "{s}{s}{s}", .{ lead, mark, node.name });
        if (node.folder) {
            cb.buttonNav(.{ .tree_toggle = @intCast(i) }, label, st, .{ .tab_stop = first_row, .roving = .focus });
            if (!open) hide_below = node.depth;
        } else {
            st.fg = pal.fg_muted;
            cb.buttonNav(.noop, label, st, .{ .tab_stop = first_row, .roving = .focus });
        }
        first_row = false;
    }
}

fn virtualList(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    const rows = model.list_rows;
    const first: u32 = @min(rows, @as(u32, @intFromFloat(@floor(m.list_scroll / model.list_row_h))));
    const visible: u32 = @as(u32, @intFromFloat(@ceil(model.list_h / model.list_row_h))) + 1;
    const last = @min(rows, first + visible);

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4 });
    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 0, .width = 250, .height = model.list_h, .scroll_y = m.list_scroll, .id = list_id });
    cb.pushVirtualList(.{ .direction = .vertical, .total_count = rows, .item_extent = model.list_row_h, .visible_start = first, .visible_end = last, .padding = 0, .gap = 0 });
    var i = first;
    while (i < last) : (i += 1) {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .pad_x = 6, .gap = 0, .height = model.list_row_h, .width = 250, .align_cross = .center, .bg = if (i % 2 == 1) pal.bg else null });
        cb.text(ui.fmt(cb, "Row {d:0>5}", .{i + 1}));
        cb.spacer(1);
        cb.textMuted(ui.fmt(cb, "{d}", .{(i *% 2654435761) % 1000}));
        cb.popGroup();
    }
    cb.popVirtualList();
    cb.popScroll();
    cb.canvas(.{ .width = 8, .height = model.list_h, .bg = pal.bg_sunken }, scrollbarThumb(cb, m));
    cb.popGroup();
}

fn scrollbarThumb(cb: anytype, m: *const Model) []const teak.CanvasPrimitive {
    if (m.list_content <= m.list_viewport or m.list_content <= 0) return &.{};
    const track = model.list_h;
    const thumb_h = @max(16, track * m.list_viewport / m.list_content);
    const range = m.list_content - m.list_viewport;
    const thumb_y = (track - thumb_h) * (m.list_scroll / range);
    const prims = cb.arena.allocator().alloc(teak.CanvasPrimitive, 1) catch return &.{};
    prims[0] = .{ .filled_rect = .{ .x = 0, .y = thumb_y, .w = 8, .h = thumb_h, .color = cb.theme.palette.fg } };
    return prims;
}
