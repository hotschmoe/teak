//! Tree app — exercises recursive view emission, conditional visibility
//! by ancestor state, and deep layout-stack nesting.
//!
//! Representation: nodes live in a flat pre-order array. Each carries
//! `depth`, `label`, and `expanded`. A node is *visible* iff every
//! ancestor in the pre-order prefix is expanded. `view` walks nodes
//! front-to-back, tracks the minimum-visible-depth cutoff, and emits
//! one indented button per visible node.
//!
//! Identity is the node's pre-order index, same pattern as todo's row
//! index. The advertised "widget-identity-via-path-in-Model" story
//! becomes "widget-identity-via-position-in-flat-array" — paths would
//! require arena-allocated slices in Msg, which breaks Cmd's
//! "data, not pointers" shape. Flat index is cleaner and still
//! exercises every claim the tree was supposed to test.

const std = @import("std");
const teak = @import("teak");

// ── Tunables ───────────────────────────────────────────────────────

pub const MAX_NODES = 128;
pub const MAX_LABEL = 48;
pub const INDENT_PER_LEVEL: f32 = 20;

// ── Model ──────────────────────────────────────────────────────────

pub const Node = struct {
    label: [MAX_LABEL]u8 = [_]u8{0} ** MAX_LABEL,
    label_len: u8 = 0,
    depth: u8 = 0,
    /// False collapses this node's children; they stay in the pre-order
    /// array but are filtered out of `view`.
    expanded: bool = true,
    /// Leaf = no children. A child is "a later node with depth > mine,
    /// with no intervening node at depth ≤ mine". Cached at init to
    /// avoid a scan per node per frame.
    is_leaf: bool = true,
};

pub const Model = struct {
    nodes: [MAX_NODES]Node = [_]Node{.{}} ** MAX_NODES,
    nodes_len: u16 = 0,
    /// Click-selected node, highlighted in the render pass (optional —
    /// kept for future expansion, unused today beyond storage).
    selected: ?u16 = null,

    pub fn init() Model {
        var m: Model = .{};
        m.load(&sample_tree);
        return m;
    }

    /// Populate from a pre-order (depth, label) table. Computes
    /// `is_leaf` by peeking at the next entry's depth.
    fn load(self: *Model, entries: []const SampleEntry) void {
        self.nodes_len = 0;
        for (entries) |e| {
            if (self.nodes_len >= MAX_NODES) break;
            const node = &self.nodes[self.nodes_len];
            const n = @min(e.label.len, MAX_LABEL);
            @memcpy(node.label[0..n], e.label[0..n]);
            node.label_len = @intCast(n);
            node.depth = e.depth;
            node.expanded = e.expanded;
            node.is_leaf = true; // rewritten below
            self.nodes_len += 1;
        }
        // Second pass: a node is a leaf unless some later node is
        // deeper AND no intervening node has depth ≤ the candidate's.
        var i: u16 = 0;
        while (i < self.nodes_len) : (i += 1) {
            const d = self.nodes[i].depth;
            if (i + 1 < self.nodes_len and self.nodes[i + 1].depth > d) {
                self.nodes[i].is_leaf = false;
            }
        }
    }
};

// ── Msg ────────────────────────────────────────────────────────────

pub const Msg = union(enum) {
    toggle: u16, // node pre-order index
    select: u16,
};

