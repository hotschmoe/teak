//! Teak: TEA + Command Buffer UI Framework for Zig.
//! Public library root — re-exports framework types.
//!
//! Re-exports the pure half of the framework: core/, layout/, input/,
//! render/. Host and GPU backends (platform/*, gpu/*) are NOT re-exported
//! — a consumer's build.zig picks a Host + Gpu backend module and wires
//! them up. See `docs/archive/tasks-file-struct.md` for the load-bearing rationale.

/// The flat `Cmd` union, `CmdBuffer` and balance validation.
pub const cmd = @import("core/cmd.zig");
/// Comptime component composition (`Components`, `validateComponent`).
pub const component = @import("core/component.zig");
/// `TransientState`: hover / press / focus / IME state that bypasses the TEA loop.
pub const transient = @import("core/transient.zig");
/// Text measurement, fonts and text-draw records.
pub const text = @import("core/text.zig");
/// UAX#29 graphemes, word boundaries, lossy UTF-8 decoding and Unicode property lookups.
pub const unicode = @import("core/unicode.zig");
/// UAX#14-lite line-break opportunities over grapheme clusters.
pub const linebreak = @import("core/linebreak.zig");
/// Pure wrapping, min/max-content measuring and caret/index mapping over a `TextMeasurer`.
pub const text_wrap = @import("core/text_wrap.zig");
/// `Editor(cap, undo_cap)`: grapheme-aware text editing model with undo/redo (used by TextField/TextArea).
pub const editor = @import("core/editor.zig");
/// Declarative subscriptions (`Sub`): timers serviced by the run loop.
pub const sub = @import("core/sub.zig");
/// `Theme`, `Palette` and `Typography` presets consulted by the theme-aware emitters.
pub const theme = @import("core/theme.zig");
/// `TextField`: the canonical text-input component and its key-dispatch helpers.
pub const text_field = @import("core/text_field.zig");
/// `NumericField`: a `TextField` with float parsing and range validation.
pub const numeric_field = @import("core/numeric_field.zig");
/// `Dropdown`: a closed button plus an open overlay list.
pub const dropdown = @import("core/dropdown.zig");
/// `Combobox(cap)`: searchable select composed from TextField + the dropdown overlay.
pub const combobox = @import("core/combobox.zig");
/// `ComponentList`: a dynamic homogeneous list of components.
pub const component_list = @import("core/component_list.zig");
/// `appendDebugOverlay`: dump the frame's cmds and rects as an overlay.
pub const debug_overlay = @import("core/debug_overlay.zig");
/// Dev inspector panel (widget tree, hovered cmd, Msg log, timings) as overlay cmds.
pub const inspector = @import("core/inspector.zig");
/// LLM-readable text serialization of a frame (`[]Cmd` + `[]Rect`).
pub const snapshot = @import("core/snapshot.zig");
/// Pure line-chart primitive builder for canvases.
pub const chart = @import("core/chart.zig");
/// Fixed-column monospace tables built from text cmds.
pub const table = @import("core/table.zig");
/// Pointer, button, modifier and canvas-event types shared by Host, run loop and hit-test.
pub const pointer = @import("core/pointer.zig");
/// Declarative effects (HARDLINE hatch 7): data describing I/O the Host performs.
pub const effects = @import("core/effects.zig");
/// Data types for `scene3d`: meshes, camera and per-frame scene draws.
pub const scene = @import("core/scene.zig");
/// Declarative GPU resources (HARDLINE hatch 8) for the App `resources()` hook.
pub const resources = @import("core/resources.zig");
/// The two-pass layout engine, `Rect` and the clip stack.
pub const layout = @import("layout/engine.zig");
/// Viewport and content size of a scroll region, measured from layout rects.
pub const scroll_extent = @import("layout/scroll_extent.zig");
/// Mouse-to-`Msg` hit-testing over the previous frame's cmds and rects.
pub const hit_test = @import("input/hit_test.zig");
/// Keyboard focus traversal and Msg-keyed focus lookup.
pub const focus = @import("input/focus.zig");
/// `SpecialKey`: the host-neutral non-text key set.
pub const keys = @import("input/keys.zig");
/// Accessibility tree built from cmds and rects.
pub const a11y = @import("input/a11y.zig");
/// Cmd-to-vertex render pass (`buildFrame`, draw records).
pub const render = @import("render/build.zig");
/// The GPU `Vertex` and quad emitters.
pub const vertex = @import("render/vertex.zig");
/// The `Host` contract (window and input source) plus its input types.
pub const host = @import("platform/host.zig");
/// `InputQueue`: event accumulator shared by the Win32 and X11 Hosts.
pub const input_queue = @import("platform/input_queue.zig");
/// The `Gpu` contract (`validateGpu`) that backends implement.
pub const gpu = @import("gpu/context.zig");
/// The canonical host loop (`teak.run`, `Runtime`).
pub const runtime = @import("run.zig");
/// Scripted-input headless runs for tests and tooling.
pub const headless = @import("headless_run.zig");
/// Agent control channel + input record/replay (docs/features/agent-driver.md).
pub const control = @import("control.zig");
/// Input record/replay file format.
pub const input_record = @import("input_record.zig");

