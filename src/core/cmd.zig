const std = @import("std");
const text = @import("text.zig");
const theme_mod = @import("theme.zig");

pub const FontSpec = text.FontSpec;
const DEFAULT_FONT = text.DEFAULT_FONT;
const TextureHandle = text.TextureHandle;

// ── Shared (Msg-independent) types ─────────────────────────────────

pub const Direction = enum { vertical, horizontal };

pub const GroupStyle = struct {
    direction: Direction = .vertical,
    padding: f32 = 8,
    gap: f32 = 8,
    /// 0 = intrinsic (measured from children). >0 = flex weight; parent
    /// distributes remaining main-axis space proportionally.
    flex: f32 = 0,
};

pub const TextCmd = struct {
    content: []const u8,
    font: FontSpec = DEFAULT_FONT,
    /// Foreground color for the rendered glyphs. Default is light grey
    /// suitable for the dark scene bg that examples currently use.
    color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
};

pub const ButtonStyle = struct {
    bg: [4]f32 = .{ 0.25, 0.25, 0.25, 1.0 },
    hover_bg: [4]f32 = .{ 0.35, 0.35, 0.35, 1.0 },
    press_bg: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    corner_radius: f32 = 4,
};

pub const TextInputStyle = struct {
    bg: [4]f32 = .{ 0.12, 0.12, 0.14, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    border: [4]f32 = .{ 0.35, 0.35, 0.4, 1.0 },
    focus_border: [4]f32 = .{ 0.3, 0.5, 1.0, 1.0 },
    cursor: [4]f32 = .{ 0.9, 0.9, 1.0, 1.0 },
    corner_radius: f32 = 4,
    /// Text inputs expand along the main axis by default.
    flex: f32 = 1,
    /// Minimum width when flex is 0 or parent has no extra space.
    min_width: f32 = 120,
};

pub const CheckboxStyle = struct {
    box_bg: [4]f32 = .{ 0.12, 0.12, 0.14, 1.0 },
    box_border: [4]f32 = .{ 0.35, 0.35, 0.4, 1.0 },
    check: [4]f32 = .{ 0.3, 0.7, 1.0, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    /// Outer square edge length.
    size: f32 = 18,
    /// Gap between the box and the label.
    label_gap: f32 = 8,
};

pub const RadioStyle = struct {
    box_bg: [4]f32 = .{ 0.12, 0.12, 0.14, 1.0 },
    box_border: [4]f32 = .{ 0.35, 0.35, 0.4, 1.0 },
    dot: [4]f32 = .{ 0.3, 0.7, 1.0, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    size: f32 = 18,
    label_gap: f32 = 8,
};

pub const SliderStyle = struct {
    track_bg: [4]f32 = .{ 0.18, 0.18, 0.22, 1.0 },
    track_fill: [4]f32 = .{ 0.3, 0.5, 1.0, 1.0 },
    thumb: [4]f32 = .{ 0.85, 0.85, 0.9, 1.0 },
    track_height: f32 = 6,
    thumb_size: f32 = 16,
    /// Default sliders expand along the main axis.
    flex: f32 = 1,
    min_width: f32 = 120,
};

pub const DividerStyle = struct {
    thickness: f32 = 1,
    color: [4]f32 = .{ 0.35, 0.35, 0.4, 1.0 },
};

pub const ScrollStyle = struct {
    direction: Direction = .vertical,
    padding: f32 = 0,
    gap: f32 = 0,
    /// Flex weight used in the parent's main-axis distribution. 0 means
    /// use the intrinsic size (capped by width/height below).
    flex: f32 = 0,
    /// Fixed viewport sizes. 0 means "measured from children" (in which
    /// case overflow scrolling is pointless, but the shape still works).
    width: f32 = 0,
    height: f32 = 0,
    /// Current scroll offsets, read from Model. The framework does not
    /// own this state; the host translates wheel / drag events into app
    /// Msgs that update the Model fields feeding this value back in.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
};

// ── Overlay (HARDLINE §2 escape hatch 5) ───────────────────────────
//
// Absolute-positioned floating region. Content between push_overlay /
// pop_overlay draws above non-overlay content and hit-tests before it.
// Position is explicit (app fills .x/.y from prev-frame anchor or mouse
// coords — same pattern as the slider). Width/height = 0 means measured
// from children; >0 = forced size.

pub const OverlayStyle = struct {
    /// Window-absolute top-left in pixels. The app typically computes
    /// this from `prev_rects[anchor_idx]` or `mouse_x/y`.
    x: f32 = 0,
    y: f32 = 0,
    /// 0 = measured from children, >0 = forced. Forced sizes are how
    /// modals occupy the full window (set both to window size).
    width: f32 = 0,
    height: f32 = 0,
    padding: f32 = 8,
    gap: f32 = 4,
    direction: Direction = .vertical,
    /// Backdrop fill drawn behind the overlay's children. Alpha 0 means
    /// no backdrop quad. Modals typically set this to a semi-opaque
    /// black, tooltips/popups leave it at zero and put their own bg in
    /// a child group/panel.
    backdrop: [4]f32 = .{ 0, 0, 0, 0 },
    /// Optical anchor side relative to (x, y) — the overlay shifts by
    /// (-w*anchor_x_frac, -h*anchor_y_frac). For a tooltip below the
    /// cursor, set anchor at top-left (0, 0). For a context menu
    /// pinned to a button's bottom-right, set (1, 1). Saves the app
    /// from re-measuring.
    anchor_x_frac: f32 = 0,
    anchor_y_frac: f32 = 0,
};

// ── Image rendering (functional gap #2) ─────────────────────────────
//
// Carries a TextureHandle that the Gpu backend resolves to a real
// resource (wgpu texture, WebGPU texture, ...). The app uploads the
// image via the Gpu surface's `uploadImage` (returns a TextureHandle),
// stashes the handle in Model, and emits `image` with it each frame.

pub const ImageStyle = struct {
    /// Intrinsic size in pixels. The render pass scales the texture
    /// to fit this rect. Width=0 or height=0 = the cmd takes no space
    /// (useful for not-yet-loaded images that the app still wants in
    /// the buffer for hit-testing).
    width: f32 = 64,
    height: f32 = 64,
    /// Flex weight on the parent's main axis. 0 = intrinsic.
    flex: f32 = 0,
    /// Tint applied to the texture in the fragment shader.
    /// `{1, 1, 1, 1}` = passthrough. Use for grayscale icons that
    /// should pick up a theme color.
    tint: [4]f32 = .{ 1, 1, 1, 1 },
};

pub const ImageCmd = struct {
    /// Opaque GPU resource id from `Gpu.uploadImage(...)`. The
    /// framework never unpacks this — render writes it into the
    /// `ImageDraw` it hands to the Gpu backend.
    handle: TextureHandle,
    style: ImageStyle = .{},
};

// ── Virtual list (functional gap #6) ────────────────────────────────
//
// Container that *claims* `total_count * item_extent` of main-axis
// space (for the scroll container to size correctly) but only contains
// cmds for the visible window. The app computes visible_start /
// visible_end from the parent scroll offset and only emits cmds for
// rows in that range. push_virtual_list is intended to sit directly
// inside a push_scroll.

pub const VirtualListStyle = struct {
    direction: Direction = .vertical,
    /// Total number of rows the list logically contains.
    total_count: u32 = 0,
    /// Per-row main-axis extent in pixels. All rows must have the
    /// same extent for layout to compute total size in O(1).
    item_extent: f32 = 0,
    /// Inclusive lower bound of rows present as children in the buffer.
    visible_start: u32 = 0,
    /// Exclusive upper bound. `visible_end - visible_start` = number
    /// of child cmds the app emits between push_virtual_list and
    /// pop_virtual_list (one row group per visible row).
    visible_end: u32 = 0,
    padding: f32 = 0,
    gap: f32 = 0,
};

// ── Rich text (functional gap #8) ───────────────────────────────────
//
// Mixed-style text: a base content string carved into runs by `spans`.
// Each span colors / weights / sizes a contiguous byte range. Layout
// measures by walking the spans (so font-size changes affect total
// width). Render emits one TextDraw per visible span. The spans slice
// lives in the per-frame arena — typically built by walking a rich_zig
// `Text` value into `RichTextSpan`s.

pub const RichTextSpan = struct {
    /// Byte start in the rich_text's content (UTF-8). Spans must be
    /// non-overlapping and sorted by start.
    start: u32,
    /// Byte end (exclusive).
    end: u32,
    color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    font: FontSpec = DEFAULT_FONT,
    /// Set on the rendered TextDraw so the text pass can pick a
    /// bold/italic font face. The Host's text measurer is expected to
    /// consult these — for now they're advisory (current GDI host
    /// always picks Regular).
    bold: bool = false,
    italic: bool = false,
};

pub const RichTextCmd = struct {
    /// Full UTF-8 string. Spans index into this. Anything not covered
    /// by a span renders with `default_color` / `default_font`.
    content: []const u8,
    spans: []const RichTextSpan = &.{},
    default_color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    default_font: FontSpec = DEFAULT_FONT,
};

// ── Mixed-font text builder ────────────────────────────────────────
//
// Ergonomic constructor for RichTextCmd: an app declares a list of
// styled parts and the framework computes byte offsets + spans in the
// arena. Closes ergonomic gap 7 — mixing mono columns + sans labels in
// one paragraph no longer requires hand-rolling spans.

pub const MixedPart = struct {
    text: []const u8,
    /// null falls back to the theme's `typography.body` at emit time.
    font: ?FontSpec = null,
    /// null falls back to the theme's `text_color` at emit time.
    color: ?[4]f32 = null,
    bold: bool = false,
    italic: bool = false,
};

// ── Generic Cmd + CmdBuffer over Msg ───────────────────────────────
//
// Per proto 2 Option A: CmdBuffer is generic over the composed AppMsg.
// Components emit commands using the composed Msg; this keeps routing
// explicit rather than hiding it behind a per-component wrapper.

pub fn ButtonCmd(comptime Msg: type) type {
    return struct {
        msg: Msg,
        label: []const u8,
        style: ButtonStyle = .{},
        font: FontSpec = DEFAULT_FONT,
    };
}

pub fn TextInputCmd(comptime Msg: type) type {
    return struct {
        /// Msg emitted when this input is clicked — the Model uses this to
        /// update its focus field. Keyboard character/key events are handled
        /// at the app level (main loop translates key events into app-level
        /// Msgs, app.update dispatches based on Model.focused).
        focus_msg: Msg,
        content: []const u8,
        cursor: usize,
        /// Selection range anchor. If non-null and != cursor, render
        /// draws a selection highlight from min(anchor,cursor) to
        /// max(anchor,cursor). Cursor stays at `cursor`; anchor is the
        /// other end. Same byte semantics as `cursor`.
        selection_anchor: ?usize = null,
        style: TextInputStyle = .{},
        font: FontSpec = DEFAULT_FONT,
    };
}

pub fn CheckboxCmd(comptime Msg: type) type {
    return struct {
        /// Msg fired on click. The app flips `Model.checked` in its
        /// update handler — the framework does not mutate `checked` here.
        msg: Msg,
        checked: bool,
        label: []const u8,
        style: CheckboxStyle = .{},
        font: FontSpec = DEFAULT_FONT,
    };
}

pub fn RadioCmd(comptime Msg: type) type {
    return struct {
        /// Msg fired on click. Radio-group semantics (only one selected
        /// at a time) are app state: the app sets `Model.selected_index`
        /// to this radio's index on msg, and passes `selected =
        /// (Model.selected_index == i)` when emitting the command.
        msg: Msg,
        selected: bool,
        label: []const u8,
        style: RadioStyle = .{},
        font: FontSpec = DEFAULT_FONT,
    };
}

pub fn SliderCmd(comptime Msg: type) type {
    return struct {
        /// Msg fired on mousedown inside the slider's track. The app
        /// reads the slider's rect from `rects[hit.index]` and computes
        /// the new value from mouse_x relative to the rect — the
        /// framework does not fabricate a value-carrying Msg (HARDLINE §3
        /// forbids function-pointer callbacks on Cmd variants).
        grab_msg: Msg,
        /// Current value in [0, 1] — rendering only.
        value: f32 = 0,
        style: SliderStyle = .{},
    };
}

pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        /// Re-expose Msg so that generic helpers can recover it from the Cmd type.
        pub const MsgT = Msg;

        push_group: GroupStyle,
        pop_group,
        push_scroll: ScrollStyle,
        pop_scroll,
        push_overlay: OverlayStyle,
        pop_overlay,
        push_virtual_list: VirtualListStyle,
        pop_virtual_list,
        text: TextCmd,
        rich_text: RichTextCmd,
        image: ImageCmd,
        button: ButtonCmd(Msg),
        text_input: TextInputCmd(Msg),
        checkbox: CheckboxCmd(Msg),
        radio: RadioCmd(Msg),
        slider: SliderCmd(Msg),
        divider: DividerStyle,
    };
}

pub fn CmdBuffer(comptime Msg: type) type {
    return struct {
        const Self = @This();
        pub const MsgT = Msg;
        pub const CmdT = Cmd(Msg);

        cmds: std.ArrayList(CmdT),
        arena: std.heap.ArenaAllocator,
        backing: std.mem.Allocator,
        /// Style + typography defaults consulted by the un-styled
        /// convenience emitters (`button`, `text`, `slider`, etc.).
        /// Apps assign `cb.theme = teak.Theme.dark_default` (or their
        /// own derived theme) before each `view()` call. Explicit
        /// `*Styled` emitters bypass theme.
        theme: theme_mod.Theme = theme_mod.Theme.dark_default,

        pub fn init(backing: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(backing),
                .cmds = .empty,
                .backing = backing,
            };
        }

        /// Replace the active theme. Returns the previous theme so callers
        /// can stash and restore (e.g. for a themed sub-tree).
        pub fn setTheme(self: *Self, t: theme_mod.Theme) theme_mod.Theme {
            const prev = self.theme;
            self.theme = t;
            return prev;
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.cmds.deinit(self.backing);
        }

        pub fn reset(self: *Self) void {
            self.cmds.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
        }

        // ── Convenience emitters ───────────────────────────────────

        pub fn pushGroup(self: *Self, style: GroupStyle) void {
            self.cmds.append(self.backing, .{ .push_group = style }) catch unreachable;
        }

        pub fn popGroup(self: *Self) void {
            self.cmds.append(self.backing, .pop_group) catch unreachable;
        }

        pub fn text(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.body,
                .color = self.theme.text_color,
            } }) catch unreachable;
        }

        /// Body text in the theme's heading color/size — for section
        /// titles. Saves an explicit FontSpec at every call site.
        pub fn heading(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.heading,
                .color = self.theme.heading_color,
            } }) catch unreachable;
        }

        /// Body text in the theme's "muted" color — placeholders, units,
        /// secondary labels.
        pub fn textMuted(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.small,
                .color = self.theme.muted_color,
            } }) catch unreachable;
        }

        /// Body text in the theme's danger color — validation messages.
        pub fn textDanger(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.small,
                .color = self.theme.danger_color,
            } }) catch unreachable;
        }

        /// Monospace text in body color — column data, code, numerics.
        pub fn textMono(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.mono,
                .color = self.theme.text_color,
            } }) catch unreachable;
        }

        pub fn divider(self: *Self) void {
            self.cmds.append(self.backing, .{ .divider = self.theme.divider }) catch unreachable;
        }

        pub fn dividerStyled(self: *Self, style: DividerStyle) void {
            self.cmds.append(self.backing, .{ .divider = style }) catch unreachable;
        }

        pub fn button(self: *Self, msg: Msg, label: []const u8) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = self.theme.button,
                .font = self.theme.typography.body,
            } }) catch unreachable;
        }

        pub fn buttonStyled(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = style,
            } }) catch unreachable;
        }

        pub fn textInput(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
        ) void {
            self.cmds.append(self.backing, .{ .text_input = .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = self.theme.text_input,
                .font = self.theme.typography.body,
            } }) catch unreachable;
        }

        pub fn textInputStyled(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
            style: TextInputStyle,
        ) void {
            self.cmds.append(self.backing, .{ .text_input = .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = style,
            } }) catch unreachable;
        }

        pub fn pushScroll(self: *Self, style: ScrollStyle) void {
            self.cmds.append(self.backing, .{ .push_scroll = style }) catch unreachable;
        }

        pub fn popScroll(self: *Self) void {
            self.cmds.append(self.backing, .pop_scroll) catch unreachable;
        }

        pub fn checkbox(self: *Self, msg: Msg, checked: bool, label: []const u8) void {
            self.cmds.append(self.backing, .{ .checkbox = .{
                .msg = msg,
                .checked = checked,
                .label = label,
                .style = self.theme.checkbox,
                .font = self.theme.typography.body,
            } }) catch unreachable;
        }

        pub fn radio(self: *Self, msg: Msg, selected: bool, label: []const u8) void {
            self.cmds.append(self.backing, .{ .radio = .{
                .msg = msg,
                .selected = selected,
                .label = label,
                .style = self.theme.radio,
                .font = self.theme.typography.body,
            } }) catch unreachable;
        }

        pub fn slider(self: *Self, grab_msg: Msg, value: f32) void {
            self.cmds.append(self.backing, .{ .slider = .{
                .grab_msg = grab_msg,
                .value = value,
                .style = self.theme.slider,
            } }) catch unreachable;
        }

        // ── Overlay / virtual list / image / rich text ─────────────

        pub fn pushOverlay(self: *Self, style: OverlayStyle) void {
            self.cmds.append(self.backing, .{ .push_overlay = style }) catch unreachable;
        }

        pub fn popOverlay(self: *Self) void {
            self.cmds.append(self.backing, .pop_overlay) catch unreachable;
        }

        pub fn pushVirtualList(self: *Self, style: VirtualListStyle) void {
            self.cmds.append(self.backing, .{ .push_virtual_list = style }) catch unreachable;
        }

        pub fn popVirtualList(self: *Self) void {
            self.cmds.append(self.backing, .pop_virtual_list) catch unreachable;
        }

        pub fn image(self: *Self, handle: TextureHandle, style: ImageStyle) void {
            self.cmds.append(self.backing, .{ .image = .{
                .handle = handle,
                .style = style,
            } }) catch unreachable;
        }

        pub fn textInputSelected(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
            selection_anchor: ?usize,
            style: TextInputStyle,
        ) void {
            self.cmds.append(self.backing, .{ .text_input = .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .selection_anchor = selection_anchor,
                .style = style,
            } }) catch unreachable;
        }

        pub fn richText(
            self: *Self,
            content: []const u8,
            spans: []const RichTextSpan,
        ) void {
            self.cmds.append(self.backing, .{ .rich_text = .{
                .content = content,
                .spans = spans,
            } }) catch unreachable;
        }

        pub fn richTextStyled(self: *Self, c: RichTextCmd) void {
            self.cmds.append(self.backing, .{ .rich_text = c }) catch unreachable;
        }

        /// Build a RichTextCmd from a slice of MixedPart, baking content
        /// + spans into the per-frame arena. Each part gets its own span;
        /// null font/color fields inherit the theme's body font and text
        /// color so apps only spell out the overrides.
        ///
        /// Example:
        ///   cb.mixedText(&.{
        ///       .{ .text = "Length: ", .color = cb.theme.muted_color },
        ///       .{ .text = "42.0",     .font = cb.theme.typography.mono },
        ///       .{ .text = " mm",      .color = cb.theme.muted_color },
        ///   });
        pub fn mixedText(self: *Self, parts: []const MixedPart) void {
            const arena_alloc = self.arena.allocator();

            var total_len: usize = 0;
            for (parts) |p| total_len += p.text.len;

            const content = arena_alloc.alloc(u8, total_len) catch unreachable;
            const spans = arena_alloc.alloc(RichTextSpan, parts.len) catch unreachable;

            var cursor: usize = 0;
            for (parts, 0..) |p, i| {
                @memcpy(content[cursor .. cursor + p.text.len], p.text);
                spans[i] = .{
                    .start = @intCast(cursor),
                    .end = @intCast(cursor + p.text.len),
                    .font = p.font orelse self.theme.typography.body,
                    .color = p.color orelse self.theme.text_color,
                    .bold = p.bold,
                    .italic = p.italic,
                };
                cursor += p.text.len;
            }

            self.cmds.append(self.backing, .{ .rich_text = .{
                .content = content,
                .spans = spans,
                .default_font = self.theme.typography.body,
                .default_color = self.theme.text_color,
            } }) catch unreachable;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "CmdBuffer emits correct sequence for simple counter view" {
    const testing = std.testing;

    const Msg = union(enum) {
        inc,
        dec,
        reset,
    };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("Count: 0");
    cb.pushGroup(.{ .direction = .horizontal });
    cb.button(.inc, "+");
    cb.button(.dec, "-");
    cb.popGroup();
    cb.button(.reset, "Reset");
    cb.popGroup();

    try testing.expectEqual(@as(usize, 8), cb.cmds.items.len);
    try testing.expectEqual(.push_group, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqual(Msg.inc, cb.cmds.items[3].button.msg);
    try testing.expectEqual(Msg.reset, cb.cmds.items[6].button.msg);
}

test "CmdBuffer emits text_input command" {
    const testing = std.testing;

    const Msg = union(enum) { focus };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.focus, "hello", 2);

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqualStrings("hello", cb.cmds.items[0].text_input.content);
    try testing.expectEqual(@as(usize, 2), cb.cmds.items[0].text_input.cursor);
    try testing.expectEqual(Msg.focus, cb.cmds.items[0].text_input.focus_msg);
}

test "CmdBuffer reset clears commands" {
    const testing = std.testing;

    const Msg = union(enum) { a };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.text("hello");
    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);

    cb.reset();
    try testing.expectEqual(@as(usize, 0), cb.cmds.items.len);
}

