//! Accessibility tree builder.
//!
//! Walks `[]Cmd` + `[]Rect` (the same flat-buffer arrays every other
//! pass consumes) and produces an `[]A11yNode` snapshot — a flat list
//! of (role, label, bounds, focused) records the host can hand to
//! whatever platform a11y API is available (UI Automation on Windows,
//! AT-SPI on Linux, WAI-ARIA-mirrored DOM on web, etc).
//!
//! Lives in `src/input/` rather than `src/render/` because it's
//! semantic, not visual: a screen reader cares that this rect is a
//! button labeled "Save", not that it draws as a beveled colored quad.
//! Mirrors the pass-over-flat-buffer shape of hit_test.zig — including
//! its scroll-clip + modal-occlusion semantics, so screen-reader
//! visibility matches mouse-input visibility.
//!
//! HARDLINE compliance: pure function of `[]Cmd` + `[]Rect`. No host
//! imports. The publish-to-platform half lives in `Host.publishA11yTree`
//! (validateHost surface extension), called by the app once per frame.

const std = @import("std");
const cmd_types = @import("../core/cmd.zig");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;
const ClipStack = layout.ClipStack;
const clipRect = layout.clipRect;

/// Which layer a buildTree pass is collecting from. Mirrors the
/// `Layer` enum in `hit_test.zig` so a11y semantics match mouse
/// semantics: base widgets and overlay widgets are filtered
/// separately, and a modal overlay occludes base-layer leaves the
/// same way it consumes their clicks.
const Layer = enum { base, overlay };

/// True if the rect has any visible area. Zero-or-negative-area rects
/// are produced by `clipRect` when the input is fully clipped out, so
/// skipping them filters scrolled-out-of-viewport widgets cleanly.
fn hasArea(r: Rect) bool {
    return r.w > 0 and r.h > 0;
}

/// Semantic role of a UI element. Mirrors the subset of WAI-ARIA roles
/// that map cleanly onto Teak's Cmd variants. New widget = new role.
pub const Role = enum {
    /// Logical grouping container (push_group, push_overlay).
    group,
    /// Scrollable region (push_scroll).
    scroll,
    /// Static text label.
    text,
    /// Mixed-style static text. Same accessibility role as `text`;
    /// distinguished so screen readers / inspectors can show that
    /// formatting is present even if they ignore it.
    rich_text,
    /// Clickable action.
    button,
    /// Editable single-line text field.
    text_input,
    /// Editable multi-line text.
    text_area,
    /// Two-state toggle.
    checkbox,
    /// Member of a single-select radio group.
    radio,
    /// Continuous range input.
    slider,
    /// Visual separator (rendered, but a11y-irrelevant — exposed for
    /// completeness; screen readers typically skip).
    divider,
    /// Image, possibly decorative.
    image,
    /// Custom 2D drawing surface (chart / plot). Announced by its label;
    /// its primitives are not individually exposed.
    canvas,
    /// Modal/popup overlay. Screen readers should announce focus
    /// trapping here when present.
    overlay,
    list,
    listitem,
    listbox,
    option,
    combobox,
    tablist,
    tab,
    tree,
    treeitem,
    table,
    row,
    columnheader,
    cell,
    menu,
    menubar,
    menuitem,
    toolbar,
    dialog,
    status,
    alert,
    progressbar,
    heading,
    link,
};

/// What assistive technology can ask of the UI. Each becomes ordinary input in
/// the run loop (a click at the node, its focus Msg, typed keys), never a
/// second mutation path: the app's `update` still sees plain Msgs.
pub const ActionKind = enum {
    /// Activate (screen-reader "click" / UIA Invoke): clicks the node.
    activate,
    /// Move keyboard focus to the node (its focus Msg).
    focus,
    /// Replace an editable node's text: focus, Ctrl+A, then `text` as typed characters.
    set_value,
    /// Slider: one step up / down (Right / Left keys after focusing).
    increment,
    decrement,
};

/// One request from assistive technology. `cmd_index` names a node of the tree
/// last published (`A11yNode.cmd_index`); `text` is valid until the Host's
/// next `pollA11yActions`.
pub const Action = struct {
    kind: ActionKind,
    cmd_index: u32,
    text: []const u8 = "",
};

