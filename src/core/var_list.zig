//! `VarList`: a virtualized list whose rows have different heights.
//!
//! Fixed-extent virtualization (`VirtualListStyle.item_extent`) cannot place row
//! N without knowing every row above it. Here the heights live in the Model:
//!
//!   * `h[i]`: the height layout *measured* for row i (0 = not seen yet);
//!   * `prefix[i]`: the top of row i, using `est` for unmeasured rows;
//!
//! so the visible window is found by binary search over `prefix` and the rows
//! are emitted at `start_offset = prefix[first]` inside a virtual list that claims
//! `prefix[n]` px (`VirtualListStyle.total_extent`).
//!
//! Measuring stays HARDLINE-clean: `view` cannot read layout, so the runtime
//! reports the emitted rows' heights back through `virtualRowsMsg` (the
//! `scrollLayoutMsg` pattern) as a `.measured` Msg. Learning a height above the
//! viewport would move the content under the reader, so `update` re-anchors:
//! the scroll offset shifts by exactly the change in the anchor row's top.
//! `insert` / `remove` anchor the same way, so a chat that appends or prepends
//! rows does not jerk.
//!
//! The row content is the app's: `src.row(cb, index)` emits exactly ONE child
//! (usually a `push_group`...`pop_group`) per row; the child's laid-out height is
//! the row height.
//!
//!     // virtualRowsMsg(m, id, first, heights) -> .{ .list = List.measuredMsg(first, heights) }
//!     // scrollMsg -> .wheel, scrollLayoutMsg -> .viewport, animationMsg -> .frame

const std = @import("std");
const cmd = @import("cmd.zig");
const scroller = @import("scroller.zig");

/// Rows one `.measured` Msg carries (a viewport rarely shows more; extra rows keep
/// their estimate until they scroll into a smaller window).
pub const max_measured = 96;

