const std = @import("std");
const oom = @import("oom.zig").oom;
const text = @import("text.zig");
const theme_mod = @import("theme.zig");
const scene = @import("scene.zig");
const eql = @import("eql.zig");

pub const FontSpec = text.FontSpec;
const DEFAULT_FONT = text.DEFAULT_FONT;
const TextureHandle = text.TextureHandle;

// ── Shared (Msg-independent) types ─────────────────────────────────

pub const Direction = enum { vertical, horizontal };

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

    pub fn padX(self: GroupStyle) f32 {
        return self.pad_x orelse self.padding;
    }

    pub fn padY(self: GroupStyle) f32 {
        return self.pad_y orelse self.padding;
    }
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
    /// Flex weight on the parent's main axis (see `GroupStyle.flex`).
    flex: f32 = 0,
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
    /// Non-zero opts this region into wheel routing and layout reports:
    /// `teak.run` hands wheel events over its innermost hovered `id != 0`
    /// scroll region to the App's `scrollMsg(model, id, dx, dy)`, and
    /// reports its viewport + content size through `scrollLayoutMsg` on
    /// first layout and whenever either changes. Apps give each such
    /// region a distinct id.
    id: u32 = 0,
};

// ── Overlay (HARDLINE §2 escape hatch 5) ───────────────────────────
//
// Absolute-positioned floating region. Content between push_overlay /
// pop_overlay draws above non-overlay content and hit-tests before it.
// Position is explicit (app fills .x/.y from prev-frame anchor or mouse
// coords — same pattern as the slider). Width/height = 0 means measured
// from children; >0 = forced size.
//
// Promoted to a Msg-generic type so `backdrop_msg` (a click-outside-to-
// close hook) can carry a Msg without smuggling a function pointer
// (HARDLINE §3). Existing call sites use anonymous struct literals
// (`cb.pushOverlay(.{ .x = ... })`) so the type lift is transparent.

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
        /// Dispatched when the click lands inside the overlay's rect but
        /// on no interactive leaf — pair with `modal = true` for the
        /// "click outside the dialog to dismiss it" idiom. The Msg is
        /// data only (HARDLINE §3 bans fn-pointer callbacks). Independent
        /// of `modal`, but only meaningful together.
        backdrop_msg: ?Msg = null,
    };
}

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

// ── Canvas (charts + custom 2D drawing, consumer issue #3) ─────────
//
// A fixed-size leaf that draws a list of pure-data 2D primitives through
// the EXISTING solid-quad pipeline — no shader / GPU-backend changes.
// Axis-aligned prims are plain quads; polyline segments are emitted as
// 4-corner quads (see render/vertex.zig `emitQuadCorners`). Coordinates
// on every primitive are canvas-LOCAL logical pixels (f32), origin at the
// canvas rect's top-left; the render pass translates them to window
// space and clips to the canvas rect. No callbacks, no closures, no
// text-in-canvas in v1 — apps compose regular `text` cmds around it.
//
// HARDLINE: `CanvasPrimitive` is a data tagged union (like `Cmd` itself);
// it carries no function pointers. The `primitives` slice is built by
// `view` into the per-frame arena (typically via `core/chart.zig`).

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
    };
}

// ── 3D scene (kerf: depth-tested mesh inside the UI) ────────────────
//
// A fixed-size leaf the Gpu fills with a rendered 3D scene (see
// `core/scene.zig`, docs/features/scene3d.md). Like `image`, it is layout
// + a draw record: the render pass emits a `SceneDraw`; the Gpu renders the
// mesh offscreen and composites it at the leaf's rect.

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
    };
}

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
        /// When true, the button renders greyed-out and is non-interactive
        /// (hit-test/hover skip it). Layout is unaffected — same rect either
        /// way, so a disabled button stays where it is without shifting.
        disabled: bool = false,
        /// Byte index into `label` of one ASCII character to underline (a
        /// menu mnemonic: the "F" of "File"). Null = no underline.
        underline: ?u16 = null,
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
        push_overlay: OverlayStyle(Msg),
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
        canvas: CanvasCmd(Msg),
        scene3d: SceneCmd(Msg),
    };
}

