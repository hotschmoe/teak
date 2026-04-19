# HARDLINE

The non-negotiable rules for Teak. Short, imperative, checkable. This is
the keystone doc: when a PR or design bumps against it, the PR yields,
not the doc. A rule changes here only by the process in §4.

Companion reading: `spec.md` (architecture), `docs/archive/init_convo/ui-framework-refinement.md` (why
these rules exist), `docs/journal/2026-04-16-zunk_teak_convo.md` (the friction audit
that produced the Host escape hatch).

---

## 1. Core invariants

Never violate these. Full stop.

- **All application state lives in `Model`.** No hidden retained widget
  state. Cursor positions, scroll offsets, focus field, hover
  overrides — fields on `Model`, not stashed behind a widget ID.
- **Every state transition is a variant of `Msg`.** No implicit mutation
  from view/layout/render. The switch in `update` is the only place
  `Model` changes.
- **`view` is a pure function of `Model → []Cmd`.** No side effects, no
  I/O, no wall-clock reads, no allocation outside the per-frame arena,
  no importing `host/*` or `gpu/*`.
- **Layout, hit-test, and render are independent passes over `[]Cmd` +
  `[]Rect`.** No shared mutable state between passes. Each pass is
  replaceable in isolation.
- **Per-frame data is arena-allocated and bulk-freed.** No per-widget
  allocation/deallocation. Two arenas alternate; `reset()` wipes the
  one we're about to write.

---

## 2. Deliberate breaks

Named, bounded, justified. Anything outside this list is not a break —
it's a violation.

### Escape hatch 1: Comptime component stitching

`src/core/component.zig` synthesizes `Model` / `Msg` / `update` / `view`
from a struct of components.

**Bounded by**:
- `validateComponent` must accept every component before synthesis.
- No runtime reflection — the stitching is comptime-only.
- Generated names are the field names from the components struct; no
  hidden mangling.

### Escape hatch 2: TransientState

Presentation-only fields (hover_index, press_index, focus_index,
frame_counter, mouse_x/y) live outside `Model`.

**Bounded by the three-rule gate** — a field qualifies for TransientState only if **all** hold:
1. **Derivable** — recomputable from `Model` + current inputs in one pass.
2. **Non-logical** — only the render pass reads it; the host writes it
   (typically from hit-test output, mouse coords, and the frame counter).
   `update`, `view`, `layout`, and hit-test never reference it.
3. **Safely losable** — dropping it across a frame boundary is a cosmetic glitch, not a correctness bug.

If a field fails any rule, it goes in `Model`.

### Escape hatch 3: Flat-buffer-with-stack layout

`LayoutEngine` walks `[]Cmd` with an explicit fixed-depth stack
(`FixedStack(_, 32)`) rather than recursion over a tree.

**Bounded by**:
- Fixed-depth stack (currently 32); exceeding it is a bug, not an
  allocation trigger.
- Two O(n) linear passes (measure bottom-up, position top-down).
- Each pass function is replaceable — swap in a constraint solver or
  grid engine without touching `view`, hit-test, or render.

### Escape hatch 4: Host layer

Platform-mutable state (window handles, GPU resources, input queues)
is allowed **only** inside `src/platform/*` and `src/gpu/*`. Host-level
lifecycle entry points — `init`, `frame(dt)`, `resize`, `cleanup` — are
allowed and belong here.

**Bounded by**:
- (a) Host must be replaceable — swapping `win32.zig` for `wasm.zig`
  must not require any change in `src/{core,layout,input,render}/*`
  above it. The contract is `validateHost` / `validateGpu`.
- (b) No platform type leaks into the framework-facing API. No
  `HWND`, no `zunk.web.gpu.Handle`, no `c.WGPUDevice` in `teak.zig`
  re-exports.
- (c) Framework code never imports `src/platform/*` or
  `src/gpu/*` directly. Dependency arrow points inward only.

The rAF / `frame(dt)` lifecycle lives at this layer. See
`docs/journal/2026-04-16-zunk_teak_convo.md` for the audit that
formalized this hatch.

---

## 3. Forbidden patterns

Concrete things we reject in PR review. If a change adds any of these,
it gets pushed back until the pattern is removed or §4 is invoked.

- **Widget-internal `static` / `var` state.** Widgets are data, not
  objects. No `static` locals, no module-level `var` that tracks widget
  identity, no thread-local caches keyed by widget.
- **Closures-by-function-pointer-plus-context smuggling.** `Cmd`
  variants carry data (labels, styles, msgs). No `*const fn(...) void`
  fields on commands — msgs are values, not callbacks.
