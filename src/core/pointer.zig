//! Pointer / canvas-event types shared by the Host, `teak.run`, hit-test
//! and the App.
//!
//! A `canvas` (and `scene3d`) Cmd with `pointer = true` is an interactive
//! surface: `teak.run` turns raw pointer input that lands on it into
//! `PointerEvent`s (`target = .canvas`) and hands each one to the App's
//! optional `pointerMsg(*const Model, PointerEvent(Msg)) ?Msg` hook, which maps
//! it to an ordinary `Msg` (`ev.asCanvas()` is the `CanvasEvent` view the helper
//! widgets consume; the old `canvasMsg` hook is a deprecated adapter). That is how an app implements pan / zoom / orbit /
//! drag-a-note without teak knowing anything about the content.
//!
//! Pure data — no platform types, no callbacks (HARDLINE §3).

/// Mouse buttons currently held. Layout is stable (packed u8) so hosts can
/// build it from a bitmask.
pub const Buttons = packed struct(u8) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,
    _pad: u5 = 0,

    pub fn any(self: Buttons) bool {
        return self.left or self.middle or self.right;
    }
};

/// Keyboard modifier state at the time of the event.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Cmd on macOS / Win key elsewhere.
    meta: bool = false,
    _pad: u4 = 0,
};

pub const Button = enum { none, left, middle, right };

pub const CanvasEventKind = enum {
    /// A button went down on the canvas. Starts a capture: subsequent
    /// `move`/`up` events keep going to this canvas even when the cursor
    /// leaves its rect, until every button is released.
    down,
    /// Cursor moved while over the canvas (no capture) or while captured.
    /// `dx`/`dy` are the delta since the previous event for this canvas.
    move,
    /// A button was released (to the capturing canvas, wherever the cursor is).
    up,
    /// Wheel / trackpad scroll over the canvas. `dx`/`dy` are DOM-signed
    /// pixels (positive `dy` = scroll down / zoom out by convention).
    wheel,
    /// The cursor left the canvas and no capture is active.
    leave,
    /// Delivered when the canvas is first laid out and whenever its rect
    /// SIZE or POSITION changes. `w`/`h` carry the size and `x`/`y` the
    /// rect's top-left in WINDOW coordinates (not canvas-local like every
    /// other event). Lets the app keep the viewport size and origin in its
    /// Model (the view cannot read layout results), e.g. to anchor overlay
    /// text over a 3D viewport.
    layout,
    /// A key pressed while the canvas has the keyboard focus (a focusable
    /// canvas, `canvasInteractiveFocusable`) and the app's own key hooks
    /// declined it. `CanvasEvent.key` names the key. Return a Msg to consume it.
    key,
};

/// One pointer event on an interactive canvas / scene. Coordinates are
/// canvas-LOCAL logical pixels (origin = the canvas rect's top-left), the
/// same space as `CanvasPrimitive` coordinates.
pub const CanvasEvent = struct {
    /// `CanvasCmd.id` / `SceneCmd.id` of the target. Apps give each
    /// interactive canvas a distinct non-zero id.
    id: u32,
    kind: CanvasEventKind,
    x: f32 = 0,
    y: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    /// For `down` / `up`: which button changed. `none` otherwise.
    button: Button = .none,
    /// Buttons held after this event.
    buttons: Buttons = .{},
    mods: Modifiers = .{},
    /// Canvas rect size in logical px.
    w: f32 = 0,
    h: f32 = 0,
    /// For `key`: which key.
    key: ?@import("../input/keys.zig").SpecialKey = null,
};

// ── Drag and drop (in-app) ─────────────────────────────────────────

pub const DragPhase = enum {
    /// The pointer moved past the threshold with a drag source pressed.
    start,
    /// Each frame while dragging (the pointer may not have moved).
    move,
    /// The button was released: drop on `over` (0 = no target).
    drop,
    /// Escape pressed (or the source vanished): drag aborted, nothing dropped.
    cancel,
};