test "Cmd exposes Msg type via MsgT" {
    const Msg = union(enum) { a, b };
    try std.testing.expectEqual(Msg, Cmd(Msg).MsgT);
}

test "CmdBuffer.mixedText: bakes content + per-part spans from theme defaults" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    const mono_font: FontSpec = .{ .size_px = 14, .family = .mono };
    const muted: [4]f32 = .{ 0.6, 0.6, 0.6, 1.0 };

    cb.mixedText(&.{
        .{ .text = "Length: ", .color = muted },
        .{ .text = "42.0", .font = mono_font },
        .{ .text = " mm", .color = muted },
    });

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    const rt = cb.cmds.items[0].rich_text;
    try testing.expectEqualStrings("Length: 42.0 mm", rt.content);
    try testing.expectEqual(@as(usize, 3), rt.spans.len);

    try testing.expectEqual(@as(u32, 0), rt.spans[0].start);
    try testing.expectEqual(@as(u32, 8), rt.spans[0].end);
    try testing.expectEqual(muted, rt.spans[0].color);
    // Part 0 has no font override -> theme default (sans body 14).
    try testing.expectEqual(text.FontFamily.sans, rt.spans[0].font.family);

    try testing.expectEqual(@as(u32, 8), rt.spans[1].start);
    try testing.expectEqual(@as(u32, 12), rt.spans[1].end);
    try testing.expectEqual(text.FontFamily.mono, rt.spans[1].font.family);

    try testing.expectEqual(@as(u32, 12), rt.spans[2].start);
    try testing.expectEqual(@as(u32, 15), rt.spans[2].end);
}

test "CmdBuffer.mixedText: bold + italic flags propagate to span" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.mixedText(&.{
        .{ .text = "hello ", .bold = true },
        .{ .text = "world", .italic = true },
    });

    const rt = cb.cmds.items[0].rich_text;
    try testing.expect(rt.spans[0].bold);
    try testing.expect(!rt.spans[0].italic);
    try testing.expect(!rt.spans[1].bold);
    try testing.expect(rt.spans[1].italic);
}

test "CmdBuffer.mixedText: empty parts list still emits a (zero-content) rich_text" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.mixedText(&.{});

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    const rt = cb.cmds.items[0].rich_text;
    try testing.expectEqual(@as(usize, 0), rt.content.len);
    try testing.expectEqual(@as(usize, 0), rt.spans.len);
}