/// `A11yNode.parent` of a root node.
pub const NO_PARENT: u32 = std.math.maxInt(u32);

fn semanticRole(s: cmd_types.A11ySemantic) ?Role {
    return switch (s) {
        .none => null,
        .list => .list,
        .listitem => .listitem,
        .listbox => .listbox,
        .option => .option,
        .combobox => .combobox,
        .tablist => .tablist,
        .tab => .tab,
        .tree => .tree,
        .treeitem => .treeitem,
        .table => .table,
        .row => .row,
        .columnheader => .columnheader,
        .cell => .cell,
        .menu => .menu,
        .menubar => .menubar,
        .menuitem => .menuitem,
        .toolbar => .toolbar,
        .dialog => .dialog,
        .status => .status,
        .alert => .alert,
        .progressbar => .progressbar,
        .heading => .heading,
        .link => .link,
    };
}

/// Fold an `A11yHint` into a node (role override, name, state, live region).
fn applyHint(n: *A11yNode, h: cmd_types.A11yHint) void {
    if (semanticRole(h.semantic)) |r| n.role = r;
    if (h.label.len > 0) n.label = h.label;
    n.selected = h.selected;
    n.expanded = h.expanded;
    n.level = h.level;
    n.live = h.live;
    if (h.semantic == .progressbar) n.state = h.value;
}

pub const A11yNode = struct {
    role: Role,
    /// Index of the originating Cmd in the buffer. Stable within a
    /// frame; lets host integration correlate back to the buffer.
    cmd_index: u32,
    /// Visible bounds in window coordinates. Already intersected with
    /// the surrounding scroll-clip stack — a widget scrolled out of
    /// its viewport never reaches the tree, and a partially-clipped
    /// one reports only its visible portion.
    bounds: Rect,
    /// Optional label/value text. Points into Cmd-owned memory
    /// (arena-allocated, valid for the frame). Empty string when not
    /// applicable.
    label: []const u8 = "",
    /// True if this node is the currently focused element (matches
    /// TransientState.focus_index from the host loop).
    focused: bool = false,
    /// For checkbox / radio: checked-or-selected state.
    /// For slider: normalized [0, 1] value packed in.
    /// Ignored for other roles.
    state: f32 = 0,
    /// Whether the widget is disabled (greyed-out, non-interactive).
    /// Only set for button / text_input; defaults false for all other
    /// roles.
    disabled: bool = false,
    /// Index (in the tree slice) of the nearest enclosing emitted container,
    /// or `NO_PARENT`. Parents always precede children.
    parent: u32 = NO_PARENT,
    /// Editable text content (`text_input`), what AT reads as the control's value.
    value: []const u8 = "",
    /// Byte offsets of the selection inside `value` (equal = caret only).
    sel_start: u32 = 0,
    sel_end: u32 = 0,
    /// Selected / current item (tab, option, tree item, row, menu item).
    selected: bool = false,
    /// Expandable items: open (true) / closed (false); null = not expandable.
    expanded: ?bool = null,
    /// Heading level / tree depth (0 = unspecified).
    level: u8 = 0,
    /// Live region: AT announces changes inside.
    live: cmd_types.A11yLive = .off,
    /// Modal overlay (a dialog that traps focus).
    modal: bool = false,
};

/// Build a flat list of A11yNodes for the given frame. Allocates the
/// output slice from `arena`; caller's per-frame arena reset frees it
/// in bulk along with everything else.
///
/// `focus_index` is the (optional) cmd index of the currently focused
/// element — typically the same value the renderer takes via
/// TransientState.focus_index, so the a11y tree agrees with the
/// rendered focus ring.
///
/// Mirrors `hit_test.zig`'s two-pass-by-layer structure so screen-
/// reader visibility tracks mouse-input visibility: scroll-clipped
/// nodes are emitted with their clipped bounds (and dropped if fully
/// clipped to zero area), and base-layer nodes are suppressed when a
/// modal overlay is open. Non-modal overlays (tooltips, debug
/// overlays) do NOT suppress the base layer — same rule hit_test uses.
pub fn buildTree(
    arena: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    focus_index: ?usize,
) ![]A11yNode {
    var out: std.ArrayList(A11yNode) = .empty;
    errdefer out.deinit(arena);

    const modal_present = try collectLayer(arena, &out, cmds, rects, focus_index, .overlay);

    // Modal overlays suppress inaccessible base-layer nodes.
    if (!modal_present) {
        _ = try collectLayer(arena, &out, cmds, rects, focus_index, .base);
    }

    return out.toOwnedSlice(arena);
}

