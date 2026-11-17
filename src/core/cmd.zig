const std = @import("std");
const oom = @import("oom.zig").oom;
const text = @import("text.zig");
const theme_mod = @import("theme.zig");
const scene = @import("scene.zig");
const CursorShape = @import("cursor.zig").CursorShape;
const surface = @import("surface.zig");

pub const Radii = surface.Radii;
pub const Shadow = surface.Shadow;
pub const Gradient = surface.Gradient;
const eql = @import("eql.zig");
const eql_mod = @import("eql.zig");
const text_wrap = @import("text_wrap.zig");

pub const FontSpec = text.FontSpec;

/// How a `text` Cmd breaks into lines: `none | word | char | ellipsis`.
pub const Wrap = text_wrap.Wrap;
const DEFAULT_FONT = text.DEFAULT_FONT;
const TextureHandle = text.TextureHandle;


pub const Direction = enum { vertical, horizontal };


pub const A11ySemantic = enum {
    none,
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

pub const A11yLive = enum { off, polite, assertive };

pub const A11yHint = struct {
    semantic: A11ySemantic = .none,
    /// Accessible name (groups); buttons already have their label.
    label: []const u8 = "",
    /// `progressbar`: completion in [0, 1].
    value: f32 = 0,
    /// `heading` level / `treeitem` depth (1-based; 0 = unspecified).
    level: u8 = 0,
    /// `tab` / `option` / `treeitem` / `row` / `menuitem`: selected (or current) item.
    selected: bool = false,
    /// Expandable items (`treeitem`, `combobox`, `menuitem`): null = not expandable.
    expanded: ?bool = null,
    /// A live region: AT announces content changes inside (toasts, status lines).
    live: A11yLive = .off,
};

/// Cross-axis placement of a container's children (the axis perpendicular
/// to `direction`).
pub const Align = enum {
    /// Children sit at the start edge at their own size. Legacy leaves that
    /// always filled the cross axis (text_input, slider, divider) still do.
    start,
    center,
    end,
    /// Every child kind is sized to the container's inner cross extent. A
    /// group or scroll that fixed its own size on that axis (`width` /
    /// `height` > 0) keeps it.
    stretch,
};

/// Main-axis distribution of leftover space. Only applies when no child
/// has a flex weight (flex children absorb the leftover first).
pub const Justify = enum { start, center, end, space_between };

/// Horizontal placement of a label inside its box (button labels).
pub const TextAlign = enum { start, center, end };

/// Options for `CmdBuffer.paragraphStyled`.
pub const ParagraphOpts = struct {
    wrap: Wrap = .word,
    max_lines: u16 = 0,
    text_align: TextAlign = .start,
};

/// Look of a `text_input`.
pub const InputVariant = enum {
    /// A filled, bordered box (`bg`, `border` / `focus_border`, `border_width`).
    boxed,
    /// No box: a 1px rule along the bottom edge (2px, in `focus_border`,
    /// while focused). For typed-form fields on a paper background.
    underline,
};

pub const GroupStyle = struct {
    direction: Direction = .vertical,
    padding: f32 = 8,
    /// Overrides `padding` on the horizontal / vertical axis when non-null.
    pad_x: ?f32 = null,
    pad_y: ?f32 = null,
    gap: f32 = 8,
    /// 0 = no growth. >0 = flex weight: the parent shares its leftover
    /// main-axis space among flex children in proportion, ON TOP of each
    /// child's own size (flex-basis auto). Flex never shrinks a group below
    /// its content; wrap overflowing content in a scroll.
    flex: f32 = 0,
    /// 0 = never shrinks (the default). >0 = shrink weight: when a horizontal
    /// parent overflows, the deficit is shared among shrinkable children in
    /// proportion to `shrink * width`, down to each child's min-content width
    /// (wrapped text inside it re-wraps). Wrapped `text` shrinks implicitly.
    shrink: f32 = 0,
    /// Fixed OUTER size (padding included) on that axis; 0 = measured from
    /// children. A fixed size is the flex basis and beats `align_cross`
    /// stretch from the parent.
    width: f32 = 0,
    height: f32 = 0,
    /// Floor on the outer size, applied to the measured size and to stretch.
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// How this group places / sizes its children on the cross axis.
    align_cross: Align = .start,
    /// How this group distributes leftover main-axis space (no flex kids).
    justify: Justify = .start,
    /// Accessibility semantics (tablist, list, tree, table, dialog, live
    /// status, ...); see `A11yHint`. Default: a plain group.
    a11y: A11yHint = .{},
    /// Optional solid background fill. When non-null, the render pass
    /// emits a single quad at the group's full (padded) rect BEFORE
    /// drawing the group's children — children paint on top. Default
    /// `null` preserves the prior no-fill behavior. This is the panel /
    /// card idiom: pair with an overlay's dim backdrop for a readable
    /// modal. Corners are square: the quad renderer has no rounding.
    bg: ?[4]f32 = null,
    /// Optional border: four `border_width` quads drawn INSIDE the group's
    /// rect, after `bg` and before the children. It takes no layout space;
    /// keep `padding >= border_width` so children don't paint over it.
    border: ?[4]f32 = null,
    border_width: f32 = 1,
    /// In-app drag and drop (docs/features/drag-drop.md). `drag_id != 0`
    /// makes the group a drag SOURCE: a press on it (that no interactive
    /// child claims) followed by movement starts a drag, reported to the
    /// App's `dragMsg`. `drop_id != 0` makes it a drop TARGET: `dragMsg`
    /// events say which target (innermost) the pointer is over. Ids are the
    /// app's, per kind (a row is typically both, with one id).
    drag_id: u32 = 0,
    drop_id: u32 = 0,
    /// Rounded corners of the fill and border. With any of `radius`,
    /// `gradient` or `soft_shadow` set the group draws as one SDF quad (the
    /// border becomes an inside stroke that follows the corners); with none
    /// it draws exactly as before.
    radius: Radii = .{},
    /// Replaces `bg` as the fill when set.
    gradient: ?Gradient = null,
    /// Blurred drop shadow outside the group's rect.
    soft_shadow: ?Shadow = null,

    pub fn padX(self: GroupStyle) f32 {
        return self.pad_x orelse self.padding;
    }

    pub fn padY(self: GroupStyle) f32 {
        return self.pad_y orelse self.padding;
    }
};

/// Most columns a grid lays out. `GridStyle.columnCount` clamps to it so the
/// layout passes can keep per-column widths in a fixed array (HARDLINE hatch 3:
/// no allocation, bounded scratch).
pub const MAX_GRID_COLUMNS = 32;

/// Width rule for one grid column.
pub const GridTrack = union(enum) {
    /// The widest child in the column (its measured width).
    auto,
    /// Exactly this many pixels.
    fixed: f32,
    /// A share of the width left after fixed + auto columns and gaps, in
    /// proportion to the weight. Never narrower than the column's widest
    /// child (CSS `minmax(auto, Nfr)`); a column it cannot shrink keeps
    /// that width and the rest share what remains.
    fr: f32,
};

/// Layout and look of a `push_grid` container: children (in buffer order,
/// one per cell, any leaf or container) fill `columnCount()` columns row by
/// row. Row height = the tallest child in the row; column width per track.
pub const GridStyle = struct {
    /// Number of columns; 0 = `tracks.len`. Columns past `tracks` are
    /// `.{ .fr = 1 }`, so `.{ .columns = 4 }` is four equal columns.
    /// Clamped to `MAX_GRID_COLUMNS`.
    columns: u16 = 0,
    /// Per-column width rule, e.g. `&.{ .auto, .{ .fr = 1 } }`.
    tracks: []const GridTrack = &.{},
    col_gap: f32 = 8,
    row_gap: f32 = 8,
    padding: f32 = 8,
    /// Overrides `padding` on the horizontal / vertical axis when non-null.
    pad_x: ?f32 = null,
    pad_y: ?f32 = null,
    /// Flex weight on the parent's main axis (see `GroupStyle.flex`).
    flex: f32 = 0,
    /// Fixed OUTER size (padding included); 0 = measured. A fixed or
    /// stretched width is what `fr` columns share.
    width: f32 = 0,
    height: f32 = 0,
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// Placement of each child inside its cell, horizontally (`align_x`) and
    /// vertically (`align_y`). `.stretch` sizes the child to the cell (a
    /// group / scroll with a fixed size on that axis keeps it). As in a
    /// vertical group, `text_input`, `slider` and `divider` fill the cell
    /// width under `.start` too.
    align_x: Align = .start,
    align_y: Align = .start,
    /// Accessibility semantics (e.g. `.table`); default: a plain group.
    a11y: A11yHint = .{},
    /// Optional fill and border, drawn like `GroupStyle.bg` / `.border`.
    bg: ?[4]f32 = null,
    border: ?[4]f32 = null,
    border_width: f32 = 1,

    pub fn padX(self: GridStyle) f32 {
        return self.pad_x orelse self.padding;
    }

    pub fn padY(self: GridStyle) f32 {
        return self.pad_y orelse self.padding;
    }

    /// Column count actually laid out (at least 1, at most `MAX_GRID_COLUMNS`).
    pub fn columnCount(self: GridStyle) usize {
        const n: usize = if (self.columns > 0) self.columns else self.tracks.len;
        return std.math.clamp(n, 1, MAX_GRID_COLUMNS);
    }

    /// Width rule of column `c`.
    pub fn track(self: GridStyle, c: usize) GridTrack {
        return if (c < self.tracks.len) self.tracks[c] else .{ .fr = 1 };
    }
};

pub const TextCmd = struct {
    content: []const u8,
    font: FontSpec = DEFAULT_FONT,
    /// Foreground color for the rendered glyphs. Default is light grey
    /// suitable for the dark scene bg that examples currently use.
    color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    /// Line breaking. `.none` (default) keeps the single-line behaviour
    /// (hard newlines are NOT interpreted unless wrapping is on). `.word` /
    /// `.char` wrap to the width layout resolves; `.ellipsis` truncates one
    /// line with U+2026. See docs/features/text-engine.md section 7.
    wrap: Wrap = .none,
    /// Visible line cap for wrapped text (0 = unlimited); the last visible
    /// line is ellipsized when text remains.
    max_lines: u16 = 0,
    /// Horizontal placement of each line inside the text's rect. Anything but
    /// `.start` makes a wrapped paragraph fill its parent's cross axis so the
    /// alignment has room to act.
    text_align: TextAlign = .start,
};

pub const ButtonStyle = struct {
    bg: [4]f32 = .{ 0.25, 0.25, 0.25, 1.0 },
    hover_bg: [4]f32 = .{ 0.35, 0.35, 0.35, 1.0 },
    press_bg: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    /// Colors used when the button's `disabled` flag is set: a flat,
    /// dimmed bg + greyed label. No hover/press feedback in this state.
    disabled_bg: [4]f32 = .{ 0.18, 0.18, 0.18, 1.0 },
    disabled_fg: [4]f32 = .{ 0.5, 0.5, 0.5, 1.0 },
    /// Label color while hovered / pressed; null keeps `fg`. Together with
    /// `hover_bg` this gives the classic ink-on-paper inversion on hover.
    hover_fg: ?[4]f32 = null,
    press_fg: ?[4]f32 = null,
    /// Optional border drawn inside the button's rect, over `bg`, in every
    /// state (a disabled button keeps it). Corners are square.
    border: ?[4]f32 = null,
    border_width: f32 = 1,
    /// The label moves down this many pixels while pressed (a tactile
    /// "key travel" without changing the rect).
    press_offset_y: f32 = 0,
    /// Where the label sits horizontally inside the padded box.
    label_align: TextAlign = .start,
    /// Horizontal padding on each side of the label. The button measures
    /// to `label width + 2 * h_padding` (floored by `min_width`) and the
    /// render pass insets the label by the same amount.
    h_padding: f32 = 8,
    /// Floor on the measured width in pixels. The default keeps the old
    /// 60px minimum; set 0 for compact buttons (icons, close boxes) or a
    /// larger value to force a width (the dropdown does, so every open-list
    /// row spans the full list and is clickable edge to edge).
    min_width: f32 = 60,
    /// Outer height in pixels.
    height: f32 = 36,
    /// Rounded corners of the fill and border (0 = square, as before).
    radius: Radii = .{},
    /// Replaces the state background (`bg` / `hover_bg` / ...) with a
    /// gradient in the idle state; hover and press keep their flat colours.
    gradient: ?Gradient = null,
    /// Blurred drop shadow outside the button (not drawn while pressed or disabled).
    soft_shadow: ?Shadow = null,
    /// Flex weight on the parent's main axis (see `GroupStyle.flex`).
    flex: f32 = 0,
    /// Fixed-width label: the button is exactly `min_width` wide whatever the label,
    /// and a label that does not fit is cut with U+2026 at the pixel (table cells).
    ellipsis: bool = false,
};

pub const TextInputStyle = struct {
    bg: [4]f32 = .{ 0.12, 0.12, 0.14, 1.0 },
    fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    border: [4]f32 = .{ 0.35, 0.35, 0.4, 1.0 },
    focus_border: [4]f32 = .{ 0.3, 0.5, 1.0, 1.0 },
    cursor: [4]f32 = .{ 0.9, 0.9, 1.0, 1.0 },
    /// Colors used when the input's `disabled` flag is set: flat dimmed
    /// border + bg + greyed text. No focus border, selection, or cursor.
    disabled_bg: [4]f32 = .{ 0.10, 0.10, 0.11, 1.0 },
    disabled_fg: [4]f32 = .{ 0.5, 0.5, 0.5, 1.0 },
    disabled_border: [4]f32 = .{ 0.22, 0.22, 0.25, 1.0 },
    /// Selection highlight behind the selected text (drawn under the glyphs,
    /// so give it some transparency).
    selection_bg: [4]f32 = .{ 0.25, 0.45, 0.95, 0.45 },
    variant: InputVariant = .boxed,
    /// Border thickness of the `.boxed` variant (the `.underline` rule is
    /// fixed at 1px, 2px focused).
    border_width: f32 = 2,
    /// Text inputs expand along the main axis by default.
    flex: f32 = 1,
    /// Minimum width when flex is 0 or parent has no extra space.
    min_width: f32 = 120,
    /// Outer height in pixels.
    height: f32 = 28,
    /// Rounded corners of the `.boxed` variant (0 = square, as before).
    radius: Radii = .{},
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
    ///
    /// A scroll with `flex > 0` and no fixed size on the parent's main axis
    /// has a zero basis there: it takes exactly its share of the leftover
    /// space (its content may be taller and is clipped), instead of growing
    /// to fit its content and pushing siblings out of the window.
    flex: f32 = 0,
    /// Shrink weight, as `GroupStyle.shrink` (a vertical scroll shrinks to
    /// its min-content width; a horizontal scroll never shrinks its content).
    shrink: f32 = 0,
    /// Fixed viewport sizes; they win over `align_cross` stretch. 0 means
    /// "measured from children" (in which case overflow scrolling is
    /// pointless, but the shape still works).
    width: f32 = 0,
    height: f32 = 0,
    /// Cross-axis placement of the scrolled children; `.stretch` makes
    /// them fill the viewport's inner width (vertical) / height (horizontal).
    align_cross: Align = .start,
    /// Current scroll offsets, read from Model. The framework does not
    /// own this state; the host translates wheel / drag events into app
    /// Msgs that update the Model fields feeding this value back in.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Accessibility semantics of the region (`.list`, `.listbox`, `.tree`, ...).
    a11y: A11yHint = .{},
    /// Non-zero opts this region into wheel routing and layout reports:
    /// `teak.run` hands wheel events over its innermost hovered `id != 0`
    /// scroll region to the App's `scrollMsg(model, id, dx, dy)`, and
    /// reports its viewport + content size through `scrollLayoutMsg` on
    /// first layout and whenever either changes. Apps give each such
    /// region a distinct id.
    id: u32 = 0,
};


pub fn OverlayStyle(comptime Msg: type) type {
    return struct {
        pub const MsgT = Msg;

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
        /// Cross-axis placement of the overlay's children (see `Align`).
        align_cross: Align = .start,
        /// Backdrop fill drawn behind the overlay's children. Alpha 0 means
        /// no backdrop quad. Modals typically set this to a semi-opaque
        /// black, tooltips/popups leave it at zero and put their own bg in
        /// a child group/panel.
        backdrop: [4]f32 = .{ 0, 0, 0, 0 },
        /// Optional border drawn inside the overlay's rect over the backdrop,
        /// before the children (keep `padding >= border_width`).
        border: ?[4]f32 = null,
        border_width: f32 = 1,
        /// Hard drop shadow: the overlay's rect, offset by `shadow_offset`
        /// and drawn BEHIND it in this color (no blur). It shows through
        /// any transparent part of the overlay, so pair it with an opaque
        /// `backdrop` (or an opaque child panel that fills the rect).
        shadow: ?[4]f32 = null,
        shadow_offset: [2]f32 = .{ 2, 2 },
        /// Optical anchor side relative to (x, y) — the overlay shifts by
        /// (-w*anchor_x_frac, -h*anchor_y_frac). For a tooltip below the
        /// cursor, set anchor at top-left (0, 0). For a context menu
        /// pinned to a button's bottom-right, set (1, 1). Saves the app
        /// from re-measuring.
        anchor_x_frac: f32 = 0,
        anchor_y_frac: f32 = 0,
        /// When true, hits inside this overlay's rect do NOT fall
        /// through to the base layer even if no interactive child claims
        /// them. Set on modals so clicking the dim backdrop doesn't
        /// activate a button underneath. Default `false` preserves the
        /// passthrough behavior tooltips / popovers / the debug overlay
        /// rely on.
        modal: bool = false,
        /// Rounded corners of the backdrop and border.
        radius: Radii = .{},
        /// Blurred drop shadow outside the overlay (the hard retro
        /// `shadow` above is unrelated and can coexist).
        soft_shadow: ?Shadow = null,
        /// Dispatched when the click lands inside the overlay's rect but
        /// on no interactive leaf — pair with `modal = true` for the
        /// "click outside the dialog to dismiss it" idiom. The Msg is
        /// data only (HARDLINE §3 bans fn-pointer callbacks). Independent
        /// of `modal`, but only meaningful together.
        backdrop_msg: ?Msg = null,
        /// Anchor the overlay to a widget instead of (x, y): the overlay is
        /// placed against the rect of the nearest EARLIER leaf in the buffer
        /// whose click / focus Msg equals this value (`leafMsg`, compared
        /// by value like `focusedMsg`; the nearest preceding match wins).
        /// Resolved by the layout pass from the same frame's final rects, so
        /// there is no frame of latency, no layout event and no app state.
        /// No match (or null): `x` / `y` / `anchor_*_frac` apply as before.
        anchor_msg: ?Msg = null,
        /// Which side of the anchor widget the overlay opens on.
        anchor_side: AnchorSide = .below_start,
        /// Pixels between the anchor's edge and the overlay.
        anchor_gap: f32 = 0,
    };
}

/// Where an `OverlayStyle.anchor_msg` overlay sits relative to its widget.
/// `*_start` aligns the overlay's left (or top) edge with the widget's,
/// `*_end` aligns the right edge. No flipping at the window edge.
pub const AnchorSide = enum { below_start, below_end, above_start, above_end, right_start, left_start };

/// The click / focus Msg a leaf carries (what `OverlayStyle.anchor_msg`
/// matches), or null for containers and decorative leaves. Exhaustive, so a
/// new Cmd variant must decide whether it can anchor an overlay.
pub fn leafMsg(c: anytype) ?@TypeOf(c).MsgT {
    return switch (c) {
        .button => |b| b.msg,
        .text_input => |t| t.focus_msg,
        .text_area => |t| t.focus_msg,
        .checkbox => |x| x.msg,
        .radio => |r| r.msg,
        .slider => |s| s.grab_msg,
        .canvas => |cv| cv.msg,
        .scene3d => |sc| sc.msg,
        .push_group, .pop_group, .push_grid, .pop_grid, .push_scroll, .pop_scroll, .push_overlay, .pop_overlay, .push_virtual_list, .pop_virtual_list, .text, .rich_text, .image, .divider => null,
    };
}


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
    /// Variable-height rows. When > 0 the list claims exactly this much main-axis
    /// space (the app knows the rows' prefix sums), `item_extent` and
    /// `total_count` are ignored, and the emitted rows (`visible_start`..
    /// `visible_end`, any heights) start `start_offset` px from the list's start.
    total_extent: f32 = 0,
    start_offset: f32 = 0,
    /// Cross-axis placement of the rows (`.stretch` fills the list's width).
    align_cross: Align = .start,
    /// Non-zero opts into measured-row reports: `teak.run` hands the heights
    /// of the emitted rows (direct children) to the App's
    /// `virtualRowsMsg(model, id, first_row, heights)` whenever they change, so
    /// a variable-height list can learn real heights from layout.
    id: u32 = 0,
};