/// One step of an in-app drag, delivered to the App's `dragMsg` hook. The
/// app keeps the drag state in its Model (what is dragged, where the ghost
/// is, which target is hot) and renders the ghost as an overlay; the loop
/// only reports pointer facts resolved against the previous frame's layout.
pub const DragEvent = struct {
    phase: DragPhase,
    /// `GroupStyle.drag_id` of the dragged source.
    id: u32,
    /// Pointer position, window coordinates.
    x: f32,
    y: f32,
    /// Where inside the source rect the press landed (ghost offset).
    grab_dx: f32 = 0,
    grab_dy: f32 = 0,
    /// The source group's rect at press time: x, y, w, h.
    src: [4]f32 = .{ 0, 0, 0, 0 },
    /// `GroupStyle.drop_id` of the innermost drop target under the pointer
    /// (0 = none), its rect, and the pointer's position inside it, 0..1.
    over: u32 = 0,
    over_rect: [4]f32 = .{ 0, 0, 0, 0 },
    over_fx: f32 = 0,
    over_fy: f32 = 0,
};

/// A window-space rectangle (`PointerEvent.box`).
pub const Box = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// Text-area facts carried by a `Target.text_area` event: the caret byte the
/// runtime resolved against the wrapped layout (the measurer lives in the
/// loop, not the app), plus -- for `kind = .layout` -- the layout metrics the
/// view cannot read.
pub const TextTarget = struct {
    /// `TextAreaCmd.id`.
    id: u32,
    /// Byte offset of the grapheme boundary nearest the pointer (`down` /
    /// `move` / `up`) or of the resolved target (`caret`); clamped to the content.
    offset: u32 = 0,
    /// Wrapped line number of `offset`.
    line: u32 = 0,
    /// `caret`: the sticky column after the move; meaningful only with `keep_goal`.
    goal_x: f32 = 0,
    keep_goal: bool = false,
    /// `layout`: inner (padding-free) box, wrapped content extent and the caret
    /// rectangle in CONTENT coordinates (scroll not applied).
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    content_w: f32 = 0,
    content_h: f32 = 0,
    caret_x: f32 = 0,
    caret_y: f32 = 0,
    caret_h: f32 = 0,
};

/// The kinds of `PointerEvent` (shared by every `Msg` instantiation).
pub const PointerKind = enum {
    /// The interactive widget under the pointer changed (`hit` is the
    /// new one, null = empty space).
    hover,
    /// A button went down. For `target = .widget`, `hit` is the widget
    /// under the pointer or null for **blank space** (the way an app
    /// clears its own focus). For a canvas / text area / slider the
    /// press starts the capture. `clicks` counts repeated presses
    /// (text areas: 1, 2, 3).
    down,
    /// Cursor moved over a canvas, or -- with a button held -- a
    /// captured canvas / text area (drag) / slider; `dx`/`dy` are the
    /// delta since the previous event for that target. A slider gets
    /// one `move` per frame while held.
    move,
    /// A button was released (to the capturing target, wherever the
    /// cursor is; widget targets: the widget under the pointer).
    up,
    /// Wheel / trackpad scroll: `dx`/`dy` are DOM-signed pixels. Target:
    /// the captured or hovered canvas / text area, else the innermost
    /// `ScrollStyle.id` region (also keyboard scrolling, as a synthetic
    /// wheel), else `.widget` / `.none` (then `wheelMsg` is the fallback
    /// when the hook returns null).
    wheel,
    /// The cursor left a canvas / text area and no capture is active.
    leave,
    /// The right button went down. `target = .widget`.
    context,
    /// Delivered when a canvas or text area is first laid out and
    /// whenever its rect (canvas: size or position; text area: its
    /// metrics) changes. Canvas: `w`/`h` = size, `x`/`y` = the rect's
    /// top-left in WINDOW coordinates. Text area: `target.text_area`
    /// carries the metrics.
    layout,
    /// A key the focused canvas (`canvasInteractiveFocusable`) or slider
    /// received that the app's own key hooks declined; `key` names it.
    /// Slider: `target.slider.value` is the already-stepped 0..1 value.
    key,
    /// Text area only: Up / Down / PageUp / PageDown / Home / End /
    /// bidi Left / Right resolved against the wrapped layout;
    /// `target.text_area.offset` is the new caret, `mods.shift` = extend.
    caret,
};