/// The flat command union for a given `Msg`; the unit every pass walks.
pub const Cmd = cmd.Cmd;
/// Per-frame arena-backed command buffer with the widget emitters.
pub const CmdBuffer = cmd.CmdBuffer;
/// Layout and look of a `push_group` container.
pub const GroupStyle = cmd.GroupStyle;
/// Layout and scroll offsets of a `push_scroll` region.
pub const ScrollStyle = cmd.ScrollStyle;
/// Placement and look of a `push_overlay` (second z-layer).
pub const OverlayStyle = cmd.OverlayStyle;
/// Geometry of a `push_virtual_list` (only visible rows are emitted).
pub const VirtualListStyle = cmd.VirtualListStyle;
/// Intrinsic size and flex of an `image` leaf.
pub const ImageStyle = cmd.ImageStyle;
/// An image leaf referencing an uploaded texture.
pub const ImageCmd = cmd.ImageCmd;
/// A styled byte range inside a `RichTextCmd`.
pub const RichTextSpan = cmd.RichTextSpan;
/// Multi-style text: shared content plus spans.
pub const RichTextCmd = cmd.RichTextCmd;
/// One run of a `mixedText` line (own font, color, weight).
pub const MixedPart = cmd.MixedPart;
/// Options for `pushFormRow`: label, units, validation message.
pub const FormRowOpts = cmd.FormRowOpts;
/// The four container kinds that `validateBalance` pairs up.
pub const BalanceKind = cmd.BalanceKind;
/// First push/pop imbalance found by `validateBalance`.
pub const BalanceError = cmd.BalanceError;
/// Return the first push/pop imbalance in a cmd buffer, or null.
pub const validateBalance = cmd.validateBalance;
/// Format a `BalanceError` as one actionable line.
pub const formatBalanceError = cmd.formatBalanceError;
/// Maximum container nesting depth accepted by the framework.
pub const MAX_BALANCE_DEPTH = cmd.MAX_BALANCE_DEPTH;
/// A clickable button leaf.
pub const ButtonCmd = cmd.ButtonCmd;
/// Colors, size and alignment of a button.
pub const ButtonStyle = cmd.ButtonStyle;
/// A single-style text leaf.
pub const TextCmd = cmd.TextCmd;
/// A single-line text input leaf (cursor, selection, focus Msg).
pub const TextInputCmd = cmd.TextInputCmd;
/// Colors and size of a text input.
pub const TextInputStyle = cmd.TextInputStyle;
/// A checkbox leaf; the app owns the checked state.
pub const CheckboxCmd = cmd.CheckboxCmd;
/// Colors and size of a checkbox.
pub const CheckboxStyle = cmd.CheckboxStyle;
/// A radio leaf; the app owns the selection.
pub const RadioCmd = cmd.RadioCmd;
/// Colors and size of a radio button.
pub const RadioStyle = cmd.RadioStyle;
/// A slider leaf; the app owns the value.
pub const SliderCmd = cmd.SliderCmd;
/// Colors and size of a slider.
pub const SliderStyle = cmd.SliderStyle;
/// Color and thickness of a divider.
pub const DividerStyle = cmd.DividerStyle;
/// A canvas leaf holding pure-data draw primitives.
pub const CanvasCmd = cmd.CanvasCmd;
/// Intrinsic size, background and flex of a canvas.
pub const CanvasStyle = cmd.CanvasStyle;
/// One draw op inside a canvas (polyline, rect, lines, triangles, ...).
pub const CanvasPrimitive = cmd.CanvasPrimitive;
/// A point in canvas-local logical pixels.
pub const CanvasPoint = cmd.CanvasPoint;
/// Main axis of a container: horizontal or vertical.
pub const Direction = cmd.Direction;
/// Cross-axis placement of a container's children.
pub const Align = cmd.Align;
/// Horizontal placement of text inside its box.
pub const TextAlign = cmd.TextAlign;
/// Visual variant of a text input.
pub const InputVariant = cmd.InputVariant;
/// Main-axis distribution of leftover space.
pub const Justify = cmd.Justify;