/// A styled byte range of a `rich_text` (defined in `text.zig` so `text_wrap`
/// can measure runs without importing the Cmd types).
pub const RichTextSpan = text.RichTextSpan;

pub const RichTextCmd = struct {
    /// Full UTF-8 string. Spans index into this. Anything not covered
    /// by a span renders with `default_color` / `default_font`.
    content: []const u8,
    spans: []const RichTextSpan = &.{},
    default_color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    default_font: FontSpec = DEFAULT_FONT,
    /// Line breaking, as `TextCmd.wrap`: lines break across spans (mixed
    /// fonts / colours per line) at UAX #14 opportunities. `.none` keeps the
    /// single-line behaviour.
    wrap: Wrap = .none,
    max_lines: u16 = 0,
    text_align: TextAlign = .start,
};


pub const MixedPart = struct {
    text: []const u8,
    /// null falls back to the theme's `typography.body` at emit time.
    font: ?FontSpec = null,
    /// null falls back to the theme's `text_color` at emit time.
    color: ?[4]f32 = null,
    bold: bool = false,
    italic: bool = false,
};


/// A point in canvas-local logical pixels.
pub const CanvasPoint = struct {
    x: f32,
    y: f32,
};

/// One 2D draw op inside a canvas. All coordinates are canvas-local.
pub const CanvasPrimitive = union(enum) {
    /// Connected line through `points` (>= 2 to draw). Each segment is a
    /// `thickness`-wide quad; arbitrary angles allowed.
    polyline: Polyline,
    /// Solid axis-aligned rectangle.
    filled_rect: FilledRect,
    /// Full-width horizontal rule at `y` (gridline / axis).
    hline: HLine,
    /// Full-height vertical rule at `x` (gridline / axis).
    vline: VLine,
    /// A small square point marker centered on (`x`, `y`).
    marker: Marker,
    /// Pre-tessellated colored triangle list (see `Triangles`).
    triangles: Triangles,
    /// A big batch of independent segments sharing one color / thickness.
    lines: Lines,
    /// A text label at a canvas-local position (top-left of the text box).
    /// Drawn above the canvas' solid primitives, clipped to the canvas. Set
    /// `font.scalable` for labels that zoom with the canvas.
    text: Text,
    /// A circle: filled, stroked or both (see `Circle`).
    circle: Circle,
    /// A circular arc, stroked (see `Arc`).
    arc: Arc,
    /// A closed polygon: filled (any simple polygon, either winding),
    /// stroked, or both (see `Polygon`).
    polygon: Polygon,

    /// Center (`x`, `y`) and `radius` in canvas-local units (so they follow
    /// `CanvasStyle.transform`), unless `screen_radius`: then the radius is
    /// in screen px and the circle keeps its size at every zoom (node dots).
    /// `stroke` is centred on the radius, `thickness` screen px wide.
    pub const Circle = struct {
        x: f32,
        y: f32,
        radius: f32,
        fill: ?[4]f32 = .{ 0.85, 0.85, 0.9, 1.0 },
        stroke: ?[4]f32 = null,
        thickness: f32 = 1,
        screen_radius: bool = false,
    };
    /// Arc of the circle (`x`, `y`, `radius`) from angle `start` through
    /// `sweep` (radians, canvas-local: 0 = +x, positive turns from +x
    /// toward +y, i.e. clockwise on screen with the identity transform;
    /// |sweep| >= 2*pi draws the full circle). `radius` / `screen_radius`
    /// as `Circle`; `thickness` in screen px.
    pub const Arc = struct {
        x: f32,
        y: f32,
        radius: f32,
        start: f32 = 0,
        sweep: f32 = std.math.pi,
        color: [4]f32 = .{ 0.85, 0.85, 0.9, 1.0 },
        thickness: f32 = 1,
        screen_radius: bool = false,
    };
    /// Closed polygon through `points` (>= 3; the last point joins the
    /// first). The fill is ear-clipped, so any simple polygon works, convex
    /// or not; a self-intersecting outline still fills, but not by any
    /// particular rule (split it at the crossings for exact results).
    /// `stroke` draws the closed outline, `thickness` screen px.
    pub const Polygon = struct {
        points: []const CanvasPoint,
        fill: ?[4]f32 = .{ 0.3, 0.7, 1.0, 0.4 },
        stroke: ?[4]f32 = null,
        thickness: f32 = 1,
    };

    pub const Polyline = struct {
        points: []const CanvasPoint,
        color: [4]f32 = .{ 0.3, 0.7, 1.0, 1.0 },
        thickness: f32 = 2,
    };
    pub const FilledRect = struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: [4]f32 = .{ 0.3, 0.3, 0.35, 1.0 },
    };
    pub const HLine = struct {
        y: f32,
        color: [4]f32 = .{ 0.3, 0.3, 0.35, 1.0 },
        thickness: f32 = 1,
    };
    pub const VLine = struct {
        x: f32,
        color: [4]f32 = .{ 0.3, 0.3, 0.35, 1.0 },
        thickness: f32 = 1,
    };
    pub const Text = struct {
        x: f32,
        y: f32,
        content: []const u8,
        font: FontSpec = DEFAULT_FONT,
        color: [4]f32 = .{ 0.92, 0.92, 0.94, 1.0 },
    };
    pub const Marker = struct {
        x: f32,
        y: f32,
        size: f32 = 4,
        color: [4]f32 = .{ 0.85, 0.85, 0.9, 1.0 },
    };

    /// One vertex of a `Triangles` list: canvas-local position + RGBA.
    pub const TriVertex = struct {
        x: f32,
        y: f32,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    };

    /// A plain triangle list (three consecutive vertices = one triangle,
    /// either winding) with a color per vertex, interpolated across the
    /// triangle. Per-vertex alpha is what lets an app feather 1 px edges
    /// for antialiasing without MSAA. The render pass clips the list to the
    /// canvas rect and the active scroll clip (CPU Sutherland–Hodgman, with
    /// a straight-copy fast path when everything is inside); triangles with
    /// a non-finite vertex are dropped, a trailing partial triangle ignored.
    ///
    /// `key` is a cheap revision of the content: the run loop's frame diff
    /// treats two frames with the same non-zero `key` and length as
    /// identical without comparing the vertices. Bump it whenever `verts`
    /// changes; leave it 0 to have the diff compare the vertex bytes.
    pub const Triangles = struct {
        verts: []const TriVertex,
        key: u64 = 0,
    };

    /// `segs[i] = {x0, y0, x1, y1}`, each drawn as a `thickness`-wide quad
    /// (no joins), clipped like polyline segments. For hatching and other
    /// large sets of unconnected strokes. `key`: as for `Triangles`.
    pub const Lines = struct {
        segs: []const [4]f32,
        color: [4]f32 = .{ 0.85, 0.85, 0.9, 1.0 },
        thickness: f32 = 1,
        key: u64 = 0,
    };

    /// Content equality for the frame diff (arena slices have fresh
    /// addresses every frame, so compare what they point at).
    pub fn eql(a: CanvasPrimitive, b: CanvasPrimitive) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .polyline => |pl| blk: {
                const o = b.polyline;
                if (!std.meta.eql(pl.color, o.color) or pl.thickness != o.thickness) break :blk false;
                if (pl.points.len != o.points.len) break :blk false;
                for (pl.points, o.points) |qa, qb| if (!std.meta.eql(qa, qb)) break :blk false;
                break :blk true;
            },
            .triangles => |t| sameRevision(TriVertex, t.verts, t.key, b.triangles.verts, b.triangles.key),
            .lines => |l| blk: {
                const o = b.lines;
                if (!std.meta.eql(l.color, o.color) or l.thickness != o.thickness) break :blk false;
                break :blk sameRevision([4]f32, l.segs, l.key, o.segs, o.key);
            },
            .filled_rect => |x| std.meta.eql(x, b.filled_rect),
            .hline => |x| std.meta.eql(x, b.hline),
            .vline => |x| std.meta.eql(x, b.vline),
            .marker => |x| std.meta.eql(x, b.marker),
            .circle => |x| std.meta.eql(x, b.circle),
            .arc => |x| std.meta.eql(x, b.arc),
            .polygon => |p| blk: {
                const o = b.polygon;
                if (!std.meta.eql(p.fill, o.fill) or !std.meta.eql(p.stroke, o.stroke) or p.thickness != o.thickness) break :blk false;
                break :blk std.mem.eql(u8, std.mem.sliceAsBytes(p.points), std.mem.sliceAsBytes(o.points));
            },
            .text => |t| blk: {
                const o = b.text;
                break :blk t.x == o.x and t.y == o.y and std.meta.eql(t.font, o.font) and
                    std.meta.eql(t.color, o.color) and std.mem.eql(u8, t.content, o.content);
            },
        };
    }

    fn sameRevision(comptime T: type, a: []const T, a_key: u64, b: []const T, b_key: u64) bool {
        if (a.len != b.len) return false;
        if (a_key != 0 or b_key != 0) return a_key == b_key;
        return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
    }
};