/// What the App's `pointerMsg` hook receives (and, through the deprecated
/// adapters, what `hoverMsg` / `contextMsg` receive): one record per pointer
/// fact, resolved against the previous frame's layout. `target` says what the
/// fact is about; every `down` on a canvas, text area or slider CAPTURES the
/// pointer for that target -- it then receives every event until all buttons
/// are up, wherever the cursor goes. `x`/`y` are window coordinates,
/// `local_x`/`local_y` are relative to the target's rect.
///
/// `hit` is the Msg the widget under the pointer would dispatch on a left
/// click (its identity: compare with `std.meta.eql`, no id hashing); `null`
/// over empty or non-interactive space. `box` is that widget's rect from the
/// previous frame's layout (the view cannot read layout, so this is how a
/// tooltip or menu learns where to anchor); all zero when `hit` is null.
/// `now_ms` is the host's monotonic clock, so the app can derive deadlines
/// for `Sub.at`. For widget-level kinds (`hover`, `down`, `up`, `context`)
/// `target == .widget` carries the same Msg as `hit`.
pub fn PointerEvent(comptime Msg: type) type {
    return struct {
        pub const Kind = PointerKind;

        pub const SliderTarget = struct {
            /// The slider's `grab_msg` (which slider).
            grab: Msg,
            /// 0..1 position under the pointer (or the keyboard-stepped value).
            value: f32,
        };

        pub const Target = union(enum) {
            /// Nothing claimed the event (wheel over blank space).
            none,
            /// The leaf under the pointer: its click Msg, or null on blank space.
            widget: ?Msg,
            /// `CanvasCmd.id` / `SceneCmd.id` of an interactive canvas.
            canvas: u32,
            text_area: TextTarget,
            slider: SliderTarget,
            /// `ScrollStyle.id` of a scroll region.
            scroll: u32,
        };

        /// True when the pointer is over no interactive widget (a click here
        /// should clear the app's focus / selection / open menus).
        pub fn isBlank(self: @This()) bool {
            return self.hit == null;
        }

        /// The canvas view of this event (`target = .canvas`, or a text
        /// area's events through `asText`): what `split`, `color_picker`,
        /// `Orbit` and `DataTable.gripMsg` consume. Coordinates are
        /// canvas-local, exactly as `CanvasEvent` always was.
        pub fn asCanvas(self: @This()) ?CanvasEvent {
            const id = switch (self.target) {
                .canvas => |i| i,
                else => return null,
            };
            const k: CanvasEventKind = switch (self.kind) {
                .down => .down,
                .move => .move,
                .up => .up,
                .wheel => .wheel,
                .leave => .leave,
                .layout => .layout,
                .key => .key,
                else => return null,
            };
            return .{
                .id = id,
                .kind = k,
                .x = if (k == .layout) self.x else self.local_x,
                .y = if (k == .layout) self.y else self.local_y,
                .dx = self.dx,
                .dy = self.dy,
                .button = self.button,
                .buttons = self.buttons,
                .mods = self.mods,
                .w = self.w,
                .h = self.h,
                .key = self.key,
            };
        }

        /// The text-area view of this event (`target = .text_area`): what
        /// `TextArea.eventMsg` / `Editor.applyPointer` consume.
        pub fn asText(self: @This()) ?text_event.TextEvent {
            const t = switch (self.target) {
                .text_area => |t| t,
                else => return null,
            };
            const k: text_event.TextEventKind = switch (self.kind) {
                .down => switch (self.clicks) {
                    0, 1 => .down,
                    2 => .double_click,
                    else => .triple_click,
                },
                .move => .drag,
                .up => .up,
                .wheel => .wheel,
                .leave => .leave,
                .layout => .metrics,
                .caret => .move,
                else => return null,
            };
            return .{
                .id = t.id,
                .kind = k,
                .index = t.offset,
                .line = t.line,
                .x = self.local_x,
                .y = self.local_y,
                .dx = self.dx,
                .dy = self.dy,
                .goal_x = t.goal_x,
                .keep_goal = t.keep_goal,
                .mods = self.mods,
                .clicks = self.clicks,
                .viewport_w = t.viewport_w,
                .viewport_h = t.viewport_h,
                .content_w = t.content_w,
                .content_h = t.content_h,
                .caret_x = t.caret_x,
                .caret_y = t.caret_y,
                .caret_h = t.caret_h,
            };
        }

        /// The slider view (`target = .slider`).
        pub fn asSlider(self: @This()) ?SliderTarget {
            return switch (self.target) {
                .slider => |s| s,
                else => null,
            };
        }

        /// The scroll-region view (`target = .scroll`, `kind = .wheel`).
        pub fn asScroll(self: @This()) ?struct { id: u32, dx: f32, dy: f32 } {
            return switch (self.target) {
                .scroll => |id| if (self.kind == .wheel) .{ .id = id, .dx = self.dx, .dy = self.dy } else null,
                else => null,
            };
        }

        /// Build the event for a `TextEvent` plus the window-space pointer
        /// state it was resolved from (the loop's text routing produces
        /// `TextEvent`s; `asText` is its inverse).
        pub fn fromText(te: text_event.TextEvent, x: f32, y: f32, buttons: Buttons, button: Button) @This() {
            const k: Kind = switch (te.kind) {
                .down, .double_click, .triple_click => .down,
                .drag => .move,
                .up => .up,
                .wheel => .wheel,
                .leave => .leave,
                .metrics => .layout,
                .move => .caret,
            };
            return .{
                .kind = k,
                .target = .{ .text_area = .{
                    .id = te.id,
                    .offset = te.index,
                    .line = te.line,
                    .goal_x = te.goal_x,
                    .keep_goal = te.keep_goal,
                    .viewport_w = te.viewport_w,
                    .viewport_h = te.viewport_h,
                    .content_w = te.content_w,
                    .content_h = te.content_h,
                    .caret_x = te.caret_x,
                    .caret_y = te.caret_y,
                    .caret_h = te.caret_h,
                } },
                .button = button,
                .buttons = buttons,
                .x = x,
                .y = y,
                .local_x = te.x,
                .local_y = te.y,
                .dx = te.dx,
                .dy = te.dy,
                .mods = te.mods,
                .clicks = switch (te.kind) {
                    .double_click => 2,
                    .triple_click => 3,
                    else => te.clicks,
                },
            };
        }

        kind: Kind = .hover,
        /// What the event is about; see `Target`.
        target: Target = .none,
        /// Which button changed (`down` / `up` / `context`); `.none` otherwise.
        button: Button = .none,
        /// Buttons held after this event.
        buttons: Buttons = .{},
        /// Window-space pointer position.
        x: f32,
        y: f32,
        /// Position relative to the target's rect (0 when there is none).
        local_x: f32 = 0,
        local_y: f32 = 0,
        /// Wheel amount, or the drag delta since the previous event for the target.
        dx: f32 = 0,
        dy: f32 = 0,
        /// Target rect size in logical px (`layout` events and canvas events).
        w: f32 = 0,
        h: f32 = 0,
        /// 1, 2, 3 for repeated presses (text areas); 1 otherwise.
        clicks: u8 = 1,
        /// `key`: which key.
        key: ?@import("../input/keys.zig").SpecialKey = null,
        hit: ?Msg = null,
        box: Box = .{},
        mods: Modifiers = .{},
        now_ms: u64 = 0,
    };
}

const text_event = @import("text_event.zig");
