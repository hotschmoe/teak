# Pitfalls + canary playbook

A short, living log of bugs we've hit — each one has a **detection** and a
**fix**, so the next person recognises the shape before paying for it
again. Minimal by design: add an entry only when a bug took real
debugging, not for every typo.

Companion to [features/](features/) (which documents what each piece
*should* do). Pitfalls are the places "should" and "does" diverged.

Feeds into [HARDLINE §5](HARDLINE.md#5-drift-audit-checklist) — every
pitfall here deserves an audit rule or a canary test that catches
regressions automatically.

---

## Entries

### 1. Component `view` taking `Model` by value

**Shape**: UAF in a text input — the greeter displayed `f` instead of whatever the user typed, then corrupted bytes.

**Detection**: CLI canary that drives a text-input trace through `update` + `view` and asserts the resulting `Cmd.text_input.content` bytes match what was typed. Visible because the string became nonsense as soon as the stack frame that held the copy returned.

**Root cause**: `fn view(model: Model, ...)` takes `Model` by value. The `text_input` command stored `model.name[0..model.name_len]` — a slice into the function's *local copy* of `Model`. Slice pointed into dead stack memory the moment `view` returned.

**Fix**: `view` always takes `*const Model`. Enforced by `validateComponent` in `src/core/component.zig`; the file-level comment explains why.

**Related audit rule**: HARDLINE §3 forbids allocation in `view` — which means any slice `view` stores must be borrowed from `Model` or from the per-frame arena. By-value params can't do either.

**Recurrence**: the same shape bit when iterating a model array inside `view`: `for (m.items) |item|` captures by value — `item.label[0..item.label_len]` then dangles after the iteration ends. Fix is `for (m.items) |*item|`. First caught in tree example, 2026-04-19. The lesson: *any* slice you plan to hand to a `Cmd` must be rooted in something that outlives the frame, not in a loop-iteration copy.

---

### 2. Simplifier collapsing the double-buffer

**Shape**: Vertex buffer never rebuilt after frame 1. UI appeared frozen despite `Model` changing.

**Detection**: Frame-diff regression test — assert vertex rebuild happens at least once in the first 3 frames after a `Msg` dispatch. A trivial "count rebuilds" assertion catches this; a visual eyeball check does not (the last-rendered frame still looks right).

**Root cause**: The main loop alternates two command buffers (`current ^= 1`) so hit-test reads frame N-1 while we build frame N. An overzealous code simplifier saw two variables of the same type used the same way and collapsed them into one — silently eliminating the double-buffer.

**Fix**: Name variables that capture "slot at time T" distinctly. `bufs[0]` and `bufs[1]` indexed by `current` (the current teak design) is more robust than `buf_a` / `buf_b` because the ^= 1 toggle is locally greppable as a double-buffer idiom.

**Related audit rule**: HARDLINE §1 says passes are independent. Independence implies they can disagree about which frame they're looking at — which implies storage for both. Deleting that storage is a drift signal.

---

### 3. Zunk pushes control chars into `typed_chars` (wasm only)

**Shape**: Backspace key in the greeter inserts a char-8 **then** deletes one — the user saw nothing happen.

**Detection**: Would have been caught by the Host parity test listed in [features/host.md](features/host.md#test-coverage-target) (drive both backends with the same scripted input; assert equivalent `InputState`). We caught it by actually typing into the wasm build.

**Root cause**: Zunk reports Backspace / Enter / Tab on both channels: as a `SpecialKey` **and** as a codepoint in `typed_chars`. The greeter handled both — inserting the control char, then acting on the special key.

**Fix**: `src/platform/wasm.zig` filters `c < 0x20 || c == 0x7f` out of `typed_chars` before returning. Upstream issue filed (tracked in `docs/zunk-handoff.md`).

**Related audit rule**: when a Host backend reports the same user action on two channels, exactly one channel owns it. Which one is a backend decision; the app shouldn't see duplicates.

---

### 4. Wasm mouse coords vs. CSS pixels

**Shape**: Hit-tests missed every widget on high-DPR displays. Mouse visibly hovering over a button didn't highlight it.

**Detection**: Manual testing on a high-DPR display. A cheap canary: log `viewport_width` and `mouse_x` on the first frame; at DPR = 2 the mouse coord is in [0, 2*viewport_width] while the viewport is in [0, viewport_width], and the ratio is a dead giveaway.

**Root cause**: Zunk reports `mouse_x` / `mouse_y` in canvas backing pixels (canvas size = `clientWidth × DPR`), but `viewport_width` / `viewport_height` in CSS pixels. Teak's layout runs in CSS pixels. The two frames diverge at DPR > 1.

**Fix**: `src/platform/wasm.zig` divides mouse coords by DPR before returning them. The `nativeHandle` passes DPR through to the Gpu backend for framebuffer sizing.

**Related audit rule**: Coordinate-system mixing is a recurring class. All input to `layout/`, `input/`, `render/` is in the **same** coordinate system as `InputState.width` / `height`. Backends convert at the edge.

---

## Canary test categories

Every new feature ships with at least one of each that's applicable.
Feature docs in `features/` list the target coverage per feature.

1. **CLI simulation.** No GPU. Drive an input trace through `update` + `view` + layout + hit-test and assert on `[]Cmd` / `[]Rect` contents. Catches logic bugs (pitfall #1, #2) at compile-test speed.
2. **Frame-diff regression.** Assert that rebuilds happen when expected **and skip when expected**. A diff-skip counter that stays at 0 is as suspicious as one that never goes up.
3. **Comptime-validator negative test.** One `@compileError`-expected block per validator rule. A commented block with the expected compile-error string works until Zig gets proper `expected-compile-error` tests.
4. **Wasm-core compile canary.** `zig build test-wasm` — compiles the framework to `wasm32-freestanding`. Fails instantly if any change pulls a posix dep into the core. Already wired in `build.zig`.
5. **Host-parity test (per-backend).** Script an input sequence; assert `InputState` is equivalent across backends. Catches pitfalls like #3. Does not exist yet.

---

## Entry template

Copy-paste when adding a new pitfall. Lead with the shape a reader
would recognise, not the fix — the fix is only useful if the reader
matches the symptom first.

```markdown
### <N>. <Name capturing the shape>

**Shape**: <what the user / dev saw — symptom, not diagnosis>

**Detection**: <the test or canary that would catch this. If none caught it when it happened, describe the test we should add.>

**Root cause**: <what was actually wrong in the code>

**Fix**: <what we changed; link to the file/commit>

**Related audit rule**: <link to the HARDLINE rule or feature-doc contract this pitfall backstops, if any>
```