- **ID hashing for widget identity.** Hit-test and layout key off cmd
  *index*, not an opaque hash of ancestors + label. If we ever need
  persistent widget identity (e.g., focus across reorders), it goes on
  `Model` as an explicit field.
- **Virtual DOM diffing.** We diff flat `[]Cmd` buffers, not trees. No
  reconciler, no keyed lists, no component tree.
- **Fine-grained reactive signals.** State changes come through `Msg`
  and `update`; observers come through the next frame's `view`. No
  `Signal(T)` with auto-subscription.
- **Per-widget lifecycle hooks.** No `onMount` / `onUnmount` on
  individual commands. (Host-level `init` / `frame` / `resize` /
  `cleanup` are explicitly allowed under escape hatch 4.)
- **Components importing `host/*` or `gpu/*`.** Dependency arrow points
  inward. A component reading from `platform/win32` or `gpu/native`
  breaks escape hatch 4(c).
- **Conditional compilation in framework core.** No
  `if (builtin.os.tag == ...)`, `switch (builtin.target.os.tag)`, or
  `@import("builtin")`-gated branches inside
  `src/{core,layout,input,render}/*`. Platform branching happens in
  `src/platform/*` and `src/gpu/*` only; the greppable form of escape
  hatch 4(c).
- **General-purpose allocator in `view()`.** `view`'s signature is
  `fn(Model, *CmdBuffer) void` — no `std.mem.Allocator` parameter, no
  `anytype` that smuggles one in. The per-frame arena is reachable
  through `CmdBuffer` by design; a second allocator path defeats the
  bulk-free guarantee in §1.
- **`view()` reading wall-clock time.** `performance.now()`,
  `std.time.nanoTimestamp()`, `Date.now()` — none of these belong in
  view. Animation `t` values live in TransientState, advanced from
  `frame(dt)` at the host boundary.
- **Leaking platform handle types into framework API.** `Vertex`,
  `Cmd`, layout passes, render build — none of these reference wgpu
  types, zunk handles, or Win32 HWNDs. The GPU backend conforms to
  `validateGpu`; the framework knows nothing about it.

---

## 4. Proposing a new break

The bar is deliberately high. If the existing hatches do not cover a
real need, the process is:

1. **Name the problem concretely.** "It would be nice to..." fails. "We
   hit X in component Y; existing mechanism Z cannot express it
   because..." passes.
2. **Show why existing mechanisms don't suffice.** Walk through how
   you'd try with Msg/Model/TransientState/etc. and where it breaks
   down.
3. **Propose the narrowest possible extension.** If a one-line
   carve-out in an existing hatch covers it, prefer that over a new
   hatch. New hatches are rare.
4. **Add it under §2 with a bounded rule.** A hatch without a
   bounded-by clause is a leak waiting to happen. Every hatch above
   has (a)–(d)-style bounds; new ones inherit the convention.

---

## 5. Drift audit checklist

`zig build audit` automates the greppable half (marked **[auto]** below)
and also runs the wasm-canary compile. Run it before every release or
quarterly, whichever comes first. The **[manual]** items still need
human review.

- [ ] **[manual]** No `var` statics in `src/{core,layout,input,render}/*`. Only
      `src/platform/*` and `src/gpu/*` are allowed to carry mutable
      module-level state.
- [ ] **[auto]** No `fn_ptr` fields on `Cmd` variants. Audit greps
      `src/core/cmd.zig` for `*const fn` / `: fn(`.
- [ ] **[manual]** All `pub` surface area in `src/teak.zig` has a feature
      doc under `docs/features/`. If not, either write the doc or drop
      the `pub` until it's ready.
- [ ] **[manual]** `validateComponent` / `validateHost` / `validateGpu`
      coverage matches the contract stated in its comment. Missing
      check? Add it.
- [ ] **[auto]** `wasm32-freestanding` canary still compiles. `zig
      build audit` depends on `test-wasm`; if the canary breaks, the
      framework core has picked up a posix dep — revert or isolate.
- [ ] **[auto]** No imports from `src/platform/*` or `src/gpu/*` inside
      `src/{core,layout,input,render}/*`. Audit greps for
      `@import("../platform/` and `@import("../gpu/`.
- [ ] **[auto]** No conditional compilation in framework core. Audit
      greps for `builtin.os.tag`, `builtin.target`, `@import("builtin")`.
- [ ] **[auto]** `view` signatures take no `std.mem.Allocator`
      parameter. Audit finds `fn view(` and scans the signature body.
