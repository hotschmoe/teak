/// Presentation-only state. Never consulted by update(); never affects routing.
/// Holds the pieces of visual state that would be pathological to funnel
/// through the TEA loop (e.g. per-pixel hover updates at 60+ Hz).
pub const TransientState = struct {
    hover_index: ?usize = null,
    /// Command index that the mouse is currently pressed over. Cleared on
    /// mouse_up or if the mouse drags off the widget.
    press_index: ?usize = null,
    /// Visual focus mirror — kept in sync with the Model's focus field by
    /// the main loop. Used by the renderer to draw the focus ring.
    focus_index: ?usize = null,
    /// Frame counter, incremented once per render. Drives cursor blink.
    frame_counter: u32 = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};