pub const CanvasStyle = struct {
    /// Intrinsic size in canvas-local pixels. The primitives' coordinate
    /// space is [0, width] × [0, height].
    width: f32 = 200,
    height: f32 = 120,
    /// Flex weight on the parent's main axis. 0 = intrinsic (matches the
    /// image widget's sizing convention: the weight still counts toward
    /// siblings' distribution, but the canvas keeps its intrinsic box).
    flex: f32 = 0,
    /// Optional solid background fill drawn before the primitives.
    bg: ?[4]f32 = null,
    /// Maps primitive coordinates to canvas-local px at lowering time (see
    /// `CanvasTransform`). Keep world-space geometry in the Model, built
    /// once, and pan / zoom by changing only this: the view no longer
    /// rebuilds the primitives, and off-canvas geometry is culled.
    transform: CanvasTransform = .{},
    /// Antialiased edges (coverage computed per pixel in the solid-quad
    /// shader) for polyline, lines, circle, arc and polygon. Off keeps the
    /// historical hard-edged quads, pixel for pixel. 3D plane layers ignore
    /// it (they always draw hard edges).
    antialias: bool = false,
};

/// Affine map from primitive coordinates ("world") to canvas-local px:
/// `local = (world.x * sx + tx, world.y * sy + ty)`. A negative `sy` gives
/// a y-up world. Positions and geometric extents (rect size, circle radius,
/// polygon points) are transformed; stroke `thickness`, `marker.size`,
/// `screen_radius` circles and text size stay in screen px. Pure data with
/// helpers for the usual pan / zoom maths in `update`.
pub const CanvasTransform = struct {
    sx: f32 = 1,
    sy: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn isIdentity(t: CanvasTransform) bool {
        return t.sx == 1 and t.sy == 1 and t.tx == 0 and t.ty == 0;
    }

    /// World point -> canvas-local px.
    pub fn apply(t: CanvasTransform, p: CanvasPoint) CanvasPoint {
        return .{ .x = p.x * t.sx + t.tx, .y = p.y * t.sy + t.ty };
    }

    /// Canvas-local px (e.g. `PointerEvent` local coords) -> world point.
    pub fn invert(t: CanvasTransform, p: CanvasPoint) CanvasPoint {
        return .{ .x = (p.x - t.tx) / t.sx, .y = (p.y - t.ty) / t.sy };
    }

    /// Move by (`dx`, `dy`) canvas px (a drag delta).
    pub fn pan(t: CanvasTransform, dx: f32, dy: f32) CanvasTransform {
        return .{ .sx = t.sx, .sy = t.sy, .tx = t.tx + dx, .ty = t.ty + dy };
    }

    /// Scale by `factor` about the canvas-local point (`px`, `py`), which
    /// stays fixed on screen (zoom at the cursor).
    pub fn zoomAt(t: CanvasTransform, px: f32, py: f32, factor: f32) CanvasTransform {
        return .{
            .sx = t.sx * factor,
            .sy = t.sy * factor,
            .tx = px - (px - t.tx) * factor,
            .ty = py - (py - t.ty) * factor,
        };
    }

    /// Uniform scale that fits the world box [x0,x1]x[y0,y1] into a
    /// `w` x `h` canvas with `margin` px on every side, centred; `y_up`
    /// flips y so larger world y is higher on screen.
    pub fn fit(x0: f32, y0: f32, x1: f32, y1: f32, w: f32, h: f32, margin: f32, y_up: bool) CanvasTransform {
        const bw = @max(x1 - x0, 1e-9);
        const bh = @max(y1 - y0, 1e-9);
        const s = @max(@min((w - 2 * margin) / bw, (h - 2 * margin) / bh), 1e-9);
        const cx = (x0 + x1) * 0.5;
        const cy = (y0 + y1) * 0.5;
        const sy = if (y_up) -s else s;
        return .{ .sx = s, .sy = sy, .tx = w * 0.5 - cx * s, .ty = h * 0.5 - cy * sy };
    }
};