/// Mouse buttons currently held.
pub const Buttons = pointer.Buttons;
/// Keyboard modifier state at the time of an event.
pub const Modifiers = pointer.Modifiers;
/// A mouse button.
pub const Button = pointer.Button;
/// One pointer event on an interactive canvas or scene.
pub const CanvasEvent = pointer.CanvasEvent;
/// Kind of a `CanvasEvent` (press, move, release, wheel, ...).
pub const CanvasEventKind = pointer.CanvasEventKind;

/// Opaque backend mesh handle.
pub const MeshHandle = scene.MeshHandle;
/// The "no mesh" handle; a scene with it draws only the clear colour.
pub const MESH_HANDLE_NONE = scene.MESH_HANDLE_NONE;
/// Vertex of a lit mesh triangle.
pub const MeshVertex = scene.MeshVertex;
/// Vertex of an instanced edge line.
pub const LineVertex = scene.LineVertex;
/// Mesh geometry for `Gpu.uploadMesh`.
pub const MeshData = scene.MeshData;
/// View and projection parameters of a `scene3d`.
pub const Camera = scene.Camera;
/// One 3D scene to render this frame.
pub const SceneDraw = scene.SceneDraw;

/// A declared GPU resource (image or mesh) keyed by an app-chosen key.
pub const Resource = resources.Resource;
/// A declared mesh resource.
pub const MeshResource = resources.MeshResource;
/// A declared image resource.
pub const ImageResource = resources.ImageResource;

/// Intrinsic size and flex of a `scene3d` leaf.
pub const SceneStyle = cmd.SceneStyle;
/// A 3D scene leaf rendered offscreen by the Gpu.
pub const SceneCmd = cmd.SceneCmd;

/// Data describing an I/O request the Host performs.
pub const Effect = effects.Effect;
/// The outcome of an effect, delivered back as a Msg.
pub const EffectResult = effects.EffectResult;
/// An HTTP request effect.
pub const HttpRequest = effects.HttpRequest;
/// The response (or failure) of an HTTP effect.
pub const HttpResult = effects.HttpResult;
/// HTTP method of an `HttpRequest`.
pub const HttpMethod = effects.HttpMethod;
/// A name/value HTTP header.
pub const Header = effects.Header;
/// Something the user pasted or dropped onto the window.
pub const Drop = effects.Drop;
/// What kind of payload a `Drop` carries.
pub const DropKind = effects.DropKind;
/// What `Host.submit` did with an effect.
pub const EffectSubmit = effects.EffectSubmit;

/// Fixed-column monospace table helpers.
pub const Table = table.Table;
/// One column of a `Table`.
pub const TableColumn = table.Column;
/// How one emitted table row looks.
pub const TableRowStyle = table.RowStyle;
/// Alignment of a cell within its column.
pub const CellAlign = table.CellAlign;
/// Fit text into a fixed number of characters (pad or ellipsize).
pub const fitCell = table.fitCell;

/// Size, bounds and colors for `lineChartPrimitives`.
pub const LineChartOpts = chart.LineChartOpts;
/// Build the canvas primitives for a line chart of a data series.
pub const lineChartPrimitives = chart.lineChartPrimitives;

/// An axis-aligned rectangle in logical pixels.
pub const Rect = layout.Rect;
/// Runs the measure and position passes over a cmd buffer.
pub const LayoutEngine = layout.LayoutEngine;
/// Viewport and content size of a scroll region.
pub const ScrollExtent = scroll_extent.Extent;
/// Measure a scroll region's viewport and content from the layout rects.
pub const scrollExtent = scroll_extent.scrollExtent;

