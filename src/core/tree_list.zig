//! `TreeList`: a virtualized tree view over a very large node set.
//!
//! The app's nodes are laid out in depth-first *preorder* with a depth per node
//! (a file listing sorted by path, an outline, a scene graph dump). With that, a
//! node has children iff the next node is deeper, and a subtree is the run of
//! deeper nodes after it, so the whole tree needs no pointers:
//!
//!     fn depth(src, node: u32) u16
//!     fn label(src, arena: Allocator, node: u32) []const u8
//!
//! The Model keeps the expanded set (a bitset) and the flattened list of visible
//! nodes (`visible[row] = node`, ascending). The list is rebuilt in `update` when a
//! node is toggled (one O(n) scan that skips collapsed subtrees), never in
//! `view`; `view` emits only the rows in the window, from a fixed-extent virtual
//! list, so a frame costs the same for 100 or 100 000 visible rows.
//!
//! Keyboard (`keyMsg`): Up/Down move, Left collapses or goes to the parent, Right
//! expands or goes to the first child, Home/End, PageUp/PageDown, Enter toggles.

const std = @import("std");
const cmd = @import("cmd.zig");
const scroller = @import("scroller.zig");
const keys = @import("../input/keys.zig");
const text_mod = @import("text.zig");

pub const Key = enum { up, down, left, right, home, end, page_up, page_down, toggle };

