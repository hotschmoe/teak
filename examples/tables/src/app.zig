//! Tables at scale: a 100 000-row sortable / resizable / selectable table, a
//! variable-height list of 20 000 messages, and a 99 000-node tree, all virtualized
//! (a frame costs the same at 100 rows or 100 000) with smooth wheel scrolling.
//!
//! No row data is stored: every cell is computed from its row index, so the
//! Model holds only view state (permutation, widths, selection, scroll).

const std = @import("std");
const teak = @import("teak");

const Allocator = std.mem.Allocator;

pub const TABLE_ID: u32 = 1;
pub const GRIP_BASE: u32 = 100;
pub const LIST_ID: u32 = 2;
pub const TREE_ID: u32 = 3;

pub const table_rows: usize = 100_000;
pub const list_rows: usize = 20_000;
pub const tree_nodes: usize = 99_450;

pub const Table = teak.DataTable(.{ .max_rows = 131_072, .max_cols = 8 });
pub const List = teak.VarList(32_768);
pub const Tree = teak.TreeList(131_072);

pub const Tab = enum { table, list, tree };

pub const columns = [_]teak.DataTableColumn{
    .{ .title = "ID", .width = 80, .cell_align = .right },
    .{ .title = "Name", .width = 200 },
    .{ .title = "Category", .width = 140 },
    .{ .title = "Qty", .width = 80, .cell_align = .right },
    .{ .title = "Price", .width = 110, .cell_align = .right },
    .{ .title = "Updated", .width = 130 },
};

pub const Msg = union(enum) {
    tab: Tab,
    table: Table.Msg,
    list: List.Msg,
    tree: Tree.Msg,
    prepend,
    append,
};

pub const Model = struct {
    tab: Tab = .table,
    // The big arrays live on the heap: the Runtime holding this Model sits on a
    // (Windows: 1 MB) stack.
    table: *Table.Model,
    list: *List.Model,
    tree: *Tree.Model,
    list_added: u32 = 0,

    pub fn init() Model {
        const a = std.heap.page_allocator;
        var m: Model = .{
            .table = a.create(Table.Model) catch @panic("oom"),
            .list = a.create(List.Model) catch @panic("oom"),
            .tree = a.create(Tree.Model) catch @panic("oom"),
        };
        m.table.* = .{};
        m.table.setColumns(&columns);
        m.table.setRows(table_rows);
        m.list.* = .{};
        m.list.setCount(list_rows, 40);
        m.tree.* = .{};
        m.tree.setNodes(tree_nodes, TreeSrc{}, 1);
        return m;
    }
};

// ── Data, computed from the row index ───────────────────────────────

fn mixHash(x: u32) u32 {
    var h = x *% 0x9E3779B1;
    h ^= h >> 15;
    h *%= 0x85EBCA77;
    h ^= h >> 13;
    h *%= 0xC2B2AE3D;
    h ^= h >> 16;
    return h;
}

const words = [_][]const u8{ "anchor", "bracket", "coupler", "damper", "flange", "gasket", "hinge", "insert", "joint", "knuckle", "latch", "mount", "nipple", "orifice", "pin", "quill" };
const cats = [_][]const u8{ "Fasteners", "Structural", "Electrical", "Hydraulic", "Pneumatic", "Optical", "Thermal", "Packaging" };

