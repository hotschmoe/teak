# Migration: `canvasMsg` / `textMsg` / `sliderMsg` / `scrollMsg` / `hoverMsg` / `contextMsg` -> `pointerMsg`

Pointer input has **one** hook now:

```zig
pub fn pointerMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg
```

`ev.kind` says what happened (`hover`, `down`, `move`, `up`, `wheel`, `leave`,
`context`, `layout`, `key`, `caret`), `ev.target` what it happened to (`.widget ?Msg`,
`.canvas id`, `.text_area {id, offset, line, ...}`, `.slider {grab, value}`,
`.scroll id`, `.none`). Coordinates are window-space (`x`, `y`) and
target-local (`local_x`, `local_y`), plus `dx`/`dy`, `w`/`h`, `button`,
`buttons`, `mods`, `clicks`. One capture rule covers every surface: the target
that received `down` receives every event until all buttons are up.

The old hooks still work: `teak.run` translates the same events back to their
old types (`Runtime.deliverDeprecated`) and logs one startup note naming them
(`teak.deprecatedHooks(App)`; never a compile error). They are removed one
release after this one. Nothing in the tree uses them (`zig build audit`
fails if an example declares one).

The helper widgets keep their data-in/Msg-out signatures; the event views are
one call away: `ev.asCanvas()` -> `CanvasEvent`, `ev.asText()` -> `TextEvent`,
`ev.asSlider()` -> `.{ grab, value }`, `ev.asScroll()` -> `.{ id, dx, dy }`.
A mechanical rewrite therefore renames each old hook to a private function and
adds a dispatcher:

```zig
// Before
pub fn canvasMsg(m: *const Model, ev: teak.CanvasEvent) ?Msg { ... }
pub fn textMsg(m: *const Model, ev: teak.TextEvent) ?Msg { ... }
pub fn sliderMsg(m: *const Model, grab: Msg, value: f32) ?Msg { ... }
pub fn scrollMsg(m: *const Model, id: u32, dx: f32, dy: f32) ?Msg { ... }
pub fn hoverMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg { ... }
pub fn contextMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg { ... }

// After: the same bodies as private functions, one hook in front
pub fn pointerMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    if (ev.asCanvas()) |c| return onCanvas(m, c);
    if (ev.asText()) |t| return onText(m, t);
    if (ev.asSlider()) |s| return onSlider(m, s.grab, s.value);
    if (ev.asScroll()) |s| return onScroll(m, s.id, s.dx, s.dy);
    return switch (ev.kind) {
        .hover => onHover(m, ev),
        .context => onContext(m, ev),
        .down => if (ev.isBlank() and m.focus != null) Msg.focus_clear else null, // new: blank presses
        else => null,
    };
}
```

## Per hook

| Old hook | In `pointerMsg` | Notes |
|---|---|---|
| `canvasMsg(m, CanvasEvent)` | `ev.asCanvas()` (`target = .canvas`) | `layout`: `x`/`y` are the rect's WINDOW origin, `w`/`h` its size, as before. `key` events (focusable canvas) are `kind = .key`. |
| `textMsg(m, TextEvent)` | `ev.asText()` (`target = .text_area`) | `TextEvent.index` is `target.text_area.offset`; double / triple click are `kind = .down` with `clicks` 2 / 3; `drag` is `.move`; `move` (Up / Down / Home...) is `.caret`; `metrics` is `kind = .layout`. |
| `sliderMsg(m, grab, value)` | `ev.target.slider` / `ev.asSlider()` | One event per frame: `down` (press), `move` (held), `up` (release frame), `key` (keyboard step). Return `null` on the press and the slider stays a plain click. |
| `scrollMsg(m, id, dx, dy)` | `ev.asScroll()` (`kind = .wheel`, `target = .scroll`) | Keyboard scrolling arrives as a synthetic wheel. |
| `hoverMsg(m, PointerEvent)` | `ev.kind == .hover` | Also fires for keyboard focus changes with `keyboard_nav`. |
| `contextMsg(m, PointerEvent)` | `ev.kind == .context` | The Menu key / Shift+F10 too (anchored at the focused widget). |
| `wheelMsg(m, dy)` | unchanged | The fallback: `pointerMsg` is offered an unclaimed wheel first (`target = .none`); returning `null` falls through to `wheelMsg`. |

## Behaviour notes

- A pointer app now also sees widget-level events for presses that land on a
  canvas or text area (`kind = .down`, `target = .widget(null | hit)`), in
  addition to the captured-surface event. Switch on `ev.target` first.
- Wheel: a surface that returns `null` for a `wheel` no longer swallows it; the
  wheel bubbles (canvas -> scroll region -> `pointerMsg` with no target ->
  `wheelMsg`). The deprecated hooks keep consuming it, as before.
- Widget `up` events go to the widget under the pointer (a click is armed on
  press and cancelled by dragging off); captured surfaces get `up` wherever the
  cursor is.