// ── Cmd-buffer balance validation ──────────────────────────────────
//
// Every push_* Cmd (push_group / push_scroll / push_overlay /
// push_virtual_list) must be closed by the matching pop_*. A missing
// pop, a stray pop, or a *crossed* pair (push_group … pop_overlay) is
// otherwise a silent bug: LayoutEngine's FixedStack only panics on
// overflow/underflow, and a balanced-but-crossed buffer doesn't even
// trip that — it just produces wrong rects. `validateBalance` walks the
// flat buffer once and names the first imbalance so it surfaces as an
// actionable message instead of a mystery layout glitch.
//
// Pure, O(n), zero allocation. Intended for debug builds / tests / the
// host loop's per-frame guard (see docs/features/layout.md).

/// The four container kinds that bracket a region of the flat buffer.
/// `pushFormRow` / `popFormRow` are sugar over `push_group` / `pop_group`
/// (they emit exactly those Cmds), so a form row shows up here as
/// `.group` — no separate kind, matching what the buffer actually
/// records.
pub const BalanceKind = enum {
    group,
    scroll,
    overlay,
    virtual_list,

    /// Name of the opening cmd, e.g. `"push_group"`.
    pub fn pushName(self: BalanceKind) []const u8 {
        return switch (self) {
            .group => "push_group",
            .scroll => "push_scroll",
            .overlay => "push_overlay",
            .virtual_list => "push_virtual_list",
        };
    }

    /// Name of the closing cmd, e.g. `"pop_group"`.
    pub fn popName(self: BalanceKind) []const u8 {
        return switch (self) {
            .group => "pop_group",
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

// ── Form row (ergonomic gap 4) ─────────────────────────────────────
//
// Composite [label, content, units] horizontal layout with an optional
// validation message stacked below it. push/pop pair so the app can
// emit any cmds it wants in the middle (text_input, slider, mixedText,
// etc.) — the framework brackets the label + units + validation.

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

        // ── Convenience emitters ───────────────────────────────────

        pub fn pushGroup(self: *Self, style: GroupStyle) void {
            self.cmds.append(self.backing, .{ .push_group = style }) catch oom();
        }

        pub fn popGroup(self: *Self) void {
            self.cmds.append(self.backing, .pop_group) catch oom();
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
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = self.theme.button,
                .font = self.theme.typography.body,
            } }) catch oom();
        }

        pub fn buttonStyled(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
            } }) catch oom();
        }

        /// Emit a greyed-out, non-interactive button. Same as `button`
        /// but sets `.disabled = true` — the rect is identical, so the
        /// button keeps its place instead of shifting the layout when it
        /// would otherwise be conditionally omitted.
        pub fn buttonDisabled(self: *Self, msg: Msg, label: []const u8) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = self.theme.button,
                .font = self.theme.typography.body,
                .disabled = true,
            } }) catch oom();
        }

        /// A styled button whose label has one underlined character (a
        /// mnemonic hint). `at` indexes `label`; out of range draws nothing.
        pub fn buttonStyledUnderlined(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle, at: ?usize) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
                .underline = if (at) |i| @intCast(i) else null,
            } }) catch unreachable;
        }

        /// `buttonDisabled` with an explicit style (a compact menu row stays
        /// its own height when disabled).
        pub fn buttonStyledDisabled(self: *Self, msg: Msg, label: []const u8, style: ButtonStyle) void {
            self.cmds.append(self.backing, .{ .button = .{
                .msg = msg,
                .label = label,
                .style = style,
                .font = self.theme.typography.body,
                .disabled = true,
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
            } }) catch oom();
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
                .font = self.theme.typography.body,
            } }) catch oom();
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
            self.cmds.append(self.backing, .{ .text_input = .{
                .focus_msg = focus_msg,
                .content = content,
                .cursor = cursor,
                .style = self.theme.text_input,
                .font = self.theme.typography.body,
                .disabled = true,
            } }) catch oom();
        }

        pub fn pushScroll(self: *Self, style: ScrollStyle) void {
            self.cmds.append(self.backing, .{ .push_scroll = style }) catch oom();
        }

        pub fn popScroll(self: *Self) void {
            self.cmds.append(self.backing, .pop_scroll) catch oom();
        }

        pub fn checkbox(self: *Self, msg: Msg, checked: bool, label: []const u8) void {
            self.cmds.append(self.backing, .{ .checkbox = .{
                .msg = msg,
                .checked = checked,
                .label = label,
                .style = self.theme.checkbox,
                .font = self.theme.typography.body,
            } }) catch oom();
        }

        pub fn radio(self: *Self, msg: Msg, selected: bool, label: []const u8) void {
            self.cmds.append(self.backing, .{ .radio = .{
                .msg = msg,
                .selected = selected,
                .label = label,
                .style = self.theme.radio,
                .font = self.theme.typography.body,
            } }) catch oom();
        }

        pub fn slider(self: *Self, grab_msg: Msg, value: f32) void {
            self.cmds.append(self.backing, .{ .slider = .{
                .grab_msg = grab_msg,
                .value = value,
                .style = self.theme.slider,
            } }) catch oom();
        }

        // ── Overlay / virtual list / image / rich text ─────────────

        pub fn pushOverlay(self: *Self, style: OverlayStyle(Msg)) void {
            self.cmds.append(self.backing, .{ .push_overlay = style }) catch oom();
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
            self.cmds.append(self.backing, .{ .canvas = .{
                .style = style,
                .primitives = primitives,
            } }) catch oom();
        }

        /// Canvas with an accessibility label (announced by the a11y tree)
        /// but still non-interactive.
        pub fn canvasLabeled(
            self: *Self,
            style: CanvasStyle,
            primitives: []const CanvasPrimitive,
            label: []const u8,
        ) void {
            self.cmds.append(self.backing, .{ .canvas = .{
                .style = style,
                .primitives = primitives,
                .label = label,
            } }) catch oom();
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
            self.cmds.append(self.backing, .{ .canvas = .{
                .style = style,
                .primitives = primitives,
                .msg = msg,
                .label = label,
            } }) catch oom();
        }

        /// Emit a 3D scene leaf; see `SceneCmd`. Typical use:
        /// `cb.scene3d(.{ .style = .{ .width = 480, .height = 360 }, .mesh = key, .camera = cam, .key = rev })`.
        pub fn scene3d(self: *Self, cmd: SceneCmd(Msg)) void {
            self.cmds.append(self.backing, .{ .scene3d = cmd }) catch oom();
        }

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
            self.cmds.append(self.backing, .{ .canvas = .{
                .style = style,
                .primitives = primitives,
                .label = label,
                .pointer = true,
                .id = id,
            } }) catch oom();
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
                .font = self.theme.typography.body,
            } }) catch oom();
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
            // Cap of 8 in-flight form rows; deeper nesting is a bug, not
            // a growth trigger. Assert mirrors the layout stacks: loud
            // crash in Debug/ReleaseSafe, zero cost in ReleaseFast.
            if (self.form_row_depth >= self.form_row_stack.len) @panic("teak: pushFormRow nested deeper than 8 (form_row_stack capacity)");
            // Outer vertical (content row + validation message).
            self.cmds.append(self.backing, .{ .push_group = .{
                .direction = .vertical,
                .padding = 0,
                .gap = opts.validation_gap,
            } }) catch oom();
            // Inner horizontal (label + content + units).
            self.cmds.append(self.backing, .{ .push_group = .{
                .direction = .horizontal,
                .padding = 0,
                .gap = opts.gap,
            } }) catch oom();
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
    // Plain `button` leaves the button interactive.
    try testing.expect(!cb.cmds.items[3].button.disabled);
}