pub fn CanvasCmd(comptime Msg: type) type {
    return struct {
        style: CanvasStyle = .{},
        /// Arena-allocated, pure data. Painter's order = slice order.
        primitives: []const CanvasPrimitive = &.{},
        /// A canvas is non-interactive by default. When non-null this Msg
        /// is dispatched on click (hit-test treats the canvas as an
        /// interactive leaf). The app pairs it with
        /// `hit_test.canvasLocalPoint` to turn the click into data
        /// coordinates — the Msg carries no value itself (HARDLINE §3
        /// bans fn-pointer callbacks on Cmd variants).
        msg: ?Msg = null,
        /// Accessible label / name for the a11y tree.
        label: []const u8 = "",
        /// Interactive canvas: when true, `teak.run` turns pointer input over
        /// this canvas into `CanvasEvent`s for the App's `canvasMsg` hook
        /// (see `core/pointer.zig`). Wheel events over it go to `canvasMsg`
        /// instead of `wheelMsg` / `scrollMsg`.
        pointer: bool = false,
        /// Identifies the canvas in `CanvasEvent.id`. Non-zero and distinct
        /// per interactive canvas.
        id: u32 = 0,
        /// Cursor shown while the pointer is over this (interactive) canvas;
        /// null keeps the arrow. The App's `cursorFor` hook still wins.
        cursor: ?CursorShape = null,
    };
}