const Rows = struct {
    fn qty(row: u32) u32 {
        return (mixHash(row) >> 16) % 1000;
    }
    fn cents(row: u32) u32 {
        return (mixHash(row +% 77) >> 8) % 1_000_000;
    }
    fn word(row: u32) u32 {
        return mixHash(row +% 3) % @as(u32, words.len);
    }
    fn serial(row: u32) u32 {
        return (mixHash(row +% 5) >> 8) % 10_000;
    }
    fn cat(row: u32) u32 {
        return (mixHash(row +% 9) >> 4) % @as(u32, cats.len);
    }
    fn month(row: u32) u32 {
        return 1 + (mixHash(row +% 11) % 12);
    }
    fn day(row: u32) u32 {
        return 1 + ((mixHash(row +% 13) >> 8) % 28);
    }

    pub fn cell(_: Rows, arena: Allocator, col: u8, row: u32) []const u8 {
        return switch (col) {
            0 => std.fmt.allocPrint(arena, "{d}", .{row + 1}) catch "?",
            1 => std.fmt.allocPrint(arena, "{s}-{d:0>4}", .{ words[word(row)], serial(row) }) catch "?",
            2 => cats[cat(row)],
            3 => std.fmt.allocPrint(arena, "{d}", .{qty(row)}) catch "?",
            4 => std.fmt.allocPrint(arena, "{d}.{d:0>2}", .{ cents(row) / 100, cents(row) % 100 }) catch "?",
            else => std.fmt.allocPrint(arena, "2026-{d:0>2}-{d:0>2}", .{ month(row), day(row) }) catch "?",
        };
    }

    pub fn compare(_: Rows, col: u8, a: u32, b: u32) std.math.Order {
        return switch (col) {
            0 => std.math.order(a, b),
            1 => blk: {
                const w = std.mem.order(u8, words[word(a)], words[word(b)]);
                break :blk if (w != .eq) w else std.math.order(serial(a), serial(b));
            },
            2 => std.mem.order(u8, cats[cat(a)], cats[cat(b)]),
            3 => std.math.order(qty(a), qty(b)),
            4 => std.math.order(cents(a), cents(b)),
            else => blk: {
                const m = std.math.order(month(a), month(b));
                break :blk if (m != .eq) m else std.math.order(day(a), day(b));
            },
        };
    }
};

/// A synthetic source tree in preorder: 450 roots x (1 + 20 dirs x (1 + 10 files)).
const TreeSrc = struct {
    const per_root = 221;
    pub fn depth(_: TreeSrc, node: u32) u16 {
        const r = node % per_root;
        if (r == 0) return 0;
        return if ((r - 1) % 11 == 0) 1 else 2;
    }
    pub fn label(_: TreeSrc, arena: Allocator, node: u32) []const u8 {
        const r = node % per_root;
        const root = node / per_root;
        if (r == 0) return std.fmt.allocPrint(arena, "pkg-{d:0>3}/", .{root}) catch "?";
        const dir = (r - 1) / 11;
        const k = (r - 1) % 11;
        if (k == 0) return std.fmt.allocPrint(arena, "{s}_{d}/", .{ words[(root + dir) % words.len], dir }) catch "?";
        return std.fmt.allocPrint(arena, "{s}_{d}.zig", .{ words[(root * 7 + dir * 3 + k) % words.len], k }) catch "?";
    }
};

/// Chat-like rows of 1..6 lines.
fn lineCount(i: u32) u32 {
    return 1 + (mixHash(i +% 0x51) >> 12) % 6;
}

const ListSrc = struct {
    pub fn row(_: ListSrc, cb: anytype, i: u32) void {
        const pal = cb.theme.palette;
        const lines = lineCount(i);
        cb.pushGroup(.{ .direction = .vertical, .padding = 6, .gap = 2, .bg = if (i % 2 == 0) pal.bg_panel else pal.bg_raised });
        cb.textStyled(std.fmt.allocPrint(cb.arena.allocator(), "message #{d}  ({d} line{s})", .{ i, lines, if (lines == 1) "" else "s" }) catch "?", .{ .size_px = 13, .family = .mono }, pal.fg_muted);
        var l: u32 = 1;
        while (l < lines) : (l += 1) {
            cb.textStyled(std.fmt.allocPrint(cb.arena.allocator(), "{s} {s} {s}", .{ words[(i + l) % words.len], words[(i * 3 + l) % words.len], cats[(i + l * 5) % cats.len] }) catch "?", .{ .size_px = 13, .family = .mono }, pal.fg);
        }
        cb.popGroup();
    }
};