test "CmdBuffer.buttonDisabled sets disabled, plain button leaves it false" {
    const testing = std.testing;

    const Msg = union(enum) { go };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.button(.go, "Add");
    cb.buttonDisabled(.go, "Add");

    try testing.expect(!cb.cmds.items[0].button.disabled);
    try testing.expect(cb.cmds.items[1].button.disabled);
    try testing.expectEqualStrings("Add", cb.cmds.items[1].button.label);
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
    // Plain `textInput` leaves the input interactive.
    try testing.expect(!cb.cmds.items[0].text_input.disabled);
}

test "CmdBuffer.textInputDisabled sets disabled, plain textInput leaves it false" {
    const testing = std.testing;

    const Msg = union(enum) { focus };

    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.textInput(.focus, "hi", 2);
    cb.textInputDisabled(.focus, "hi", 2);

    try testing.expect(!cb.cmds.items[0].text_input.disabled);
    try testing.expect(cb.cmds.items[1].text_input.disabled);
    try testing.expectEqualStrings("hi", cb.cmds.items[1].text_input.content);
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

test "CmdBuffer.pushFormRow: emits vertical, horizontal, label" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushFormRow(.{ .label = "Mass", .units = "kg" });
    cb.textInput(.focus, "10", 2);
    cb.popFormRow();

    // Expected sequence:
    //   0: push_group (outer vertical)
    //   1: push_group (inner horizontal)
    //   2: text "Mass"
    //   3: text_input
    //   4: text "kg" (units)
    //   5: pop_group (inner horizontal)
    //   6: pop_group (outer vertical)
    try testing.expectEqual(@as(usize, 7), cb.cmds.items.len);
    try testing.expectEqual(Direction.vertical, cb.cmds.items[0].push_group.direction);
    try testing.expectEqual(Direction.horizontal, cb.cmds.items[1].push_group.direction);
    try testing.expectEqualStrings("Mass", cb.cmds.items[2].text.content);
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[3]));
    try testing.expectEqualStrings("kg", cb.cmds.items[4].text.content);
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[5]));
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[6]));
}