pub const SceneStyle = struct {
    /// Intrinsic size in logical pixels; the scene is rendered at exactly
    /// this size (times the display scale), so it is never resampled.
    width: f32 = 320,
    height: f32 = 240,
    /// Flex weight on the parent's main axis (0 = intrinsic), as `image`.
    flex: f32 = 0,
};

pub fn SceneCmd(comptime Msg: type) type {
    return struct {
        style: SceneStyle = .{},
        /// The mesh to draw: a `Gpu.uploadMesh` handle, or — when the App
        /// declares the `resources` hook — the app key of a `.mesh`
        /// resource, which the run loop maps to the handle. 0 draws only
        /// the clear colour.
        mesh: scene.MeshHandle = scene.MESH_HANDLE_NONE,
        camera: scene.Camera = .{},
        /// Background colour of the scene.
        clear: [4]f32 = .{ 0.1, 0.11, 0.14, 1 },
        /// Multiplied into each line vertex's colour; line width in px.
        edge_color: [4]f32 = .{ 1, 1, 1, 1 },
        edge_px: f32 = 1.5,
        /// Content revision. The frame diff (`core/eql.zig`) compares the whole struct, but
        /// the mesh's *contents* live behind `mesh` — bump `key` when the
        /// geometry behind an unchanged handle/key changes (typically the
        /// resource `rev`), or the frame is skipped as unchanged.
        key: u64 = 0,
        /// Interactive-scene routing (see `core/pointer.zig`): with
        /// `pointer = true` and `id != 0` the scene receives `CanvasEvent`s
        /// like an interactive canvas.
        id: u32 = 0,
        pointer: bool = false,
        /// Dispatched on click when non-null (non-pointer scenes).
        msg: ?Msg = null,
        /// Accessible name for the a11y tree.
        label: []const u8 = "",
        /// Placed items, grid, gizmo, cut, material (`viewport3d`). With no
        /// items this is the legacy single-mesh scene.
        view: scene.view.View = .{},
    };
}


/// Keyboard grouping of list-row buttons (see docs/features/focus.md).
pub const Roving = enum {
    /// Not part of a group.
    none,
    /// Arrow keys move the keyboard focus between the group's buttons; Enter / Space activate.
    focus,
    /// As `focus`, and moving onto a button also dispatches its Msg (selection follows focus).
    select,
};

/// Keyboard-navigation options of a button (`CmdBuffer.buttonNav`).
pub const ButtonNav = struct {
    /// false: Tab / Shift+Tab skip it (clicks, Space, Enter and arrows still work). A list marks
    /// every row but the active one, so the whole list is ONE Tab stop.
    tab_stop: bool = true,
    roving: Roving = .none,
};

pub fn ButtonCmd(comptime Msg: type) type {
    return struct {
        msg: Msg,
        label: []const u8,
        style: ButtonStyle = .{},
        font: FontSpec = DEFAULT_FONT,
        /// When true, the button renders greyed-out and is non-interactive
        /// (hit-test/hover skip it). Layout is unaffected — same rect either
        /// way, so a disabled button stays where it is without shifting.
        disabled: bool = false,
        /// Semantics beyond "button": `.tab`, `.menuitem`, `.option`,
        /// `.treeitem`, `.link`, `.combobox` (+ `selected` / `expanded`).
        a11y: A11yHint = .{},
        /// Byte index into `label` of one ASCII character to underline (a
        /// menu mnemonic: the "F" of "File"). Null = no underline.
        underline: ?u16 = null,
        /// See `ButtonNav`.
        tab_stop: bool = true,
        roving: Roving = .none,
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
        /// When true, the input renders greyed-out and is non-interactive
        /// (no focus, selection, or cursor; hit-test/hover skip it). Layout
        /// is unaffected — same rect either way.
        disabled: bool = false,
        /// Accessible name (an input has no visible label of its own).
        a11y_label: []const u8 = "",
    };
}

/// Multi-line editable text (`text_area`). Layout sizes it like a canvas
/// (`width`/`min_width`, `height`, `flex`; it fills a stretching parent's
/// cross axis); render wraps `content` to the inner width, draws the
/// selection across lines, the caret, and the IME composition (from
/// `TransientState`) clipped to the box. Pointer input over it becomes
/// `TextEvent`s for the app's `textMsg` hook (see `core/text_event.zig`) -- the
/// framework never builds a Msg from a pointer, and nothing here is a callback.
pub fn TextAreaCmd(comptime Msg: type) type {
    return struct {
        /// Msg emitted when the area is clicked (the app sets its focus).
        focus_msg: Msg,
        /// Distinct non-zero id: `TextEvent.id` names the target.
        id: u32,
        content: []const u8,
        cursor: usize = 0,
        selection_anchor: ?usize = null,
        /// Scroll offsets into the wrapped content, from the Model.
        scroll_x: f32 = 0,
        scroll_y: f32 = 0,
        /// Sticky x for Up/Down (from the Model); lets the runtime resolve
        /// vertical motion against the real layout.
        goal_x: ?f32 = null,
        /// `.word` / `.char` wrap to the inner width; `.none` scrolls
        /// horizontally. (`.ellipsis` behaves like `.none`.)
        wrap: Wrap = .word,
        font: FontSpec = DEFAULT_FONT,
        style: TextInputStyle = .{},
        /// Box sizing: `width > 0` fixes the width, else `min_width` (or the
        /// parent's cross extent when it stretches); `flex` grows the main axis.
        width: f32 = 0,
        min_width: f32 = 120,
        height: f32 = 120,
        flex: f32 = 0,
        /// Inner padding inside the border.
        padding: f32 = 6,
        disabled: bool = false,
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

        push_group: *const GroupStyle,
        pop_group,
        push_grid: *const GridStyle,
        pop_grid,
        push_scroll: ScrollStyle,
        pop_scroll,
        push_overlay: *const OverlayStyle(Msg),
        pop_overlay,
        push_virtual_list: VirtualListStyle,
        pop_virtual_list,
        text: TextCmd,
        rich_text: RichTextCmd,
        image: ImageCmd,
        button: *const ButtonCmd(Msg),
        text_input: *const TextInputCmd(Msg),
        text_area: *const TextAreaCmd(Msg),
        checkbox: *const CheckboxCmd(Msg),
        radio: *const RadioCmd(Msg),
        slider: *const SliderCmd(Msg),
        divider: DividerStyle,
        canvas: *const CanvasCmd(Msg),
        scene3d: *const SceneCmd(Msg),

        /// Content equality for the frame diff. Variants whose payload lives out of
        /// line (a `*const` into the per-frame arena) compare the pointed-to
        /// payload, never the address: the arena hands out fresh addresses each frame.
        pub fn eql(a: @This(), b: @This()) bool {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |va, tag| {
                    const vb = @field(b, @tagName(tag));
                    const V = @TypeOf(va);
                    if (@typeInfo(V) == .pointer) {
                        if (va == vb) return true;
                        return eql_mod.deepEql(@typeInfo(V).pointer.child, va.*, vb.*);
                    }
                    return eql_mod.deepEql(V, va, vb);
                },
            }
        }
    };
}