/// Return the topmost interactive leaf (and its Msg) under a point.
pub const hitTest = hit_test.hitTest;
/// Like `hitTest` but returns only the cmd index.
pub const hoverTest = hit_test.hoverTest;
/// Convert a window-space point to canvas-local coordinates.
pub const canvasLocalPoint = hit_test.canvasLocalPoint;
/// Normalized [0, 1] slider value for a mouse x within the slider's rect.
pub const sliderValueAt = hit_test.sliderValueAt;
/// Describe an in-progress slider drag from the pressed cmd index.
pub const sliderDrag = hit_test.sliderDrag;
/// Drag state of a slider currently held.
pub const SliderDrag = hit_test.SliderDrag;
/// Next focusable cmd index after `current`, wrapping around.
pub const nextFocusable = focus.nextFocusable;
/// Previous focusable cmd index before `current`, wrapping around.
pub const prevFocusable = focus.prevFocusable;
/// Cmd index of the interactive leaf carrying a given focus Msg.
pub const indexOfFocusMsg = focus.indexOfFocusMsg;
/// The activation / focus Msg of the leaf at an index, if any.
pub const focusMsgAt = focus.focusMsgAt;
/// Host-neutral non-text keys and chords.
pub const SpecialKey = keys.SpecialKey;
/// One accessibility-tree node derived from a cmd.
pub const A11yNode = a11y.A11yNode;
/// Semantic role of an `A11yNode`.
pub const A11yRole = a11y.Role;
/// Build the flat accessibility tree for a frame.
pub const buildA11yTree = a11y.buildTree;

/// A declarative subscription (timer) producing a Msg.
pub const Sub = sub.Sub;
/// Fire the subscriptions due this frame via a dispatch callback.
pub const runSubs = sub.runSubs;

/// Bundled palette, typography and per-widget styles for the theme-aware emitters.
pub const Theme = theme.Theme;
/// Semantic color set of a theme.
pub const Palette = theme.Palette;
/// Font set of a theme.
pub const Typography = theme.Typography;
/// The default dark palette.
pub const dark_palette = theme.dark_palette;
/// The default light palette.
pub const light_palette = theme.light_palette;

/// Text-input component with cursor, selection and editing `update`.
pub const TextField = text_field.TextField;
/// Text field specialised for numbers (parse, validate, value).
pub const NumericField = numeric_field.NumericField;
/// Comptime configuration for `NumericField`.
pub const NumericConfig = numeric_field.NumericConfig;
/// Closed button plus an open overlay list of options.
pub const Dropdown = dropdown.Dropdown;
/// Anchor and sizing for the open dropdown list.
pub const DropdownViewOpts = dropdown.DropdownViewOpts;
/// Searchable select component (see `combobox`).
pub const Combobox = combobox.Combobox;
/// Anchor and sizing options for the open combobox list.
pub const ComboboxViewOpts = combobox.ViewOpts;
/// Build the app Msg for a typed character into a named field.
pub const textFieldChar = text_field.textFieldChar;
/// Build the app Msg for a `SpecialKey` into a named field.
pub const textFieldSpecial = text_field.textFieldSpecial;
/// Build the app Msg for pasted text into a named field.
pub const textFieldReplaceSelection = text_field.textFieldReplaceSelection;
/// True if a key needs host-level clipboard access.
pub const keyNeedsClipboard = text_field.keyNeedsClipboard;

/// The GPU vertex layout shared by every quad (position, color, uv).
pub const Vertex = vertex.Vertex;
/// Append a solid or textured axis-aligned quad as two triangles.
pub const emitQuad = vertex.emitQuad;
/// Append a quad from four explicit corners as two triangles.
pub const emitQuadCorners = vertex.emitQuadCorners;
/// Render cmds + rects into a vertex list (no text/image/scene output).
pub const buildVertices = render.buildVertices;
/// An image draw record produced by the render pass.
pub const ImageDraw = render.ImageDraw;
/// Render cmds + rects + transient state into vertices and draw records.
pub const buildFrame = render.buildFrame;
/// Vertex/draw-list offsets separating the base layer from the overlay layer.
pub const OverlaySplit = render.OverlaySplit;
/// Run-loop resource bookkeeping for hand-written host loops (web): `sync`
/// the table with `App.resources(model)`, then `stageDraws` instead of
/// `uploadImages`. `teak.run` does both for you.
pub const ResourceTable = @import("resources.zig").Table;
/// Map app resource keys in a frame's draws to backend handles.
pub const stageDraws = @import("resources.zig").stageDraws;