test "CmdBuffer.pushFormRow with validation: validation text sits below content row" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushFormRow(.{
        .label = "Speed",
        .units = "m/s",
        .validation = "must be positive",
    });
    cb.textInput(.focus, "-5", 2);
    cb.popFormRow();

    // Validation comes AFTER the inner pop_group (between inner pop and
    // outer pop) so it stacks vertically under the content row.
    // Sequence:
    //   0: push_group (vertical)
    //   1: push_group (horizontal)
    //   2: text "Speed"
    //   3: text_input
    //   4: text "m/s"
    //   5: pop_group (horizontal)
    //   6: text "must be positive"  (danger color)
    //   7: pop_group (vertical)
    try testing.expectEqual(@as(usize, 8), cb.cmds.items.len);
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[5]));
    try testing.expectEqualStrings("must be positive", cb.cmds.items[6].text.content);
    // Validation uses danger color.
    try testing.expectEqual(cb.theme.danger_color, cb.cmds.items[6].text.color);
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[7]));
}

test "CmdBuffer.pushFormRow: no label/units/validation → minimal bracket" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushFormRow(.{});
    cb.textInput(.focus, "", 0);
    cb.popFormRow();

    // 4 cmds: outer push, inner push, text_input, inner pop, outer pop = 5
    try testing.expectEqual(@as(usize, 5), cb.cmds.items.len);
    try testing.expectEqual(.push_group, std.meta.activeTag(cb.cmds.items[0]));
    try testing.expectEqual(.push_group, std.meta.activeTag(cb.cmds.items[1]));
    try testing.expectEqual(.text_input, std.meta.activeTag(cb.cmds.items[2]));
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[3]));
    try testing.expectEqual(.pop_group, std.meta.activeTag(cb.cmds.items[4]));
}

test "CmdBuffer.pushFormRow: nested form rows track their own state" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushFormRow(.{ .label = "Outer", .units = "u_o" });
    cb.pushFormRow(.{ .label = "Inner", .units = "u_i" });
    cb.textInput(.focus, "", 0);
    cb.popFormRow(); // inner — should append "u_i"
    cb.popFormRow(); // outer — should append "u_o"

    // Find the units text cmds and verify the ORDER is inner then outer.
    var units_seen: [2][]const u8 = .{ "", "" };
    var u_idx: usize = 0;
    for (cb.cmds.items) |c| {
        if (c == .text and (std.mem.eql(u8, c.text.content, "u_i") or std.mem.eql(u8, c.text.content, "u_o"))) {
            units_seen[u_idx] = c.text.content;
            u_idx += 1;
        }
    }
    try testing.expectEqualStrings("u_i", units_seen[0]);
    try testing.expectEqualStrings("u_o", units_seen[1]);
}

test "CmdBuffer.reset clears in-flight form row depth" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushFormRow(.{ .label = "Mass" });
    try testing.expectEqual(@as(u8, 1), cb.form_row_depth);

    cb.reset();
    try testing.expectEqual(@as(u8, 0), cb.form_row_depth);
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

test "validateBalance: balanced buffer returns null" {
    const testing = std.testing;
    const Msg = union(enum) { inc };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("hi");
    cb.pushGroup(.{ .direction = .horizontal });
    cb.button(.inc, "+");
    cb.popGroup();
    cb.popGroup();

    try testing.expectEqual(@as(?BalanceError, null), validateBalance(cb.cmds.items));
}

test "validateBalance: every container kind, nested + balanced, returns null" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.pushScroll(.{});
    cb.pushVirtualList(.{ .total_count = 3, .item_extent = 10, .visible_end = 3 });
    cb.text("row");
    cb.popVirtualList();
    cb.popScroll();
    cb.pushOverlay(.{ .x = 10, .y = 10 });
    cb.text("tip");
    cb.popOverlay();
    cb.popGroup();

    try testing.expectEqual(@as(?BalanceError, null), validateBalance(cb.cmds.items));
}

