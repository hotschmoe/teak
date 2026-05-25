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
//! Mirrors the pass-over-flat-buffer shape of hit_test.zig.
//!
//! HARDLINE compliance: pure function of `[]Cmd` + `[]Rect`. No host
//! imports. The publish-to-platform half lives in `Host.publishA11yTree`
//! (validateHost surface extension), called by the app once per frame.

const std = @import("std");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;

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
    /// Visible bounds in window coordinates.
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
};

/// Build a flat list of A11yNodes for the given frame. Allocates the
/// output slice from `arena`; caller's per-frame arena reset frees it
/// in bulk along with everything else.
///
/// `focus_index` is the (optional) cmd index of the currently focused
/// element — typically the same value the renderer takes via
/// TransientState.focus_index, so the a11y tree agrees with the
/// rendered focus ring.
pub fn buildTree(
    arena: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    focus_index: ?usize,
) ![]A11yNode {
    var out: std.ArrayList(A11yNode) = .empty;
    errdefer out.deinit(arena);

    for (cmds, 0..) |c, i| {
        const node: ?A11yNode = switch (c) {
            .push_group => .{ .role = .group, .cmd_index = @intCast(i), .bounds = rects[i] },
            .push_scroll => .{ .role = .scroll, .cmd_index = @intCast(i), .bounds = rects[i] },
            .push_overlay => .{ .role = .overlay, .cmd_index = @intCast(i), .bounds = rects[i] },
            .pop_group, .pop_scroll, .pop_overlay, .push_virtual_list, .pop_virtual_list => null,
            .text => |txt| .{
                .role = .text,
                .cmd_index = @intCast(i),
                .bounds = rects[i],
                .label = txt.content,
            },
            .rich_text => |rt| .{
                .role = .rich_text,
                .cmd_index = @intCast(i),
                .bounds = rects[i],
                .label = rt.content,
            },
            .button => |btn| .{
                .role = .button,
                .cmd_index = @intCast(i),
                .bounds = rects[i],
                .label = btn.label,
                .focused = if (focus_index) |fi| fi == i else false,
            },
            .text_input => |ti| .{
                .role = .text_input,
                .cmd_index = @intCast(i),
                .bounds = rects[i],
                .label = ti.content,
                .focused = if (focus_index) |fi| fi == i else false,
            },
            .checkbox => |cb| .{
                .role = .checkbox,
                .cmd_index = @intCast(i),
                .bounds = rects[i],
                .label = cb.label,
                .state = if (cb.checked) 1 else 0,
            },
            .radio => |rd| .{
                .role = .radio,
                .cmd_index = @intCast(i),
                .bounds = rects[i],
                .label = rd.label,
                .state = if (rd.selected) 1 else 0,
            },
            .slider => |sl| .{
                .role = .slider,
                .cmd_index = @intCast(i),
                .bounds = rects[i],
                .state = sl.value,
                .focused = if (focus_index) |fi| fi == i else false,
            },
            .divider => .{ .role = .divider, .cmd_index = @intCast(i), .bounds = rects[i] },
            .image => .{ .role = .image, .cmd_index = @intCast(i), .bounds = rects[i] },
        };
        if (node) |n| try out.append(arena, n);
    }

    return out.toOwnedSlice(arena);
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
