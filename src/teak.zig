//! Teak: TEA + Command Buffer UI Framework for Zig.
//! Public library root — re-exports framework types.
//!
//! Re-exports the pure half of the framework: core/, layout/, input/,
//! render/. Host and GPU backends (platform/*, gpu/*) are NOT re-exported
//! — a consumer's build.zig picks a Host + Gpu backend module and wires
//! them up. See `docs/archive/tasks-file-struct.md` for the load-bearing rationale.

pub const cmd = @import("core/cmd.zig");
pub const component = @import("core/component.zig");
pub const transient = @import("core/transient.zig");
pub const text = @import("core/text.zig");
pub const layout = @import("layout/engine.zig");
pub const hit_test = @import("input/hit_test.zig");
pub const focus = @import("input/focus.zig");
pub const keys = @import("input/keys.zig");
pub const render = @import("render/build.zig");
pub const vertex = @import("render/vertex.zig");
pub const host = @import("platform/host.zig");
pub const gpu = @import("gpu/context.zig");

pub const Cmd = cmd.Cmd;
pub const CmdBuffer = cmd.CmdBuffer;
pub const GroupStyle = cmd.GroupStyle;
pub const ScrollStyle = cmd.ScrollStyle;
pub const OverlayStyle = cmd.OverlayStyle;
pub const VirtualListStyle = cmd.VirtualListStyle;
pub const ImageStyle = cmd.ImageStyle;
pub const ImageCmd = cmd.ImageCmd;
pub const RichTextSpan = cmd.RichTextSpan;
pub const RichTextCmd = cmd.RichTextCmd;
pub const ButtonCmd = cmd.ButtonCmd;
pub const ButtonStyle = cmd.ButtonStyle;
pub const TextCmd = cmd.TextCmd;
pub const TextInputCmd = cmd.TextInputCmd;
pub const TextInputStyle = cmd.TextInputStyle;
pub const CheckboxCmd = cmd.CheckboxCmd;
pub const CheckboxStyle = cmd.CheckboxStyle;
pub const RadioCmd = cmd.RadioCmd;
pub const RadioStyle = cmd.RadioStyle;
pub const SliderCmd = cmd.SliderCmd;
pub const SliderStyle = cmd.SliderStyle;
pub const DividerStyle = cmd.DividerStyle;
pub const Direction = cmd.Direction;

pub const Rect = layout.Rect;
pub const LayoutEngine = layout.LayoutEngine;

pub const hitTest = hit_test.hitTest;
pub const hoverTest = hit_test.hoverTest;
pub const sliderValueAt = hit_test.sliderValueAt;
pub const nextFocusable = focus.nextFocusable;
pub const prevFocusable = focus.prevFocusable;
pub const SpecialKey = keys.SpecialKey;

pub const Vertex = vertex.Vertex;
pub const emitQuad = vertex.emitQuad;
pub const buildVertices = render.buildVertices;
pub const ImageDraw = render.ImageDraw;

pub const TransientState = transient.TransientState;

pub const Components = component.Components;
pub const validateComponent = component.validateComponent;

pub const InputState = host.InputState;
pub const validateHost = host.validateHost;

pub const ClearColor = gpu.ClearColor;
pub const validateGpu = gpu.validateGpu;

pub const FontFamily = text.FontFamily;
pub const FontSpec = text.FontSpec;
pub const DEFAULT_FONT = text.DEFAULT_FONT;
pub const TextMetrics = text.TextMetrics;
pub const TextMeasurer = text.TextMeasurer;
pub const TextureHandle = text.TextureHandle;
pub const TEXTURE_HANDLE_NONE = text.TEXTURE_HANDLE_NONE;
pub const TextDraw = text.TextDraw;
pub const monoMeasurer = text.monoMeasurer;

test {
    @import("std").testing.refAllDecls(@This());
}
