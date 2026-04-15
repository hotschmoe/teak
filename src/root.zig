//! Teak: TEA + Command Buffer UI Framework for Zig.
//! Public library root — re-exports framework types.

pub const cmd = @import("cmd.zig");
pub const model = @import("model.zig");
pub const layout = @import("layout.zig");
pub const hit_test = @import("hit_test.zig");
pub const render = @import("render.zig");
pub const transient = @import("transient.zig");

pub const Cmd = cmd.Cmd;
pub const CmdBuffer = cmd.CmdBuffer;
pub const GroupStyle = cmd.GroupStyle;
pub const ButtonCmd = cmd.ButtonCmd;
pub const ButtonStyle = cmd.ButtonStyle;
pub const TextCmd = cmd.TextCmd;
pub const Direction = cmd.Direction;

pub const Model = model.Model;
pub const Msg = model.Msg;
pub const update = model.update;
pub const view = model.view;

pub const Rect = layout.Rect;
pub const LayoutEngine = layout.LayoutEngine;

pub const hitTest = hit_test.hitTest;
pub const hoverTest = hit_test.hoverTest;

pub const Vertex = render.Vertex;
pub const emitQuad = render.emitQuad;
pub const buildVertices = render.buildVertices;

pub const TransientState = transient.TransientState;

test {
    @import("std").testing.refAllDecls(@This());
}