// ── Update ─────────────────────────────────────────────────────────

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .toggle => |i| {
            if (i >= m.nodes_len) return;
            m.nodes[i].expanded = !m.nodes[i].expanded;
        },
        .select => |i| {
            if (i < m.nodes_len) m.selected = i;
        },
    }
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 20, .gap = 12 });

    cb.text("File tree");
    cb.divider();

    cb.pushScroll(.{
        .direction = .vertical,
        .padding = 0,
        .gap = 2,
        .flex = 1,
        .height = 400,
    });

    // Walk pre-order. `hide_below_depth` is the shallow-most collapsed
    // ancestor's depth + 1; any later node at depth ≥ this is filtered
    // out until we see a node at depth < this (we've exited the subtree).
    // By-pointer iteration matters: emitRow stores `node.label[..]` in a
    // Cmd, which outlives this frame's stack. Taking `node` by value
    // would dangle the slice the moment the loop iteration ended
    // (pitfall #1 in docs/pitfalls.md).
    var hide_below_depth: u8 = std.math.maxInt(u8);
    for (m.nodes[0..m.nodes_len], 0..) |*node, idx| {
        if (node.depth < hide_below_depth) hide_below_depth = std.math.maxInt(u8);
        if (node.depth >= hide_below_depth) continue;

        emitRow(cb, @intCast(idx), node);

        if (!node.is_leaf and !node.expanded) {
            hide_below_depth = node.depth + 1;
        }
    }

    cb.popScroll();
    cb.popGroup();
}

fn emitRow(cb: anytype, idx: u16, node: *const Node) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6 });

    // push_scroll with fixed width + no children acts as a spacer. No
    // dedicated spacer primitive today; a fixed-dim scroll is the
    // narrowest escape hatch.
    if (node.depth > 0) {
        cb.pushScroll(.{
            .direction = .horizontal,
            .width = INDENT_PER_LEVEL * @as(f32, @floatFromInt(node.depth)),
        });
        cb.popScroll();
    }

    if (!node.is_leaf) {
        const glyph: []const u8 = if (node.expanded) "v" else ">";
        cb.button(.{ .toggle = idx }, glyph);
    }

    cb.button(.{ .select = idx }, node.label[0..node.label_len]);

    cb.popGroup();
}

// ── Sample tree ────────────────────────────────────────────────────

const SampleEntry = struct { depth: u8, label: []const u8, expanded: bool = true };

const sample_tree = [_]SampleEntry{
    .{ .depth = 0, .label = "src" },
    .{ .depth = 1, .label = "core", .expanded = true },
    .{ .depth = 2, .label = "cmd.zig" },
    .{ .depth = 2, .label = "component.zig" },
    .{ .depth = 2, .label = "transient.zig" },
    .{ .depth = 1, .label = "layout" },
    .{ .depth = 2, .label = "engine.zig" },
    .{ .depth = 1, .label = "input", .expanded = false },
    .{ .depth = 2, .label = "focus.zig" },
    .{ .depth = 2, .label = "hit_test.zig" },
    .{ .depth = 2, .label = "keys.zig" },
    .{ .depth = 1, .label = "platform" },
    .{ .depth = 2, .label = "host.zig" },
    .{ .depth = 2, .label = "win32.zig" },
    .{ .depth = 2, .label = "wasm.zig" },
    .{ .depth = 1, .label = "gpu", .expanded = false },
    .{ .depth = 2, .label = "context.zig" },
    .{ .depth = 2, .label = "native.zig" },
    .{ .depth = 2, .label = "web.zig" },
    .{ .depth = 0, .label = "examples" },
    .{ .depth = 1, .label = "counter_greeter" },
    .{ .depth = 1, .label = "todo" },
    .{ .depth = 1, .label = "tree" },
    .{ .depth = 0, .label = "docs" },
    .{ .depth = 1, .label = "HARDLINE.md" },
    .{ .depth = 1, .label = "features" },
    .{ .depth = 1, .label = "pitfalls.md" },
};

// Tree has no text input → no key translation. Host loop still calls
// these; they return null.
pub fn keyCharMsg(_: *const Model, _: u8) ?Msg {
    return null;
}

