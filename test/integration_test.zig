//! Framework-wide integration tests. Complements the per-module tests
//! colocated with each source file by driving the full
//! update → view → layout → hit-test → render pipeline end-to-end.
//!
//! Also compiled under `zig build test-wasm` against
//! `wasm32-freestanding` as a canary: if the framework core picks up a
//! posix-only std dep, this file fails to build for wasm before it
//! reaches production. See `tasks-wasm.md` §1 and `docs/HARDLINE.md` §5
//! drift-audit checklist.

const std = @import("std");
const builtin = @import("builtin");
const teak = @import("teak");

// ── A minimal composed app used by the round-trip test ────────────

const Counter = struct {
    pub const Model = struct { count: i32 = 0 };
    pub const Msg = union(enum) { inc, reset };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .inc => m.count += 1,
            .reset => m.count = 0,
        }
    }
    pub fn view(m: *const Model, cb: anytype, msgs: anytype) void {
        _ = m;
        cb.pushGroup(.{ .direction = .horizontal, .padding = 8, .gap = 8 });
        cb.button(msgs.inc, "+");
        cb.button(msgs.reset, "R");
        cb.popGroup();
    }
};

const App = teak.component.Components(.{ .counter = Counter }, null);

// ── Round-trip: click flows through all five passes ───────────────

test "round-trip: click button → update → view reflects new state" {
    const testing = std.testing;

    var model: App.Model = .{};
    var cb = teak.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    // Frame 1: build view, layout.
    App.view(&model, &cb);
    var rects: [64]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 400, teak.monoMeasurer());

    // Click the first button ("+"). Find its rect and hit-test its center.
    var inc_idx: ?usize = null;
    for (cb.cmds.items, 0..) |c, i| {
        if (c == .button) {
            inc_idx = i;
            break;
        }
    }
    try testing.expect(inc_idx != null);
    const r = rects[inc_idx.?];
    const hit = teak.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], r.x + r.w / 2, r.y + r.h / 2);
    try testing.expect(hit != null);
    try testing.expect(hit.?.msg != null);

    // Dispatch the msg; model advances.
    App.update(&model, hit.?.msg.?);
    try testing.expectEqual(@as(i32, 1), model.counter.count);

    // Frame 2: render vertices. Must produce at least one quad per button.
    cb.reset();
    App.view(&model, &cb);
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 400, teak.monoMeasurer());

    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws: std.ArrayList(teak.TextDraw) = .empty;
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(teak.ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    teak.buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, teak.monoMeasurer());
    // 2 button bg quads = 12 verts; labels go to text_draws.
    try testing.expect(verts.items.len >= 12);
    try testing.expect(text_draws.items.len == 2);
}

// ── Virtual list: visible window holds work bounded ──────────────

test "virtual list: only emits cmds for the visible window, container claims full size" {
    const testing = std.testing;
    const Msg = union(enum) { pick };
    const allocator = testing.allocator;

    var cb = teak.CmdBuffer(Msg).init(allocator);
    defer cb.deinit();

    // 10,000 logical rows, 24px each. App "scrolls" to rows 400..420.
    const TOTAL: u32 = 10_000;
    const ITEM_H: f32 = 24;
    const VISIBLE_START: u32 = 400;
    const VISIBLE_END: u32 = 420;

    cb.pushScroll(.{ .direction = .vertical, .width = 400, .height = 480, .padding = 0, .gap = 0 });
    cb.pushVirtualList(.{
        .direction = .vertical,
        .total_count = TOTAL,
        .item_extent = ITEM_H,
        .visible_start = VISIBLE_START,
        .visible_end = VISIBLE_END,
    });
    var i: u32 = VISIBLE_START;
    while (i < VISIBLE_END) : (i += 1) {
        cb.button(.pick, "row");
    }
    cb.popVirtualList();
    cb.popScroll();

    // 4 wrapper cmds + (VISIBLE_END - VISIBLE_START) row buttons.
    const visible_rows = VISIBLE_END - VISIBLE_START;
    try testing.expectEqual(@as(usize, 4 + visible_rows), cb.cmds.items.len);

    var rects: [128]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, teak.monoMeasurer());

    // The virtual-list container's height is the logical total
    // (TOTAL * ITEM_H), not just visible_rows * ITEM_H. That's how
    // the parent scroll container learns the full scroll extent.
    const list_idx: usize = 1; // [0]=push_scroll, [1]=push_virtual_list
    try testing.expectEqual(@as(f32, TOTAL * ITEM_H), rects[list_idx].h);

    // The first emitted row sits at y = VISIBLE_START * ITEM_H.
    const first_row_idx: usize = 2; // first child after push_virtual_list
    try testing.expectEqual(@as(f32, VISIBLE_START * ITEM_H), rects[first_row_idx].y);
}

test "a11y tree round-trip: build over a real frame's cmds + rects" {
    const testing = std.testing;
    const Msg = union(enum) { inc, reset };
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("Counter");
    cb.button(.inc, "+");
    cb.button(.reset, "Reset");
    cb.popGroup();

    var rects: [16]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, teak.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try teak.buildA11yTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], 2);

    // group + text + button + button = 4 nodes.
    try testing.expectEqual(@as(usize, 4), tree.len);
    try testing.expectEqual(teak.A11yRole.button, tree[2].role);
    try testing.expectEqualStrings("+", tree[2].label);
    try testing.expect(tree[2].focused);
}

// ── WASM canary: pipeline compiles without posix ─────────────────

/// Exported so `wasm32-freestanding -fno-entry -rdynamic` keeps the
/// pipeline alive at link time. Not meaningful to call at runtime;
/// compile-success is the signal.
export fn teak_wasm_probe() u32 {
    const Msg = union(enum) { ping };

    var heap_buf: [1 << 18]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    const gpa = fba.allocator();

    var cb = teak.CmdBuffer(Msg).init(gpa);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("hello");
    cb.button(.ping, "+");
    cb.textInput(.ping, "world", 5);
    cb.checkbox(.ping, true, "ok");
    cb.radio(.ping, false, "pick");
    cb.slider(.ping, 0.42);
    cb.divider();
    cb.pushScroll(.{ .width = 100, .height = 100 });
    cb.button(.ping, "inside");
    cb.popScroll();
    cb.popGroup();

    var rects: [32]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, teak.monoMeasurer());

    _ = teak.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 10, 10);

    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(gpa);
    var text_draws: std.ArrayList(teak.TextDraw) = .empty;
    defer text_draws.deinit(gpa);
    var image_draws: std.ArrayList(teak.ImageDraw) = .empty;
    defer image_draws.deinit(gpa);
    teak.buildVertices(&verts, &text_draws, &image_draws, gpa, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, teak.monoMeasurer());

    return @intCast(verts.items.len);
}

// On native, drive teak_wasm_probe via a test so `zig build test`
// exercises the same surface the wasm canary covers.
test "wasm probe pipeline produces vertices on native too" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const n = teak_wasm_probe();
    try std.testing.expect(n > 0);
}
