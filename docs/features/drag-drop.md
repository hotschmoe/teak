# In-app drag and drop

**Status**: `pub` as `teak.DragEvent`, `teak.DragPhase`; new `GroupStyle.drag_id` / `drop_id`; App hook `dragMsg`.
**Source**: `src/core/pointer.zig` (event types), `src/core/cmd.zig` (`GroupStyle`), `src/input/hit_test.zig` (`dragTargets`), `src/run.zig` (`routeDrag`).
**Tests**: `src/run_test.zig` ("drag: ..."), `src/input/hit_test.zig`, `examples/todo` (reorder), `src/platform/headless_drive_test.zig` (agent `drag`).

Reorder a list or drop an item on a target with the mouse, keeping all state in the Model.

## The contract

* Mark a group a **source** with `.drag_id = id` and/or a **target** with `.drop_id = id` (non-zero, the app's ids; a list row is usually both with one id). No new Cmd variants: they are two fields of `GroupStyle`, hit-tested against the previous frame's layout like everything else (scroll-clipped, overlay-layered).
* The App declares `pub fn dragMsg(*const Model, teak.DragEvent) ?Msg` and turns each event into a Msg.
* A left press on a source that **no interactive widget claims** (a button, checkbox, text input under the pointer still click normally) arms a drag; moving past 4 px starts it.

```zig
DragEvent = struct { phase: .start | .move | .drop | .cancel, id,        // the source's drag_id
                     x, y,                                               // pointer, window coords
                     grab_dx, grab_dy, src: [4]f32,                      // where in the source rect it was grabbed; the rect
                     over: u32, over_rect: [4]f32, over_fx, over_fy }    // innermost drop target under the pointer (0 = none), pointer inside it 0..1
```

`move` arrives every frame while dragging (even when the pointer rests, so a ghost never lags), `drop` on release (with `over`; the app decides whether `over == 0` or `over == id` means anything), `cancel` on Escape.

## What the app does

All of it is ordinary TEA (see `examples/todo/src/app.zig`):

* **Drag state** is a Model field (`drag: ?Drag` with the source, pointer, grab offset, hot target, "after" half), written by `update` from the events.
* The **ghost** is an overlay the view emits at `x - grab_dx, y - grab_dy` while `drag != null`; the **drop indicator** is a border/bg the view puts on the row whose id equals `drag.over`.
* The **reorder** happens in `update` on `drop`: `over_fy >= 0.5` means insert after the target row.
* **Keyboard alternative**: a `commands` table with Alt+Up / Alt+Down acting on a selected row ([commands.md](commands.md)); the same `update` helper (`moveItem`) serves both.

## Agents

`{"cmd":"drag","from":{selector},"to":{selector}}` (CLI `teak-drive drag '<json>' '<json>'`, MCP tool `drag`) presses on `from`, moves to `to` in six steps (one frame each) and releases, through the real pointer path. Selectors accept `offset_x` / `offset_y` from the node's center, since pressing an interactive widget clicks it instead of dragging; for a row, select its grip text (`{"role":"text","label":"::","nth":2}`).

## Limits

Left button only; one drag at a time; no drag across windows or to/from the OS (file drop into the window is a separate effect, see [effects.md](effects.md)); targets are rectangles (no custom shapes); auto-scrolling a list during a drag is the app's job (it receives `move` events with the pointer position).
