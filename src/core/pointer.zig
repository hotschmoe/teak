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

/// A window-space rectangle (`PointerEvent.box`).
pub const Box = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// What the App's `hoverMsg` / `contextMsg` hooks receive: where the pointer
/// is and which interactive widget is under it. `hit` is the Msg that widget
/// would dispatch on a left click (its identity: the app compares it with
/// `std.meta.eql`, no id hashing); `null` over empty or non-interactive
/// space. `box` is that widget's rect from the previous frame's layout (the
/// view cannot read layout, so this is how a tooltip or menu learns where to
/// anchor); all zero when `hit` is null. `now_ms` is the host's monotonic
/// clock, so the app can derive deadlines for `Sub.at`.
pub fn PointerEvent(comptime Msg: type) type {
    return struct {
        pub const Kind = enum {
            /// The interactive widget under the pointer changed (`hit` is the
            /// new one, null = empty space). Also what `hoverMsg` receives.
            hover,
            /// A button went down. `hit` is the widget under the pointer or
            /// null for **blank space** (the way an app clears its own focus).
            down,
            /// A button was released (`hit` as for `down`).
            up,
            /// The right button went down (what `contextMsg` receives).
            context,
        };

        /// True when the pointer is over no interactive widget (a click here
        /// should clear the app's focus / selection / open menus).
        pub fn isBlank(self: @This()) bool {
            return self.hit == null;
        }

        kind: Kind = .hover,
        /// Which button changed (`down` / `up` / `context`); `.none` for hover.
        button: Button = .none,
        x: f32,
        y: f32,
        hit: ?Msg = null,
        box: Box = .{},
        mods: Modifiers = .{},
        now_ms: u64 = 0,
    };
}
