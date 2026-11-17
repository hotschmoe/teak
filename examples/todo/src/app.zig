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
    label: [MAX_LABEL]u8 = @splat(0),
    label_len: u8 = 0,
    done: bool = false,
};

pub const Model = struct {
    items: [MAX_ITEMS]Item = @splat(.{}),
    items_len: u16 = 0,
    /// In-progress label for the "add" input.
    input: [MAX_INPUT]u8 = @splat(0),
    input_len: u8 = 0,
    /// Whether the add-input has focus. Drives the cursor + directs
    /// keyboard events. Mirrored into TransientState.focus_index by the
    /// main loop.
    input_focused: bool = false,
    /// The row the keyboard reorder commands act on: the last row toggled
    /// or dragged.
    selected: ?u16 = null,
    /// An in-progress drag (HARDLINE: drag state is Model state; the loop
    /// only reports `DragEvent`s).
    drag: ?Drag = null,
};

/// What the view needs to draw the ghost and the drop indicator.
pub const Drag = struct {
    /// Row being dragged (index) and the pointer + grab offset for the ghost.
    from: u16,
    x: f32,
    y: f32,
    grab_dx: f32,
    grab_dy: f32,
    /// Row id (index + 1) under the pointer, 0 = none; and whether the
    /// pointer is in its lower half (drop after it).
    over: u32 = 0,
    after: bool = false,
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

    /// Drag and drop reorder (mouse) ...
    drag: teak.DragEvent,
    /// ... and its keyboard alternative: Alt+Up / Alt+Down move the selected row.
    move_selected: i8,
};

/// Move item `from` so it ends up at index `to` (order-preserving shift).
pub fn moveItem(m: *Model, from: usize, to: usize) void {
    if (from >= m.items_len or to >= m.items_len or from == to) return;
    const item = m.items[from];
    if (from < to) {
        std.mem.copyForwards(Item, m.items[from..to], m.items[from + 1 .. to + 1]);
    } else {
        std.mem.copyBackwards(Item, m.items[to + 1 .. from + 1], m.items[to..from]);
    }
    m.items[to] = item;
}

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
            m.selected = @intCast(i);
        },

        .drag => |ev| updateDrag(m, ev),

        .move_selected => |d| {
            const s = m.selected orelse return;
            const to: i32 = @as(i32, s) + d;
            if (to < 0 or to >= m.items_len) return;
            moveItem(m, s, @intCast(to));
            m.selected = @intCast(to);
        },

        .remove => |i| {
            if (i >= m.items_len) return;
            // Order-preserving shift; swap-remove would be cheaper but
            // would reorder the list on every delete.
            std.mem.copyForwards(Item, m.items[i .. m.items_len - 1], m.items[i + 1 .. m.items_len]);
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

fn updateDrag(m: *Model, ev: teak.DragEvent) void {
    switch (ev.phase) {
        .start => if (ev.id >= 1 and ev.id <= m.items_len) {
            m.drag = .{ .from = @intCast(ev.id - 1), .x = ev.x, .y = ev.y, .grab_dx = ev.grab_dx, .grab_dy = ev.grab_dy };
            m.selected = @intCast(ev.id - 1);
        },
        .move => if (m.drag) |*d| {
            d.x = ev.x;
            d.y = ev.y;
            d.over = ev.over;
            d.after = ev.over_fy >= 0.5;
        },
        .drop => if (m.drag) |d| {
            m.drag = null;
            if (ev.over == 0) return;
            const over: usize = ev.over - 1;
            // Dropping on the lower half inserts after the target row.
            var to: usize = if (ev.over_fy >= 0.5) over + 1 else over;
            // Removing the source first shifts later rows up by one.
            if (d.from < to) to -= 1;
            if (to >= m.items_len) to = m.items_len - 1;
            moveItem(m, d.from, to);
            m.selected = @intCast(to);
        },
        .cancel => m.drag = null,
    }
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 20, .gap = 12, .align_cross = .stretch });

    cb.text("Todo");

    // Add-item row: input stretches to fill, "Add" pinned to the right.
    cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 0 });
    cb.textInputA11y(.input_focus, m.input[0..m.input_len], m.input_len, "New item");
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
        .align_cross = .stretch, // rows span the list so each "x" pins right
        .width = 0, // 0 → inherit parent width
        .height = 320,
        .a11y = .{ .semantic = .list, .label = "Todo items" },
    });
    for (m.items[0..m.items_len], 0..) |*item, i| {
        const id: u32 = @intCast(i + 1);
        const dragging_this = if (m.drag) |d| d.from == i else false;
        const hot = if (m.drag) |d| (d.over == id and d.from != i) else false;
        const selected = if (m.selected) |s| s == i else false;
        cb.pushGroup(.{
            .direction = .horizontal,
            .gap = 8,
            .padding = 4,
            .drag_id = id,
            .drop_id = id,
            .a11y = .{ .semantic = .listitem },
            .bg = if (dragging_this) .{ 0.12, 0.12, 0.15, 1 } else if (selected) .{ 0.16, 0.18, 0.24, 1 } else null,
            .border = if (hot) .{ 0.4, 0.7, 1.0, 1 } else null,
        });
        cb.text("::");
        cb.checkbox(.{ .toggle = i }, item.done, item.label[0..item.label_len]);
        // Spacer claims the middle so the delete button pins right.
        cb.spacer(1);
        // The visible label is "x"; screen readers hear "Remove <item>".
        const remove_name = std.fmt.allocPrint(cb.arena.allocator(), "Remove {s}", .{item.label[0..item.label_len]}) catch "Remove";
        cb.buttonA11y(.{ .remove = i }, "x", .{ .label = remove_name });
        cb.popGroup();
    }
    cb.popScroll();

    cb.divider();

    // Footer: item count + clear-completed button.
    cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 0 });
    // The count is a polite live region: AT announces "3 items" as it changes.
    cb.pushGroup(.{ .direction = .horizontal, .gap = 0, .padding = 0, .a11y = .{ .semantic = .status, .live = .polite } });
    // Allocate from the frame arena — a stack buffer's slice would escape
    // into the cmd buffer and be clobbered before layout reads it.
    const count_str = std.fmt.allocPrint(cb.arena.allocator(), "{d} items", .{m.items_len}) catch "? items";
    cb.text(count_str);
    cb.popGroup();
    cb.spacer(1);
    cb.button(.clear_completed, "Clear done");
    cb.popGroup();

    cb.popGroup();

    // The drag ghost: the dragged row's label, following the pointer.
    if (m.drag) |d| {
        if (d.from < m.items_len) {
            cb.pushOverlay(.{
                .x = d.x - d.grab_dx,
                .y = d.y - d.grab_dy,
                .padding = 8,
                .backdrop = .{ 0.2, 0.3, 0.5, 0.85 },
                .border = .{ 0.5, 0.75, 1.0, 1 },
            });
            const it = &m.items[d.from];
            cb.text(it.label[0..it.label_len]);
            cb.popOverlay();
        }
    }
}

