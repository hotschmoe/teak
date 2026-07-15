# Application loop (`teak.run`)

`src/run.zig` — the canonical host-loop wrapper. Re-exported as
`teak.run` (+ `teak.RunOptions`).

## Why

Every consumer was hand-copying ~200 lines of `ui_main.zig`: a
double-buffered `CmdBuffer` + rect store, the press-target mousedown/up
dance, keyboard + wheel + clipboard routing, the frame-diff that skips
redundant vertex rebuilds, layout, transient-state update, the
`buildVertices` → upload → `renderFrame` sequence. ~80% of it was
identical across apps, and the per-app variance (key routing, focus,
theme) was small and mechanical. `run` ships the shared loop once and
exposes the variance as **optional App declarations**.

A consumer's `ui_main.zig` collapses from ~200 lines to ~10:

```zig
pub fn main() !void {
    var host = try Host.init("My App", 900, 500);
    defer host.deinit();
    var gpu = try Gpu.init(host.nativeHandle(), 900, 500);
    defer gpu.deinit();
    try teak.run(App, gpa, &host, &gpu, .{});
}
```

## Shape

```zig
pub fn run(comptime App: type, gpa: Allocator, host: anytype, gpu: anytype, opts: RunOptions) !void
```

`App` must expose `Model`, `Msg`, `update(*Model, Msg)`,
`view(*const Model, *CmdBuffer(Msg))`. `Model.init()` is used for the
initial state if present, else `.{}`.

Optional App decls, each detected with `@hasDecl` — present only what you
need (full table in [consuming-teak.md §5](../consuming-teak.md)):
`keyCharMsg`, `keySpecialMsg`, `keyNeedsClipboard` + `handleClipboard`,
`wheelMsg`, `focusedMsg`, `submitMsg`, `themeFor`, `windowTitle`,
`secondaryWindow` + `secondaryView` (+ optional `secondaryClosedMsg`).

### Secondary window

An app that wants a second top-level window (e.g. a detached stats/inspector
panel) exposes:

| Decl | Signature | Role |
|------|-----------|------|
| `secondaryWindow` | `(*const Model) ?SecondaryWindowSpec` | data-shaped intent: `{ title, width, height }` when the window should be open, `null` when closed |
| `secondaryView` | `(*const Model, *CmdBuffer(Msg)) void` | the second window's view (same Cmd type as the primary) |
| `secondaryClosedMsg` | `(*const Model) ?Msg` | optional — dispatched through `update` when the user closes the window from the OS, so the Model's own flag flips |

`run` diffs the spec against the live window each frame and owns the whole
lifecycle: `host.openSecondaryWindow` + `gpu.openSecondarySurface` on open,
`host.pollSecondaryInputs` + resize + `secondaryView` layout/build +
`gpu.renderToWindow` while alive, and teardown (`closeSecondarySurface` +
`closeSecondaryWindow`) on close, user-close, or shutdown. The app never
touches a platform handle — `run` passes the Host's `NativeHandle` straight
into `gpu.openSecondarySurface(handle, w, h)`, which the Gpu backend's
injected `Surface` provider duck-types (HARDLINE §4(c)). While a secondary
window is open the primary is force-rebuilt each frame (the secondary render
re-uploads into the shared Gpu scratch buffers after the primary present).

The whole path is comptime-gated on `@hasDecl(App, "secondaryWindow")`, so
`gpu.openSecondarySurface` / `renderToWindow` (which are surface extensions
*outside* `validateGpu`) are never analyzed for apps that don't opt in — a
minimal stub Gpu still satisfies `run`.

`SecondaryWindowSpec` is re-exported as `teak.SecondaryWindowSpec`.

`RunOptions`:
- `clear_color: [4]f32` — scene clear color (default dark).
- `blink_period: u32` — frames between forced rebuilds while a widget is
  focused, so the text cursor blinks (default 30; matches the renderer's
  cursor phase). Apps with no text input pay nothing.

### What the loop does each frame

