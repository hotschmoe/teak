//! Pointer / navigation / metrics events for `text_area` (text-engine 6.3-6.4).
//!
//! `view` cannot read layout and a Msg is never built by the framework from a
//! pointer, so -- exactly like `CanvasEvent` for canvases -- `teak.run` turns
//! input over a `text_area` into plain `TextEvent` records and hands each to
//! the App's optional `textMsg(*const Model, TextEvent) ?Msg` hook, which
//! wraps it into an ordinary Msg (`TextArea` components do it in one line).
//! The runtime fills in everything that needs the measurer: the byte `index`
//! of the grapheme boundary nearest the pointer, wrapped `line`, the resolved
//! target of visual-line motion, and the layout `metrics`.
//!
//! Pure data -- no platform types, no callbacks (HARDLINE §3).

const pointer = @import("pointer.zig");

pub const TextEventKind = enum {
    /// Left button went down on the area (single click). `index` = caret target.
    down,
    /// Pointer moved with the button held (captured: continues outside the rect).
    drag,
    /// Button released.
    up,
    /// Second / third click in a row at about the same spot (word / line select).
    double_click,
    triple_click,
    /// Wheel over the area: `dx` / `dy` (DOM-signed pixels).
    wheel,
    /// Visual motion resolved by the runtime against the real wrapped layout:
    /// Up / Down / PageUp / PageDown / Home / End. `index` is the new caret
    /// position, `goal_x` the sticky column to keep, `mods.shift` = extend.
    move,
    /// Layout facts the view cannot read; delivered on first layout and when
    /// any of them changes. Use it to clamp scroll and reveal the caret.
    metrics,
    /// The pointer left (no capture active).
    leave,
};

pub const TextEvent = struct {
    /// `TextAreaCmd.id` of the target.
    id: u32,
    kind: TextEventKind,
    /// Byte offset of the grapheme boundary nearest the pointer (down / drag /
    /// clicks) or of the resolved target (`move`); clamped to the content.
    index: u32 = 0,
    /// Wrapped line number of `index`.
    line: u32 = 0,
    /// Area-local logical px (origin = the rect's top-left), `down`/`drag`/`up`.
    x: f32 = 0,
    y: f32 = 0,
    /// Wheel deltas.
    dx: f32 = 0,
    dy: f32 = 0,
    /// `move`: the sticky column after the move; meaningful only when
    /// `keep_goal` (vertical motion), else the app should clear its sticky column.
    goal_x: f32 = 0,
    keep_goal: bool = false,
    mods: pointer.Modifiers = .{},
    clicks: u8 = 1,
    // metrics -------------------------------------------------------
    /// Inner (padding-free) box and the wrapped content extent.
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    content_w: f32 = 0,
    content_h: f32 = 0,
    /// Caret rectangle in CONTENT coordinates (scroll not applied).
    caret_x: f32 = 0,
    caret_y: f32 = 0,
    caret_h: f32 = 0,
};

/// Which visual-motion key a `move` resolves.
pub const NavKind = enum { up, down, page_up, page_down, line_start, line_end };