/// Walk cmds for a single layer, appending visible nodes to `out`.
/// Returns true if any modal overlay was encountered with non-empty
/// clipped bounds (used by the caller to gate the base-layer pass).
/// A modal nested under a scrolled-away parent has empty clipped
/// bounds and therefore does NOT occlude the base layer — same rule
/// `hit_test` uses to decide whether the modal can claim a click.
fn collectLayer(
    arena: std.mem.Allocator,
    out: *std.ArrayList(A11yNode),
    cmds: anytype,
    rects: []const Rect,
    focus_index: ?usize,
    layer: Layer,
) !bool {
    var clip: ClipStack = .{};
    var overlay_depth: u32 = 0;
    var modal_present: bool = false;
    var parents: [64]u32 = undefined;
    var plen: usize = 0;

    for (cmds, 0..) |c, i| {
        const cur_clip = clip.top();
        const in_overlay = overlay_depth > 0;
        const visible_to_layer = switch (layer) {
            .base => !in_overlay,
            .overlay => in_overlay,
        };
        const parent: u32 = if (plen > 0) parents[plen - 1] else NO_PARENT;

        switch (c) {
            .push_scroll => |sc| {
                clip.push(clipRect(rects[i], cur_clip));
                var my_parent = parent;
                if (visible_to_layer) {
                    const b = clipRect(rects[i], cur_clip);
                    if (hasArea(b)) {
                        var n: A11yNode = .{ .role = .scroll, .cmd_index = @intCast(i), .bounds = b, .parent = parent };
                        applyHint(&n, sc.a11y);
                        my_parent = @intCast(out.items.len);
                        try out.append(arena, n);
                    }
                }
                parents[plen] = my_parent;
                plen += 1;
                continue;
            },
            .pop_scroll => {
                clip.pop();
                plen -= 1;
                continue;
            },
            .push_overlay => |ov| {
                const ov_bounds = clipRect(rects[i], cur_clip);
                overlay_depth += 1;
                clip.push(ov_bounds);
                var my_parent = parent;
                if (layer == .overlay and hasArea(ov_bounds)) {
                    my_parent = @intCast(out.items.len);
                    try out.append(arena, .{
                        .role = .overlay,
                        .cmd_index = @intCast(i),
                        .bounds = ov_bounds,
                        .parent = parent,
                        .modal = ov.modal,
                    });
                    if (ov.modal) modal_present = true;
                }
                parents[plen] = my_parent;
                plen += 1;
                continue;
            },
            .pop_overlay => {
                overlay_depth -= 1;
                clip.pop();
                plen -= 1;
                continue;
            },
            .push_group => |g| {
                var my_parent = parent;
                if (visible_to_layer) {
                    const b = clipRect(rects[i], cur_clip);
                    if (hasArea(b)) {
                        var n: A11yNode = .{ .role = .group, .cmd_index = @intCast(i), .bounds = b, .parent = parent };
                        applyHint(&n, g.a11y);
                        my_parent = @intCast(out.items.len);
                        try out.append(arena, n);
                    }
                }
                parents[plen] = my_parent;
                plen += 1;
                continue;
            },
            .push_grid => |g| {
                var my_parent = parent;
                if (visible_to_layer) {
                    const b = clipRect(rects[i], cur_clip);
                    if (hasArea(b)) {
                        var n: A11yNode = .{ .role = .group, .cmd_index = @intCast(i), .bounds = b, .parent = parent };
                        applyHint(&n, g.a11y);
                        my_parent = @intCast(out.items.len);
                        try out.append(arena, n);
                    }
                }
                parents[plen] = my_parent;
                plen += 1;
                continue;
            },
            .pop_group, .pop_grid => {
                plen -= 1;
                continue;
            },
            .push_virtual_list, .pop_virtual_list => continue,
            .text, .rich_text, .image, .divider, .button, .text_input, .text_area, .checkbox, .radio, .slider, .canvas, .scene3d => {},
        }

        if (!visible_to_layer) continue;

        const b = clipRect(rects[i], cur_clip);
        if (!hasArea(b)) continue;

        const focused = if (focus_index) |fi| fi == i else false;
        var node: ?A11yNode = switch (c) {
            .text => |txt| .{ .role = .text, .cmd_index = @intCast(i), .bounds = b, .label = txt.content },
            .rich_text => |rt| .{ .role = .rich_text, .cmd_index = @intCast(i), .bounds = b, .label = rt.content },
            .button => |btn| blk: {
                var n: A11yNode = .{
                    .role = .button,
                    .cmd_index = @intCast(i),
                    .bounds = b,
                    .label = btn.label,
                    .focused = focused,
                    .disabled = btn.disabled,
                };
                applyHint(&n, btn.a11y);
                break :blk n;
            },
            .text_input => |ti| blk: {
                const lo: u32 = @intCast(@min(ti.cursor, ti.selection_anchor orelse ti.cursor));
                const hi: u32 = @intCast(@max(ti.cursor, ti.selection_anchor orelse ti.cursor));
                break :blk .{
                    .role = .text_input,
                    .cmd_index = @intCast(i),
                    .bounds = b,
                    .label = ti.a11y_label,
                    .value = ti.content,
                    .sel_start = lo,
                    .sel_end = hi,
                    .focused = focused,
                    .disabled = ti.disabled,
                };
            },
            .text_area => |ta| .{
                .role = .text_area,
                .cmd_index = @intCast(i),
                .bounds = b,
                .label = ta.content,
                .focused = if (focus_index) |fi| fi == i else false,
                .disabled = ta.disabled,
            },
            .checkbox => |cb| .{
                .role = .checkbox,
                .cmd_index = @intCast(i),
                .bounds = b,
                .label = cb.label,
                .state = if (cb.checked) 1 else 0,
            },
            .radio => |rd| .{
                .role = .radio,
                .cmd_index = @intCast(i),
                .bounds = b,
                .label = rd.label,
                .state = if (rd.selected) 1 else 0,
            },
            .slider => |sl| .{
                .role = .slider,
                .cmd_index = @intCast(i),
                .bounds = b,
                .state = sl.value,
                .focused = focused,
            },
            .divider => .{ .role = .divider, .cmd_index = @intCast(i), .bounds = b },
            .image => .{ .role = .image, .cmd_index = @intCast(i), .bounds = b },
            .canvas => |cv| .{ .role = .canvas, .cmd_index = @intCast(i), .bounds = b, .label = cv.label },
            .scene3d => |sc| .{ .role = .image, .cmd_index = @intCast(i), .bounds = b, .label = sc.label },
            .push_group, .push_grid, .pop_group, .pop_grid, .push_scroll, .pop_scroll, .push_overlay, .pop_overlay, .push_virtual_list, .pop_virtual_list => null,
        };
        if (node) |*n| {
            n.parent = parent;
            try out.append(arena, n.*);
        }
    }

    return modal_present;
}