pub fn keySpecialMsg(_: *const Model, _: teak.SpecialKey) ?Msg {
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "init loads the sample tree with correct leaf flags" {
    const t = std.testing;
    const m = Model.init();
    try t.expect(m.nodes_len == sample_tree.len);

    // "src" has children → not a leaf.
    try t.expect(!m.nodes[0].is_leaf);
    // "cmd.zig" at depth 2 under src/core → leaf.
    try t.expect(m.nodes[2].is_leaf);
    // "input" is collapsed in the sample data.
    try t.expect(!m.nodes[7].expanded);
}

test "view hides descendants of a collapsed node" {
    const t = std.testing;
    const m = Model.init();

    var cb = teak.CmdBuffer(Msg).init(t.allocator);
    defer cb.deinit();
    view(&m, &cb);

    // "input" is collapsed; its children focus/hit/keys should not appear.
    var found_input = false;
    var found_focus = false;
    for (cb.cmds.items) |c| {
        if (c == .button) {
            if (std.mem.eql(u8, c.button.label, "input")) found_input = true;
            if (std.mem.eql(u8, c.button.label, "focus.zig")) found_focus = true;
        }
    }
    try t.expect(found_input);
    try t.expect(!found_focus);
}

test "toggle expand flips visibility of direct children" {
    const t = std.testing;
    var m = Model.init();

    // Locate "input" (depth=1, collapsed by default) at some index.
    var input_idx: ?u16 = null;
    for (m.nodes[0..m.nodes_len], 0..) |node, i| {
        if (std.mem.eql(u8, node.label[0..node.label_len], "input")) {
            input_idx = @intCast(i);
            break;
        }
    }
    try t.expect(input_idx != null);

    update(&m, .{ .toggle = input_idx.? });
    try t.expect(m.nodes[input_idx.?].expanded);

    var cb = teak.CmdBuffer(Msg).init(t.allocator);
    defer cb.deinit();
    view(&m, &cb);

    var found_focus = false;
    for (cb.cmds.items) |c| {
        if (c == .button and std.mem.eql(u8, c.button.label, "focus.zig")) {
            found_focus = true;
        }
    }
    try t.expect(found_focus);
}

test "collapse of an outer subtree hides all nested descendants, not just direct" {
    const t = std.testing;
    var m = Model.init();

    // "src" is node 0; collapse it → everything indented under it must go.
    update(&m, .{ .toggle = 0 });

    var cb = teak.CmdBuffer(Msg).init(t.allocator);
    defer cb.deinit();
    view(&m, &cb);

    var found_cmd = false;
    var found_examples = false;
    for (cb.cmds.items) |c| {
        if (c == .button) {
            if (std.mem.eql(u8, c.button.label, "cmd.zig")) found_cmd = true;
            if (std.mem.eql(u8, c.button.label, "examples")) found_examples = true;
        }
    }
    try t.expect(!found_cmd); // src's grandchildren hidden
    try t.expect(found_examples); // sibling of src still visible
}

test "end-to-end: click the collapsed 'input' row's chevron expands it" {
    const t = std.testing;
    var m = Model.init();

    var cb = teak.CmdBuffer(Msg).init(t.allocator);
    defer cb.deinit();
    view(&m, &cb);

    var rects: [512]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 700, 500);

    // Find the ">" button (the collapsed chevron).
    var chevron_rect: ?teak.Rect = null;
    for (cb.cmds.items, 0..) |c, i| {
        if (c == .button and std.mem.eql(u8, c.button.label, ">")) {
            chevron_rect = rects[i];
            break;
        }
    }
    try t.expect(chevron_rect != null);

    const r = chevron_rect.?;
    const hit = teak.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], r.x + 2, r.y + 2);
    try t.expect(hit != null);
    update(&m, hit.?.msg);

    // The first collapsed node in sample_tree is "input" → verify it's
    // now expanded.
    var input_idx: ?u16 = null;
    for (m.nodes[0..m.nodes_len], 0..) |node, i| {
        if (std.mem.eql(u8, node.label[0..node.label_len], "input")) {
            input_idx = @intCast(i);
            break;
        }
    }
    try t.expect(input_idx != null);
    try t.expect(m.nodes[input_idx.?].expanded);
}