test "validateBalance: unclosed push reports kind + index of the push" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{}); // 0
    cb.text("x"); // 1
    cb.pushOverlay(.{}); // 2 — never popped (innermost still-open push)
    cb.text("y"); // 3
    // No pops: both the group (0) and overlay (2) stay open; the
    // innermost open push (the overlay at 2) is the one reported.

    const err = validateBalance(cb.cmds.items).?;
    try testing.expectEqual(BalanceError.Tag.unclosed_push, err.tag);
    try testing.expectEqual(BalanceKind.overlay, err.open_kind);
    try testing.expectEqual(@as(usize, 2), err.open_index);
}

test "validateBalance: stray pop reports kind + index of the pop" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{}); // 0
    cb.popGroup(); // 1
    cb.popScroll(); // 2 — stray, nothing open

    const err = validateBalance(cb.cmds.items).?;
    try testing.expectEqual(BalanceError.Tag.stray_pop, err.tag);
    try testing.expectEqual(BalanceKind.scroll, err.close_kind);
    try testing.expectEqual(@as(usize, 2), err.close_index);
}

test "validateBalance: crossed pair reports both open push and wrong pop" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{}); // 0
    cb.pushGroup(.{}); // 1
    cb.popOverlay(); // 2 — closes a group with the wrong pop

    const err = validateBalance(cb.cmds.items).?;
    try testing.expectEqual(BalanceError.Tag.mismatched_pop, err.tag);
    try testing.expectEqual(BalanceKind.group, err.open_kind);
    try testing.expectEqual(@as(usize, 1), err.open_index);
    try testing.expectEqual(BalanceKind.overlay, err.close_kind);
    try testing.expectEqual(@as(usize, 2), err.close_index);
}

test "validateBalance: reports the FIRST imbalance, innermost unclosed" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Two unclosed pushes; the innermost (last opened) is reported.
    cb.pushGroup(.{}); // 0
    cb.pushScroll(.{}); // 1 — innermost open at end
    cb.text("x"); // 2

    const err = validateBalance(cb.cmds.items).?;
    try testing.expectEqual(BalanceError.Tag.unclosed_push, err.tag);
    try testing.expectEqual(BalanceKind.scroll, err.open_kind);
    try testing.expectEqual(@as(usize, 1), err.open_index);
}

test "validateBalance: balanced form row (sugar over push/pop_group) returns null" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushFormRow(.{ .label = "Mass", .units = "kg", .validation = "bad" });
    cb.textInput(.focus, "10", 2);
    cb.popFormRow();

    try testing.expectEqual(@as(?BalanceError, null), validateBalance(cb.cmds.items));
}

test "validateBalance: form row missing its pop is caught as unclosed group" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // pushFormRow emits push_group (outer, idx 0) + push_group (inner,
    // idx 1) + label text. Without popFormRow both groups stay open; the
    // innermost (idx 1) is reported.
    cb.pushFormRow(.{ .label = "Mass" });
    cb.textInput(.focus, "10", 2);

    const err = validateBalance(cb.cmds.items).?;
    try testing.expectEqual(BalanceError.Tag.unclosed_push, err.tag);
    try testing.expectEqual(BalanceKind.group, err.open_kind);
    try testing.expectEqual(@as(usize, 1), err.open_index);
}

test "validateBalance: nesting past MAX_BALANCE_DEPTH is depth_overflow" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // One more push than the validator's stack can hold. No pops, so the
    // (MAX+1)-th push overflows at index MAX_BALANCE_DEPTH.
    var i: usize = 0;
    while (i < MAX_BALANCE_DEPTH + 1) : (i += 1) cb.pushGroup(.{});

    const err = validateBalance(cb.cmds.items).?;
    try testing.expectEqual(BalanceError.Tag.depth_overflow, err.tag);
    try testing.expectEqual(@as(usize, MAX_BALANCE_DEPTH), err.open_index);
}