pub fn VarList(comptime cap: usize) type {
    return struct {
        const Self = @This();
        pub const capacity = cap;

        pub const Model = struct {
            n: u32 = 0,
            /// Height assumed for rows layout has not measured yet.
            est: f32 = 32,
            h: [cap]f32 = @splat(0),
            /// `prefix[i]` = top of row i; `prefix[n]` = total height.
            prefix: [cap + 1]f32 = @splat(0),
            sc: scroller.Scroller = .{},
            view_h: f32 = 0,

            /// Replace the contents: `n` rows, none measured.
            pub fn setCount(self: *Model, n: usize, est: f32) void {
                self.n = @intCast(@min(n, cap));
                self.est = est;
                @memset(self.h[0..self.n], 0);
                self.rebuild();
                self.sc = .{};
                self.sc.setExtent(self.view_h, self.total());
            }

            pub fn total(self: *const Model) f32 {
                return self.prefix[self.n];
            }

            fn heightOf(self: *const Model, i: usize) f32 {
                return if (self.h[i] > 0) self.h[i] else self.est;
            }

            fn rebuild(self: *Model) void {
                var y: f32 = 0;
                for (0..self.n) |i| {
                    self.prefix[i] = y;
                    y += self.heightOf(i);
                }
                self.prefix[self.n] = y;
            }

            /// The row containing content y (clamped).
            pub fn rowAt(self: *const Model, y: f32) u32 {
                if (self.n == 0) return 0;
                // Largest i with prefix[i] <= y.
                var lo: u32 = 0;
                var hi: u32 = self.n; // exclusive
                while (hi - lo > 1) {
                    const mid = lo + (hi - lo) / 2;
                    if (self.prefix[mid] <= y) lo = mid else hi = mid;
                }
                return lo;
            }

            /// Insert a row before `at` (`h` = its height if known, else 0).
            /// Keeps the reader's position when the row lands above the viewport.
            pub fn insert(self: *Model, at: u32, h: f32) void {
                if (self.n >= cap or at > self.n) return;
                const anchor = self.rowAt(self.sc.pos);
                var i = self.n;
                while (i > at) : (i -= 1) self.h[i] = self.h[i - 1];
                self.h[at] = h;
                self.n += 1;
                self.rebuild();
                if (at <= anchor and self.sc.pos > 0) self.sc.shift(self.heightOf(at));
                self.sc.setExtent(self.view_h, self.total());
            }

            /// Remove row `at`, anchoring like `insert`.
            pub fn remove(self: *Model, at: u32) void {
                if (at >= self.n) return;
                const anchor = self.rowAt(self.sc.pos);
                const gone = self.heightOf(at);
                var i = at;
                while (i + 1 < self.n) : (i += 1) self.h[i] = self.h[i + 1];
                self.n -= 1;
                self.rebuild();
                if (at < anchor) self.sc.shift(-gone);
                self.sc.setExtent(self.view_h, self.total());
            }

            pub fn animating(self: *const Model) bool {
                return self.sc.animating();
            }
        };

        pub const Msg = union(enum) {
            wheel: f32,
            viewport: struct { vw: f32, vh: f32, cw: f32, ch: f32 },
            /// Layout measured rows `first..first+count` (heights beyond `count` are unused).
            measured: struct { first: u32, count: u8, heights: [max_measured]f32 },
            frame: u32,
        };

        /// Build a `.measured` Msg from the runtime's slice (copies up to `max_measured`).
        pub fn measuredMsg(first: u32, heights: []const f32) Msg {
            var m: Msg = .{ .measured = .{ .first = first, .count = 0, .heights = undefined } };
            const n = @min(heights.len, max_measured);
            @memcpy(m.measured.heights[0..n], heights[0..n]);
            m.measured.count = @intCast(n);
            return m;
        }

        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .wheel => |dy| m.sc.wheel(dy),
                .viewport => |v| {
                    m.view_h = v.vh;
                    m.sc.setExtent(v.vh, m.total());
                },
                .frame => |dt| m.sc.step(dt),
                .measured => |ms| measure(m, ms.first, ms.heights[0..ms.count]),
            }
        }

        fn measure(m: *Model, first: u32, heights: []const f32) void {
            var changed = false;
            for (heights, 0..) |h, k| {
                const row = first + k;
                if (row >= m.n or h <= 0) continue;
                if (@abs(m.h[row] - h) > 0.01) {
                    m.h[row] = h;
                    changed = true;
                }
            }
            if (!changed) return;
            // Anchor: the row at the top of the viewport and the offset into it.
            const anchor = m.rowAt(m.sc.pos);
            const old_top = m.prefix[anchor];
            const into = m.sc.pos - old_top;
            m.rebuild();
            const new_pos = m.prefix[anchor] + into;
            m.sc.shift(new_pos - m.sc.pos);
            m.sc.setExtent(m.view_h, m.total());
        }

        pub const ViewOpts = struct {
            /// `ScrollStyle.id` (wheel + layout) AND `VirtualListStyle.id` (row reports).
            id: u32,
            /// Viewport height; 0 = flex.
            height: f32 = 0,
            overscan: u32 = 2,
            /// Rows to emit before the viewport height is known.
            initial_rows: u32 = 12,
        };

        /// First row and one-past-last the view would emit.
        pub fn window(m: *const Model, opts: ViewOpts) struct { first: u32, end: u32 } {
            if (m.n == 0) return .{ .first = 0, .end = 0 };
            const top = m.rowAt(m.sc.pos);
            const first = top -| opts.overscan;
            var end: u32 = top;
            if (m.view_h > 0) {
                const bottom = m.sc.pos + m.view_h;
                while (end < m.n and m.prefix[end] < bottom) end += 1;
            } else end = @min(m.n, top + opts.initial_rows);
            return .{ .first = first, .end = @min(m.n, end + opts.overscan) };
        }

        /// Emit the list. `src.row(cb, index)` must emit exactly one top-level child.
        pub fn view(m: *const Model, cb: anytype, src: anytype, opts: ViewOpts) void {
            cb.pushScroll(.{
                .direction = .vertical,
                .padding = 0,
                .gap = 0,
                .id = opts.id,
                .flex = if (opts.height > 0) 0 else 1,
                .height = opts.height,
                .align_cross = .stretch,
                .scroll_y = m.sc.pos,
            });
            const w = window(m, opts);
            cb.pushVirtualList(.{
                .total_extent = @max(m.total(), 1),
                .start_offset = m.prefix[w.first],
                .visible_start = w.first,
                .visible_end = w.end,
                .align_cross = .stretch,
                .id = opts.id,
            });
            var i = w.first;
            while (i < w.end) : (i += 1) src.row(cb, i);
            cb.popVirtualList();
            cb.popScroll();
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const L = VarList(64);

test "prefix sums use the estimate until a row is measured" {
    var m: L.Model = .{};
    m.setCount(10, 30);
    try testing.expectEqual(@as(f32, 300), m.total());
    L.update(&m, L.measuredMsg(2, &.{ 50, 70 }));
    try testing.expectEqual(@as(f32, 60), m.prefix[2]);
    try testing.expectEqual(@as(f32, 110), m.prefix[3]);
    try testing.expectEqual(@as(f32, 180), m.prefix[4]);
    try testing.expectEqual(@as(f32, 300 - 60 + 120), m.total());
}

test "rowAt: binary search over uneven heights" {
    var m: L.Model = .{};
    m.setCount(5, 10);
    L.update(&m, L.measuredMsg(0, &.{ 10, 40, 5, 100, 20 }));
    try testing.expectEqual(@as(u32, 0), m.rowAt(0));
    try testing.expectEqual(@as(u32, 0), m.rowAt(9.9));
    try testing.expectEqual(@as(u32, 1), m.rowAt(10));
    try testing.expectEqual(@as(u32, 2), m.rowAt(50));
    try testing.expectEqual(@as(u32, 3), m.rowAt(55));
    try testing.expectEqual(@as(u32, 4), m.rowAt(1000));
}

test "measuring rows above the viewport does not move the content under the reader" {
    var m: L.Model = .{};
    m.view_h = 100;
    m.setCount(20, 30);
    m.sc.setExtent(100, m.total());
    m.sc.jumpTo(300); // top of row 10
    // Rows 0..9 turn out 40 px each (10 px taller than estimated): 100 px above the viewport.
    var first: [10]f32 = @splat(40);
    L.update(&m, L.measuredMsg(0, &first));
    try testing.expectEqual(@as(f32, 400), m.sc.pos);
    try testing.expectEqual(@as(f32, 400), m.prefix[10]); // row 10 is still at the top
    // Rows inside / below the viewport change the total but not the anchor.
    L.update(&m, L.measuredMsg(12, &.{ 80, 80 }));
    try testing.expectEqual(@as(f32, 400), m.sc.pos);
}

test "an anchor offset inside the row survives re-measurement" {
    var m: L.Model = .{};
    m.view_h = 100;
    m.setCount(20, 30);
    m.sc.setExtent(100, m.total());
    m.sc.jumpTo(310); // 10 px into row 10
    var first: [10]f32 = @splat(34);
    L.update(&m, L.measuredMsg(0, &first));
    try testing.expectEqual(@as(f32, 340 + 10), m.sc.pos);
}

test "insert above the viewport keeps the reader in place; at the top it does not scroll" {
    var m: L.Model = .{};
    m.view_h = 100;
    m.setCount(20, 30);
    m.sc.setExtent(100, m.total());
    m.sc.jumpTo(300);
    m.insert(2, 45);
    try testing.expectEqual(@as(f32, 345), m.sc.pos);
    try testing.expectEqual(@as(u32, 21), m.n);
    m.sc.jumpTo(0);
    m.insert(0, 45);
    try testing.expectEqual(@as(f32, 0), m.sc.pos);
    m.sc.jumpTo(200);
    m.insert(m.n, 10); // appended below: no shift
    try testing.expectEqual(@as(f32, 200), m.sc.pos);
}

test "remove above the viewport shifts back" {
    var m: L.Model = .{};
    m.view_h = 100;
    m.setCount(20, 30);
    m.sc.setExtent(100, m.total());
    m.sc.jumpTo(300);
    m.remove(1);
    try testing.expectEqual(@as(f32, 270), m.sc.pos);
    try testing.expectEqual(@as(u32, 19), m.n);
}

test "window emits the visible rows plus overscan only" {
    var m: L.Model = .{};
    m.view_h = 100;
    m.setCount(60, 20);
    m.sc.setExtent(100, m.total());
    m.sc.jumpTo(400); // row 20
    const w = L.window(&m, .{ .id = 1 });
    try testing.expectEqual(@as(u32, 18), w.first);
    try testing.expect(w.end >= 25 and w.end <= 28);
}

test "view: a virtual list in variable mode wrapped by a scroll, rows emitted once each" {
    const Msg = union(enum) { a };
    const Rows = struct {
        pub fn row(_: @This(), cb: anytype, i: u32) void {
            cb.pushGroup(.{ .padding = 2, .gap = 0 });
            cb.text(if (i % 2 == 0) "short" else "a longer one");
            cb.popGroup();
        }
    };
    const L2 = VarList(2048);
    var m: L2.Model = .{};
    m.view_h = 90;
    m.setCount(1000, 24);
    m.sc.setExtent(90, m.total());
    m.sc.jumpTo(2400);
    var cb = cmd.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    L2.view(&m, &cb, Rows{}, .{ .id = 5 });
    try testing.expect(cmd.validateBalance(cb.cmds.items) == null);
    const vl = cb.cmds.items[1].push_virtual_list;
    try testing.expectEqual(@as(f32, 24000), vl.total_extent);
    try testing.expectEqual(@as(f32, 2400 - 48), vl.start_offset); // overscan of 2 rows above row 100
    try testing.expectEqual(@as(u32, 5), vl.id);
    try testing.expect(vl.visible_end - vl.visible_start <= 12);
}