/// The container kinds that bracket a region of the flat buffer.
/// `pushFormRow` / `popFormRow` are sugar over `push_group` / `pop_group`
/// (they emit exactly those Cmds), so a form row shows up here as
/// `.group` — no separate kind, matching what the buffer actually
/// records.
pub const BalanceKind = enum {
    group,
    grid,
    scroll,
    overlay,
    virtual_list,

    /// Name of the opening cmd, e.g. `"push_group"`.
    pub fn pushName(self: BalanceKind) []const u8 {
        return switch (self) {
            .group => "push_group",
            .grid => "push_grid",
            .scroll => "push_scroll",
            .overlay => "push_overlay",
            .virtual_list => "push_virtual_list",
        };
    }

    /// Name of the closing cmd, e.g. `"pop_group"`.
    pub fn popName(self: BalanceKind) []const u8 {
        return switch (self) {
            .group => "pop_group",
            .grid => "pop_grid",
            .scroll => "pop_scroll",
            .overlay => "pop_overlay",
            .virtual_list => "pop_virtual_list",
        };
    }
};

/// First balance fault found by `validateBalance`. A small POD struct so
/// callers can format a precise message (see `formatBalanceError`) or
/// branch on `tag` without any allocation.
pub const BalanceError = struct {
    pub const Tag = enum {
        /// A push_* had no matching pop_* before the buffer ended.
        /// `open_kind` / `open_index` name the dangling push.
        unclosed_push,
        /// A pop_* appeared with no open push_* to close.
        /// `close_kind` / `close_index` name the stray pop.
        stray_pop,
        /// A pop_* closed a push_* of a different kind (a crossed pair).
        /// `open_*` name the still-open push, `close_*` the wrong pop.
        mismatched_pop,
        /// Container nesting exceeded the validator's fixed depth
        /// (`MAX_BALANCE_DEPTH`, mirroring LayoutEngine's
        /// `MAX_BALANCE_DEPTH`); deeper input would also overflow the
        /// layout stack. Reported instead of panicked so the caller gets
        /// a named error. `open_kind` / `open_index` name the push that
        /// overflowed.
        depth_overflow,
    };

    tag: Tag,
    /// Kind of the relevant open push. Valid for `unclosed_push`,
    /// `mismatched_pop`, and `depth_overflow`; unused for `stray_pop`.
    open_kind: BalanceKind = .group,
    /// cmd index of that open push (or the overflowing push). Valid
    /// wherever `open_kind` is.
    open_index: usize = 0,
    /// Kind named by the offending pop. Valid for `stray_pop` and
    /// `mismatched_pop`; unused otherwise.
    close_kind: BalanceKind = .group,
    /// cmd index of the offending pop. Valid wherever `close_kind` is.
    close_index: usize = 0,
};

/// Container nesting cap for the whole framework: the layout passes' stacks
/// and the hit-test / render / a11y clip stacks are all sized to it. A
/// buffer nesting deeper is rejected by `validateBalance` as
/// `depth_overflow` (the run loop checks every frame, in every optimize
/// mode), and the stacks themselves `@panic` on overflow rather than write
/// out of bounds.
pub const MAX_BALANCE_DEPTH = 64;

/// `.group` / `.scroll` / … if `c` opens a container, else `null`.
/// `anytype` so it works for any `Cmd(Msg)` instantiation (the tag set
/// is Msg-independent).
fn pushKindOf(c: anytype) ?BalanceKind {
    return switch (c) {
        .push_group => .group,
        .push_grid => .grid,
        .push_scroll => .scroll,
        .push_overlay => .overlay,
        .push_virtual_list => .virtual_list,
        else => null,
    };
}

/// `.group` / `.scroll` / … if `c` closes a container, else `null`.
fn popKindOf(c: anytype) ?BalanceKind {
    return switch (c) {
        .pop_group => .group,
        .pop_grid => .grid,
        .pop_scroll => .scroll,
        .pop_overlay => .overlay,
        .pop_virtual_list => .virtual_list,
        else => null,
    };
}

/// Walk `cmds` once (O(n), zero allocation) and return the first
/// push/pop imbalance, or `null` if every container is balanced. `cmds`
/// is any slice of `Cmd(Msg)` — only Msg-independent tags are read, so
/// it takes `anytype` the same way the layout passes do.
///
/// Detects: unclosed push, stray pop, crossed pair (`mismatched_pop`),
/// and nesting past `MAX_BALANCE_DEPTH` (`depth_overflow`). Leaves
/// (text, button, …) are ignored.
pub fn validateBalance(cmds: anytype) ?BalanceError {
    const StackEntry = struct { kind: BalanceKind, index: usize };
    var stack: [MAX_BALANCE_DEPTH]StackEntry = undefined;
    var depth: usize = 0;

    for (cmds, 0..) |c, i| {
        if (pushKindOf(c)) |kind| {
            if (depth >= MAX_BALANCE_DEPTH) {
                return .{ .tag = .depth_overflow, .open_kind = kind, .open_index = i };
            }
            stack[depth] = .{ .kind = kind, .index = i };
            depth += 1;
        } else if (popKindOf(c)) |kind| {
            if (depth == 0) {
                return .{ .tag = .stray_pop, .close_kind = kind, .close_index = i };
            }
            const open = stack[depth - 1];
            if (open.kind != kind) {
                return .{
                    .tag = .mismatched_pop,
                    .open_kind = open.kind,
                    .open_index = open.index,
                    .close_kind = kind,
                    .close_index = i,
                };
            }
            depth -= 1;
        }
    }

    if (depth > 0) {
        const open = stack[depth - 1];
        return .{ .tag = .unclosed_push, .open_kind = open.kind, .open_index = open.index };
    }
    return null;
}

/// Render a `BalanceError` as one human/LLM-actionable line into `buf`,
/// returning the written slice. Zero allocation — the caller owns the
/// buffer; 128 bytes is always enough. If `buf` is too small the result
/// is an empty slice rather than a partial line.
pub fn formatBalanceError(err: BalanceError, buf: []u8) []const u8 {
    return switch (err.tag) {
        .unclosed_push => std.fmt.bufPrint(
            buf,
            "{s} at cmd #{d} was never popped",
            .{ err.open_kind.pushName(), err.open_index },
        ),
        .stray_pop => std.fmt.bufPrint(
            buf,
            "{s} at cmd #{d} has no matching push",
            .{ err.close_kind.popName(), err.close_index },
        ),
        .mismatched_pop => std.fmt.bufPrint(
            buf,
            "{s} at cmd #{d} was closed by {s} at cmd #{d}",
            .{ err.open_kind.pushName(), err.open_index, err.close_kind.popName(), err.close_index },
        ),
        .depth_overflow => std.fmt.bufPrint(
            buf,
            "{s} at cmd #{d} exceeds the max container nesting depth ({d})",
            .{ err.open_kind.pushName(), err.open_index, MAX_BALANCE_DEPTH },
        ),
    } catch buf[0..0];
}


pub const FormRowOpts = struct {
    /// Label to the left of the content (theme.text_color). Empty
    /// string skips the label cmd.
    label: []const u8 = "",
    /// Suffix to the right of the content (theme.muted_color, small
    /// font). Typical: unit suffixes like "kg", "mm/s", "Hz".
    units: []const u8 = "",
    /// Message drawn below the row in theme.danger_color (small font).
    /// Empty = no validation row. Apps drive this from their own
    /// validation state in Model.
    validation: []const u8 = "",
    /// Horizontal gap between label, content, and units.
    gap: f32 = 8,
    /// Vertical gap between the content row and the validation message.
    validation_gap: f32 = 4,
};

