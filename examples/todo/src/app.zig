//! Todo app — exercises Teak's dynamic-content story.
//!
//! Stresses: a `view` that emits N rows from `model.items`, Msg
//! variants carrying a row index (`.toggle: usize`, `.remove: usize`),
//! a scrolling list with per-row hit-testing, and an input that drains
//! character events into `Model.input` and dispatches `.add_item` on
//! Enter.
//!
//! No `Components` here — a single Model + Msg is plenty. The composed
//! pattern in counter_greeter exists for the multi-widget-group case,
//! not one-screen apps.

const std = @import("std");
const teak = @import("teak");

// ── Tunables ───────────────────────────────────────────────────────

pub const MAX_ITEMS = 256;
pub const MAX_LABEL = 64;
pub const MAX_INPUT = MAX_LABEL;

// ── Model ──────────────────────────────────────────────────────────

pub const Item = struct {
    label: [MAX_LABEL]u8 = [_]u8{0} ** MAX_LABEL,
    label_len: u8 = 0,
    done: bool = false,
};

pub const Model = struct {
    items: [MAX_ITEMS]Item = [_]Item{.{}} ** MAX_ITEMS,
    items_len: u16 = 0,
    /// In-progress label for the "add" input.
    input: [MAX_INPUT]u8 = [_]u8{0} ** MAX_INPUT,
    input_len: u8 = 0,
    /// Whether the add-input has focus. Drives the cursor + directs
    /// keyboard events. Mirrored into TransientState.focus_index by the
    /// main loop.
    input_focused: bool = false,
};

// ── Msg ────────────────────────────────────────────────────────────

pub const Msg = union(enum) {
    // Add-input lifecycle.
    input_focus,
    input_char: u8,
    input_backspace,
    add_item,

    // Per-row actions. The usize is the row index at the time of the
    // click — translated from cmd index via the Model's items_len.
    toggle: usize,
    remove: usize,

    // Bulk.
    clear_completed,
};

// ── Update ─────────────────────────────────────────────────────────

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .input_focus => m.input_focused = true,

        .input_char => |c| {
            if (m.input_len < MAX_INPUT) {
                m.input[m.input_len] = c;
                m.input_len += 1;
            }
        },

        .input_backspace => {
            if (m.input_len > 0) m.input_len -= 1;
        },

        .add_item => {
            if (m.input_len == 0 or m.items_len >= MAX_ITEMS) return;
            const slot = &m.items[m.items_len];
            slot.label_len = m.input_len;
            @memcpy(slot.label[0..m.input_len], m.input[0..m.input_len]);
            slot.done = false;
            m.items_len += 1;
            m.input_len = 0;
        },

        .toggle => |i| {
            if (i < m.items_len) m.items[i].done = !m.items[i].done;
        },

        .remove => |i| {
            if (i >= m.items_len) return;
            // Shift [i+1..end] left by one. Preserves order — simpler
            // than swap-remove and the app is small enough that the
            // cost doesn't matter.
            var k: usize = i;
            while (k + 1 < m.items_len) : (k += 1) {
                m.items[k] = m.items[k + 1];
            }
            m.items_len -= 1;
        },

        .clear_completed => {
            var write: u16 = 0;
            var read: u16 = 0;
            while (read < m.items_len) : (read += 1) {
                if (!m.items[read].done) {
                    if (write != read) m.items[write] = m.items[read];
                    write += 1;
                }
            }
            m.items_len = write;
        },
    }
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 20, .gap = 12 });

    cb.text("Todo");

    // Add-item row: input stretches to fill, "Add" pinned to the right.
    cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 0 });
    cb.textInput(.input_focus, m.input[0..m.input_len], m.input_len);
    cb.button(.add_item, "Add");
    cb.popGroup();

    cb.divider();

    // The list. A scroll container so the UI stays bounded when items
    // pile up. Height is fixed; width stretches via flex=1.
    cb.pushScroll(.{
        .direction = .vertical,
        .padding = 0,
        .gap = 4,
        .flex = 1,
        .width = 0, // 0 → inherit parent width
        .height = 320,
    });
    for (m.items[0..m.items_len], 0..) |item, i| {
        cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 4 });
        cb.checkbox(.{ .toggle = i }, item.done, item.label[0..item.label_len]);
        // Spacer group claims the middle so the delete button pins right.
        cb.pushGroup(.{ .direction = .vertical, .flex = 1, .padding = 0, .gap = 0 });
        cb.popGroup();
        cb.button(.{ .remove = i }, "x");
        cb.popGroup();
    }
    cb.popScroll();

    cb.divider();

    // Footer: item count + clear-completed button.
    cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 0 });
    var buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&buf, "{d} items", .{m.items_len}) catch "? items";
    cb.text(count_str);
    cb.pushGroup(.{ .direction = .vertical, .flex = 1, .padding = 0, .gap = 0 });
    cb.popGroup();
    cb.button(.clear_completed, "Clear done");
    cb.popGroup();

    cb.popGroup();
}