test "formatBalanceError: each tag renders an actionable line" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;

    try testing.expectEqualStrings(
        "push_overlay at cmd #17 was never popped",
        formatBalanceError(.{ .tag = .unclosed_push, .open_kind = .overlay, .open_index = 17 }, &buf),
    );
    try testing.expectEqualStrings(
        "pop_group at cmd #9 has no matching push",
        formatBalanceError(.{ .tag = .stray_pop, .close_kind = .group, .close_index = 9 }, &buf),
    );
    try testing.expectEqualStrings(
        "push_group at cmd #4 was closed by pop_overlay at cmd #12",
        formatBalanceError(.{
            .tag = .mismatched_pop,
            .open_kind = .group,
            .open_index = 4,
            .close_kind = .overlay,
            .close_index = 12,
        }, &buf),
    );
    try testing.expectEqualStrings(
        "push_scroll at cmd #33 exceeds the max container nesting depth (64)",
        formatBalanceError(.{ .tag = .depth_overflow, .open_kind = .scroll, .open_index = 33 }, &buf),
    );
}

test "CmdBuffer.canvas emits a canvas cmd carrying its primitives" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    const prims = [_]CanvasPrimitive{
        .{ .hline = .{ .y = 10 } },
        .{ .polyline = .{ .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 10 } } } },
    };
    cb.canvas(.{ .width = 300, .height = 120 }, &prims);

    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    const cv = cb.cmds.items[0].canvas;
    try testing.expectEqual(@as(f32, 300), cv.style.width);
    try testing.expectEqual(@as(usize, 2), cv.primitives.len);
    // Plain `canvas` is non-interactive (no click msg) and unlabeled.
    try testing.expectEqual(@as(?Msg, null), cv.msg);
    try testing.expectEqual(@as(usize, 0), cv.label.len);
}

test "CmdBuffer.canvasInteractive sets pointer + id; other emitters leave them off" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.canvas(.{}, &.{});
    cb.canvasInteractive(.{ .width = 300, .height = 200 }, &.{}, 7, "viewport");
    cb.pushScroll(.{ .id = 3 });
    cb.popScroll();

    try testing.expect(!cb.cmds.items[0].canvas.pointer);
    try testing.expectEqual(@as(u32, 0), cb.cmds.items[0].canvas.id);
    const cv = cb.cmds.items[1].canvas;
    try testing.expect(cv.pointer);
    try testing.expectEqual(@as(u32, 7), cv.id);
    try testing.expectEqualStrings("viewport", cv.label);
    try testing.expectEqual(@as(?Msg, null), cv.msg);
    try testing.expectEqual(@as(u32, 3), cb.cmds.items[2].push_scroll.id);
}

test "CmdBuffer.canvasClickable / canvasLabeled set msg + label" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.canvasLabeled(.{}, &.{}, "history");
    cb.canvasClickable(.poke, .{}, &.{}, "plot");

    try testing.expectEqualStrings("history", cb.cmds.items[0].canvas.label);
    try testing.expectEqual(@as(?Msg, null), cb.cmds.items[0].canvas.msg);
    try testing.expectEqual(@as(?Msg, Msg.poke), cb.cmds.items[1].canvas.msg);
    try testing.expectEqualStrings("plot", cb.cmds.items[1].canvas.label);
}

test "CmdBuffer.pushFormRow: documented depth of 8 is reachable without tripping the assert" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // form_row_stack is 8 deep. Push 8 form rows, all in flight
    // simultaneously, then pop them all back out. This exercises the
    // full bound on both sides; if pushFormRow's assert fired at the
    // boundary or popFormRow's bookkeeping was off, this would crash.
    const DEPTH: u8 = 8;
    var i: u8 = 0;
    while (i < DEPTH) : (i += 1) {
        cb.pushFormRow(.{ .label = "row" });
    }
    try testing.expectEqual(DEPTH, cb.form_row_depth);

    i = 0;
    while (i < DEPTH) : (i += 1) cb.popFormRow();
    try testing.expectEqual(@as(u8, 0), cb.form_row_depth);
}

test "CmdBuffer.scene3d emits a scene3d cmd with defaults" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.scene3d(.{ .mesh = 5, .key = 12, .style = .{ .width = 480, .height = 360 } });
    cb.scene3d(.{ .id = 2, .pointer = true, .msg = .poke, .label = "view" });

    const a = cb.cmds.items[0].scene3d;
    try testing.expectEqual(@as(u32, 5), a.mesh);
    try testing.expectEqual(@as(u64, 12), a.key);
    try testing.expectEqual(@as(f32, 480), a.style.width);
    try testing.expectEqual(@as(u32, 0), a.id);
    try testing.expect(!a.pointer);
    try testing.expectEqual(scene.MESH_HANDLE_NONE, cb.cmds.items[1].scene3d.mesh);
    const b = cb.cmds.items[1].scene3d;
    try testing.expectEqual(@as(u32, 2), b.id);
    try testing.expect(b.pointer);
    try testing.expectEqual(@as(?Msg, Msg.poke), b.msg);
}

