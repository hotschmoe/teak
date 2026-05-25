# Functional gaps — 8 features that closed the production-readiness list

**Status**: All 8 features `pub` in `src/teak.zig` (or in example glue).
**Branch**: `functional_gaps_yolo`
**HARDLINE additions**: §2 escape hatches 5 (overlay layer) + 6 (subscriptions).
**Tests**: distributed — each section names its test files.

The pre-YOLO Teak prototype could only express a flat document of
colored quads + monospaced glyphs. That covered the proof-of-architecture
demo (counter + greeter) but missed eight things that any production
desktop app needs from day one. This doc lays out what changed, what
the contract is, and where the implementation lives.

Read [`docs/HARDLINE.md`](../HARDLINE.md) first if you haven't —
escape hatches 5 and 6 were added during this push and the surface
extensions on the Host validator are bounded by §4(d).

---

## 1. Overlay / floating layer (§2 escape hatch 5)

**Source**: `src/core/cmd.zig` (`OverlayStyle`, `push_overlay`,
`pop_overlay`); layout/hit-test/render arms in
`src/{layout,input,render}/`.
**Tests**: `src/layout/engine.zig`, `src/input/hit_test.zig`,
`src/render/build.zig`.

`push_overlay` / `pop_overlay` delimit a region of the flat `[]Cmd`
buffer that:

- Positions absolutely (`x`, `y` in window coords; `anchor_x_frac` /
  `anchor_y_frac` shift by `(-w*frac, -h*frac)` for pin-to-corner).
- Doesn't contribute to its parent's measured size (overlays "hop"
  the layout).