/// An owned copy of the last tree handed to the platform, so the run loop can
/// publish only when something changed. (The per-frame tree lives in a frame
/// arena that is recycled two frames later, so it cannot be kept by reference.)
pub const TreeCache = struct {
    nodes: std.ArrayList(A11yNode) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    /// False until the first `store`: the first tree always counts as changed.
    valid: bool = false,

    pub fn deinit(self: *TreeCache, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
        self.bytes.deinit(gpa);
        self.* = .{};
    }

    /// True when `tree` is identical (fields and string contents) to the cache.
    pub fn same(self: *const TreeCache, tree: []const A11yNode) bool {
        if (!self.valid or self.nodes.items.len != tree.len) return false;
        for (self.nodes.items, tree) |a, b| if (!nodeEql(a, b)) return false;
        return true;
    }

    /// Replace the cache with a deep copy of `tree`.
    pub fn store(self: *TreeCache, gpa: std.mem.Allocator, tree: []const A11yNode) std.mem.Allocator.Error!void {
        var total: usize = 0;
        for (tree) |n| total += n.label.len + n.value.len;
        self.bytes.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        try self.bytes.ensureTotalCapacity(gpa, total);
        try self.nodes.ensureTotalCapacity(gpa, tree.len);
        for (tree) |n| {
            var c = n;
            const lo = self.bytes.items.len;
            self.bytes.appendSliceAssumeCapacity(n.label);
            const vo = self.bytes.items.len;
            self.bytes.appendSliceAssumeCapacity(n.value);
            c.label = self.bytes.items[lo..vo];
            c.value = self.bytes.items[vo..];
            self.nodes.appendAssumeCapacity(c);
        }
        self.valid = true;
    }
};