/// Per-row state captured at push time and consumed at pop time so
/// `popFormRow()` knows what to append. A small fixed-depth stack
/// supports nested rows (e.g. a row inside an overlay/modal). Eight
/// is the same depth the layout engine uses for its group stack.
const PendingFormRow = struct {
    units: []const u8,
    validation: []const u8,
};

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
        /// Stack of in-flight form rows; pushed by `pushFormRow`,
        /// drained by `popFormRow`. Reset by `reset()` along with the
        /// rest of the per-frame state.
        form_row_stack: [8]PendingFormRow = undefined,
        form_row_depth: u8 = 0,

        /// Build a `Cmd` whose big payload lives in the per-frame arena (the union
        /// holds an 8-byte pointer, keeping every slot of the flat buffer small).
        /// Arena-only, no per-widget free; the payload is plain data like any other.
        pub fn box(self: *Self, comptime tag: std.meta.Tag(CmdT), payload: @typeInfo(@FieldType(CmdT, @tagName(tag))).pointer.child) CmdT {
            const p = self.arena.allocator().create(@TypeOf(payload)) catch oom();
            p.* = payload;
            return @unionInit(CmdT, @tagName(tag), p);
        }

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
            self.form_row_depth = 0;
        }


        pub fn pushGroup(self: *Self, style: GroupStyle) void {
            self.cmds.append(self.backing, self.box(.push_group, style)) catch oom();
        }

        pub fn popGroup(self: *Self) void {
            self.cmds.append(self.backing, .pop_group) catch oom();
        }

        /// Open a grid: the cmds up to `popGrid()` fill its cells row by row
        /// (one direct child per cell; a nested group makes a multi-widget cell).
        pub fn pushGrid(self: *Self, style: GridStyle) void {
            self.cmds.append(self.backing, self.box(.push_grid, style)) catch oom();
        }

        pub fn popGrid(self: *Self) void {
            self.cmds.append(self.backing, .pop_grid) catch oom();
        }

        /// Invisible flex filler: an empty zero-padding group with the given
        /// flex weight, so it soaks up leftover main-axis space (pin a button
        /// to the far end of a row, push a footer down a column). Emits a
        /// `push_group` / `pop_group` pair; no new Cmd variant.
        pub fn spacer(self: *Self, flex: f32) void {
            self.pushGroup(.{ .padding = 0, .gap = 0, .flex = flex });
            self.popGroup();
        }

        pub fn text(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.body,
                .color = self.theme.text_color,
            } }) catch oom();
        }

        /// Wrapped body text (`wrap = .word`): breaks at UAX #14 opportunities
        /// to the width layout gives it, shrinks with its row, grows its
        /// height to the line count. Long unbreakable tokens break at graphemes.
        pub fn paragraph(self: *Self, content: []const u8) void {
            self.paragraphStyled(content, self.theme.typography.body, self.theme.text_color, .{});
        }

        /// `paragraph` with an explicit font, color and options.
        pub fn paragraphStyled(self: *Self, content: []const u8, font: FontSpec, color: [4]f32, opts: ParagraphOpts) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = font,
                .color = color,
                .wrap = opts.wrap,
                .max_lines = opts.max_lines,
                .text_align = opts.text_align,
            } }) catch oom();
        }

        /// One line of body text truncated with "…" where it does not fit.
        pub fn textEllipsis(self: *Self, content: []const u8) void {
            self.paragraphStyled(content, self.theme.typography.body, self.theme.text_color, .{ .wrap = .ellipsis });
        }

        /// Body text in the theme's heading color/size — for section
        /// titles. Saves an explicit FontSpec at every call site.
        pub fn heading(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.heading,
                .color = self.theme.heading_color,
            } }) catch oom();
        }

        /// Body text in the theme's "muted" color — placeholders, units,
        /// secondary labels.
        pub fn textMuted(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.small,
                .color = self.theme.muted_color,
            } }) catch oom();
        }

        /// Body text in the theme's danger color — validation messages.
        pub fn textDanger(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.small,
                .color = self.theme.danger_color,
            } }) catch oom();
        }

        /// Small text in the theme's warning color — non-fatal cautions
        /// (the sibling of `textDanger`).
        pub fn textWarning(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.small,
                .color = self.theme.warning_color,
            } }) catch oom();
        }

        /// Monospace text in body color — column data, code, numerics.
        pub fn textMono(self: *Self, content: []const u8) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = self.theme.typography.mono,
                .color = self.theme.text_color,
            } }) catch oom();
        }

        /// Text with explicit font + color, bypassing theme defaults.
        /// Useful for one-off styled labels (debug overlays, custom
        /// chrome) where the theme doesn't provide a fitting token.
        pub fn textStyled(self: *Self, content: []const u8, font: FontSpec, color: [4]f32) void {
            self.cmds.append(self.backing, .{ .text = .{
                .content = content,
                .font = font,
                .color = color,
            } }) catch oom();
        }

        pub fn divider(self: *Self) void {
            self.cmds.append(self.backing, .{ .divider = self.theme.divider }) catch oom();
        }

        pub fn dividerStyled(self: *Self, style: DividerStyle) void {
            self.cmds.append(self.backing, .{ .divider = style }) catch oom();
        }

        pub fn button(self: *Self, msg: Msg, label: []const u8) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = self.theme.button,
                .font = self.theme.typography.body,
            })) catch oom();
        }

        /// A button with accessibility semantics (a tab, menu item, option, tree item).
        pub fn buttonA11y(self: *Self, msg: Msg, label: []const u8, hint: A11yHint) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = self.theme.button,
                .font = self.theme.typography.body,
                .a11y = hint,
            })) catch oom();
        }

        /// `buttonA11y` with an explicit style.
        pub fn buttonStyledA11y(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle, hint: A11yHint) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
                .a11y = hint,
            })) catch oom();
        }

        pub fn buttonStyled(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
            })) catch oom();
        }

        /// `buttonStyled` with keyboard-navigation options: list rows pass
        /// `.{ .tab_stop = false, .roving = .focus }` (all but the active row).
        pub fn buttonNav(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle, nav: ButtonNav) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
                .tab_stop = nav.tab_stop,
                .roving = nav.roving,
            })) catch oom();
        }

        /// Emit a greyed-out, non-interactive button. Same as `button`
        /// but sets `.disabled = true` — the rect is identical, so the
        /// button keeps its place instead of shifting the layout when it
        /// would otherwise be conditionally omitted.
        pub fn buttonDisabled(self: *Self, msg: Msg, label: []const u8) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = self.theme.button,
                .font = self.theme.typography.body,
                .disabled = true,
            })) catch oom();
        }

        /// A styled button whose label has one underlined character (a
        /// mnemonic hint). `at` indexes `label`; out of range draws nothing.
        pub fn buttonStyledUnderlined(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle, at: ?usize) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
                .underline = if (at) |i| @intCast(i) else null,
            })) catch unreachable;
        }

        /// `buttonDisabled` with an explicit style (a compact menu row stays
        /// its own height when disabled).
        pub fn buttonStyledDisabled(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle) void {
            self.cmds.append(self.backing, self.box(.button, .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
                .disabled = true,
            })) catch unreachable;
        }

        pub fn textInput(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
        ) void {
            self.cmds.append(self.backing, self.box(.text_input, .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = self.theme.text_input,
                .font = self.theme.typography.body,
            })) catch oom();
        }

        /// A text input with an accessible name ("New item", "Search"): what a
        /// screen reader announces for the field.
        pub fn textInputA11y(self: *Self, focus_msg: Msg, content: []const u8, cursor: usize, label: []const u8) void {
            self.cmds.append(self.backing, self.box(.text_input, .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = self.theme.text_input,
                .font = self.theme.typography.body,
                .a11y_label = label,
            })) catch oom();
        }

        pub fn textInputStyled(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
            style: TextInputStyle,
        ) void {
            self.cmds.append(self.backing, self.box(.text_input, .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = style,
                .font = self.theme.typography.body,
            })) catch oom();
        }

        /// Emit a greyed-out, non-interactive text input. Same as
        /// `textInput` but sets `.disabled = true` — the rect is identical,
        /// so the input keeps its place instead of shifting the layout.
        pub fn textInputDisabled(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
        ) void {
            self.cmds.append(self.backing, self.box(.text_input, .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = self.theme.text_input,
                .font = self.theme.typography.body,
                .disabled = true,
            })) catch oom();
        }

        pub fn pushScroll(self: *Self, style: ScrollStyle) void {
            self.cmds.append(self.backing, .{ .push_scroll = style }) catch oom();
        }

        pub fn popScroll(self: *Self) void {
            self.cmds.append(self.backing, .pop_scroll) catch oom();
        }

        pub fn checkbox(self: *Self, msg: Msg, checked: bool, label: []const u8) void {
            self.cmds.append(self.backing, self.box(.checkbox, .{
                .msg = msg,
                .checked = checked,
                .label = label,
                .style = self.theme.checkbox,
                .font = self.theme.typography.body,
            })) catch oom();
        }

        pub fn radio(self: *Self, msg: Msg, selected: bool, label: []const u8) void {
            self.cmds.append(self.backing, self.box(.radio, .{
                .msg = msg,
                .selected = selected,
                .label = label,
                .style = self.theme.radio,
                .font = self.theme.typography.body,
            })) catch oom();
        }

        pub fn slider(self: *Self, grab_msg: Msg, value: f32) void {
            self.cmds.append(self.backing, self.box(.slider, .{
                .grab_msg = grab_msg,
                .value = value,
                .style = self.theme.slider,
            })) catch oom();
        }


        pub fn pushOverlay(self: *Self, style: OverlayStyle(Msg)) void {
            self.cmds.append(self.backing, self.box(.push_overlay, style)) catch oom();
        }

        pub fn popOverlay(self: *Self) void {
            self.cmds.append(self.backing, .pop_overlay) catch oom();
        }

        pub fn pushVirtualList(self: *Self, style: VirtualListStyle) void {
            self.cmds.append(self.backing, .{ .push_virtual_list = style }) catch oom();
        }

        pub fn popVirtualList(self: *Self) void {
            self.cmds.append(self.backing, .pop_virtual_list) catch oom();
        }

        pub fn image(self: *Self, handle: TextureHandle, style: ImageStyle) void {
            self.cmds.append(self.backing, .{ .image = .{
                .handle = handle,
                .style = style,
            } }) catch oom();
        }

        /// Emit a non-interactive canvas. `style` carries size + optional
        /// bg; `primitives` are arena-owned pure-data draw ops (build them
        /// with `teak.chart.lineChartPrimitives` or by hand).
        pub fn canvas(self: *Self, style: CanvasStyle, primitives: []const CanvasPrimitive) void {
            self.cmds.append(self.backing, self.box(.canvas, .{
                .style = style,
                .primitives = primitives,
            })) catch oom();
        }

        /// Canvas with an accessibility label (announced by the a11y tree)
        /// but still non-interactive.
        pub fn canvasLabeled(
            self: *Self,
            style: CanvasStyle,
            primitives: []const CanvasPrimitive,
            label: []const u8,
        ) void {
            self.cmds.append(self.backing, self.box(.canvas, .{
                .style = style,
                .primitives = primitives,
                .label = label,
            })) catch oom();
        }

        /// Clickable canvas: `msg` fires on click. The app pairs it with
        /// `hit_test.canvasLocalPoint` to recover the data coordinate that
        /// was clicked (the Msg carries no value — HARDLINE §3).
        pub fn canvasClickable(
            self: *Self,
            msg: Msg,
            style: CanvasStyle,
            primitives: []const CanvasPrimitive,
            label: []const u8,
        ) void {
            self.cmds.append(self.backing, self.box(.canvas, .{
                .style = style,
                .primitives = primitives,
                .msg = msg,
                .label = label,
            })) catch oom();
        }

        /// Emit a 3D scene leaf; see `SceneCmd`. Typical use:
        /// `cb.scene3d(.{ .style = .{ .width = 480, .height = 360 }, .mesh = key, .camera = cam, .key = rev })`.
        pub fn scene3d(self: *Self, cmd: SceneCmd(Msg)) void {
            self.cmds.append(self.backing, self.box(.scene3d, cmd)) catch oom();
        }

        /// The 3D viewport: `scene3d` with `cmd.view` populated (placed
        /// `Item`s, grid, gizmo, section cut). Same Cmd, same passes.
        pub const viewport3d = scene3d;

        /// Interactive canvas: pointer input over it (down/move/up/wheel/
        /// leave, plus `layout` on first layout and resize) reaches the
        /// App's `canvasMsg(model, CanvasEvent)` hook tagged with `id`.
        /// That is how an app implements pan / zoom / drag over a canvas —
        /// the primitives are still pure data built from the Model.
        pub fn canvasInteractive(
            self: *Self,
            style: CanvasStyle,
            primitives: []const CanvasPrimitive,
            id: u32,
            label: []const u8,
        ) void {
            self.cmds.append(self.backing, self.box(.canvas, .{
                .style = style,
                .primitives = primitives,
                .label = label,
                .pointer = true,
                .id = id,
            })) catch oom();
        }

        /// `canvasInteractive` that is also a keyboard-navigable leaf: Tab lands on
        /// it (focus ring), Space / Enter dispatch `focus_msg` (a no-op Msg is fine)
        /// and the keys the app's hooks decline reach `canvasMsg` as `.key` events.
        pub fn canvasInteractiveFocusable(
            self: *Self,
            style: CanvasStyle,
            primitives: []const CanvasPrimitive,
            id: u32,
            label: []const u8,
            focus_msg: Msg,
        ) void {
            self.cmds.append(self.backing, self.box(.canvas, .{
                .style = style,
                .primitives = primitives,
                .label = label,
                .pointer = true,
                .id = id,
                .msg = focus_msg,
            })) catch oom();
        }

        pub fn textInputSelected(
            self: *Self,
            focus_msg: Msg,
            content: []const u8,
            cursor: usize,
            selection_anchor: ?usize,
            style: TextInputStyle,
        ) void {
            self.cmds.append(self.backing, self.box(.text_input, .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .selection_anchor = selection_anchor,
                .style = style,
                .font = self.theme.typography.body,
            })) catch oom();
        }

        /// Multi-line editable text; see `TextAreaCmd`. The theme's
        /// `text_input` style and body font are used.
        pub fn textArea(self: *Self, c: TextAreaCmd(Msg)) void {
            self.cmds.append(self.backing, self.box(.text_area, c)) catch oom();
        }

        /// `textArea` with the theme's input style + body font filled in.
        pub fn textAreaThemed(self: *Self, focus_msg: Msg, id: u32, content: []const u8, cursor: usize, selection_anchor: ?usize) void {
            self.textArea(.{
                .focus_msg = focus_msg,
                .id = id,
                .content = content,
                .cursor = cursor,
                .selection_anchor = selection_anchor,
                .style = self.theme.text_input,
                .font = self.theme.typography.body,
            });
        }

        pub fn richText(
            self: *Self,
            content: []const u8,
            spans: []const RichTextSpan,
        ) void {
            self.cmds.append(self.backing, .{ .rich_text = .{
                .content = content,
                .spans = spans,
            } }) catch oom();
        }

        /// Wrapped `rich_text` (mixed fonts / colours per line, breaking across
        /// spans). Uses the theme's body font and text colour as the defaults.
        pub fn richParagraph(self: *Self, content: []const u8, spans: []const RichTextSpan, opts: ParagraphOpts) void {
            self.cmds.append(self.backing, .{ .rich_text = .{
                .content = content,
                .spans = spans,
                .default_font = self.theme.typography.body,
                .default_color = self.theme.text_color,
                .wrap = opts.wrap,
                .max_lines = opts.max_lines,
                .text_align = opts.text_align,
            } }) catch oom();
        }

        pub fn richTextStyled(self: *Self, c: RichTextCmd) void {
            self.cmds.append(self.backing, .{ .rich_text = c }) catch oom();
        }

        /// Begin a form row. Emits an outer vertical group + an inner
        /// horizontal group, then writes the label. The caller emits
        /// their content cmds (text_input, slider, etc.) and closes the
        /// row with `popFormRow()`.
        ///
        /// Layout shape:
        ///   vertical
        ///     horizontal: [label] [content] [units]
        ///     [validation]
        pub fn pushFormRow(self: *Self, opts: FormRowOpts) void {
            // Form-row nesting is bounded at eight.
            if (self.form_row_depth >= self.form_row_stack.len) @panic("teak: pushFormRow nested deeper than 8 (form_row_stack capacity)");
            self.cmds.append(self.backing, self.box(.push_group, .{
                .direction = .vertical,
                .padding = 0,
                .gap = opts.validation_gap,
            })) catch oom();
            self.cmds.append(self.backing, self.box(.push_group, .{
                .direction = .horizontal,
                .padding = 0,
                .gap = opts.gap,
            })) catch oom();
            if (opts.label.len > 0) {
                self.cmds.append(self.backing, .{ .text = .{
                    .content = opts.label,
                    .font = self.theme.typography.body,
                    .color = self.theme.text_color,
                } }) catch oom();
            }
            self.form_row_stack[self.form_row_depth] = .{
                .units = opts.units,
                .validation = opts.validation,
            };
            self.form_row_depth += 1;
        }

        /// Close the most recent `pushFormRow`. Appends the units
        /// suffix (if any), closes the horizontal group, appends the
        /// validation message (if any), then closes the outer vertical
        /// group.
        pub fn popFormRow(self: *Self) void {
            if (self.form_row_depth == 0) @panic("teak: popFormRow without a matching pushFormRow");
            self.form_row_depth -= 1;
            const pending = self.form_row_stack[self.form_row_depth];
            if (pending.units.len > 0) {
                self.cmds.append(self.backing, .{ .text = .{
                    .content = pending.units,
                    .font = self.theme.typography.small,
                    .color = self.theme.muted_color,
                } }) catch oom();
            }
            self.cmds.append(self.backing, .pop_group) catch oom();
            if (pending.validation.len > 0) {
                self.cmds.append(self.backing, .{ .text = .{
                    .content = pending.validation,
                    .font = self.theme.typography.small,
                    .color = self.theme.danger_color,
                } }) catch oom();
            }
            self.cmds.append(self.backing, .pop_group) catch oom();
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

            const content = arena_alloc.alloc(u8, total_len) catch oom();
            const spans = arena_alloc.alloc(RichTextSpan, parts.len) catch oom();

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
            } }) catch oom();
        }
    };
}


