pub fn TreeList(comptime cap: usize) type {
    return struct {
        const Self = @This();
        pub const capacity = cap;
        const words = (cap + 63) / 64;

        pub const Model = struct {
            n_nodes: u32 = 0,
            expanded: [words]u64 = @splat(0),
            /// Visible nodes in display order (ascending node ids).
            visible: [cap]u32 = undefined,
            n_visible: u32 = 0,
            selected: ?u32 = null,
            focused: bool = false,
            sc: scroller.Scroller = .{},
            view_h: f32 = 0,
            row_h: f32 = 22,

            /// Replace the tree: `n` nodes, everything collapsed except `expand_depth` levels.
            pub fn setNodes(self: *Model, n: usize, src: anytype, expand_depth: u16) void {
                self.n_nodes = @intCast(@min(n, cap));
                @memset(&self.expanded, 0);
                if (expand_depth > 0) {
                    for (0..self.n_nodes) |i| {
                        if (hasChildren(self, src, @intCast(i)) and src.depth(@intCast(i)) < expand_depth)
                            self.setExpanded(@intCast(i), true);
                    }
                }
                self.selected = null;
                self.sc = .{};
                self.rebuild(src);
            }

            pub fn isExpanded(self: *const Model, node: u32) bool {
                return (self.expanded[node >> 6] >> @intCast(node & 63)) & 1 != 0;
            }

            fn setExpanded(self: *Model, node: u32, on: bool) void {
                const bit = @as(u64, 1) << @intCast(node & 63);
                if (on) self.expanded[node >> 6] |= bit else self.expanded[node >> 6] &= ~bit;
            }

            /// Recompute `visible` (skipping the subtrees of collapsed nodes).
            pub fn rebuild(self: *Model, src: anytype) void {
                var n: u32 = 0;
                var i: u32 = 0;
                while (i < self.n_nodes) {
                    self.visible[n] = i;
                    n += 1;
                    if (hasChildren(self, src, i) and !self.isExpanded(i)) {
                        const d = src.depth(i);
                        i += 1;
                        while (i < self.n_nodes and src.depth(i) > d) i += 1;
                    } else i += 1;
                }
                self.n_visible = n;
                self.sc.setExtent(self.view_h, @as(f32, @floatFromInt(n)) * self.row_h);
            }

            /// Row (display index) of a visible node, if it is visible.
            pub fn rowOf(self: *const Model, node: u32) ?u32 {
                const v = self.visible[0..self.n_visible];
                const i = std.sort.lowerBound(u32, v, node, struct {
                    fn order(ctx: u32, item: u32) std.math.Order {
                        return std.math.order(ctx, item);
                    }
                }.order);
                return if (i < v.len and v[i] == node) @intCast(i) else null;
            }

            pub fn animating(self: *const Model) bool {
                return self.sc.animating();
            }
        };

        fn hasChildren(m: *const Model, src: anytype, node: u32) bool {
            return node + 1 < m.n_nodes and src.depth(node + 1) > src.depth(node);
        }

        pub const Msg = union(enum) {
            /// Chevron click.
            toggle: u32,
            /// Label click.
            select: u32,
            key: Key,
            wheel: f32,
            viewport: struct { vw: f32, vh: f32, cw: f32, ch: f32 },
            frame: u32,
            blur,
        };

        pub fn update(m: *Model, msg: Msg, src: anytype) void {
            switch (msg) {
                .toggle => |node| {
                    if (node >= m.n_nodes or !hasChildren(m, src, node)) return;
                    m.setExpanded(node, !m.isExpanded(node));
                    // A collapsed ancestor may now hide the selection: move it up.
                    if (m.selected) |s| if (m.rowOf(s) == null) {
                        // handled after rebuild below
                    };
                    m.rebuild(src);
                    if (m.selected) |s| if (m.rowOf(s) == null) {
                        m.selected = node;
                    };
                },
                .select => |node| {
                    if (node >= m.n_nodes) return;
                    m.selected = node;
                    m.focused = true;
                },
                .key => |k| keyCommand(m, src, k),
                .wheel => |dy| m.sc.wheel(dy),
                .viewport => |v| {
                    m.view_h = v.vh;
                    m.sc.setExtent(v.vh, @as(f32, @floatFromInt(m.n_visible)) * m.row_h);
                },
                .frame => |dt| m.sc.step(dt),
                .blur => m.focused = false,
            }
        }

        fn pageRows(m: *const Model) u32 {
            return @intFromFloat(@max(1, @floor(m.view_h / m.row_h)));
        }

        fn keyCommand(m: *Model, src: anytype, k: Key) void {
            if (m.n_visible == 0) return;
            const last = m.n_visible - 1;
            const cur_row: u32 = if (m.selected) |s| m.rowOf(s) orelse 0 else 0;
            const cur_node = m.visible[cur_row];
            var target: u32 = cur_row;
            switch (k) {
                .up => target = if (m.selected == null) 0 else cur_row -| 1,
                .down => target = if (m.selected == null) 0 else @min(cur_row + 1, last),
                .page_up => target = cur_row -| pageRows(m),
                .page_down => target = @min(cur_row + pageRows(m), last),
                .home => target = 0,
                .end => target = last,
                .toggle => {
                    if (m.selected != null) update(m, .{ .toggle = cur_node }, src);
                    return;
                },
                .left => {
                    if (m.selected == null) return;
                    if (hasChildren(m, src, cur_node) and m.isExpanded(cur_node)) {
                        update(m, .{ .toggle = cur_node }, src);
                        return;
                    }
                    // To the parent: the nearest visible row above with a smaller depth.
                    const d = src.depth(cur_node);
                    var r = cur_row;
                    while (r > 0) {
                        r -= 1;
                        if (src.depth(m.visible[r]) < d) break;
                    }
                    if (src.depth(m.visible[r]) >= d) return; // a root: nowhere to go
                    target = r;
                },
                .right => {
                    if (m.selected == null) return;
                    if (!hasChildren(m, src, cur_node)) return;
                    if (!m.isExpanded(cur_node)) {
                        update(m, .{ .toggle = cur_node }, src);
                        return;
                    }
                    target = @min(cur_row + 1, last); // the first child follows its parent
                },
            }
            m.selected = m.visible[target];
            m.focused = true;
            reveal(m, target);
        }

        pub fn reveal(m: *Model, row: u32) void {
            const top = @as(f32, @floatFromInt(row)) * m.row_h;
            if (top < m.sc.pos) {
                m.sc.jumpTo(top);
            } else if (top + m.row_h > m.sc.pos + m.view_h) {
                m.sc.jumpTo(top + m.row_h - m.view_h);
            }
        }

        pub fn keyMsg(k: keys.SpecialKey) ?Msg {
            return switch (k) {
                .up => .{ .key = .up },
                .down => .{ .key = .down },
                .left => .{ .key = .left },
                .right => .{ .key = .right },
                .home => .{ .key = .home },
                .end => .{ .key = .end },
                .page_up => .{ .key = .page_up },
                .page_down => .{ .key = .page_down },
                .enter => .{ .key = .toggle },
                else => null,
            };
        }

        pub const ViewOpts = struct {
            /// `ScrollStyle.id` of the list. Non-zero.
            id: u32,
            row_h: f32 = 22,
            indent: f32 = 16,
            height: f32 = 0,
            font: text_mod.FontSpec = .{ .size_px = 13, .family = .mono },
            overscan: u32 = 2,
            initial_rows: u32 = 40,
        };

        pub fn window(m: *const Model, opts: ViewOpts) struct { first: u32, end: u32 } {
            if (m.n_visible == 0) return .{ .first = 0, .end = 0 };
            const top: u32 = @intFromFloat(@max(0, @floor(m.sc.pos / opts.row_h)));
            const span: u32 = if (m.view_h > 0) @as(u32, @intFromFloat(@ceil(m.view_h / opts.row_h))) + 1 else opts.initial_rows;
            return .{ .first = @min(top -| opts.overscan, m.n_visible), .end = @min(m.n_visible, top + span + opts.overscan) };
        }

        /// Emit the list. `msgs` supplies `toggle(node: u32)` and `select(node: u32)` as the app's Msg values.
        pub fn view(m: *const Model, cb: anytype, src: anytype, msgs: anytype, opts: ViewOpts) void {
            const pal = cb.theme.palette;
            const arena = cb.arena.allocator();
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
            const w = window(m, opts);
            cb.pushVirtualList(.{ .total_count = m.n_visible, .item_extent = opts.row_h, .visible_start = w.first, .visible_end = w.end });
            // One Tab stop: the selected node's label (else the first row's).
            var stop_row = w.first;
            if (m.selected) |sel| {
                var r = w.first;
                while (r < w.end) : (r += 1) if (m.visible[r] == sel) {
                    stop_row = r;
                    break;
                };
            }
            var row = w.first;
            while (row < w.end) : (row += 1) {
                const node = m.visible[row];
                const depth = src.depth(node);
                const selected = m.selected != null and m.selected.? == node;
                cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .height = opts.row_h });
                if (depth > 0) {
                    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .width = opts.indent * @as(f32, @floatFromInt(depth)), .height = opts.row_h });
                    cb.popGroup();
                }
                var cs = cb.theme.button;
                cs.bg = pal.bg_panel;
                cs.hover_bg = pal.bg_hover;
                cs.fg = pal.fg_muted;
                cs.min_width = opts.indent;
                cs.h_padding = 2;
                cs.height = opts.row_h;
                cs.label_align = .center;
                const kids = node + 1 < m.n_nodes and src.depth(node + 1) > depth;
                const glyph: []const u8 = if (!kids) " " else if (m.isExpanded(node)) "\u{25BE}" else "\u{25B8}";
                if (kids) cb.buttonNav(msgs.toggle(node), glyph, cs, .{ .tab_stop = false }) else cb.buttonNav(msgs.select(node), glyph, cs, .{ .tab_stop = false });
                var ls = cb.theme.button;
                ls.bg = if (selected) mix(pal.bg_panel, pal.accent, if (m.focused) 0.55 else 0.3) else pal.bg_panel;
                ls.hover_bg = if (selected) ls.bg else pal.bg_hover;
                ls.press_bg = ls.hover_bg;
                ls.fg = pal.fg;
                ls.min_width = 0;
                ls.h_padding = 6;
                ls.height = opts.row_h;
                ls.label_align = .start;
                cb.buttonNav(msgs.select(node), src.label(arena, node), ls, .{ .tab_stop = row == stop_row });
                cb.popGroup();
            }
            cb.popVirtualList();
            cb.popScroll();
        }
    };
}

fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, 1 };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const Tr = TreeList(64);

// root0
//   a1
//     a2
//     b2
//   c1
// root1
//   d1
const depths = [_]u16{ 0, 1, 2, 2, 1, 0, 1 };
const TestTree = struct {
    pub fn depth(_: TestTree, node: u32) u16 {
        return depths[node];
    }
    pub fn label(_: TestTree, _: std.mem.Allocator, node: u32) []const u8 {
        return switch (node) {
            0 => "root0",
            1 => "a1",
            2 => "a2",
            3 => "b2",
            4 => "c1",
            5 => "root1",
            else => "d1",
        };
    }
};
const tree: TestTree = .{};

fn collapsed(m: *Tr.Model) void {
    m.* = .{};
    m.view_h = 66;
    m.setNodes(depths.len, tree, 0);
}

test "setNodes: everything collapsed shows only the roots" {
    var m: Tr.Model = undefined;
    collapsed(&m);
    try testing.expectEqualSlices(u32, &.{ 0, 5 }, m.visible[0..m.n_visible]);
}

test "toggle expands one level; nested collapsed subtrees stay hidden; collapsing re-hides" {
    var m: Tr.Model = undefined;
    collapsed(&m);
    Tr.update(&m, .{ .toggle = 0 }, tree);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, m.visible[0..m.n_visible]);
    Tr.update(&m, .{ .toggle = 1 }, tree);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, m.visible[0..m.n_visible]);
    Tr.update(&m, .{ .toggle = 0 }, tree);
    try testing.expectEqualSlices(u32, &.{ 0, 5 }, m.visible[0..m.n_visible]);
    Tr.update(&m, .{ .toggle = 2 }, tree); // a leaf: no-op
    try testing.expectEqual(@as(u32, 2), m.n_visible);
}

