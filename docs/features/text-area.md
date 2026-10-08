# `text_area` and `TextArea` (text-engine PR11a/PR11b)

Multi-line editable text: wrapping, scrolling, selection across wrapped lines, a caret, IME composition,
pointer editing and visual-line motion. Design: [text-engine.md](text-engine.md) sections 6.2-6.4.

## Cmd

`cb.textArea(TextAreaCmd{...})` / `cb.textAreaThemed(...)`: `focus_msg`, `id` (distinct non-zero), `content`, `cursor`,
`selection_anchor`, `scroll_x/y`, `goal_x` (all from the Model), `wrap` (`.word` default, `.char`, `.none` = horizontal
scroll), `font`, `style` (a `TextInputStyle`), `width` / `min_width` / `height` / `flex`, `padding`, `disabled`.
It is a new variant, so it ticks the full widget checklist: layout arm (canvas-like box; fills a stretching parent),
hit-test (focus Msg, pointer surface), render, snapshot, a11y role `.text_area`, frame diff, Win32 UIA `Edit`, focus
traversal, `teak.zig` + `llms.txt`.

Render (`render/build.zig`) wraps with the same `text_wrap` walk as layout: one `TextDraw` per visible line (culled
by `scroll_y`), per-line selection quads (a newline inside the selection shows a small stub), the IME composition from
`TransientState` underlined at the caret, and the blinking caret, all clipped to the inner box (border + padding).

## Events: `textMsg`

`teak.run` turns input over a `text_area` into `TextEvent` records for the optional hook
`textMsg(*const Model, TextEvent) ?Msg` (HARDLINE hatch 4(d): same shape as `canvasMsg`; the framework builds no Msg).

| kind | when | fields |
|---|---|---|
| `down` / `double_click` / `triple_click` | left press (click count: same spot within 400 ms, cycling 1-3) | `index`, `line`, `x`, `y`, `mods` |
| `drag` | pointer moved with the button held; **captured**, so it continues outside the rect | `index`, ... |
| `up`, `leave` | release; pointer left with no capture | |
| `wheel` | wheel over the area (INSTEAD of `wheelMsg`/`scrollMsg`) | `dx`, `dy` |
| `move` | Up/Down/PageUp/PageDown/Home/End (+Shift) while the area has focus; the key is consumed | `index`, `line`, `goal_x`, `keep_goal`, `mods.shift` |
| `metrics` | first layout and whenever viewport / content / caret rect change | `viewport_*`, `content_*`, `caret_x/y/h` |

`index` is the byte offset of the grapheme boundary nearest the pointer (`text_wrap.indexAt`); `move` is resolved by
`text_wrap.resolveNav` on the real wrapped layout, so Up/Down follow visual lines and keep the sticky column.
The focused caret rect also goes to `Host.setImeSpot(x, y)` when the Host has it (and for a focused `text_input`).
The metrics table remembers 8 areas; more are re-reported only when they differ from "unknown".

## `TextArea(cap)` component

An `Editor` (multiline) plus scroll state. `Msg = focus | char | newline | key | paste | event`. `update` applies
`Editor.applyPointer` (down = caret, Shift extends, drag extends, double = word, triple = hard line, `move` = target +
sticky column), the wheel scrolls (clamped to the content), and `metrics` clamps and reveals the caret. Wiring: see the
header of `src/core/text_area.zig` and `examples/notes` (a notes editor and a chat box, ~10 lines of glue each).

Clipboard stays the app's (`keyNeedsClipboard` / `handleClipboard` with `Model.selectionText()` and `pasteMsg`).
