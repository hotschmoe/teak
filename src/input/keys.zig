//! Framework-authoritative list of non-text keys that Hosts may deliver.
//! Text characters flow through InputState.chars; everything else is a
//! variant here. Hosts map their native key codes onto this enum.

pub const SpecialKey = enum {
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    enter,
    tab,
    escape,
};
