# Application loop (`teak.run` / `teak.Runtime`)

`src/run.zig` — the canonical host-loop wrapper. Re-exported as
`teak.run`, `teak.Runtime` (+ `teak.RunOptions`).

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

## `Runtime` — the loop body, one frame at a time

`run` is `Runtime` driven in a `while (!host.shouldClose())` loop. Hosts that
do not own the loop — the web, where the browser calls an exported `frame`
once per rAF tick — build a `Runtime` and call `frame` themselves:

```zig
const Runtime = teak.Runtime(App, Host, Gpu);   // comptime App + concrete backend types
var runtime: Runtime = undefined;               // module-level: exports can't close over a struct

export fn init() void {
    host = Host.init("My App", 900, 500) catch @panic("host init failed");
    gpu = Gpu.init(host.nativeHandle(), 900, 500) catch @panic("gpu init failed");
    runtime = Runtime.init(std.heap.wasm_allocator, &host, &gpu, .{}) catch @panic("runtime init failed");
}
export fn frame(_: f32) void { runtime.frame() catch @panic("frame failed"); }
export fn resize(w: u32, h: u32) void { gpu.resize(w, h); }
```

`init(gpa, *Host, *Gpu, RunOptions) !Runtime`, `frame(*Runtime) !void` (one
iteration; returns early without presenting if the host reports close during the
input poll), `deinit()`. The value holds the Model, the double-buffered cmd/rect
storage and all loop bookkeeping — create it once and don't move it. `frame`
errors are allocation failures only. All three examples' `web_main.zig` are this
shape; there are no hand-copied pipelines, fixed allocators or rect caps.

The secondary-window path compiles away when the Gpu has no
`openSecondarySurface` (the web Gpu), so apps with a "Stats" window still build
for the web; the window simply never opens there.

## Shape

```zig
pub fn run(comptime App: type, gpa: Allocator, host: anytype, gpu: anytype, opts: RunOptions) !void
```

`App` must expose `Model`, `Msg`, `update(*Model, Msg)`,
`view(*const Model, *CmdBuffer(Msg))`. `Model.init()` is used for the
initial state if present, else `.{}`.