- Draws **after** non-overlay content (overlay layer z=1, base z=0;
  within each layer painter's order = doc order).
- Hit-tests **before** non-overlay content (so a tooltip / menu /
  modal wins clicks at the same point).
- Optionally fills a `backdrop` color behind its children (for modals).
- Optionally claims clicks landing on the empty backdrop (`modal: bool`)
  and dispatches a `backdrop_msg: ?Msg` for click-outside-to-close.
  `OverlayStyle` is Msg-generic to carry the Msg as data (HARDLINE §3
  still bans fn-pointer callbacks on Cmd variants). Hit-test's
  `HitResult.msg` is `?Msg`: `null` = modal consumed but no Msg —
  host must not fall through. See `docs/features/hit-test.md` for the
  full pattern.

The two-layer walk is implemented inside both `buildVertices` and
`hitTest` — each pass walks the buffer twice (`.base`, then `.overlay`)
keeping the flat-buffer invariant. **No per-cmd z field. No second
buffer. No tree.**

Counter-greeter wires a help-modal demo: AppLevel state
`show_help_modal`, "Help" toolbar button, modal contains a rich-text
panel + close button. See `examples/counter_greeter/src/app.zig`.

## 2. Image / texture rendering

**Source**: `src/core/cmd.zig` (`ImageCmd`, `ImageStyle`);
`src/render/build.zig` (`ImageDraw`); `src/gpu/{context,native,web}.zig`.
**Tests**: validator covered by `src/gpu/context.zig`; render-side
covered in `src/render/build.zig`.

Two surface methods on the Gpu validator (HARDLINE §4(d) extension):

```zig
uploadImage(bytes: []const u8, width: u32, height: u32) TextureHandle
uploadImages(draws: []const ImageDraw) void
```

The app uploads an RGBA8 image once, stashes the returned handle in
its Model, and emits `cmd.image(handle, .{ ... })` each frame. The
renderer collects per-frame `ImageDraw`s into a buffer parallel to
`text_draws`. Handles are interpreted by the *image* cache, not the
text cache — no per-handle discriminator needed (dispatch happens at
the `uploadImages` call site).

Native uses a separate `image_pipeline` driven by `shaders/image.wgsl`
(`textureSample * tint`, no alpha-from-texture coercion — real RGBA
colors flow through). 64-slot app-driven cache; no LRU because the
app explicitly manages handle lifecycle.

Wasm: stub returning `TEXTURE_HANDLE_NONE` so the renderer falls back
to a tinted placeholder quad. The contract is honored; the visual is
pending real zunk texture upload + a parallel image pipeline.

## 3. Rich text input — selection + clipboard + IME stub

**Source**: `src/core/cmd.zig` (`TextInputCmd.selection_anchor`);
`src/input/keys.zig` (new variants); `src/platform/host.zig`
(`Clipboard`, `ImeState`); `src/platform/win32.zig` (real impl);
`src/platform/wasm.zig` (stub).
**Tests**: `examples/counter_greeter/src/greeter.zig`,
`src/render/build.zig`.

`TextInputCmd` gains `selection_anchor: ?usize`. When non-null and
`!= cursor`, the renderer draws a selection highlight from
`min(anchor, cursor)` to `max(anchor, cursor)`. Same byte semantics
as `cursor`.

`SpecialKey` picks up:

- `shift_left`, `shift_right`, `shift_up`, `shift_down`, `shift_home`,
  `shift_end` — selection extension.
- `ctrl_a`, `ctrl_c`, `ctrl_x`, `ctrl_v`, `ctrl_z`, `ctrl_y` — chord
  intents. Apps switch on these.

`Host` surface (HARDLINE §4(d)) picks up:

- `clipboard() Clipboard` — `{ read() []const u8, write(t) void }`
  vtable. Win32 uses `CF_UNICODETEXT` + `GlobalAlloc` + UTF-16 ↔
  UTF-8 conversion via a 64K in-Host scratch buffer.
- `imeState() ImeState` — `{ active, text, cursor }`. Win32 returns
  inactive (WM_IME_* messages reach the window proc but aren't
  propagated yet — tracked as follow-up).

Counter-greeter wiring: greeter component grows
`name_select_left/right`, `name_select_all`, `name_select_none`, and
`name_replace_selection: []const u8`. Typing or backspace with an
active selection **replaces** the range — standard text-input
semantics. `app.zig` routes shift-arrows and ctrl_a/escape into
greeter Msgs; `ctrl_c/x/v` are flagged as needing clipboard so the
host loop fires `clipboard.read/write` at the boundary and dispatches
a normal `name_replace_selection` Msg.

## 4. Subscriptions / timers (§2 escape hatch 6)

**Source**: `src/core/sub.zig`.
**Host surface**: `nowMs() u64` on validateHost (HARDLINE §4(d)).
**Tests**: `src/core/sub.zig`.

App declares:

```zig
pub fn subscribe(model: *const Model) []const Sub
```

This is a **pure function** of model — same rules as `view`. It
returns the subs the runtime should service this frame. Two variants:

```zig
Sub(Msg) = union(enum) {
    every: { interval_ms: u32, msg: Msg },     // fires every N ms
    at:    { deadline_ms: u64, msg: Msg },     // fires once at a deadline
};
```

`runSubs(comptime Msg, subs, last_frame_ms, now_ms, dispatch)` does
the firing — stateless at the framework level, no per-sub key
tracking. `.every` fires once per crossed `interval_ms` boundary;
`.at` fires once on the frame transition past `deadline_ms`. App
responsibility:

- Re-emit `.every` subs each frame (subscribe is recomputed; no
  identity tracking).
- Drop `.at` subs from `subscribe()` after they fire to prevent re-firing
  on subsequent transitions (typically by clearing the deadline field
  in the handler).

Fired Msgs flow through normal `update`. **This is NOT a reactive
signal** (HARDLINE §3 forbids those) — observers are still the next
frame's `view`, not auto-recomputed expressions.

## 5. Multi-window + platform file dialogs

**Source**: `src/platform/host.zig` (`FileDialogResult`,
`FileDialogFilter`); `src/platform/win32.zig` (real impl via
`comdlg32.GetOpenFileNameW` / `GetSaveFileNameW`);
`src/platform/wasm.zig` (stub).

Three Host surface methods (HARDLINE §4(d)):

```zig
openFileDialog(filter: FileDialogFilter) FileDialogResult
saveFileDialog(filter: FileDialogFilter) FileDialogResult
openSecondaryWindow(title: []const u8, w: u32, h: u32) ?u32
```

`FileDialogFilter` is `{ name, pattern }` (e.g. `"Zig files"` /
`"*.zig;*.zon"`). Win32 packs both into the double-null-terminated
filter format the OS expects, calls comdlg32, converts the returned
UTF-16 path into a UTF-8 slice in the Host's `dialog_path_buf` (1024
bytes; valid until the next dialog call).

`openSecondaryWindow` returns a Host-internal id (`?u32`) for a second
top-level window. Single-window for now on both Win32 (returns null —
real impl needs a per-window wgpu surface in the Gpu layer) and wasm
(popup blockers killed `window.open` — apps fall back to overlays).
Surface stays stable so callers compile cleanly.

## 6. Virtual list primitive

**Source**: `src/core/cmd.zig` (`VirtualListStyle`, `push_virtual_list`,
`pop_virtual_list`); layout/hit-test arms in `src/{layout,input}/`.
**Tests**: `src/layout/engine.zig`, `test/integration_test.zig`.

Container that **claims** `total_count * item_extent` of main-axis
space but only **contains** cmds for the visible window. The app
computes the visible window from the parent scroll's offset and emits
cmds only for rows in `[visible_start, visible_end)`. Layout positions
the first emitted row at `visible_start * item_extent` so children
land in their virtual position.

For a 10,000-row table with a 480-px-tall scroll viewport and 24-px
rows, the buffer holds ~22 row groups while the layout reports the
scroll container's full 240,000-px extent. Bounded per-frame work
regardless of total row count.

