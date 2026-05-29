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
    /// Modal/popup overlay. Screen readers should announce focus
    /// trapping here when present.
    overlay,
};

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

    // Pass 1 (overlay): collect overlay-layer nodes and remember
    // whether any modal overlay is present in this frame. The result
    // gates pass 2.
    const modal_present = try collectLayer(arena, &out, cmds, rects, focus_index, .overlay);

    // Pass 2 (base): collect base-layer nodes, but only if no modal
    // overlay was open. A modal overlay occludes the base layer for
    // input — a11y mirrors that so a screen reader doesn't announce
    // widgets the user can't actually interact with.
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

    for (cmds, 0..) |c, i| {
        const cur_clip = clip.top();
        const in_overlay = overlay_depth > 0;
        const visible_to_layer = switch (layer) {
            .base => !in_overlay,
            .overlay => in_overlay,
        };

        // Container handling: maintain the clip stack + overlay-depth
        // counter, and emit the container's own node when its layer
        // matches the current pass. Mirrors `hitTestLayer` exactly.
        switch (c) {
            .push_scroll => {
                clip.push(clipRect(rects[i], cur_clip));
                if (visible_to_layer) {
                    const b = clipRect(rects[i], cur_clip);
                    if (hasArea(b)) {
                        try out.append(arena, .{
                            .role = .scroll,
                            .cmd_index = @intCast(i),
                            .bounds = b,
                        });
                    }
                }
                continue;
            },
            .pop_scroll => {
                clip.pop();
                continue;
            },
            .push_overlay => |ov| {
                // The overlay's own bounds, clipped by its parent (so
                // a modal nested in a scrolled-away parent gets zero
                // area — same rule hit_test uses).
                const ov_bounds = clipRect(rects[i], cur_clip);
                overlay_depth += 1;
                // The overlay establishes its own clip for contents.
                clip.push(ov_bounds);
                // The overlay node + its modal flag belong to the
                // .overlay pass; we only record / count there.
                if (layer == .overlay and hasArea(ov_bounds)) {
                    try out.append(arena, .{
                        .role = .overlay,
                        .cmd_index = @intCast(i),
                        .bounds = ov_bounds,
                    });
                    if (ov.modal) modal_present = true;
                }
                continue;
            },
            .pop_overlay => {
                overlay_depth -= 1;
                clip.pop();
                continue;
            },
            .push_group => {
                if (visible_to_layer) {
                    const b = clipRect(rects[i], cur_clip);
                    if (hasArea(b)) {
                        try out.append(arena, .{
                            .role = .group,
                            .cmd_index = @intCast(i),
                            .bounds = b,
                        });
                    }
                }
                continue;
            },
            .pop_group, .push_virtual_list, .pop_virtual_list => continue,
            else => {},
        }

        if (!visible_to_layer) continue;

        const b = clipRect(rects[i], cur_clip);
        if (!hasArea(b)) continue;

        const node: ?A11yNode = switch (c) {
            .text => |txt| .{
                .role = .text,
                .cmd_index = @intCast(i),
                .bounds = b,
                .label = txt.content,
            },
            .rich_text => |rt| .{
                .role = .rich_text,
                .cmd_index = @intCast(i),
                .bounds = b,
                .label = rt.content,
            },
            .button => |btn| .{
                .role = .button,
                .cmd_index = @intCast(i),
                .bounds = b,
                .label = btn.label,
                .focused = if (focus_index) |fi| fi == i else false,
                .disabled = btn.disabled,
            },
            .text_input => |ti| .{
                .role = .text_input,
                .cmd_index = @intCast(i),
                .bounds = b,
                .label = ti.content,
                .focused = if (focus_index) |fi| fi == i else false,
                .disabled = ti.disabled,
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
                .focused = if (focus_index) |fi| fi == i else false,
            },
            .divider => .{ .role = .divider, .cmd_index = @intCast(i), .bounds = b },
            .image => .{ .role = .image, .cmd_index = @intCast(i), .bounds = b },
            // Containers handled above; pop_* + virtual_list never
            // emit leaves.
            else => null,
        };
        if (node) |n| try out.append(arena, n);
    }

    return modal_present;
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd_mod = @import("../core/cmd.zig");
const text_mod = @import("../core/text.zig");

test "buildTree: emits one node per interactive widget + container" {
    const testing = std.testing;
    const Msg = union(enum) { inc, focus_input };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical });
    cb.text("Title");
    cb.button(.inc, "+");
    cb.textInput(.focus_input, "hello", 5);
    cb.checkbox(.inc, true, "agree");
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try buildTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], 3);

    // group + text + button + text_input + checkbox = 5 nodes (pop_group is skipped).
    try testing.expectEqual(@as(usize, 5), tree.len);

    try testing.expectEqual(Role.group, tree[0].role);
    try testing.expectEqual(Role.text, tree[1].role);
    try testing.expectEqualStrings("Title", tree[1].label);
    try testing.expectEqual(Role.button, tree[2].role);
    try testing.expectEqualStrings("+", tree[2].label);
    try testing.expectEqual(Role.text_input, tree[3].role);
    try testing.expectEqualStrings("hello", tree[3].label);
    try testing.expect(tree[3].focused); // focus_index == 3
    try testing.expectEqual(Role.checkbox, tree[4].role);
    try testing.expectEqualStrings("agree", tree[4].label);
    try testing.expectEqual(@as(f32, 1), tree[4].state);
    // Enabled button/input default `.disabled` to false.
    try testing.expect(!tree[2].disabled);
    try testing.expect(!tree[3].disabled);
}