Optional App decls are detected with `@hasDecl` — present only what you need.
See [App hooks](#app-hooks-the-one-table) for every one.

## App hooks (the one table)

Every optional decl `teak.run` / `Runtime` probes on the App. **Rules for all of
them** (HARDLINE §1-§3): a hook is a plain function of `*const Model` (never
`*Model`) plus data the loop supplies; it returns data (a `Msg`, a spec, a
theme) and never calls back; the only state change is the returned `Msg`
going through `update`. `zig build audit` fails if the loop probes a hook this
table does not name.

| Hook | Signature | Called | May return / do |
|---|---|---|---|
| `keyCharMsg` | `(*const Model, u8) ?Msg` | each typed character, in order | a Msg (null = ignore) |
| `keySpecialMsg` | `(*const Model, SpecialKey) ?Msg` | each non-text key / chord | a Msg |
| `keyNeedsClipboard` | `(SpecialKey) bool` | on a special key | whether `handleClipboard` should take it |
| `handleClipboard` | `(*Model, SpecialKey, Clipboard) void` | cut/copy/paste chords that `keyNeedsClipboard` claims | **mutates the Model directly** (a known HARDLINE §1 exception, see the audit note below) |
| `submitMsg` | `(*const Model) ?Msg` | Enter key (before `keySpecialMsg`) | a Msg |
| `focusedMsg` | `(*const Model) ?Msg` | every frame | the focus Msg of the focused widget; enables Tab traversal + the focus ring + caret |
| `wheelMsg` | `(*const Model, f32) ?Msg` | vertical wheel not claimed by a scroll region / pointer canvas | a Msg |
| `scrollMsg` | `(*const Model, id, dx, dy) ?Msg` | wheel over the innermost `ScrollStyle.id != 0` region | a Msg |
| `scrollLayoutMsg` | `(*const Model, id, vw, vh, cw, ch) ?Msg` | a scroll region's first layout and each size change | a Msg (the view cannot read layout) |
| `canvasMsg` | `(*const Model, CanvasEvent) ?Msg` | pointer input over interactive canvases / scenes; `layout` events | a Msg |
| `windowMsg` | `(*const Model, w: f32, h: f32) ?Msg` | first frame and every resize | a Msg |
| `windowTitle` | `(*const Model) ?[]const u8` | every frame; `Host.setTitle` only on change | the title |
| `themeFor` | `(*const Model) Theme` | every frame, before `view` | the theme the emitters use |
| `subscribe` | `(*const Model) []const Sub(Msg)` | every frame | timers (`every`, `at`) and `animation_frame` |
| `animationMsg` | `(*const Model, dt_ms: u32) ?Msg` | every frame while a `Sub.animation_frame` is listed | a Msg (see [animation.md](animation.md)) |
| `effects` | `(*const Model) []const Effect` | every frame | effects to hand the Host once each (HARDLINE hatch 7) |
| `effectMsg` | `(*const Model, EffectResult) ?Msg` | each effect result and each unsolicited drop / paste | a Msg |
| `resources` | `(*const Model) []const Resource` | every frame | GPU meshes / images by (key, rev) (hatch 8) |
| `secondaryWindow` | `(*const Model) ?SecondaryWindowSpec` | every frame | open / close the second window |
| `secondaryView` | `(*const Model, *CmdBuffer(Msg)) void` | each frame the second window is open | its view (pure, same rules as `view`) |
| `secondaryClosedMsg` | `(*const Model) ?Msg` | the user closed the second window from the OS | a Msg |

Hooks in open PRs (`textMsg`, `hoverMsg`, `contextMsg`, `modsMsg`,
`sliderMsg`, `virtualRowsMsg`, `cursorFor`, `commands`, `debugState`) follow the
same rules and join this table when they land.

### Interactive canvases and scroll regions

Three optional hooks turn pointer input over specific regions into `Msg`s. All
route against the **previous** frame's layout, exactly like hit-testing.

| Decl | Signature | Role |
|------|-----------|------|
| `canvasMsg` | `(*const Model, CanvasEvent) ?Msg` | pointer events over `CanvasCmd.pointer` canvases: `down` / `move` / `up` / `wheel` / `leave`, and `layout` on first layout and whenever the rect size changes. Semantics in [canvas.md](canvas.md). |
| `scrollMsg` | `(*const Model, id: u32, dx: f32, dy: f32) ?Msg` | wheel over the innermost hovered scroll region whose `ScrollStyle.id != 0`. `dx`/`dy` are DOM-signed px. Return `null` to ignore; the wheel is still consumed. |
| `scrollLayoutMsg` | `(*const Model, id: u32, viewport_w, viewport_h, content_w, content_h: f32) ?Msg` | for every `ScrollStyle.id != 0` region, on its first layout and whenever its viewport or content size changes. Content is the extent of its children (`teak.scrollExtent`: nested scroll interiors and overlays excluded), independent of the scroll offset — enough to clamp `scroll_y` and size a scrollbar thumb. |

**Wheel routing**, innermost first: a captured pointer canvas (during a drag,
wherever the cursor is) → the pointer canvas or `id != 0` scroll region
innermost under the cursor (`hit_test.wheelTarget`; overlays win, modals block)
→ plain `wheelMsg`. A wheel handled by `canvasMsg` / `scrollMsg` never also
reaches `wheelMsg`.

```zig
// A pan/zoom viewport + a scrollable chat list, in one App:
pub fn canvasMsg(_: *const Model, ev: teak.CanvasEvent) ?Msg {
    return switch (ev.kind) {
        .layout => Msg{ .viewport_size = .{ ev.w, ev.h } },
        .move => if (ev.buttons.middle) Msg{ .pan = .{ ev.dx, ev.dy } } else Msg{ .hover = .{ ev.x, ev.y } },
        .wheel => Msg{ .zoom = .{ ev.dy, ev.x, ev.y } },   // ev.mods.ctrl = pinch
        else => null,
    };
}
pub fn scrollMsg(_: *const Model, id: u32, _: f32, dy: f32) ?Msg {
    return if (id == chat_scroll) Msg{ .chat_scroll_by = dy } else null;
}
pub fn scrollLayoutMsg(_: *const Model, id: u32, vw: f32, vh: f32, cw: f32, ch: f32) ?Msg {
    return if (id == chat_scroll) Msg{ .chat_extent = .{ vh, ch } } else null;
}
```

`layout` / scroll-layout reports are computed after the frame's layout from the
two frame buffers (current vs previous), so they need no retained table; the
Msg they produce shows up in the next frame's `view`. An id that disappears
and later returns reports again, like a fresh layout.

### Subscriptions

An app that wants a timer / periodic Msg exposes one pure decl:

| Decl | Signature | Role |
|------|-----------|------|
| `subscribe` | `(*const Model) []const Sub(Msg)` | declares the timers to watch this frame — `.every(interval_ms, msg)` (periodic) or `.at(deadline_ms, msg)` (one-shot). Pure, like `view`. |

Each frame, immediately before it builds the view, `run` calls
`subscribe(model)` and feeds the returned subs through `teak.runSubs` on
the host's monotonic clock (`Host.nowMs()`). A fired sub is dispatched
through the same router as an input Msg, so it mutates `Model` through
`update` (no second mutation path), reflects in the frame emitted this
tick, and updates `last_msg` for the live snapshot. The only loop state is
`last_sub_ms` (the previous frame's timestamp — `runSubs` itself is
stateless); no sub fires on the opening frame. `.at` fires exactly once on
its deadline crossing and then auto-stops. Full contract and bounds:
[subscriptions.md](subscriptions.md).

### Effects

An app that talks to the outside world (HTTP, files, storage, clipboard,
clock) exposes two decls; an app that only wants dropped / pasted input
needs only the second:

| Decl | Signature | Role |
|------|-----------|------|
| `effects` | `(*const Model) []const Effect` | declares the requests to service this frame; each `id` is issued once while listed. Pure. |
| `effectMsg` | `(*const Model, EffectResult) ?Msg` | turns an answer (or an unsolicited drop / paste) into a Msg. Required when `effects` is declared. |

Each frame, after key routing, `run` fetches the Host's finished results
(`Host.pollEffectResults`) and dispatches each through `effectMsg` ->
`update`; then, after subscriptions, it hands newly listed effects to
`Host.submit` and forgets the ids that stopped being listed. A Host without
the effect pair answers every effect with its "unsupported" result. Full
contract: [effects.md](effects.md).

### Secondary window

An app that wants a second top-level window (e.g. a detached stats/inspector
panel) exposes:

| Decl | Signature | Role |
|------|-----------|------|
| `secondaryWindow` | `(*const Model) ?SecondaryWindowSpec` | data-shaped intent: `{ title, width, height }` when the window should be open, `null` when closed |
| `secondaryView` | `(*const Model, *CmdBuffer(Msg)) void` | the second window's view (same Cmd type as the primary) |
| `secondaryClosedMsg` | `(*const Model) ?Msg` | optional — dispatched through `update` when the user closes the window from the OS, so the Model's own flag flips |

If the app omits `secondaryClosedMsg`, a user-closed window stays closed:
`run` remembers the spec that was open at close time and suppresses reopen
until `secondaryWindow` returns a *different* spec (or `null`). Secondary
content is double-buffered and frame-diffed like the primary, so a change
that only affects the secondary view still triggers a `TEAK_SNAPSHOT`
rewrite.

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

**Platform support:** secondary windows are **Win32-only** today. The X11
and wasm hosts' `openSecondaryWindow` return `null`, so the hooks compile
and run everywhere but the second window only actually opens on Windows;
the primary window is unaffected on the other backends.

`RunOptions`:
- `clear_color: [4]f32` — scene clear color (default dark).
- `blink_period: u32` — frames between forced rebuilds while a widget is
  focused, so the text cursor blinks (default 30; matches the renderer's
  cursor phase). Apps with no text input pay nothing.
- `snapshot_path: ?[]const u8` — live-snapshot sink (default `null`).
- `app_name: []const u8` — names the app for hosts that keep per-app files (native storage under `<config>/teak/<app_name>/`); empty = the window title.

### Live snapshot sink (`TEAK_SNAPSHOT`)

When `snapshot_path` is non-null — or the `TEAK_SNAPSHOT` env var is set
(env wins, read once at `run` start) — `run` mirrors each *changed* frame's
snapshot text to that file, so an agent driving the running app can read
the GUI as data instead of pixels. The write is atomic (`<path>.tmp` then
rename, so a reader never sees a torn file) and change-gated (idle frames
never touch disk); an unwritable path disables the sink after one
`std.log.warn` and never crashes or slows the app. On a target with no host
filesystem (wasm/freestanding) the sink compiles out. Depth:
[snapshot.md](snapshot.md).

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
4. Pointer canvases (`canvasMsg`): hover / move / down / up / leave +
   capture. Wheel: pointer canvas -> `scrollMsg` region -> `wheelMsg`.
5. Effect results (`effectMsg`), then subscriptions: `runSubs(subscribe(model))`
   on `Host.nowMs()`; fired subs dispatch as ordinary Msgs before the view
   builds (if `subscribe` present). Then newly listed `effects()` go to the
   Host.
6. Build this frame's view into the alternate buffer (theme from
   `themeFor` if present), layout into a grown rect slice; then report
   canvas size / scroll extent changes (`canvasMsg` `layout`,
   `scrollLayoutMsg`).