## 7. Accessibility tree

**Source**: `src/input/a11y.zig`.
**Host surface**: `publishA11yTree(nodes: []const A11yNode) void` on
validateHost (HARDLINE §4(d)).
**Tests**: `src/input/a11y.zig`, `test/integration_test.zig`.

`buildA11yTree(arena, cmds, rects, focus_index) → []A11yNode` — pure
function over `[]Cmd` + `[]Rect`. Each node carries `role`, `cmd_index`,
`bounds`, `label`, `focused`, and a packed `state` (checkbox/radio: 0/1;
slider: [0, 1]).

Roles map to Cmd variants: `group`, `scroll`, `text`, `rich_text`,
`button`, `text_input`, `checkbox`, `radio`, `slider`, `divider`,
`image`, `overlay`.

**Mirrors hit-test semantics.** `buildTree` is structured exactly like
`hit_test.zig` — two passes over `[]Cmd` (`.overlay` then `.base`),
maintaining the same `layout.ClipStack` and `overlay_depth` counter:

- **Scroll clipping.** Each node's `bounds` are intersected with the
  surrounding scroll-clip stack. A widget fully scrolled out of its
  parent's viewport produces a zero-area clipped rect and is omitted
  from the tree; a partially-clipped one reports only the visible
  portion. Screen readers don't announce widgets the user can't see.
- **Modal occlusion.** If the overlay pass finds any `push_overlay`
  with `.modal = true` and non-empty clipped bounds, the base pass is
  skipped entirely. A screen reader doesn't announce widgets behind
  a modal — same rule `hitTestLayer` uses to refuse clicks. The modal
  overlay node itself is still emitted so the host can announce
  "dialog opened" and trap focus.
- **Non-modal overlays don't occlude.** Tooltips, debug overlays, and
  popovers (`modal = false`) keep the base layer announceable, mirror-
  ing how the base layer keeps receiving clicks outside their bounds.
- **A modal nested in a scrolled-away parent** has empty clipped
  bounds and therefore does NOT occlude the base — same rule
  `hit_test` uses to decide whether the modal can claim a click.

Win32 and wasm both implement `publishA11yTree` as a stable no-op —
the surface is in place so apps call unconditionally. Real UIA
(Windows) / aria-attribute DOM mirror (web) integrations are tracked
as follow-up.

## 8. Rich text rendering (via rich_zig)

**Source**: `src/core/cmd.zig` (`RichTextCmd`, `RichTextSpan`);
`examples/counter_greeter/src/rich_zig_adapter.zig`.
**Tests**: `src/render/build.zig`,
`examples/counter_greeter/src/rich_zig_adapter.zig`.

`RichTextCmd` carries:

- `content: []const u8` — full UTF-8 string.
- `spans: []const RichTextSpan` — non-overlapping byte ranges with
  per-run `color`, `font`, `bold`, `italic`.
- `default_color`, `default_font` — applied to bytes not covered by
  any span.

Layout walks spans + uncovered ranges to compute total width and
max-height. Render emits one `TextDraw` per visible span with that
span's color and font.

The `rich_zig` integration lives in the example layer (not in teak
itself) — sibling repo at `../rich_zig` is wired as a path dep in
`examples/counter_greeter/build.zig.zon`. The adapter consumes only
rich_zig's parser + Style — no terminal rendering imports — so the
wasm target compiles cleanly. Counter-greeter's help modal demos
mixed runs (`[bold]Overlay[/], [bold red]rich text[/], ...`).

---

## Drift audit + test surface

`zig build audit` still passes — HARDLINE §5 greppable rules survived
the push:

- No `var` statics in framework core.
- No fn-pointer fields on Cmd variants (sub uses an `anytype`
  dispatch *runtime helper*, not a Cmd field).
- All framework core stays platform / gpu import-free.
- wasm canary compiles all of `src/{core,layout,input,render}/` for
  `wasm32-freestanding`.

Test counts: library + integration + glyph cache modules — all green
on `zig build test`. All three examples (counter_greeter, todo, tree)
still build and test green.

## Still pending after this push

Per-section "stub" notes call out the remaining work; the big-ticket
items are:

- **IME**: WM_IME_* handling on Win32 (compose + commit text).
- **wgpu image pipeline on web**: parallel to native; needs zunk
  texture upload + a second pipeline.
- **UIA on Win32**: full `IRawElementProviderSimple` per a11y node.
- **Multi-window**: per-window wgpu surface in `src/gpu/native.zig`,
  Host-side window-id tracking.
- **Browser file dialogs**: showOpenFilePicker / showSaveFilePicker
  bridge (async + gesture-gated, breaks the synchronous Host shape).

These are real follow-up items — not silent gaps. The surface contracts
exist and apps can target them today.
