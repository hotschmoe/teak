//! Framework-authoritative list of non-text keys that Hosts may deliver.
//! Text characters flow through InputState.chars; everything else is a
//! variant here. Hosts map their native key codes onto this enum.
//!
//! Modifier-bearing variants are flat (shift_left, ctrl_c, ...) rather
//! than a separate modifier struct. Apps switch exhaustively on the
//! enum which keeps the routing code linear — adding a chord = adding a
//! variant + a switch arm, same as adding a Msg.

pub const SpecialKey = enum {
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    enter,
    tab,
    escape,

    // Shift-modified motion — selection extension. App-side text input
    // logic uses selection_anchor (cursor start) + cursor (current) to
    // build a selection range.
    shift_left,
    shift_right,
    shift_up,
    shift_down,
    shift_home,
    shift_end,
    // Shift+Tab — backward focus traversal, the companion to plain `tab`.
    // `teak.run` consumes it for Tab/Shift+Tab navigation. A host that
    // hasn't been taught to emit it yet simply never delivers it; forward
    // Tab still works.
    shift_tab,

    // Ctrl chords for the text-input prose path. Apps that don't care
    // can ignore them — the Host still delivers them when the user
    // pressed Ctrl+key.
    ctrl_a, // select all
    ctrl_c, // copy
    ctrl_x, // cut
    ctrl_v, // paste
    ctrl_z, // undo (app-defined; not wired in MVP)
    ctrl_y, // redo (app-defined; not wired in MVP)
};