// ── Update ──────────────────────────────────────────────────────────

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .tab => |t| m.tab = t,
        .table => |t| Table.update(m.table, t, Rows{}),
        .list => |l| List.update(m.list, l),
        .tree => |t| Tree.update(m.tree, t, TreeSrc{}),
        .prepend => {
            m.list.insert(0, 0);
            m.list_added += 1;
        },
        .append => {
            m.list.insert(m.list.n, 0);
            m.list_added += 1;
        },
    }
}

// ── Hooks ───────────────────────────────────────────────────────────

/// The one pointer hook: scroll-region wheels and the column-grip canvases.
pub fn pointerMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (ev.asScroll()) |s| return onScroll(m, s.id, s.dx, s.dy);
    if (ev.asCanvas()) |c| return onCanvas(m, c);
    return null;
}

fn onScroll(_: *const Model, id: u32, _: f32, dy: f32) ?Msg {
    return switch (id) {
        TABLE_ID => .{ .table = .{ .wheel = dy } },
        LIST_ID => .{ .list = .{ .wheel = dy } },
        TREE_ID => .{ .tree = .{ .wheel = dy } },
        else => null,
    };
}

pub fn scrollLayoutMsg(_: *const Model, id: u32, vw: f32, vh: f32, cw: f32, ch: f32) ?Msg {
    return switch (id) {
        TABLE_ID => .{ .table = .{ .viewport = .{ .vw = vw, .vh = vh, .cw = cw, .ch = ch } } },
        LIST_ID => .{ .list = .{ .viewport = .{ .vw = vw, .vh = vh, .cw = cw, .ch = ch } } },
        TREE_ID => .{ .tree = .{ .viewport = .{ .vw = vw, .vh = vh, .cw = cw, .ch = ch } } },
        else => null,
    };
}

pub fn virtualRowsMsg(_: *const Model, id: u32, first: u32, heights: []const f32) ?Msg {
    if (id != LIST_ID) return null;
    return .{ .list = List.measuredMsg(first, heights) };
}

fn onCanvas(_: *const Model, ev: teak.CanvasEvent) ?Msg {
    const g = Table.gripMsg(ev, GRIP_BASE) orelse return null;
    return .{ .table = g };
}

pub fn modsMsg(_: *const Model, mods: teak.Modifiers) ?Msg {
    return .{ .table = .{ .mods = mods } };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    return switch (m.tab) {
        .table => if (Table.keyMsg(key, m.table.mods)) |k| .{ .table = k } else null,
        .tree => if (Tree.keyMsg(key)) |k| .{ .tree = k } else null,
        .list => null,
    };
}

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    if (m.tab != .table or !m.table.focused) return null;
    return if (Table.charMsg(c)) |k| .{ .table = k } else null;
}

pub fn animationMsg(_: *const Model, dt_ms: u32) ?Msg {
    // One frame time feeds whichever scroller is moving; the others ignore a step at rest.
    return .{ .table = .{ .frame = dt_ms } };
}

const anim_subs = [_]teak.Sub(Msg){.animation_frame};

pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    return if (m.table.animating() or m.list.animating() or m.tree.animating()) &anim_subs else &.{};
}

pub fn themeFor(_: *const Model) teak.Theme {
    return teak.Theme.dark_default;
}

// ── View ────────────────────────────────────────────────────────────

const msgs = struct {
    pub fn sort(col: u8) Msg {
        return .{ .table = .{ .sort = col } };
    }
    pub fn row(display: u32) Msg {
        return .{ .table = .{ .row = display } };
    }
};

const tree_msgs = struct {
    pub fn toggle(node: u32) Msg {
        return .{ .tree = .{ .toggle = node } };
    }
    pub fn select(node: u32) Msg {
        return .{ .tree = .{ .select = node } };
    }
};

fn tabButton(cb: anytype, m: *const Model, tab: Tab, label: []const u8) void {
    // The active tab is the primary button: its label colour is picked for contrast on the accent.
    var s = if (m.tab == tab) cb.theme.button_primary else cb.theme.button;
    s.min_width = 90;
    s.height = 30;
    cb.buttonStyled(.{ .tab = tab }, label, s);
}