test "buildTree: disabled button/input produce nodes with .disabled true" {
    const testing = std.testing;
    const Msg = union(enum) { add, focus };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.buttonDisabled(.add, "Add point load");
    cb.textInputDisabled(.focus, "locked", 0);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try buildTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], null);
    // group + button + text_input = 3 nodes.
    try testing.expectEqual(@as(usize, 3), tree.len);
    try testing.expectEqual(Role.button, tree[1].role);
    try testing.expect(tree[1].disabled);
    try testing.expectEqual(Role.text_input, tree[2].role);
    try testing.expect(tree[2].disabled);
}

test "buildTree: overlay nodes appear with overlay role" {
    const testing = std.testing;
    const Msg = union(enum) { close };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushOverlay(.{ .x = 0, .y = 0, .width = 200, .height = 100 });
    cb.button(.close, "X");
    cb.popOverlay();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try buildTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], null);

    try testing.expectEqual(@as(usize, 2), tree.len);
    try testing.expectEqual(Role.overlay, tree[0].role);
    try testing.expectEqual(Role.button, tree[1].role);
}

// ── Clip + occlusion (mirrors hit_test.zig semantics) ──────────────

test "buildTree: button scrolled outside its viewport is omitted" {
    const testing = std.testing;
    const Msg = union(enum) { pick };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Wrap in a root group so the inner scroll keeps its declared
    // 100x100 viewport (top-level containers get expanded to fill
    // the window by doLayout, which would defeat the clip test).
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.pushScroll(.{
        .direction = .vertical,
        .padding = 0,
        .gap = 0,
        .width = 100,
        .height = 100,
        .scroll_y = 0,
    });
    cb.button(.pick, "A"); // y ∈ [0, 36) — visible
    cb.button(.pick, "B"); // y ∈ [36, 72) — visible
    cb.button(.pick, "C"); // y ∈ [72, 108) — partially clipped at y=100
    cb.button(.pick, "D"); // y ∈ [108, 144) — fully outside
    cb.popScroll();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try buildTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], null);

    // Button D (y starts ≥ 108) is fully outside the y=100 viewport
    // → zero-area clipped bounds → omitted. Other buttons survive
    // (possibly with clipped bounds for C).
    var d_found = false;
    var any_button = false;
    for (tree) |n| {
        if (n.role != .button) continue;
        any_button = true;
        if (std.mem.eql(u8, n.label, "D")) d_found = true;
        // Surviving buttons all have positive area and lie inside
        // the scroll viewport.
        try testing.expect(n.bounds.w > 0 and n.bounds.h > 0);
        try testing.expect(n.bounds.y < 100);
    }
    try testing.expect(any_button);
    try testing.expect(!d_found);
}

test "buildTree: base-layer node is suppressed under an open modal overlay" {
    const testing = std.testing;
    const Msg = union(enum) { base_click, close };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Base button + modal overlay. The base button must NOT appear in
    // the tree — a screen reader should not announce widgets occluded
    // by a modal, same as how hitTest refuses to dispatch clicks to
    // them.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Underneath");
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 200,
        .padding = 0,
        .modal = true,
        .backdrop_msg = .close,
    });
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try buildTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], null);

    // No base button. The overlay node itself is present (so a screen
    // reader can announce "dialog opened"); the base group + button
    // are both dropped since modal occlusion suppresses the whole
    // base layer.
    var saw_underneath = false;
    var saw_overlay = false;
    for (tree) |n| {
        if (n.role == .button and std.mem.eql(u8, n.label, "Underneath")) saw_underneath = true;
        if (n.role == .overlay) saw_overlay = true;
    }
    try testing.expect(!saw_underneath);
    try testing.expect(saw_overlay);
}

test "buildTree: button inside modal overlay is emitted" {
    const testing = std.testing;
    const Msg = union(enum) { dismiss, close };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 200,
        .padding = 16,
        .modal = true,
        .backdrop_msg = .dismiss,
    });
    cb.button(.close, "Close");
    cb.popOverlay();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try buildTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], null);

    // overlay + button = 2 nodes.
    try testing.expectEqual(@as(usize, 2), tree.len);
    try testing.expectEqual(Role.overlay, tree[0].role);
    try testing.expectEqual(Role.button, tree[1].role);
    try testing.expectEqualStrings("Close", tree[1].label);
}

test "buildTree: non-modal overlay does NOT suppress base-layer nodes" {
    const testing = std.testing;
    const Msg = union(enum) { base_click };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Non-modal overlay (tooltip / debug overlay). The base button
    // remains interactable, so it must remain announceable.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Underneath");
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 200,
        .padding = 0,
        // modal defaults to false; no backdrop_msg.
    });
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const tree = try buildTree(arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], null);

    var saw_base_button = false;
    var saw_overlay = false;
    for (tree) |n| {
        if (n.role == .button and std.mem.eql(u8, n.label, "Underneath")) saw_base_button = true;
        if (n.role == .overlay) saw_overlay = true;
    }
    try testing.expect(saw_base_button);
    try testing.expect(saw_overlay);
}
