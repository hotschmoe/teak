//! Teak: TEA + Command Buffer UI Framework for Zig.
//! Public library root — re-exports framework types.

pub const cmd = @import("core/cmd.zig");
pub const compose = @import("core/component.zig");
pub const transient = @import("core/transient.zig");
pub const layout = @import("layout/engine.zig");
pub const hit_test = @import("input/hit_test.zig");
pub const render = @import("render/build.zig");
pub const vertex = @import("render/vertex.zig");

pub const Cmd = cmd.Cmd;
pub const CmdBuffer = cmd.CmdBuffer;
pub const GroupStyle = cmd.GroupStyle;
pub const ButtonCmd = cmd.ButtonCmd;
pub const ButtonStyle = cmd.ButtonStyle;
pub const TextCmd = cmd.TextCmd;
pub const TextInputCmd = cmd.TextInputCmd;
pub const TextInputStyle = cmd.TextInputStyle;
pub const Direction = cmd.Direction;

pub const Rect = layout.Rect;
pub const LayoutEngine = layout.LayoutEngine;

pub const hitTest = hit_test.hitTest;
pub const hoverTest = hit_test.hoverTest;

pub const Vertex = vertex.Vertex;
pub const emitQuad = vertex.emitQuad;
pub const buildVertices = render.buildVertices;

pub const TransientState = transient.TransientState;

pub const Components = compose.Components;
pub const validateComponent = compose.validateComponent;

test {
    @import("std").testing.refAllDecls(@This());
}
