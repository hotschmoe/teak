//! Teak: TEA + Command Buffer UI Framework for Zig.
//! Public library root — re-exports framework types.

pub const cmd = @import("cmd.zig");
pub const layout = @import("layout.zig");
pub const hit_test = @import("hit_test.zig");
pub const render = @import("render.zig");
pub const transient = @import("transient.zig");
pub const compose = @import("compose.zig");
pub const counter = @import("counter.zig");
pub const greeter = @import("greeter.zig");
pub const app = @import("app.zig");

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

pub const Vertex = render.Vertex;
pub const emitQuad = render.emitQuad;
pub const buildVertices = render.buildVertices;

pub const TransientState = transient.TransientState;

pub const Components = compose.Components;
pub const validateComponent = compose.validateComponent;

pub const App = app;

test {
    @import("std").testing.refAllDecls(@This());
}