/// Agent / keyboard command table: reorder the selected row without a mouse.
pub fn commands(m: *const Model, list: *teak.CommandList(Msg)) void {
    const s = m.selected orelse return;
    list.add(.{ .id = "item.up", .label = "Move item up", .shortcut = teak.Chord.altKey(.up), .enabled = s > 0, .msg = .{ .move_selected = -1 } });
    list.add(.{ .id = "item.down", .label = "Move item down", .shortcut = teak.Chord.altKey(.down), .enabled = s + 1 < m.items_len, .msg = .{ .move_selected = 1 } });
}

/// Mouse drag reorder: groups carry `drag_id` / `drop_id` (see `view`).
pub fn dragMsg(_: *const Model, ev: teak.DragEvent) ?Msg {
    return .{ .drag = ev };
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

/// The focus Msg of the add-input when it's focused, so `teak.run` can
/// draw its focus ring + blink the cursor (and, incidentally, Tab-focus
/// it — there's only the one focusable widget). The input's `focus_msg`
/// is `.input_focus`, so `run` maps this back to its cmd index by value.
pub fn focusedMsg(m: *const Model) ?Msg {
    return if (m.input_focused) Msg.input_focus else null;
}

/// Agent-driver hook (`state` command): the Model as text, read-only.
pub fn debugState(m: *const Model, w: *std.Io.Writer) void {
    w.print("items={d} input=\"{s}\" focused={}\n", .{ m.items_len, m.input[0..m.input_len], m.input_focused }) catch return;
    for (m.items[0..m.items_len], 0..) |it, i| {
        w.print("  [{d}] {s} \"{s}\"\n", .{ i, if (it.done) "x" else " ", it.label[0..it.label_len] }) catch return;
    }
}

// ── Tests ──────────────────────────────────────────────────────────








fn labels(m: *const Model, buf: *[8][]const u8) []const []const u8 {
    for (m.items[0..m.items_len], 0..) |*it, i| buf[i] = it.label[0..it.label_len];
    return buf[0..m.items_len];
}


fn flat(parts: []const []const u8) []const u8 {
    const S = struct {
        var out: [16]u8 = undefined;
    };
    var n: usize = 0;
    for (parts) |p| {
        @memcpy(S.out[n..][0..p.len], p);
        n += p.len;
    }
    return S.out[0..n];
}




