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
    /// IME pre-commit composition mirror. The host loop snapshots
    /// `Host.imeState()` here each frame; the renderer reads it when
    /// the focused widget is a text input and draws the composition
    /// inline at the caret with an underline indicator. Fits the
    /// TransientState gate (HARDLINE §2 hatch 2):
    ///   - derivable: the host produces it each frame
    ///   - non-logical: update/view/layout/hit-test never read it
    ///   - safely losable: dropping a frame is a cosmetic glitch
    /// On commit the OS dispatches a WM_CHAR for each codepoint, which
    /// flows through the existing TextField path — composition never
    /// enters Model.
    ime_active: bool = false,
    ime_text: []const u8 = "",
    ime_cursor: usize = 0,
};
