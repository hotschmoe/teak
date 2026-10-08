# Proposal: one `pointerMsg` hook instead of five pointer hooks

Status: **proposal** (drift audit 2026-10). Not implemented: the hooks it would
replace are still landing in open PRs, and the queue must not break. Revisit once
`textMsg`, `hoverMsg`, `contextMsg` and `sliderMsg` are on master.

## Today

The run loop has one routing function and one hook per pointer surface:

| Hook | Surface | Event type |
|---|---|---|
| `canvasMsg` | interactive canvas / scene | `CanvasEvent` (down/move/up/wheel/leave/layout) |
| `textMsg` | `text_area` | `TextEvent` (caret placement, selection drag, clicks) |
| `hoverMsg` | any interactive widget | `PointerEvent(Msg)` (enter / leave) |
| `contextMsg` | any widget, right button | `PointerEvent(Msg)` |
| `sliderMsg` | `slider` cmd | `(grab Msg, value)` |
| `wheelMsg` / `scrollMsg` | wheel | `f32` / `(id, dx, dy)` |

Each has its own capture rule ("a press captures the pointer until every button
is released"), its own opt-in `@hasDecl`, its own idle-skip handling, and its
own row in the docs table. A new surface (a draggable splitter, a table column
resize) means a new hook, a new route function and a new capture variable.

## Proposal

```zig
pub fn PointerEvent(comptime Msg: type) type {
    return struct {
        kind: Kind,          // down, move, up, wheel, enter, leave, context, layout
        target: Target,      // what the pointer is over / captured by
        x: f32, y: f32,      // window space
        local_x: f32, local_y: f32,   // relative to the target's rect
        dx: f32, dy: f32,    // wheel or drag delta
        button: Button,      // which button changed (down/up/context)
        buttons: Buttons, mods: Modifiers,
        clicks: u8,          // 1, 2, 3 for repeated presses
        pub const Kind = enum { down, move, up, wheel, enter, leave, context, layout };
        pub const Target = union(enum) {
            none,
            widget: ?Msg,                 // the leaf's own click Msg (button, checkbox, ...)
            canvas: u32,                  // CanvasCmd.id / SceneCmd.id
            text_area: struct { id: u32, offset: usize },   // resolved caret byte
            slider: struct { grab: Msg, value: f32 },
            scroll: u32,                  // ScrollStyle.id
        };
    };
}
// App: pub fn pointerMsg(*const Model, PointerEvent(Msg)) ?Msg
```

One hook, one capture (the target that got `down` receives every event until all
buttons are up), one routing function in `run.zig`, one docs row. `wheelMsg` stays
(it is the "nothing claimed it" fallback). `commands` and the key hooks are
unaffected.

## Why it is better

* HARDLINE: still data-in / Msg-out, no callbacks; actually *less* surface to
  audit (the audit rule counts hooks, so five rows become one).
* Idle skip and the layout-dirty rule apply to one place instead of five.
* New surfaces add a `Target` variant, not a hook: no change to the App contract.

## Costs

* Breaking for apps using `canvasMsg` (viewport, kerf_viewer, scene examples) and
  every PR that adds a pointer hook: migrate with a mechanical rewrite (`switch
  (ev.kind)` replaces the hook, the target payload replaces the event fields).
* Apps that only care about one surface now switch on `ev.target` first. A thin
  adapter (`teak.pointer.canvasOnly(App.canvasMsg)`) can keep the old shape for
  one release.
* `TextEvent`'s selection logic should stay in `core/` as pure helpers; the hook
  only forwards the resolved byte offset.

## Plan

1. Land the open pointer PRs unchanged (#40, #52, #56, #33/#47).
2. One PR: add `PointerEvent`/`pointerMsg` and route the five hooks *through* it
   (old hooks become adapters over the new path; no behaviour change, tests prove
   it). Update the docs table.
3. Migrate the examples, deprecate the old hooks with a CHANGELOG + migration
   note, remove them one release later.