pub fn view(m: *const Model, cb: anytype) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .vertical, .padding = 12, .gap = 8, .align_cross = .stretch });

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .align_cross = .center });
    tabButton(cb, m, .table, "Table");
    tabButton(cb, m, .list, "List");
    tabButton(cb, m, .tree, "Tree");
    const status = switch (m.tab) {
        .table => std.fmt.allocPrint(cb.arena.allocator(), "{d} rows, {d} selected{s}{s}", .{
            m.table.n_rows,
            m.table.sel_count,
            if (m.table.sort_col) |c| std.fmt.allocPrint(cb.arena.allocator(), ", sorted by {s} {s}", .{ columns[c].title, if (m.table.sort_desc) "desc" else "asc" }) catch "" else "",
            if (m.table.search_len > 0) std.fmt.allocPrint(cb.arena.allocator(), ", find \"{s}\"", .{Table.searchText(m.table)}) catch "" else "",
        }) catch "",
        .list => std.fmt.allocPrint(cb.arena.allocator(), "{d} messages of 1-6 lines, {d:.0} px tall", .{ m.list.n, m.list.total() }) catch "",
        .tree => std.fmt.allocPrint(cb.arena.allocator(), "{d} nodes, {d} visible", .{ m.tree.n_nodes, m.tree.n_visible }) catch "",
    };
    cb.textStyled(status, .{ .size_px = 13, .family = .mono }, pal.fg_muted);
    cb.popGroup();

    switch (m.tab) {
        .table => Table.view(m.table, cb, &columns, Rows{}, msgs, .{ .id = TABLE_ID, .grip_base = GRIP_BASE }),
        .list => {
            cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8 });
            cb.button(.prepend, "Prepend");
            cb.button(.append, "Append");
            cb.popGroup();
            List.view(m.list, cb, ListSrc{}, .{ .id = LIST_ID });
        },
        .tree => Tree.view(m.tree, cb, TreeSrc{}, tree_msgs, .{ .id = TREE_ID }),
    }
    cb.popGroup();
}

// ── Tests ───────────────────────────────────────────────────────────

test "the table sorts 100k rows by every column, and each sort is a permutation in order" {
    const a = std.heap.page_allocator;
    const m = try a.create(Table.Model);
    defer a.destroy(m);
    m.* = .{};
    m.setRows(table_rows);
    for (0..columns.len) |c| {
        // Reset to identity, then sort ascending by column c.
        m.sort_col = null;
        Table.update(m, .{ .sort = @intCast(c) }, Rows{});
        var i: u32 = 1;
        while (i < m.n_rows) : (i += 1) {
            try std.testing.expect(Rows.compare(.{}, @intCast(c), m.order[i - 1], m.order[i]) != .gt);
        }
        // Inverse is exact.
        try std.testing.expectEqual(@as(u32, 0), m.rank[m.order[0]]);
        try std.testing.expectEqual(@as(u32, m.n_rows - 1), m.rank[m.order[m.n_rows - 1]]);
        Table.update(m, .{ .sort = @intCast(c) }, Rows{}); // desc
        Table.update(m, .{ .sort = @intCast(c) }, Rows{}); // off
    }
}

test "the tree source has the preorder shape the TreeList expects" {
    const t = TreeSrc{};
    try std.testing.expectEqual(@as(u16, 0), t.depth(0));
    try std.testing.expectEqual(@as(u16, 1), t.depth(1));
    try std.testing.expectEqual(@as(u16, 2), t.depth(2));
    try std.testing.expectEqual(@as(u16, 1), t.depth(12));
    try std.testing.expectEqual(@as(u16, 0), t.depth(221));
}

test "the view builds and balances on every tab" {
    var m = Model.init();
    inline for (.{ Tab.table, Tab.list, Tab.tree }) |tab| {
        m.tab = tab;
        var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
        defer cb.deinit();
        view(&m, &cb);
        try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
        try std.testing.expect(cb.cmds.items.len < 2000); // virtualized: nothing near 100k
    }
}
