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

### Complete wiring (one area, copy-paste)

Everything an app needs, in one place (no need to read `examples/notes`):

```zig
const std = @import("std");
const teak = @import("teak");

const Notes = teak.TextArea(8192);       // capacity in bytes
const NOTES_ID = 1;                      // distinct, non-zero per area on screen

pub const Model = struct {
    notes: Notes.Model = .{},
    notes_focused: bool = false,         // YOUR focus bit: the Msg carries no data
};

pub const Msg = union(enum) { notes: Notes.Msg };

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .notes => |a| {
            if (a == .focus) m.notes_focused = true;      // a click on the area
            Notes.update(&m.notes, a);
        },
    }
}

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 16, .align_cross = .stretch });
    Notes.viewWith(&m.notes, cb, .{ .focus = Msg{ .notes = .focus } }, .{ .id = NOTES_ID, .height = 200 });
    cb.popGroup();
}

// ── hooks the run loop calls ─────────────────────────────────────────
/// Pointer, wheel, caret motion (Up/Down/Home/End/PageUp/PageDown) and layout
/// metrics arrive as `TextEvent`s already resolved against the wrapped layout.
pub fn textMsg(_: *const Model, ev: teak.TextEvent) ?Msg {
    return if (ev.id == NOTES_ID) Msg{ .notes = Notes.eventMsg(ev) } else null;
}
/// Typed characters (UTF-8 bytes; the editor assembles them atomically).
pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    return if (m.notes_focused) Msg{ .notes = Notes.charMsg(c) } else null;
}
/// Editing keys and chords (Backspace, Delete, arrows with Shift/Ctrl, Ctrl+A,
/// Ctrl+Z/Y, ...) AND Enter (-> `.newline`). `Notes.keyMsg(k)` is null for keys
/// it does not handle.
pub fn keySpecialMsg(m: *const Model, k: teak.SpecialKey) ?Msg {
    if (!m.notes_focused) return null;
    return if (Notes.keyMsg(k)) |a| Msg{ .notes = a } else null;
}
/// So the loop draws the caret, enables Tab traversal and (see below) knows
/// that Enter belongs to the area.
pub fn focusedMsg(m: *const Model) ?Msg {
    return if (m.notes_focused) Msg{ .notes = .focus } else null;
}
```

* **Enter** is a key in a focused text area: the loop delivers it to
  `keySpecialMsg` (where `Notes.keyMsg(.enter)` is `.newline`) **even when the App
  also declares `submitMsg`** — `submitMsg` is only used while the focused widget
  is *not* a `text_area` (needs `focusedMsg`, as above). A form with a chat box
  (`submitMsg` -> send) and a notes area (Enter -> newline) therefore needs no
  trick.
* **Set the text from code** with `Model.set(bytes)` (`m.notes.set("")` clears;
  caret to the end, history cleared) from `update`. Read it with `m.notes.content()`.
* **Several areas**: one `Model` field + `Msg` variant + `update` arm + `viewWith`
  per area, distinct `id`s, and one `switch (ev.id)` in `textMsg`.
* The IME caret rect goes to `Host.setImeSpot` automatically.

Clipboard stays the app's: `clipboardText` returns `Model.selectionText()` for Ctrl+C / Ctrl+X and `clipboardMsg` returns `Notes.pasteMsg(paste)` for Ctrl+V and a backspace key Msg for Ctrl+X (the older `handleClipboard` pair is deprecated).