fn nodeEql(a: A11yNode, b: A11yNode) bool {
    return a.role == b.role and a.cmd_index == b.cmd_index and std.meta.eql(a.bounds, b.bounds) and
        a.focused == b.focused and a.state == b.state and a.disabled == b.disabled and
        a.parent == b.parent and a.sel_start == b.sel_start and a.sel_end == b.sel_end and
        a.selected == b.selected and a.expanded == b.expanded and a.level == b.level and
        a.live == b.live and a.modal == b.modal and
        std.mem.eql(u8, a.label, b.label) and std.mem.eql(u8, a.value, b.value);
}


const cmd_mod = @import("../core/cmd.zig");
const text_mod = @import("../core/text.zig");












/// Fixed-capacity queue of assistive-technology requests that arrive on
/// another thread (UIA worker). The producer calls `push` under its own lock;
/// the run-loop thread calls `drain` (under the same lock), which moves the
/// requests into caller-owned storage so their `text` stays valid after the
/// queue is reused. Pure data: the Win32 provider owns the lock.
pub const ActionQueue = struct {
    pub const CAP = 32;
    pub const TEXT_CAP = 2048;

    const Entry = struct { kind: ActionKind, cmd_index: u32, text_off: u16, text_len: u16 };

    entries: [CAP]Entry = undefined,
    len: usize = 0,
    text: [TEXT_CAP]u8 = undefined,
    text_used: usize = 0,

    /// Queue a request. False when full or the text does not fit (dropped).
    pub fn push(self: *ActionQueue, kind: ActionKind, cmd_index: u32, text: []const u8) bool {
        if (self.len == CAP or self.text_used + text.len > TEXT_CAP) return false;
        @memcpy(self.text[self.text_used..][0..text.len], text);
        self.entries[self.len] = .{
            .kind = kind,
            .cmd_index = cmd_index,
            .text_off = @intCast(self.text_used),
            .text_len = @intCast(text.len),
        };
        self.len += 1;
        self.text_used += text.len;
        return true;
    }

    /// Move up to `out.len` requests into `out` (texts copied into `text_buf`,
    /// which must hold `TEXT_CAP` bytes); the rest stay queued. Returns the count.
    pub fn drain(self: *ActionQueue, out: []Action, text_buf: []u8) usize {
        var n: usize = 0;
        var used: usize = 0;
        while (n < self.len and n < out.len) : (n += 1) {
            const e = self.entries[n];
            const src = self.text[e.text_off..][0..e.text_len];
            if (used + src.len > text_buf.len) break;
            @memcpy(text_buf[used..][0..src.len], src);
            out[n] = .{ .kind = e.kind, .cmd_index = e.cmd_index, .text = text_buf[used..][0..src.len] };
            used += src.len;
        }
        // Text offsets remain valid until the queue empties.
        const rest = self.len - n;
        std.mem.copyForwards(Entry, self.entries[0..rest], self.entries[n..self.len]);
        self.len = rest;
        if (rest == 0) self.text_used = 0;
        return n;
    }
};