test "setNodes with expand depth 1 opens the roots only" {
    var m: Tr.Model = .{};
    m.view_h = 66;
    m.setNodes(depths.len, tree, 1);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5, 6 }, m.visible[0..m.n_visible]);
    try testing.expectEqual(@as(?u32, 2), m.rowOf(4));
    try testing.expectEqual(@as(?u32, null), m.rowOf(2));
}

test "collapsing the parent of the selection selects the parent" {
    var m: Tr.Model = undefined;
    collapsed(&m);
    Tr.update(&m, .{ .toggle = 0 }, tree);
    Tr.update(&m, .{ .toggle = 1 }, tree);
    Tr.update(&m, .{ .select = 3 }, tree);
    Tr.update(&m, .{ .toggle = 0 }, tree);
    try testing.expectEqual(@as(?u32, 0), m.selected);
}

test "keyboard: down/up, right expands then enters, left collapses then goes to the parent" {
    var m: Tr.Model = undefined;
    collapsed(&m);
    Tr.update(&m, .{ .key = .down }, tree);
    try testing.expectEqual(@as(?u32, 0), m.selected);
    Tr.update(&m, .{ .key = .right }, tree); // expand root0
    try testing.expectEqual(@as(u32, 4), m.n_visible);
    try testing.expectEqual(@as(?u32, 0), m.selected);
    Tr.update(&m, .{ .key = .right }, tree); // into the first child
    try testing.expectEqual(@as(?u32, 1), m.selected);
    Tr.update(&m, .{ .key = .left }, tree); // a1 is collapsed: to the parent
    try testing.expectEqual(@as(?u32, 0), m.selected);
    Tr.update(&m, .{ .key = .left }, tree); // root0 expanded: collapse
    try testing.expectEqual(@as(u32, 2), m.n_visible);
    Tr.update(&m, .{ .key = .left }, tree); // a root: stays
    try testing.expectEqual(@as(?u32, 0), m.selected);
    Tr.update(&m, .{ .key = .end }, tree);
    try testing.expectEqual(@as(?u32, 5), m.selected);
    Tr.update(&m, .{ .key = .toggle }, tree);
    try testing.expectEqual(@as(u32, 3), m.n_visible);
    Tr.update(&m, .{ .key = .home }, tree);
    try testing.expectEqual(@as(?u32, 0), m.selected);
}

test "a large tree: 100k nodes in preorder flatten and scan correctly" {
    const Big = struct {
        // 1000 roots, each with 99 children: node i is a root when i % 100 == 0.
        pub fn depth(_: @This(), node: u32) u16 {
            return if (node % 100 == 0) 0 else 1;
        }
    };
    const B = TreeList(100_000);
    var m = try testing.allocator.create(B.Model);
    defer testing.allocator.destroy(m);
    m.* = .{};
    m.view_h = 440;
    m.setNodes(100_000, Big{}, 0);
    try testing.expectEqual(@as(u32, 1000), m.n_visible);
    B.update(m, .{ .toggle = 500 * 100 }, Big{});
    try testing.expectEqual(@as(u32, 1000 + 99), m.n_visible);
    try testing.expectEqual(@as(?u32, 500), m.rowOf(500 * 100));
    try testing.expectEqual(@as(?u32, 501), m.rowOf(500 * 100 + 1));
}

test "view: indentation groups, chevrons for parents, balanced" {
    const AppMsg = union(enum) { toggle: u32, select: u32 };
    const msgs = struct {
        pub fn toggle(n: u32) AppMsg {
            return .{ .toggle = n };
        }
        pub fn select(n: u32) AppMsg {
            return .{ .select = n };
        }
    };
    var m: Tr.Model = undefined;
    collapsed(&m);
    Tr.update(&m, .{ .toggle = 0 }, tree);
    Tr.update(&m, .{ .toggle = 1 }, tree);
    var cb = cmd.CmdBuffer(AppMsg).init(testing.allocator);
    defer cb.deinit();
    Tr.view(&m, &cb, tree, msgs, .{ .id = 3 });
    try testing.expect(cmd.validateBalance(cb.cmds.items) == null);
    var toggles: usize = 0;
    var chevrons_open: usize = 0;
    for (cb.cmds.items) |c| switch (c) {
        .button => |b| {
            if (b.msg == .toggle) toggles += 1;
            if (std.mem.eql(u8, b.label, "\u{25BE}")) chevrons_open += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), toggles); // root0, a1, root1 have children
    try testing.expectEqual(@as(usize, 2), chevrons_open); // root0 and a1 are open
}