test "SceneCmd: deepEql compares content (label by value) and the revision key" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    const S = SceneCmd(Msg);
    var label_a = [_]u8{ 'a', 'b' };
    var label_b = [_]u8{ 'a', 'b' };
    const x: S = .{ .label = &label_a, .key = 1 };
    var y: S = .{ .label = &label_b, .key = 1 };
    try testing.expect(eql.deepEql(S, x, y)); // different addresses, same content
    y.key = 2;
    try testing.expect(!eql.deepEql(S, x, y)); // geometry behind the handle changed
    y.key = 1;
    y.camera.eye[1] = 4;
    try testing.expect(!eql.deepEql(S, x, y));
    y.camera.eye[1] = 0;
    y.msg = .poke;
    try testing.expect(!eql.deepEql(S, x, y));
}

test "CanvasPrimitive.eql: batches compare by key (or by bytes when key is 0)" {
    const testing = std.testing;
    const V = CanvasPrimitive.TriVertex;
    var a = [_]V{ .{ .x = 0, .y = 0, .r = 1, .g = 0, .b = 0, .a = 1 }, .{ .x = 1, .y = 0, .r = 1, .g = 0, .b = 0, .a = 1 }, .{ .x = 0, .y = 1, .r = 1, .g = 0, .b = 0, .a = 1 } };
    var b = a; // distinct storage, equal content
    const pa: CanvasPrimitive = .{ .triangles = .{ .verts = &a, .key = 7 } };
    const pb: CanvasPrimitive = .{ .triangles = .{ .verts = &b, .key = 7 } };
    try testing.expect(pa.eql(pb));

    // Same key => trusted equal even if bytes differ (that is the contract).
    b[0].x = 5;
    try testing.expect(pa.eql(pb));
    // A new key => different.
    const pc: CanvasPrimitive = .{ .triangles = .{ .verts = &b, .key = 8 } };
    try testing.expect(!pa.eql(pc));

    // key 0 => deep compare.
    const p0a: CanvasPrimitive = .{ .triangles = .{ .verts = &a } };
    const p0b: CanvasPrimitive = .{ .triangles = .{ .verts = &b } };
    try testing.expect(!p0a.eql(p0b));
    b[0].x = 0;
    try testing.expect(p0a.eql(p0b));

    // Length mismatch is always unequal.
    const short: CanvasPrimitive = .{ .triangles = .{ .verts = a[0..2], .key = 7 } };
    try testing.expect(!pa.eql(short));

    // Lines: style participates, key as above.
    const segs = [_][4]f32{.{ 0, 0, 1, 1 }};
    const l1: CanvasPrimitive = .{ .lines = .{ .segs = &segs, .key = 3 } };
    const l2: CanvasPrimitive = .{ .lines = .{ .segs = &segs, .key = 3, .thickness = 2 } };
    try testing.expect(l1.eql(l1));
    try testing.expect(!l1.eql(l2));
    try testing.expect(!l1.eql(pa));
}

test "validateBalance: nesting at MAX_BALANCE_DEPTH passes, one deeper is depth_overflow (every optimize mode)" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    var i: usize = 0;
    while (i < MAX_BALANCE_DEPTH) : (i += 1) cb.pushGroup(.{});
    i = 0;
    while (i < MAX_BALANCE_DEPTH) : (i += 1) cb.popGroup();
    try testing.expect(validateBalance(cb.cmds.items) == null);

    // One more level: reported with the offending cmd index, not a crash.
    cb.reset();
    i = 0;
    while (i <= MAX_BALANCE_DEPTH) : (i += 1) cb.pushGroup(.{});
    const err = validateBalance(cb.cmds.items).?;
    try testing.expectEqual(BalanceError.Tag.depth_overflow, err.tag);
    try testing.expectEqual(@as(usize, MAX_BALANCE_DEPTH), err.open_index);
    var buf: [128]u8 = undefined;
    const msg = formatBalanceError(err, &buf);
    try testing.expect(std.mem.indexOf(u8, msg, "cmd #64") != null);
}
