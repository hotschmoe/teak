//! Teak: TEA + Command Buffer UI Framework for Zig.
//! Public library root — re-exports framework types.
//!
//! Re-exports the pure half of the framework: core/, layout/, input/,
//! render/. Host and GPU backends (platform/*, gpu/*) are NOT re-exported
//! — a consumer's build.zig picks a Host + Gpu backend module and wires
//! them up. See `tasks-file-struct.md` for the load-bearing rationale.

pub const cmd = @import("core/cmd.zig");
pub const compose = @import("core/component.zig");
pub const transient = @import("core/transient.zig");
pub const layout = @import("layout/engine.zig");
pub const hit_test = @import("input/hit_test.zig");
pub const keys = @import("input/keys.zig");
pub const render = @import("render/build.zig");
pub const vertex = @import("render/vertex.zig");
pub const host = @import("platform/host.zig");
pub const gpu = @import("gpu/context.zig");

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
pub const SpecialKey = keys.SpecialKey;

pub const Vertex = vertex.Vertex;
pub const emitQuad = vertex.emitQuad;
pub const buildVertices = render.buildVertices;

pub const TransientState = transient.TransientState;

pub const Components = compose.Components;
pub const validateComponent = compose.validateComponent;

pub const InputState = host.InputState;
pub const validateHost = host.validateHost;

pub const ClearColor = gpu.ClearColor;
pub const validateGpu = gpu.validateGpu;

test {
    @import("std").testing.refAllDecls(@This());
}