1. `host.pollInputs()`; on `resized`, `gpu.resize`.
2. Hit-test against the **previous** frame's layout (one-frame latency,
   imperceptible). Press-target arms on mousedown, fires on mouseup over
   the same widget, cancels on drag-off. A `null` hit msg (modal backdrop
   consumed, no Msg requested) is swallowed, not fallen through.
3. Keyboard: chars via `keyCharMsg`; then special keys — built-in
   Tab/Shift+Tab traversal and Enter→`submitMsg` first (if the app
   exposes the relevant hooks), then clipboard chords via
   `handleClipboard`, else `keySpecialMsg`.
4. Wheel via `wheelMsg`.
5. Build this frame's view into the alternate buffer (theme from
   `themeFor` if present), layout into a grown rect slice.
6. Update `TransientState` (hover/press/focus/frame counter); focus index
   resolved from `focusedMsg` via `indexOfFocusMsg`.
7. Push `windowTitle` to the host on change.
8. Frame diff (`cmdsEqual` + `rectsEqual` + transient compare, plus the
   blink tick): skip `buildVertices` + uploads when nothing observable
   changed. Always `renderFrame`.

`cmdsEqual` / `rectsEqual` are exposed from `run.zig` (they used to be
duplicated in every example's `ui_main.zig`) and correctly diff the
`disabled` field.

## HARDLINE

`run` is the host-loop **orchestrator**, and it stays on the right side
of the dependency arrow:

- It takes `host` and `gpu` as `anytype` and imports **neither**
  `platform/*` nor `gpu/*` — only the pure passes (`core`, `layout`,
  `input`, `render`). The consumer's entry point picks the backends and
  hands them in; `run` only duck-types the `validateHost` / `validateGpu`
  surfaces. Dependency arrow still points inward (§3). Because it is
  host-generic, `run` drives the **X11** host (Linux) and **wasm** host
  exactly as it does Win32 — no per-OS code in `run.zig`.
- It lives at `src/run.zig`, a sibling of the library root, **outside**
  the `src/{core,layout,input,render}/*` dirs the drift audit treats as
  framework core. It is not an escape hatch — it adds no new mutable
  state and routes every transition through the app's `update`.
- No wall-clock reads, no hidden state: animation (cursor blink) is
  driven by the `TransientState.frame_counter`, advanced once per frame,
  exactly as the renderer expects.

## Tests

`zig build test` drives the full loop headlessly with stub `Host`/`Gpu`
that satisfy `validateHost`/`validateGpu`: a scripted click routes through
`update` and presents per frame; a model side-channel confirms the
mutation; scripted keyboard runs exercise `keyCharMsg`/`keySpecialMsg`/
`themeFor`, Tab-advances-focus, and Enter-fires-`submitMsg`. `cmdsEqual`
is unit-tested for label/disabled/length changes.

## Status

All three in-repo examples (`counter_greeter`, `todo`, `tree`) now run on
`teak.run` — each `ui_main.zig` is a ~20-line `Host.init` / `Gpu.init` /
`teak.run` shell, with the per-app variance living in the app module as
optional `@hasDecl` hooks. This migration was `run`'s first real exercise;
it surfaced two gaps that are now closed:

- **Secondary window** (counter_greeter's "Stats" window) — added the
  `secondaryWindow` / `secondaryView` / `secondaryClosedMsg` hook set (see
  above). The old hand-rolled loop bridged the GPU surface with
  `gpu.openSecondarySurface(nh.hinstance, nh.hwnd, …)`, i.e. Win32-only
  field access that **failed to compile on Linux**; routing surface
  creation through the Gpu backend's `Surface` provider (`openSecondarySurface(handle, w, h)`)
  makes it platform-generic and unbreaks the Linux `ui` build.
- **IME composition** — `run` now folds `Host.imeState()` into
  `TransientState` every frame (previously only counter_greeter's loop did).

The examples' native UI builds on **Linux (X11)** and **Windows**;
`teak.linkNativeWgpu` picks the backend by target OS and the examples gate
their `ui` step on `teak.hasNativeBackend`. Pixels-on-screen verification on
a real display is still pending (the CI host is headless + cross-arch).
