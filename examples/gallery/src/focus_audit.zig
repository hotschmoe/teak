//! Keyboard-focus audit of the gallery: on every page, in every look, each
//! interactive leaf (button, checkbox, radio, slider, text field) is reachable
//! with Tab (a list is ONE Tab stop; its other rows must be arrow-reachable, i.e. roving),
//! disabled ones are not, and Tab visits each exactly once per cycle.

const std = @import("std");
const teak = @import("teak");
const app = @import("app.zig");
const model_mod = @import("model.zig");

fn interactive(c: anytype) bool {
    return switch (c) {
        .button, .checkbox, .radio, .slider, .text_input, .text_area => true,
        .canvas => |cv| cv.msg != null, // the toggle switch
        else => false,
    };
}

/// Tab skips it: a disabled widget, or a list row that is not the list's Tab stop.
fn disabled(c: anytype) bool {
    return switch (c) {
        .button => |b| b.disabled or !b.tab_stop,
        .text_input => |t| t.disabled,
        .text_area => |t| t.disabled,
        else => false,
    };
}