/// Hover / press / focus state that short-circuits input to render.
pub const TransientState = transient.TransientState;

/// Comptime-compose components into one Model / Msg / update / view.
pub const Components = component.Components;
/// Compile-time check that a type satisfies the component contract.
pub const validateComponent = component.validateComponent;
/// A comptime-generated dynamic list of homogeneous components.
pub const ComponentList = component_list.ComponentList;

/// Options for `appendDebugOverlay`.
pub const DebugOverlayOpts = debug_overlay.DebugOverlayOpts;
/// Append an overlay listing every cmd and its rect.
pub const appendDebugOverlay = debug_overlay.appendDebugOverlay;

/// Options for snapshot serialization.
pub const SnapshotOptions = snapshot.SnapshotOptions;
/// Optional header line (window size, frame, last Msg) for a snapshot.
pub const SnapshotHeader = snapshot.Header;
/// Serialize a frame's cmds + rects to a writer.
pub const writeSnapshot = snapshot.write;
/// Serialize a frame to an allocated string.
pub const snapshotAlloc = snapshot.snapshotAlloc;
/// Golden-test helper: compare a frame's snapshot with expected text.
pub const expectSnapshot = snapshot.expectSnapshot;

/// Per-frame input snapshot returned by `Host.pollInputs`.
pub const InputState = host.InputState;
/// Event accumulator turning native events into an `InputState`.
pub const InputQueue = input_queue.InputQueue;
/// Navigation keys a Host may deliver.
pub const NavKey = input_queue.NavKey;
/// The one Shift/Ctrl policy: map a key plus modifiers to a `SpecialKey`.
pub const resolveKey = input_queue.resolveKey;
/// Host-owned clipboard surface.
pub const Clipboard = host.Clipboard;
/// IME composition state.
pub const ImeState = host.ImeState;
/// Result of a file dialog.
pub const FileDialogResult = host.FileDialogResult;
/// A file-type filter for a file dialog.
pub const FileDialogFilter = host.FileDialogFilter;
/// Result of polling an async file dialog.
pub const FileDialogPoll = host.FileDialogPoll;
/// Compile-time check that a type satisfies the `Host` contract.
pub const validateHost = host.validateHost;

/// Background clear color passed to the Gpu.
pub const ClearColor = gpu.ClearColor;
/// Compile-time check that a type satisfies the `Gpu` contract.
pub const validateGpu = gpu.validateGpu;

/// Run an App against a Host and Gpu until the window closes.
pub const run = runtime.run;
/// The frame-stepping runtime behind `run` (one `frame()` per iteration).
pub const Runtime = runtime.Runtime;
/// Options for `run` (title, clear color, snapshot sink, ...).
pub const RunOptions = runtime.RunOptions;
/// A second top-level window the app wants open this frame.
pub const SecondaryWindowSpec = runtime.SecondaryWindowSpec;

/// Font family selector (monospace or sans).
pub const FontFamily = text.FontFamily;
/// A font request: family, size and weight.
pub const FontSpec = text.FontSpec;
/// Regular or bold.
pub const FontWeight = text.FontWeight;
/// The default font request.
pub const DEFAULT_FONT = text.DEFAULT_FONT;
/// Measured width and height of a text run.
pub const TextMetrics = text.TextMetrics;
/// The Host-provided text measurement interface.
pub const TextMeasurer = text.TextMeasurer;
/// One positioned glyph produced by a `Shaper`.
pub const ShapedGlyph = text.ShapedGlyph;
/// A shaped run: glyphs plus total advance.
pub const ShapeResult = text.ShapeResult;
/// Pluggable shaping interface (runs -> positioned glyph ids); `SimpleShaper` lives in teak-text.
pub const Shaper = text.Shaper;
/// Opaque GPU texture token.
pub const TextureHandle = text.TextureHandle;
/// The "no texture" handle.
pub const TEXTURE_HANDLE_NONE = text.TEXTURE_HANDLE_NONE;
/// Render-pass output for one run of text.
pub const TextDraw = text.TextDraw;
/// Stateless fixed-advance measurer for CLI canaries and tests.
pub const monoMeasurer = text.monoMeasurer;

test {
    @import("std").testing.refAllDecls(@This());
}