7. Update `TransientState` (hover/press/focus/frame counter); focus index
   resolved from `focusedMsg` via `indexOfFocusMsg`.
8. Push `windowTitle` to the host on change.
9. Declarative resources (if the App declares `resources`): reconcile the
   GPU with the listed meshes/images (upload on new key / changed `rev`,
   release vanished keys); a change forces step 10 to re-stage.
10. Frame diff (`cmdsEqual` + `rectsEqual` + transient compare, plus the
   blink tick and resource changes): skip `buildFrame` + uploads when
   nothing observable changed. Otherwise build the frame (solid quads,
   text, image and `SceneDraw` records), remap resource keys to handles,
   `uploadVertices` / `uploadText` / `uploadImages` and — when the Gpu has
   the scene extension — `renderScenes`. Always `renderFrame`.

### Resources (optional hook)

`pub fn resources(*const Model) []const Resource` — HARDLINE §2 hatch 8.
`Resource = union(enum) { mesh: { key, rev, data: MeshData }, image:
{ key, rev, width, height, rgba } }`. The loop keeps a fixed-capacity
(1024; overflow logs a warning) table of what is resident (`src/resources.zig`): a new (kind, key)
uploads, a changed `rev` re-uploads (old handle released first), a key that
disappears is released, and everything is released at shutdown. `Cmd`s use
the app key: `cb.image(key, ...)`, `cb.scene3d(.{ .mesh = key })`; the loop
rewrites those to backend handles in the draw records it hands the Gpu (an
unknown / failed key draws nothing for an image and just the clear colour
for a scene). Without the hook, `ImageCmd.handle` / `SceneCmd.mesh` are
raw `Gpu` handles from `uploadImage` / `uploadMesh`, as before. The hook
needs the Gpu scene extension (`uploadMesh`, `releaseMesh`,
`renderScenes`, `releaseImage`); apps that do not declare it run on any
conforming Gpu. See [scene3d.md](scene3d.md).

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
  framework core. It is not an escape hatch — it holds no *application*
  state (only loop bookkeeping: the double-buffered cmds/rects, the press
  target, the canvas hover/capture ids, the previous subscription
  timestamp) and routes every transition through the app's `update`.
