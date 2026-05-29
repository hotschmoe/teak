# Host interface

**Status**: `pub` in `src/teak.zig` as `InputState`, `validateHost`, `SpecialKey`.
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
| `clipboard` | `fn(*Host) Clipboard` | Return a Clipboard vtable for OS-level cut / copy / paste. `read` returns a UTF-8 slice valid until the next `read`. No-op impls (empty read, discard write) are acceptable for headless / wasm. |
| `imeState` | `fn(*const Host) ImeState` | Current IME composition snapshot. Hosts without IME return `.{ .active = false }`. |
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

`validateHost` comptime-asserts every non-`init` decl above. The clipboard / IME / a11y / dialog / secondary-window / `nowMs` decls landed during the `functional_gaps_yolo` push as HARDLINE §4(d) surface extensions. Compile-error format:

```
Host 'MyHost' is missing declaration 'pollInputs'
```

### `InputState`

```zig
pub const InputState = struct {
    mouse_x: f32,           // state — current cursor position
    mouse_y: f32,
    mouse_down: bool,       // edge — true only the frame the button went down
    mouse_up: bool,         // edge — true only the frame the button went up
    wheel_dx: f32,          // accumulator — pixels of intended horizontal scroll
    wheel_dy: f32,          // accumulator — pixels of intended vertical scroll
    chars: []const u8,      // queue — typed Unicode codepoints this frame (ASCII for now)
    keys: []const SpecialKey, // queue — backspace, enter, arrows, etc. this frame
    resized: bool,
    width: u32,
    height: u32,
};
```

**Slice lifetime**: `chars` and `keys` reference Host-internal buffers. They are valid **only until the next `pollInputs` call**. Copy into `Model` if you need to retain.

**Edge vs state**: `mouse_down` / `mouse_up` are edges — the Host computes them by diffing against the previous poll. `mouse_x` / `mouse_y` are state. A widget that wants "is the button currently held?" must track it in `Model` based on edges.

**Wheel sign convention**: `wheel_dx` / `wheel_dy` carry pixels of *intended* scroll accumulated since the previous `pollInputs`. Positive `wheel_dy` means the user wants the content to scroll **down** (visible viewport advances toward higher y); positive `wheel_dx` means scroll **right**. This matches the DOM `WheelEvent.deltaX` / `deltaY` convention. Backends translate native wheel notches into pixels — Win32 maps each `WHEEL_DELTA` (120 raw units) to ~48 px (the standard "3 lines"); X11 maps each wheel notch (`Button4`/`5` vertical, `Button6`/`7` horizontal) to the same 48 px; the wasm host forwards zunk's already-pixel `mouse.wheel`. Zero when no wheel events arrived. Apps translate `wheel_dy` into a regular Msg (e.g. `.scroll_by`) and route it through `update`, same as any other input — there is no wheel-handler callback.

## Backends

Three Hosts implement the contract; all satisfy `validateHost`.

- **Win32** (`win32.zig`) — `WNDPROC`-driven; buffers async messages and drains on `pollInputs`. GDI text measurer. Implements clipboard and file dialogs for real.
- **X11** (`x11.zig`) — the Linux backend. libX11 is loaded at runtime via `std.DynLib("libX11.so.6")` (no `-lX11`, no X11 dev package needed to build; the module links libc for the dlopen path). Window create/map, synchronous `XNextEvent` pump (mouse, wheel via `Button4`/`5`+`6`/`7`, keys), `keysym`→`SpecialKey` mapping (arrows + shift variants, Tab/Shift-Tab, Enter, Home/End/PgUp/PgDn, Esc, Ctrl chords), ASCII text via `XLookupString`, `setTitle` via `XStoreName`, `nowMs`. The text measurer is the shared stb_truetype `teak-text` module — the *same* font the GPU rasterizer renders from, so layout and rendering agree. All state lives on the `Host` struct (no module-scope globals), since X11 delivers events synchronously. X11 runs under **XWayland** on Wayland desktops; there is no native Wayland backend.
- **wasm** (`wasm.zig`) — the web backend over zunk shared memory; `shouldClose` returns `false` (page lifecycle is zunk's problem).

**X11 v1 stubs** — present in the contract so apps call them unconditionally, but no-ops today: `clipboard` read returns `""` and write is a no-op (X11 selections need an async `XConvertSelection`/`SelectionNotify` round-trip); `openFileDialog` / `saveFileDialog` return `null` (need a portal/toolkit dependency); `publishA11yTree` is a no-op (no AT-SPI yet); `openSecondaryWindow` returns `null`; `imeState` is inactive (text entry is ASCII via `XLookupString`; wider Unicode needs `Xutf8LookupString` + an input method). Windows implements clipboard + file dialogs for real.

> **Verification status (Linux).** The X11 host has been verified to compile, link, and start headlessly (the dlopen + Xlib FFI path is sound); pixels-on-screen verification on a real display is pending.

## Invariants

- **Single owner.** The main loop owns one Host. No globals.
- **Polling model.** The Host does not push events. The app pulls once per frame. Backends that receive events asynchronously (Win32 `WNDPROC`, zunk shared memory) buffer them and drain on `pollInputs`.
- **No allocation on the hot path.** Backends hold fixed-size scratch buffers (see `Host.keys_buf` / `chars_buf` in `src/platform/wasm.zig`).
- **`init` signatures are NOT validated.** A wasm host that only takes a title vs. a Win32 host that takes dimensions both satisfy the contract. Callers construct the Host via the backend-specific signature and then use it generically.

## Non-goals / known limits

- **No keyboard auto-repeat handling.** Backends report raw key events. A widget that wants repeat (e.g. holding backspace to delete) must implement it in `update` based on frame timing.
- **IME surface fully wired on Win32.** `imeState()` is backed by `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` / `WM_IME_ENDCOMPOSITION`; the renderer draws the composition inline at the caret with an underline indicator. Wasm still returns `.{ .active = false }` (browser IME goes through the DOM's contenteditable shaping which we don't bridge yet).
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
