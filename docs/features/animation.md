# Animation

Animation in teak is **data in the Model plus frame time as a Msg** — no
hidden widget state, no wall clock in `view`, no retained animation objects.

```zig
// Model
help_slide: teak.anim.Tween(f32) = .still(1),
// Msg
frame: u32,                       // dt in ms
// update
.toggle_help => m.help_slide.start(if (open) 1 else 0, 400, .out_cubic),
.frame => |dt| m.help_slide.advance(dt),
// subscribe: frames only while something is moving
pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    return if (m.help_slide.active()) &.{.animation_frame} else &.{};
}
// the run loop's frame time, as a Msg
pub fn animationMsg(_: *const Model, dt_ms: u32) ?Msg { return .{ .frame = dt_ms }; }
// view: pure read of the Model
const y = 120 - (1 - m.help_slide.value()) * 70;
```

## Pieces (`teak.anim`)

* `Tween(T)` — `from`, `to`, `duration_ms`, `elapsed_ms`, `easing`. `still(v)`,
  `start(target, duration_ms, ease)` (continues from the *current* value, so
  reversing mid-flight never jumps), `advance(dt_ms)`, `active()`, `progress()`,
  `value()`.
* `Ease` / `ease(kind, t)` — linear, quad/cubic in/out/in-out, `out_back`.
* `lerp(T, a, b, t)` — floats, ints, bools/enums (switch at 0.5), arrays and
  vectors (a colour is `[4]f32`), and structs of those (a `Rect`, a style).
  Not clamped, so eased overshoot works.
* `Sub.animation_frame` + the App hook `animationMsg(model, dt_ms) ?Msg`. While
  an `animation_frame` sub is listed the loop calls the hook every frame (dt =
  Host-clock ms since the previous frame, capped at 100 ms so a stall cannot
  jump an animation to its end) and does not idle-skip. Stop listing it when
  the tween finishes and the loop goes quiet again (`RunOptions.idle_skip`).

## Why this is HARDLINE-clean

All state is in the Model (the tween is a plain struct); every transition is a
Msg (`.frame`); `view` only reads `value()`; time reaches the Model through
the same Msg channel as input, so an animation replays deterministically from
a Msg log (the headless host's fake clock makes screenshots reproducible). The
`animation_frame` sub carries no fn pointer: the Msg is built by the App's own
`animationMsg`, the same data-in / optional-Msg-out hook shape as `windowMsg`.

## Example

`examples/chrome`: the QUICK KEYS popover slides in (400 ms, `out_cubic`) and
its border and shadow fade in from paper to ink via `lerp`;
closing slides out in 160 ms. `zig build shot -- out.png N` captures N frames
into the slide-in (N=1 mid-slide, N=40 settled).
