# Host interface

**Status**: `pub` in `src/teak.zig` as `InputState`, `InputQueue`, `NavKey`, `resolveKey`, `validateHost`, `SpecialKey`.
**Source**: `src/platform/host.zig`; three backends — `src/platform/win32.zig` (Win32), `src/platform/x11.zig` (X11/Linux), `src/platform/wasm.zig` (web).
**Tests**: `validateHost` has a colocated stub-acceptance test (and `x11.zig` runs its keysym→`SpecialKey` mapping unit test). Backend behavior is exercised through `examples/counter_greeter`.

Escape hatch 4 in [HARDLINE §2](../HARDLINE.md#escape-hatch-4-host-interface). Wires Teak to OS windowing and input — the only place outside `src/gpu/*` allowed to import platform-specific code.

## Contract

A Host type must expose these declarations:

| Decl | Signature | Purpose |
|---|---|---|
| `init` | backend-specific (e.g. `fn(title, w, h) !Host`) | Create the window / surface. **Not** validated by `validateHost` — signatures legitimately differ between backends. |
| `deinit` | `fn(*Host) void` | Tear down the window. |
| `pollInputs` | `fn(*Host) InputState` | Drain one frame's events. Called once per frame at the top of the main loop. |
| `shouldClose` | `fn(*const Host) bool` | True when the user closed the window. The wasm host returns `false` unconditionally; the page lifecycle is zunk's problem. |
| `nativeHandle` | `fn(*const Host) NativeHandleT` | Opaque handle the matching Gpu backend consumes. Shape is a private agreement between the Host and its Gpu. Win32: `{ hinstance, hwnd }`. X11: `{ display: *anyopaque, window: u64 }` (opaque `Display*` + `Window` XID). |
| `textMeasurer` | `fn(*Host) TextMeasurer` | Return a glyph-accurate measurer vtable. Native hosts wrap their font system; headless / wasm hosts may return `monoMeasurer()`. |
| `clipboard` | `fn(*Host) Clipboard` | Return a Clipboard vtable for OS-level cut / copy / paste. `read` returns a UTF-8 slice valid until the next `read`. No-op impls (empty read, discard write) are acceptable for headless / wasm. X11: `write` owns the `CLIPBOARD` selection; `read` returns our own content or does a bounded (250 ms) blocking `XConvertSelection` round trip ("" on timeout / empty / non-text clipboard) and claims the paste so it is not also reported as `pasted_text`. |
| `imeState` | `fn(*const Host) ImeState` | Current IME composition snapshot. Hosts without IME return `.{ .active = false }`. X11: backed by `XIMPreedit*` callbacks when an input method offers on-the-spot (`XIMPreeditCallbacks`); inactive when `XMODIFIERS` names no running IM. |
| `publishA11yTree` | `fn(*Host, []const A11yNode) void` | Hand the accessibility tree to whatever screen-reader API the platform exposes (UI Automation on Windows, AT-SPI on Linux, mirrored DOM on web). No-op on hosts without one. |
| `openFileDialog` | `fn(*Host, FileDialogFilter) FileDialogResult` | **Synchronous** picker; blocks until the user picks a path; `null` on cancel. Native only — browser file APIs are async and require the `request*` variants below. |
| `saveFileDialog` | `fn(*Host, FileDialogFilter) FileDialogResult` | Save-side counterpart of `openFileDialog`. |
| `requestFileDialog` | `fn(*Host, FileDialogFilter) u32` | **Async** open request. Returns a request id (0 = submission failed, slot table full). Win32 fills the result inline (the OS picker is sync), so the very next poll resolves; browser hosts dispatch the async picker and stay `.pending` until the JS bridge fires the callback. |
| `requestSaveFileDialog` | `fn(*Host, FileDialogFilter) u32` | Save-side counterpart of `requestFileDialog`. |
| `pollFileDialogResult` | `fn(*Host, u32) FileDialogPoll` | Read the result for a previously-submitted request id. Returns `.pending`, `.ok(path)`, or `.cancelled`. On `.ok` / `.cancelled` the slot is freed; a subsequent poll on the same id returns `.pending`. |
| `openSecondaryWindow` | `fn(*Host, []const u8, u32, u32) ?u32` | Open a second top-level window sharing this Host's event source; returns an opaque id the app holds and renders into via the GPU layer's `renderToWindow`. Single-window hosts (wasm) return `null`. |
| `pollSecondaryInputs` | `fn(*Host, u32) ?InputState` | Per-frame input snapshot for a secondary window; `null` on invalid id or single-window host. Primary keeps the legacy `pollInputs()` — secondaries are additive. |
| `closeSecondaryWindow` | `fn(*Host, u32) void` | Destroy a secondary window and free its slot. No-op on invalid ids. |
| `secondaryWindowHandle` | `fn(*const Host, u32) ?NativeHandle` | Return the native handle of a secondary window so the app can hand it to `gpu.openSecondarySurface`. |
| `nowMs` | `fn(*const Host) u64` | Monotonic millisecond timestamp on the host's clock. Used by `Sub.at(deadline_ms, msg)` and anything else needing a host-side wall clock without violating HARDLINE §3's "no wall-clock in `view`". |
| `submit` + `pollEffectResults` *(optional pair)* | `fn(*Host, Effect) EffectSubmit` / `fn(*Host, []EffectResult) usize` | Declarative effects ([effects.md](effects.md), HARDLINE hatch 7): `submit` starts one effect (slices valid only during the call), `pollEffectResults` fills `buf` with finished results and unsolicited drops / pastes (slices valid until the next `pollInputs`). Declare both or neither; a Host without them answers every effect as unsupported. |
| `renderScale` *(optional; Win32)* | `fn(*const Host) f32` | Physical pixels per logical pixel the Host reports in `InputState`. The run loop forwards it to `Gpu.setScale` when both declare the hook. |
| `registerFont` *(X11, Win32; not in `validateHost`)* | `fn(*Host, FontFamily, FontWeight, []const u8) !void` | Register a TTF (typically `@embedFile`) as the face for a family and weight, shared with the Gpu rasterizer. See [text.md](text.md#custom-fonts-ibm-plex-mono-and-friends). |
| `scaleFactor` *(optional)* | `fn(*const Host) f32` | Physical device pixels per logical UI unit at the window's current DPI (1.0 = no scaling). **Optional** — `validateHost` checks it for callability only when present, so Hosts (and `run.zig`'s test stubs) that predate it still validate. Nothing in the framework consumes it yet; see [DPI and scaling](#dpi-and-scaling). |

`validateHost` comptime-asserts every non-`init` **required** decl above, and checks the optional `scaleFactor` only when a Host declares it. The clipboard / IME / a11y / dialog / secondary-window / `nowMs` decls landed during the `functional_gaps_yolo` push as HARDLINE §4(d) surface extensions. Compile-error format:

```
Host 'MyHost' is missing declaration 'pollInputs'
```

### `InputState`

```zig
pub const InputState = struct {
    mouse_x: f32,             // state — current cursor position (logical px, client area)
    mouse_y: f32,
    buttons: Buttons,         // state — held now: left / middle / right
    button_down: Buttons,     // edges since the previous poll
    button_up: Buttons,
    mouse_down: bool,         // left-button edges (== button_down.left / button_up.left)
    mouse_up: bool,
    mods: Modifiers,          // shift / ctrl / alt / meta at the most recent input event
    wheel_dx: f32,            // accumulator — pixels of intended horizontal scroll
    wheel_dy: f32,            // accumulator — pixels of intended vertical scroll
    chars: []const u8,        // queue — UTF-8 text typed this frame (whole code points)
    keys: []const SpecialKey, // queue — backspace, delete, enter, arrows, Home/End, chords...
    resized: bool,
    width: u32,
    height: u32,
};
```

**Slice lifetime**: `chars` and `keys` reference Host-internal buffers. They are valid **only until the next `pollInputs` call**. Copy into `Model` if you need to retain.

**Buttons**: `button_down` / `button_up` are edges since the previous poll; a press *and* release inside one frame sets both (and `buttons` reads released), so a fast click is never lost — on the web this matters, since a frame can span several mouse events. `buttons` is the held state, which `teak.run` uses to keep a drag going. The left-button edges stay available as `mouse_down` / `mouse_up`. `mouse_x` / `mouse_y` are state.

**Text and keys**: `chars` is real UTF-8 — a typed `e-acute` arrives as two bytes, an emoji as four, never a truncated code unit; a code point that does not fit the queue is dropped whole. Control codes and Ctrl/Cmd chords are never text. `keys` carries the `SpecialKey` set: Backspace, Delete, arrows, Home/End, PageUp/Down, Enter, Tab / Shift+Tab, Escape, Shift+arrows/Home/End (selection extension), Ctrl+A/C/X/V/Y/Z. Hosts map native key codes to a host-neutral `NavKey` and `teak.resolveKey(NavKey, Modifiers)` applies the Shift/Ctrl policy — one table of "what does Shift+Left mean", not three.

**Wheel sign convention**: `wheel_dx` / `wheel_dy` carry pixels of *intended* scroll accumulated since the previous `pollInputs`. Positive `wheel_dy` means the user wants the content to scroll **down** (visible viewport advances toward higher y); positive `wheel_dx` means scroll **right**. This matches the DOM `WheelEvent.deltaX` / `deltaY` convention. Backends translate native wheel notches into pixels — Win32 maps each `WHEEL_DELTA` (120 raw units) to ~48 px (the standard "3 lines"); X11 maps each wheel notch (`Button4`/`5` vertical, `Button6`/`7` horizontal) to the same 48 px; the wasm host forwards zunk's pixel deltas (line/page-mode wheels are scaled to pixels in the JS). Zero when no wheel events arrived. A trackpad **pinch** on the web arrives as a wheel event with `mods.ctrl` set (the browser's `ctrlKey + wheel` convention). Apps translate wheel input into a regular Msg and route it through `update` (`wheelMsg`, or `canvasMsg` / `scrollMsg` over an interactive canvas / scroll region) — there is no wheel-handler callback.

### `InputQueue` (shared by event-driven hosts)

`src/platform/input_queue.zig`, re-exported as `teak.InputQueue`. Win32 (primary + secondary windows) and X11 fold OS events into one: `beginFrame()` at the top of a poll, `pointerMoved` / `buttonDown` / `buttonUp` / `wheel` / `pushNav` / `pushCodepoint` / `pushUtf16Unit` (surrogate pairing for `WM_CHAR`) while pumping, `finish(resized, w, h)` to produce the `InputState` and clear the edges. The wasm host is poll-based but reuses the key policy and the text queue.

## Backends

Three Hosts implement the contract; all satisfy `validateHost`.

- **Win32** (`win32.zig`) — `WNDPROC`-driven; buffers async messages and drains on `pollInputs`. stb_truetype measurer shared with the Gpu (`registerFont`, letter spacing). Implements clipboard (`CF_UNICODETEXT`) and file dialogs for real, services declarative effects (shared `native_effects.zig` plus native pickers, clipboard and `WM_DROPFILES` drops), and runs per-monitor DPI v2: it reports **logical** pixels and `renderScale()`, and the run loop passes the factor to `Gpu.setScale` so the swap-chain is physical-sized.
- **X11** (`x11.zig`) — the Linux backend. libX11 is loaded at runtime via `std.DynLib("libX11.so.6")` (no `-lX11`, no X11 dev package needed to build; the module links libc for the dlopen path). Window create/map, synchronous `XNextEvent` pump (mouse, wheel via `Button4`/`5`+`6`/`7`, keys), buttons 1-3 + modifiers from every event's `state`, `keysym`→`NavKey` mapping (Delete, arrows, Tab/Shift-Tab, Enter, Home/End/PgUp/PgDn, Esc, Ctrl chords), text through `Xutf8LookupString` on an XIM input context (committed compositions, Compose / dead keys on the built-in IM) with a plain-keysym fallback when no input method opens, preedit composition via `imeState()` (on-the-spot callbacks; over-the-spot style supported with `Host.setImeSpot(x, y)`, which the runtime does not call yet (deferred to the TextArea pointer/metrics work, which knows the focused caret rect); the built-in `local` IM only offers the root-window style, so no preedit appears without ibus/fcitx/uim), clipboard read/write (`CLIPBOARD` selection, INCR on receive) and XDND v5 file / text drops (see [effects.md](effects.md)), `setTitle` via `XStoreName`, `nowMs`. The text measurer is the shared stb_truetype `teak-text` module — the *same* font the GPU rasterizer renders from, so layout and rendering agree. All state lives on the `Host` struct (no module-scope globals), since X11 delivers events synchronously. X11 runs under **XWayland** on Wayland desktops; there is no native Wayland backend.
- **wasm** (`wasm.zig`) — the web backend over zunk shared memory; `shouldClose` returns `false` (page lifecycle is zunk's problem). Services effects through `zunk.web.fx` (fetch, downloads, file picker, localStorage, clock, query params, clipboard, paste / drop; see [effects.md](effects.md)). `clipboard().write` goes through the effects bridge; `clipboard().read` returns the text of the paste event that came with the Ctrl/Cmd+V key press (the browser only exposes it there) and claims it so it is not also reported as `pasted_text`. Cmd acts as Ctrl for chord keys. `nowMs` is `performance.now()`.

X11 also services declarative effects (HTTP on worker threads, storage files, downloads, `TEAK_OPEN`, query params) through `native_effects.zig`; `Host.setAppName` (called from `RunOptions.app_name`) names the storage directory. See [effects.md](effects.md).

**X11 v1 stubs** — present in the contract so apps call them unconditionally, but no-ops today: `openFileDialog` / `saveFileDialog` return `null` (need a portal/toolkit dependency); `publishA11yTree` is a no-op (no AT-SPI yet); `openSecondaryWindow` returns `null`. Windows implements file dialogs for real.

> **Verification status (Linux).** The X11 host has been verified to compile, link, and start headlessly (the dlopen + Xlib FFI path is sound); pixels-on-screen verification on a real display is pending.

## DPI and scaling

Teak's layout, hit-test, and render passes are **unit-agnostic** — they
operate on whatever coordinate space the Host reports in `InputState`
(mouse + `width`/`height`) and whatever `size_px` a `FontSpec` carries.
Correct HiDPI rendering therefore hinges entirely on the Host/GPU
boundary: input coords, the value fed to `doLayout`, and the GPU surface
size at `configure`/`resize` must all agree, and glyph rasterization must
happen at the *physical* framebuffer resolution to stay crisp.

Today the three backends sit in three different places on that spectrum.
`scaleFactor()` reports each backend's true factor so a future
orchestrator can close the loop; **no framework code consumes it yet, so
current rendering behavior is unchanged.**

### Per-host truth table

| Host | Input + `width`/`height` units | GPU surface configured at | `scaleFactor()` today | Result at scale ≠ 1 |
|---|---|---|---|---|
| **Win32** | Logical px (per-monitor v2 aware; Host divides physical by the DPI scale) | Physical px = logical × `renderScale()` (`Gpu.setScale`) | `GetDpiForWindow/96` | **Crisp and correctly sized.** Solids are vectors at physical resolution and glyphs are baked at `size_px × scale`; images and 3D scene composites are rasterized at logical resolution and magnified. |
| **X11** | Device (physical) px — no automatic scaling | Same physical px (Vulkan swap-chain) | `Xft.dpi/96` (e.g. 2.0 on a 192-DPI desktop) | **Crisp but undersized** — fonts rasterize at logical `size_px`, so on a 200 % desktop the UI is ~half the intended physical size. No blur. |
| **wasm/zunk** | CSS px (zunk v0.5.2+) | zunk owns the canvas; backing store sized at CSS×`devicePixelRatio` internally | **1.0** (teak never sees physical px) | **Crisp and correctly sized** — zunk rasterizes glyphs at DPR into its backing store; teak works purely in CSS px. |

The web path is the only one crisp *and* correctly sized today, and it is
so because the DPR handling lives inside zunk, invisible to teak (this is
the mechanism behind the "browser-verified at HiDPI" note in `tasks.md` —
verified, but owned by zunk's swap-chain, not by `src/gpu/web.zig`, which
configures no surface). The pixel-snapping in `render/build.zig` +
`wgpu_core.uploadText` (`@floor`/`@ceil` on rect coords to derive texture
extent and UVs) assumes 1 layout unit = 1 texture texel = 1 framebuffer
pixel — i.e. **scale == 1** — which is why the native paths cannot yet
render at scale without the follow-up below.

### Render-at-scale

`Gpu.InitOptions.scale` (device pixels per logical pixel) already lays the UI
out in logical px and rasterizes glyphs at the physical size; `Gpu.setScale`
changes it at runtime. Win32 wires the Host side: it declares
`PER_MONITOR_AWARE_V2` in `Host.init`, handles `WM_DPICHANGED` (accepting the
suggested rect, which re-lays out via `WM_SIZE`), and reports **logical**
pixels (mouse coordinates and `width`/`height` are the physical client values
divided by the DPI scale). It exposes the factor as the optional
`renderScale()`; `run.zig` forwards it to `Gpu.setScale` before each resize, so
solids are crisp, glyphs are baked at `size_px * scale`, and the UI is the
right size on a 150 % / 200 % monitor. Images and 3D scene composites are still
rasterized at logical resolution and magnified.
X11 and wasm do not declare `renderScale` (they report physical / CSS pixels).

## Invariants

- **Single owner.** The main loop owns one Host. No globals.
- **Polling model.** The Host does not push events. The app pulls once per frame. Backends that receive events asynchronously (Win32 `WNDPROC`, zunk shared memory) buffer them and drain on `pollInputs`.
- **No allocation on the hot path.** Backends hold fixed-size scratch buffers (see `InputQueue`'s fixed `chars` / `keys` arrays).
- **`init` signatures are NOT validated.** A wasm host that only takes a title vs. a Win32 host that takes dimensions both satisfy the contract. Callers construct the Host via the backend-specific signature and then use it generically.

## Non-goals / known limits

- **No keyboard auto-repeat handling.** Backends report raw key events. A widget that wants repeat (e.g. holding backspace to delete) must implement it in `update` based on frame timing.
- **IME surface wired on Win32 and X11.** (X11: XIM preedit callbacks; verified against the built-in IM and the no-IM fallback only. Live CJK composition needs ibus / fcitx running with `XMODIFIERS=@im=...` and has not been exercised here.)
- **IME on Win32.** `imeState()` is backed by `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` / `WM_IME_ENDCOMPOSITION`; the renderer draws the composition inline at the caret with an underline indicator. Wasm still returns `.{ .active = false }` (browser IME goes through the DOM's contenteditable shaping which we don't bridge yet).
- **No focus-in / focus-out.** Apps track focus in `Model`; backends don't report window-focus edges today.
- **No gamepad / touch / pen.** Single mouse + keyboard only.
- **Secondary windows: Win32 + native GPU.** `openSecondaryWindow` returns a real id on Win32 backed by a 4-slot table, and `gpu.renderToWindow(id)` draws into the corresponding wgpu surface. `secondaryWndProc` handles `WM_SIZE` end-to-end: width/height + a `resized` edge-flag are bubbled out of `pollSecondaryInputs` in the same `InputState` shape the primary loop uses, and the app responds with `gpu.resizeWindow(id, w, h)`. Wasm returns `null` from `openSecondaryWindow` (popup blockers killed `window.open` — web apps use overlays).
- **File dialogs: sync on Win32, async-ready on wasm.** The `openFileDialog` sync API works on Win32 only. The async `requestFileDialog` / `pollFileDialogResult` pair works on both Win32 (resolves immediately) and wasm (resolves when the JS bridge in zunk fires the result callback; see zunk issue #14). Until the bridge ships, wasm requests stay `.pending` forever and apps treat that as "file picker unavailable".
- **Win32 UIA: per-node fragment providers.** The `publishA11yTree` Host surface snapshots the per-frame tree (labels copied into an 8 KB string heap) under a `CRITICAL_SECTION` so UIA worker threads can read safely, then fires `UiaRaiseStructureChangedEvent` on shape changes. The root provider implements `IRawElementProviderSimple` + `IRawElementProviderFragment` + `IRawElementProviderFragmentRoot`; per-`A11yNode` instances come from a pre-allocated `[MAX_A11Y_NODES]NodeProvider` pool exposing `ControlType`, `Name`, `IsKeyboardFocusable`, `HasKeyboardFocus`, and `BoundingRectangle` (in screen coords). Narrator iterates buttons / inputs / sliders directly. Patterns (Invoke / Value / Toggle) are deferred — adding them needs a Msg-back path from `SetFocus` / `Invoke` into the TEA loop.
- **Web a11y: serialize-and-dispatch.** Wasm `publishA11yTree` packs the tree into a fixed-stride 40-byte `A11yRecord` array (cap 256 nodes) + 8 KB UTF-8 string heap and hands the byte ranges to `__zunk_publish_a11y_tree`. The JS shim — tracked in [zunk issue #15](https://github.com/hotschmoe/zunk/issues/15) — diffs against the previous frame and updates a hidden ARIA-mirrored DOM subtree so NVDA / JAWS / VoiceOver can announce canvas-rendered widgets. The extern is `@hasDecl`-gated so pre-bridge builds link cleanly as a serialize-then-no-op.

## Test coverage target

- **Stub acceptance** (covered): `validateHost` accepts a minimal conformant struct.
- **Gap tests** (missing): one compile-fail test per missing decl — HARDLINE §5 asks for 100 % validator coverage.
- **Backend parity** (missing): an integration test that drives both `win32.zig` and `wasm.zig` Host stubs through a scripted input sequence and asserts the resulting `InputState` slices are equivalent. Would catch backend drift — e.g. the control-char filter regression described in [pitfalls.md](../pitfalls.md#3-zunk-pushes-control-chars-into-typed_chars-wasm-only).
