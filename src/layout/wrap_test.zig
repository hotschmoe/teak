//! Wrapped text and flex shrink in layout (text-engine PR8): paragraph
//! height-for-width, shrinking rows, min-content floors, scroll content, and
//! the pass-structure guarantee that frames without wrapped nodes never run
//! the extra width passes. Mono measurer: 10 px per byte, 20 px lines.

const std = @import("std");
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const text_wrap = @import("../core/text_wrap.zig");
const snapshot = @import("../core/snapshot.zig");
const engine = @import("engine.zig");
const Rect = engine.Rect;
const LayoutEngine = engine.LayoutEngine;

const mono = text.monoMeasurer();
const Msg = union(enum) { a, b };
const Buf = cmd.CmdBuffer(Msg);

fn layout(cb: *Buf, rects: []Rect, w: f32, h: f32) []const Rect {
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, mono);
    return rects[0..cb.cmds.items.len];
}














