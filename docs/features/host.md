# Host interface

**Status**: `pub` in `src/teak.zig` as `InputState`, `validateHost`, `SpecialKey`.
**Source**: `src/platform/host.zig`; concrete backends at `src/platform/win32.zig`, `src/platform/wasm.zig`.
**Tests**: `validateHost` has a colocated stub-acceptance test. Backend behavior is exercised through `examples/counter_greeter`.

Escape hatch 4 in [HARDLINE §2](../HARDLINE.md#escape-hatch-4-host-interface). Wires Teak to OS windowing and input — the only place outside `src/gpu/*` allowed to import platform-specific code.

## Contract

A Host type must expose these declarations:

| Decl | Signature | Purpose |
|---|---|---|
| `init` | backend-specific (e.g. `fn(title, w, h) !Host`) | Create the window / surface. **Not** validated by `validateHost` — signatures legitimately differ between backends. |
| `deinit` | `fn(*Host) void` | Tear down the window. |
| `pollInputs` | `fn(*Host) InputState` | Drain one frame's events. Called once per frame at the top of the main loop. |
| `shouldClose` | `fn(*const Host) bool` | True when the user closed the window. The wasm host returns `false` unconditionally; the page lifecycle is zunk's problem. |
| `nativeHandle` | `fn(*const Host) NativeHandleT` | Opaque handle the matching Gpu backend consumes. Shape is a private agreement between the Host and its Gpu. |
| `textMeasurer` | `fn(*Host) TextMeasurer` | Return a glyph-accurate measurer vtable. Native hosts wrap their font system; headless / wasm hosts may return `monoMeasurer()`. |
| `clipboard` | `fn(*Host) Clipboard` | Return a Clipboard vtable for OS-level cut / copy / paste. `read` returns a UTF-8 slice valid until the next `read`. No-op impls (empty read, discard write) are acceptable for headless / wasm. |
| `imeState` | `fn(*const Host) ImeState` | Current IME composition snapshot. Hosts without IME return `.{ .active = false }`. |
| `publishA11yTree` | `fn(*Host, []const A11yNode) void` | Hand the accessibility tree to whatever screen-reader API the platform exposes (UI Automation on Windows, AT-SPI on Linux, mirrored DOM on web). No-op on hosts without one. |
| `openFileDialog` | `fn(*Host, FileDialogFilter) FileDialogResult` | Block until the user picks a path; `null` on cancel. Native hosts call the OS file picker; web stubs return `null`. |
| `saveFileDialog` | `fn(*Host, FileDialogFilter) FileDialogResult` | Save-side counterpart of `openFileDialog`. |
| `openSecondaryWindow` | `fn(*Host, []const u8, u32, u32) ?u32` | Open a second top-level window sharing this Host's event source; returns an opaque id the app holds and renders into via the GPU layer. Single-window hosts return `null`. |
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

**Wheel sign convention**: `wheel_dx` / `wheel_dy` carry pixels of *intended* scroll accumulated since the previous `pollInputs`. Positive `wheel_dy` means the user wants the content to scroll **down** (visible viewport advances toward higher y); positive `wheel_dx` means scroll **right**. This matches the DOM `WheelEvent.deltaX` / `deltaY` convention. Backends translate native wheel notches into pixels — Win32 maps each `WHEEL_DELTA` (120 raw units) to ~48 px (the standard "3 lines"); the wasm host forwards zunk's already-pixel `mouse.wheel`. Zero when no wheel events arrived. Apps translate `wheel_dy` into a regular Msg (e.g. `.scroll_by`) and route it through `update`, same as any other input — there is no wheel-handler callback.

## Invariants

- **Single owner.** The main loop owns one Host. No globals.
- **Polling model.** The Host does not push events. The app pulls once per frame. Backends that receive events asynchronously (Win32 `WNDPROC`, zunk shared memory) buffer them and drain on `pollInputs`.
- **No allocation on the hot path.** Backends hold fixed-size scratch buffers (see `Host.keys_buf` / `chars_buf` in `src/platform/wasm.zig`).
- **`init` signatures are NOT validated.** A wasm host that only takes a title vs. a Win32 host that takes dimensions both satisfy the contract. Callers construct the Host via the backend-specific signature and then use it generically.

## Non-goals / known limits

- **No keyboard auto-repeat handling.** Backends report raw key events. A widget that wants repeat (e.g. holding backspace to delete) must implement it in `update` based on frame timing.
- **IME surface only.** `imeState()` is in the contract and the Win32 host wires WM_IME_* messages through it, but `chars` on Win32 is still ASCII-fast-path and wasm caps `chars` at 32 bytes per frame (zunk limit) — IME paste of >32 bytes silently truncates. Tracked in [zunk-handoff.md](../archive/zunk-handoff.md).
- **No focus-in / focus-out.** Apps track focus in `Model`; backends don't report window-focus edges today.
- **No gamepad / touch / pen.** Single mouse + keyboard only.
- **Secondary windows are stub-only.** `openSecondaryWindow` is in the contract for forward compatibility; current backends return `null` and the GPU layer has no `renderToWindow` yet.

## Test coverage target

- **Stub acceptance** (covered): `validateHost` accepts a minimal conformant struct.
- **Gap tests** (missing): one compile-fail test per missing decl — HARDLINE §5 asks for 100 % validator coverage.
- **Backend parity** (missing): an integration test that drives both `win32.zig` and `wasm.zig` Host stubs through a scripted input sequence and asserts the resulting `InputState` slices are equivalent. Would catch backend drift — e.g. the control-char filter regression described in [pitfalls.md](../pitfalls.md#3-zunk-pushes-control-chars-into-typed_chars-wasm-only).
