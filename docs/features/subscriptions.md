# Subscriptions (`teak.Sub` / `subscribe`)

`src/core/sub.zig` — declarative timers / external-event listeners.
HARDLINE §2 escape hatch 6. Re-exported as `teak.Sub` + `teak.runSubs`.

## Why

A view must not read the wall clock (HARDLINE §3 bans
`std.time.nanoTimestamp()` / `Date.now()` in `view`), yet plenty of apps
need to *do something over time*: a cursor blink, a clock label, an
autosave tick, a "fire X after 500 ms idle" deadline, a poll of an async
file dialog. Subscriptions express that intent as **data** the app
declares and the runtime services — no clock in `view`, no callback on a
`Cmd`, no second mutation path.

A `Sub` is *not* a reactive signal (HARDLINE §3 forbids those). A fired
sub becomes a regular `Msg` through `update`; observers are still the
next frame's `view`, exactly like every other transition.

## The hook

An app (or component) exposes a **pure** function of model:

```zig
pub fn subscribe(model: *const Model) []const teak.Sub(Msg)
```

Same purity rules as `view`: no I/O, no wall-clock, no allocation outside
the per-frame arena. Its job is to *declare* what should be watched this
frame; the runtime does the watching. It is recomputed every frame, so a
sub is "active" exactly as long as `subscribe` keeps returning it.

`teak.run` detects the decl with `@hasDecl` — apps without a timer omit
it and pay nothing.

## The data

```zig
Sub(comptime Msg: type) = union(enum) {
    every: struct { interval_ms: u32, msg: Msg },   // periodic
    at:    struct { deadline_ms: u64, msg: Msg },    // one-shot deadline
};
```

- **`.every(interval_ms, msg)`** fires once per crossed
  `now / interval_ms` boundary since the previous frame. Approximate
  cadence (within a frame): a slow frame can skip a tick or fire twice —
  both fires go through `update`. Good for cursor blink, autosave, polling.
  A zero interval is a no-op (guards div-by-zero).
- **`.at(deadline_ms, msg)`** fires exactly once on the frame transition
  where `last_frame_ms < deadline_ms <= now_ms`. `deadline_ms` is on the
  host's monotonic clock (`Host.nowMs()`). Build "fire after 500 ms idle"
  by storing `deadline = nowMs + 500` in `Model` and emitting
  `.at(model.deadline, msg)` until it fires.

Both variants are **stateless at the framework level** — no sub-key
dedup, no last-fired tracking. `.at` fires on *every* frame past its
deadline, so the app must **drop the sub from `subscribe()`** once it
fires (e.g. clear the deadline field in the handler) or it re-fires.

## How `teak.run` services it

`run` closes the loop for you (before this wave the primitives existed but
`run` never called them). Each frame, immediately before it builds the
view:

```zig
if (has_subscribe) {
    const now_ms = host.nowMs();
    const since = last_sub_ms orelse now_ms; // first frame: no window, no fire
    runSubs(Msg, App.subscribe(&model), since, now_ms, dispatch);
    last_sub_ms = now_ms;
}
```

- **Timer state lives in one place.** `runSubs` is stateless — it decides
  fire/skip purely from `(last_frame_ms, now_ms, sub data)`. The only
  bookkeeping `run` holds is `last_sub_ms`, the previous frame's
  timestamp — loop-orchestration state, exactly like `press_target`.
  Time itself lives on the **Host** (`nowMs`), never in core (HARDLINE
  §2 hatch 6 + §4).
- **No sub fires on the opening frame.** `last_sub_ms` starts `null` and
  binds to the first `nowMs`, so there is no window to compare against —
  subs need a `[last, now)` interval.
- **Fired subs are ordinary Msgs.** `run` routes each through the same
  `Router.dispatch` that input Msgs use, so a sub-driven change mutates
  `Model` through `update` (no second mutation path) and updates
  `last_msg` for the live snapshot header. Because servicing happens
  before the frame's `view` builds, the change is reflected in the frame
  emitted this tick and — when it changes observable content — mirrored to
  the `TEAK_SNAPSHOT` sink via the normal frame-diff.

## Standalone use (no `teak.run`)

The primitives are usable directly if you hand-roll a loop. `runSubs`
takes `dispatch` as `anytype` and calls it as `dispatch(msg)` — a bare
function; bind context via the small-static-struct idiom the in-file
tests use:

```zig
const Sink = struct {
    var model: *Model = undefined;
    fn dispatch(msg: Msg) void { update(model, msg); }
};
Sink.model = &model;

const now = host.nowMs();
runSubs(Msg, subscribe(&model), last_frame_ms, now, Sink.dispatch);
last_frame_ms = now;
```

## HARDLINE bounds (§2 hatch 6)

- `subscribe` is pure — declares only; no I/O, no wall-clock, no
  allocation. Same rules as `view`.
- `Sub` carries data only — no function pointers, no callbacks (same rule
  as `Cmd`, §3).
- Time / frame-counter state lives on the Host (it owns `frame(dt)` and
  `nowMs` per §4). No globals in core.
- A fired sub is a regular `Msg` through `update`. There is no second
  mutation path — which is precisely why a `Sub` is not a reactive signal.

## Tests

`src/core/sub.zig` unit-tests `runSubs` directly: `.every` fires once per
crossed interval (and twice across a slow two-interval frame), `.at` fires
exactly once on the deadline crossing and never again, zero interval is a
no-op. `src/run.zig` drives the full loop headlessly with an
advancing-clock stub Host and an app declaring a `.every` sub, asserting
the Msg reaches `update` (Model changes) and that the live snapshot
mirrors the post-fire frame with `last_msg=tick`.

See also: [cookbook recipe 11](../cookbook.md) (timer/subscription),
[run.md](run.md) (the loop + hook table),
[functional-gaps.md §4](functional-gaps.md).