- No wall-clock reads, no hidden state: animation (cursor blink) is
  driven by the `TransientState.frame_counter`, advanced once per frame,
  exactly as the renderer expects.

## Tests

`zig build test` drives the full loop headlessly with stub `Host`/`Gpu`
that satisfy `validateHost`/`validateGpu`: a scripted click routes through
`update` and presents per frame; a model side-channel confirms the
mutation; scripted keyboard runs exercise `keyCharMsg`/`keySpecialMsg`/
`themeFor`, Tab-advances-focus, and Enter-fires-`submitMsg`. `cmdsEqual`
is unit-tested for label/disabled/length changes, `scene3d` revisions and
keyed canvas batches; a resource-recording stub Gpu checks upload-once,
rev-bump re-upload, key remapping into draw records, and shutdown release.

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

## Benchmarking the CPU pipeline (`zig build bench`)

`zig build bench` (always ReleaseFast, symbols kept so `perf record` works on
`.zig-cache/o/*/teak-bench`) times, per frame and averaged over 20 iterations,
the stages of the loop that run on the CPU: `view` (emit cmds), `layout`,
`hit` (hit-test), `render` (`buildFrame` -> vertices/draw records) and the
frame diff `cmdsEq`, for 100 / 1k / 10k / 50k rows (about 5 cmds per row), plus
a text-heavy "prose" case measured through the real `teak-text` shaper (needs a
system font; `TEAK_FONT` overrides, else the row prints `n/a`). Output goes to
stderr as one fixed-width table in milliseconds so two runs diff cleanly.
Source: `tools/bench/main.zig`. `cmdsEq` compares two equal buffers, which is
its worst case (a changed frame exits at the first difference).

## Event-driven idle

With `RunOptions.idle_skip` (default true) a frame in which nothing happened
does no pipeline work at all: no view, layout, diff, upload or present. A
frame is *quiet* when, after routing, there was no input event (pointer
moved / button / wheel / key / char / resize), no Msg was dispatched (so no
sub fired, no effect result or window hook arrived), no text input is
focused (the cursor blink needs frames; `blink_period = 0` lifts this), no
IME composition, no secondary window, and it is not the first frame.
`Runtime.quiet` reports it, and `run` then calls the Host's optional
`waitEvents(timeout_ms)` (documented in `platform/host.zig`) with the time to
the next due `Sub` (`sub.nextDueMs`; 16 ms while an effect is outstanding,
else at most 1 s). The web loop stays rAF-driven but skips the same work.

Consequences: `ts.frame_counter` and the snapshot `frame=` header count
frames that actually built; an app that animates must do it through a `Sub`
(a model field advanced by `.every`), which is the HARDLINE way anyway.
Measured (headless, 600 identical frames, an 8k-cmd view, ReleaseFast): 337 ms
without idle skip, 30 ms with it (all of it the one real first frame).
