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
sticky column), the wheel scrolls (clamped to the content), and `metrics` clamps and reveals the caret.

### Wiring (the whole contract, no source reading needed)

1. **Model / Msg / update**: a `TextArea(cap).Model` field, a `TextArea(cap).Msg` variant, and one `update` arm that
   forwards to `TextArea(cap).update(&m.area, a)`. Record focus yourself when the Msg is `.focus` (the area cannot know
   which of your widgets owns the keyboard).
2. **view**: `Area.viewWith(&m.area, cb, .{ .focus = Msg{ .area = .focus } }, .{ .id = 1, .height = 200 })`. `id` is a
   distinct non-zero number per area; options: `width`, `min_width`, `height`, `flex`, `wrap` (`.word` / `.char` /
   `.none`), `padding`, `style`, `font`, `disabled`. The area fills the width of a stretching parent.
3. **Hooks** (optional declarations on the app struct that `teak.run` looks for):

| hook | one-line body | carries |
|---|---|---|
| `textMsg(m, ev) ?Msg` | `.{ .area = Area.eventMsg(ev) }` (route on `ev.id` with several areas) | pointer, wheel, `move` (Up/Down/PageUp/PageDown/Home/End), `metrics` |
| `keyCharMsg(m, c) ?Msg` | `if (focused) .{ .area = Area.charMsg(c) } else null` | typed UTF-8 bytes |
| `keySpecialMsg(m, k) ?Msg` | `if (focused) if (Area.keyMsg(k)) \|a\| .{ .area = a }` | Enter, Backspace/Delete, Left/Right (+Shift, +Ctrl), Ctrl+A/Z/Y |
| `focusedMsg(m) ?Msg` | `if (focused) .{ .area = .focus } else null` | focus for Tab traversal, caret blink, IME spot |
| `keyNeedsClipboard(k)` + `handleClipboard(m, k, clip)` | see below | Ctrl+C / X / V |

4. **Clipboard** is the app's policy: copy with `clip.write(m.area.selectionText())`, cut = copy then
   `update(m, .{ .area = .{ .key = .backspace } })`, paste with `Area.pasteMsg(clip.read())`.

The complete, compiled version of exactly this is [cookbook recipe 23](../cookbook.md#23-add-a-multi-line-textarea)
(it is a test in `src/run_test.zig`, so it cannot drift); `examples/notes` has two areas, a chat log and Send/Clear.

Motion: Left/Right and Shift variants go to the `Editor` (grapheme-aware; word jumps with Ctrl). Up/Down/Home/End/PageUp/
PageDown never arrive as keys: the run loop resolves them against the real wrapped layout and sends a `move` event with
the target byte offset and the sticky column. Undo/redo (Ctrl+Z / Ctrl+Y) and select-all (Ctrl+A) are handled by the
editor and grouped by typing bursts.

Not here: bidi / complex scripts (see [text.md](text.md) for what is supported and what is queued), spell-check, rich
formatting inside the area (use `rich_text` for read-only styled text).
