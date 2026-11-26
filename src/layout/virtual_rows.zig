//! Measured row extents of a virtual list, read from the rects the layout
//! passes already produced.
//!
//! A variable-height list cannot know its rows' heights before layout, so the
//! runtime reports them back through `virtualRowsMsg` (the same pattern as
//! `scrollLayoutMsg`): the main-axis extent of each emitted row, i.e. each
//! *direct child* of the `push_virtual_list`.

const std = @import("std");
const layout = @import("engine.zig");
const Rect = layout.Rect;

/// Main-axis extents of the direct children of the `push_virtual_list` at
/// `index`, in emission order, written into `out` (extra children are
/// ignored). Returns the number written.
pub fn rowExtents(cmds: anytype, rects: []const Rect, index: usize, out: []f32) usize {
    const vertical = cmds[index].push_virtual_list.direction == .vertical;
    var n: usize = 0;
    var depth: usize = 1;
    var i = index + 1;
    while (i < cmds.len and depth > 0) : (i += 1) {
        switch (cmds[i]) {
            .push_group, .push_grid, .push_virtual_list, .push_scroll, .push_overlay => {
                if (depth == 1 and n < out.len and cmds[i] != .push_overlay) {
                    out[n] = if (vertical) rects[i].h else rects[i].w;
                    n += 1;
                }
                depth += 1;
            },
            .pop_group, .pop_grid, .pop_virtual_list, .pop_scroll, .pop_overlay => depth -= 1,
            .text, .rich_text, .image, .divider, .button, .text_input, .text_area, .checkbox, .radio, .slider, .canvas, .scene3d => if (depth == 1 and n < out.len) {
                out[n] = if (vertical) rects[i].h else rects[i].w;
                n += 1;
            },
        }
    }
    return n;
}
