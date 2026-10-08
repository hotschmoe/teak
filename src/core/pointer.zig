//! Pointer / canvas-event types shared by the Host, `teak.run`, hit-test
//! and the App.
//!
//! A `canvas` (and `scene3d`) Cmd with `pointer = true` is an interactive
//! surface: `teak.run` turns raw pointer input that lands on it into
//! `CanvasEvent`s and hands each one to the App's optional
//! `canvasMsg(*const Model, CanvasEvent) ?Msg` hook, which maps it to an
//! ordinary `Msg`. That is how an app implements pan / zoom / orbit /
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
    /// SIZE changes. `w`/`h` carry the new size; `x`/`y` are 0. Lets the
    /// app keep the viewport size in its Model (the view cannot read
    /// layout results).
    layout,
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