// ── Key event translation (for host integration) ──────────────────

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    if (!m.input_focused) return null;
    return .{ .input_char = c };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    if (!m.input_focused) return null;
    return switch (key) {
        .backspace => .input_backspace,
        .enter => .add_item,
        else => null,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "add_item copies input into items and clears input" {
    const t = std.testing;
    var m: Model = .{};

    update(&m, .{ .input_char = 'a' });
    update(&m, .{ .input_char = 'b' });
    update(&m, .add_item);

    try t.expectEqual(@as(u16, 1), m.items_len);
    try t.expectEqualStrings("ab", m.items[0].label[0..m.items[0].label_len]);
    try t.expectEqual(@as(u8, 0), m.input_len);
}

test "add_item is a no-op when input is empty" {
    const t = std.testing;
    var m: Model = .{};
    update(&m, .add_item);
    try t.expectEqual(@as(u16, 0), m.items_len);
}

test "toggle flips done; ignores out-of-range" {
    const t = std.testing;
    var m: Model = .{};
    // Prime with one item.
    for ("hi") |c| update(&m, .{ .input_char = c });
    update(&m, .add_item);

    try t.expect(!m.items[0].done);
    update(&m, .{ .toggle = 0 });
    try t.expect(m.items[0].done);
    update(&m, .{ .toggle = 0 });
    try t.expect(!m.items[0].done);

    // Out-of-range is ignored silently.
    update(&m, .{ .toggle = 99 });
}

test "remove shifts later items left and preserves order" {
    const t = std.testing;
    var m: Model = .{};
    for ([_][]const u8{ "a", "b", "c" }) |s| {
        for (s) |ch| update(&m, .{ .input_char = ch });
        update(&m, .add_item);
    }
    try t.expectEqual(@as(u16, 3), m.items_len);

    update(&m, .{ .remove = 0 });
    try t.expectEqual(@as(u16, 2), m.items_len);
    try t.expectEqualStrings("b", m.items[0].label[0..m.items[0].label_len]);
    try t.expectEqualStrings("c", m.items[1].label[0..m.items[1].label_len]);
}

test "clear_completed removes done items, preserves pending" {
    const t = std.testing;
    var m: Model = .{};
    for ([_][]const u8{ "a", "b", "c" }) |s| {
        for (s) |ch| update(&m, .{ .input_char = ch });
        update(&m, .add_item);
    }
    update(&m, .{ .toggle = 0 });
    update(&m, .{ .toggle = 2 });

    update(&m, .clear_completed);

    try t.expectEqual(@as(u16, 1), m.items_len);
    try t.expectEqualStrings("b", m.items[0].label[0..m.items[0].label_len]);
}

test "view emits one row per item; row carries the correct index Msg" {
    const t = std.testing;
    var m: Model = .{};
    for ([_][]const u8{ "x", "y" }) |s| {
        for (s) |ch| update(&m, .{ .input_char = ch });
        update(&m, .add_item);
    }

    var cb = teak.CmdBuffer(Msg).init(t.allocator);
    defer cb.deinit();
    view(&m, &cb);

    // Find every checkbox; its msg must be {.toggle = expected_index}.
    var checkbox_count: usize = 0;
    var expected: usize = 0;
    for (cb.cmds.items) |c| {
        if (c == .checkbox) {
            try t.expectEqual(Msg{ .toggle = expected }, c.checkbox.msg);
            expected += 1;
            checkbox_count += 1;
        }
    }
    try t.expectEqual(@as(usize, 2), checkbox_count);
}

test "end-to-end: click delete button on item 0 removes it" {
    const t = std.testing;
    var m: Model = .{};
    for ([_][]const u8{ "a", "b" }) |s| {
        for (s) |ch| update(&m, .{ .input_char = ch });
        update(&m, .add_item);
    }

    var cb = teak.CmdBuffer(Msg).init(t.allocator);
    defer cb.deinit();
    view(&m, &cb);

    var rects: [256]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 600, 500);

    // First "x" button is the delete for item 0.
    var first_x: ?teak.Rect = null;
    for (cb.cmds.items, 0..) |c, i| switch (c) {
        .button => |b| if (std.mem.eql(u8, b.label, "x")) {
            if (first_x == null) first_x = rects[i];
        },
        else => {},
    };
    try t.expect(first_x != null);

    const r = first_x.?;
    const hit = teak.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], r.x + 2, r.y + 2);
    try t.expect(hit != null);
    update(&m, hit.?.msg);

    try t.expectEqual(@as(u16, 1), m.items_len);
    try t.expectEqualStrings("b", m.items[0].label[0..m.items[0].label_len]);
}
