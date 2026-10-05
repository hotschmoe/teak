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
