# Teak: Next-Phase Task List

Working document for the cleanup/abstraction phase after proto 2. Ordering is the user's proposed sequence; dependencies are called out where they matter.

**Status (2026-04-18)**: tasks 1, 2, 3, 6, 7 landed. Task 4 (feature docs) landed — seven docs in `docs/features/` plus an index + template. Task 5 (pitfalls playbook) landed in minimal form — `docs/pitfalls.md` has four entries backed by real bugs, a canary-test category list, and a template for future entries. All docs intentionally kept lean; expand as new features / pitfalls land. Phase is complete.

---

## 1. ✅ Migrate to Zig v0.16.0

**Why**: We're pinned to Zig 0.15.2 in `CLAUDE.md` and `build.zig`. 0.16 will bring breaking changes (std API, builder API, comptime semantics) — better to migrate once now than to accumulate drift.

**Deliverables**:
- Update `.minimum_zig_version` / version gate in `build.zig` and any readme.
- Update `CLAUDE.md` build-tooling section.
- Fix all 0.16 deprecation / breakage warnings (no `@compileLog` spam tolerated).
- Confirm `wgpu-native` dependency still resolves (may need a newer fetch hash).
- `zig build test && zig build run && zig build ui` all pass.

**Risk**: The aarch64 `i8mm` workaround in `build.zig` may need revisiting — 0.16 may have fixed feature detection upstream.

**Do before**: task 3 (file restructure) so we're not fighting two churn sources at once.

---

## 2. ✅ Documentation cleanup + consolidation

**Why**: We have `docs/init_convo/` (4 original-design MDs), `docs/proto_2.md` (phase plan), `docs/proto2_post.md` (postmortem), `docs/day1_recap.md` (review), and `CLAUDE.md`. Already sprawling after one day.

**Deliverables**:
- `docs/archive/` for historical-only documents. Move `docs/init_convo/*` in.
- Distill `spec.md` (or keep `ui-framework-spec.md`) as the *current* living spec — superseded by task 7's HARDLINE doc eventually.
- Collapse `proto_2.md` + `proto2_post.md` + `day1_recap.md` into a single `docs/journal/` directory (dated entries) or a `history.md` narrative. Keep them as source of truth for *what happened* but out of the root docs view.
- Root-level `README.md` with: what Teak is, build commands, where to read next.
- `CLAUDE.md` stays at root (Claude Code looks for it there) but should point at the spec/README rather than restating.

**Rule going forward**: new MDs land in `docs/journal/YYYY-MM-DD-topic.md` unless they're one of the canonical docs (README, spec, HARDLINE, tasks, CLAUDE).

---

## 3. ✅ New file structure: framework / host / example split

**Why**: `src/` currently mixes framework core, Win32 host, composed demo, and CLI demo. To support (a) more hosts, (b) consumption as a library, and (c) multiple example apps, this has to be untangled.

**Target layout** — the full spec lives in [`docs/archive/tasks-file-struct.md`](docs/archive/tasks-file-struct.md) (archived 2026-04-17; migration plan executed); this section keeps only the top-level sketch. The companion doc records the `gpu/` backend split, the `platform/` boundary, and deviations from Isaac's reference sketch.

Top-level sketch (refer to `docs/archive/tasks-file-struct.md` for the detailed tree):

```
teak/
├── build.zig
├── build.zig.zon
├── src/                    ← the library (consumable as a Zig dependency)
│   ├── root.zig            ← public API surface
│   ├── cmd.zig
│   ├── compose.zig
│   ├── layout.zig
│   ├── hit_test.zig
│   ├── render.zig
│   ├── transient.zig
│   └── host/               ← platform abstraction
│       ├── host.zig        ← Host interface (window + input events + render target)
│       ├── win32.zig       ← Win32 implementation (extracted from ui_main.zig)
│       ├── cocoa.zig       ← TODO
│       ├── x11.zig         ← TODO (or wayland.zig)
│       └── wasm.zig        ← TODO (coordinates with task 6)
├── examples/
│   ├── counter_greeter/    ← current proto 2 demo
│   │   ├── build.zig
│   │   └── src/
│   │       ├── main.zig
│   │       ├── counter.zig
│   │       ├── greeter.zig
│   │       └── app.zig
│   └── (future examples)
├── docs/
├── CLAUDE.md
├── README.md
└── tasks.md
```

**Subtasks**:

### 3a. Windowing abstraction

Extract `ui_main.zig` (762 LOC) into a `Host` interface + Win32 implementation. The interface should carry:
- Window lifecycle (create / resize / destroy).
- Input event stream (mouse, keyboard, focus, resize).
- Render target handoff to wgpu (surface + queue + device).
- Main loop driver (or expose a "poll + present" pair so the app owns the loop).

The interface must also be satisfiable by **zunk's lifecycle** (`init` / `frame(dt)` / `resize(w,h)` / `cleanup`) so `host/wasm.zig` is a thin shim over zunk rather than a parallel implementation. See task 6 for the audit that informs the exact shape.

Critical sub-decision: **wgpu backend abstraction**. Teak currently calls `wgpu-native` via `@cImport`. On web we'll call `zunk.web.gpu` (typed handles, slightly different API surface). The render-pass interface needs to be narrow enough that both back it. Options:
- Trait-style vtable in `render.zig` that both backends satisfy (manual dispatch).
- `comptime`-parameterized backend (`Renderer(comptime Gpu: type)`).
- Convergence on a single shared wrapper that wgpu-native and zunk.web.gpu both conform to — *this is the conversation to have with zunk upstream* (task 6).

Acceptance: swapping `win32.zig` for a stub shouldn't require touching anything in `src/*.zig` above it.

### 3b. Extract framework as library

Make `src/` a publishable Zig module:
- `build.zig.zon` exports a module named `teak`.
- No executable targets in the library build — those move to `examples/`.
- `root.zig` re-exports everything a consumer needs (`Cmd`, `CmdBuffer`, `Components`, `LayoutEngine`, `hitTest`, `hoverTest`, `TransientState`, `Vertex`, `buildVertices`, `Host`, `SpecialKey`, etc.).

### 3c. Extract demo to `examples/`

Move `counter.zig`, `greeter.zig`, `app.zig`, `main.zig`, `ui_main.zig` → `examples/counter_greeter/`. The example's `build.zig` depends on the `teak` module via relative path for in-repo, via `.zon` for out-of-repo.

**Do after**: task 1 (Zig version). **Do before**: tasks 4–7 (they all assume the new layout).

---

## 4. ✅ Document "library-candidate" features

**Why**: Several pieces exist in-tree but haven't earned their stripes as library surface. `validateComponent` is the canonical example — it's in `compose.zig` but we should decide whether it's `pub`, what contract it promises, and what errors it guarantees.

**Deliverables** — for each candidate, write a short spec in `docs/features/`:
- Current status (internal vs `pub`).
- Intended contract (signature, pre/post conditions, compile-error format).
- Missing pieces.
- Test coverage target.

**Known candidates**:
- `validateComponent` — compile-time shape enforcement with human-readable errors.
- `buildMsgs` — msg-struct synthesis (currently only wraps payload-less variants; document the limitation).
- `Components(...)` — composition factory; document validator ordering and generated names.
- `TransientState` policy (the three-rule gate from the refinement doc).
- `Host` interface (from task 3a).
- `hitTest` / `hoverTest` split.
- `LayoutEngine` extension points (for future CSS Grid / constraint solver, per refinement doc §3).

**Rule**: anything marked `pub` in `root.zig` needs a feature doc before we bless a 1.0.

---

## 5. ✅ Pitfalls + test-and-validate playbook (minimal)

**Why**: The proto-2 UAF bug ("input f" instead of "input H") and the simplifier's double-buffer regression were caught by ad-hoc canaries, not by a repeatable process. We should encode those lessons.

**Deliverables**: `docs/pitfalls.md` with entries like:

| Pitfall | Detection | Fix |
|---|---|---|
| Component `view` taking `Model` by value → dangling slices into stack-copied fields | CLI canary: print text input contents; dangling bytes show as `f` / garbage | Always `*const Model` in view signature |
| Simplifying across a time-varying variable (`current ^= 1`) | Frame-diff regression test: assert vertex rebuild happens at least once in first 3 frames | Name variables that capture "slot at time T" distinctly |
| Arena-allocated strings compared by pointer across frames | Diff-skip counter stays at zero OR diff-skip counter never goes up — either is suspicious | Content-compare (`std.mem.eql`) in diff predicates |
| Nested `pub const Msg` shadowing file-scope `pub const Msg` | `ambiguous reference` compile error | Use `@This().Msg` or rename one |

**Plus**: a "canary tests" section listing tests that should exist for every new feature:
- A CLI simulation (no GPU) that walks an input trace through update + view and asserts on command-buffer contents.
- A frame-diff test asserting rebuild happens when expected and skips when expected.
- A comptime `validateComponent` negative test (commented-out block with expected error message).

---

## 6. ✅ Co-develop with zunk (two-way feedback loop)

> **Status 2026-04-18**: integration landed. `src/platform/wasm.zig` + `src/gpu/web.zig` consume zunk's `web.input` / `web.app` / `web.gpu`; `examples/counter_greeter` builds a working `dist/` via `teak.linkWebWgpu` → `zunk build`. Audit doc lives at `docs/zunk-integration.md`; open upstream asks tracked in `docs/zunk-handoff.md`. The WASM gap punch list (archived at `docs/archive/tasks-wasm.md`) is closed. Governance/independence commitments below remain ongoing.


**What zunk is**: A Zig build plugin + runtime library that takes a pure-Zig WASM binary, inspects its import table, and auto-generates the JS + HTML glue required to run it in a browser. Layered API: raw `extern "env" fn` at the bottom, ergonomic `zunk.web.*` modules (canvas, input, audio, gpu, app) in the middle, custom `bridge.js` escape hatch on top. Already ships WebGPU bindings (`zunk.web.gpu`, 33 extern fns, typed handles).

**Integration model**: zunk is consumed as a normal Zig dependency — **no globally-installed CLI, no external tooling**. Consumer's `build.zig.zon` declares `.zunk = .{ ... }`; consumer's `build.zig` imports zunk and calls `zunk.installApp(b, zunk_dep, user_exe, .{})` which wires the zunk CLI as a build-graph artifact. `zig build run` compiles the wasm, invokes zunk against it, emits HTML/JS, starts a dev server. Cleaner than Rust's trunk-based equivalents — see `docs/journal/2026-04-16-zunk_teak_convo.md` §8 for the full logistics breakdown with code pointers.

**Ownership**: Both repos owned by @hotschmoe. Teak is the primary focus, but zunk must remain a **general-purpose Zig wasm build tool** that Teak happens to be one consumer of — standing on its own two feet for others, or at minimum as inspiration for Zig projects leveraging comptime + WASM introspection. This is a deliberate commitment, not an accident of history.

**Local path**: `../zunk/` (sibling repo). Neither repo pins a stable release of the other yet — we iterate against each other's `master`.

### Why the fit is natural

Zunk's lifecycle protocol and input model map almost directly onto what Teak's host layer needs:

| Teak needs | Zunk provides |
|---|---|
| A main loop driver that respects `requestAnimationFrame` timing on web | `export fn frame(dt: f32) void` — zunk wires it to rAF automatically |
| Resize handling | `export fn resize(w: u32, h: u32) void` — zunk generates the handler |
| Keyboard + mouse input | `zunk.web.input` — polling model (shared-memory struct), matches how `ui_main.zig` already drains input queues |
| WebGPU surface + device acquisition | `zunk.web.gpu.requestAdapter` / `requestDevice` — same async-callback pattern as wgpu-native |
| One-shot init after canvas is ready | `export fn init() void` |

Teak's current `ui_main.zig` main loop is structurally a `while (running) { drain_input; build_frame; render; present; }` — trivially re-shapes to zunk's per-rAF `frame(dt)`.

### Audit work (required before `host/wasm.zig` can be written)

Run this scoping exercise and write the result to `docs/zunk-integration.md`:

1. **WebGPU coverage gap analysis**. Enumerate every wgpu call Teak makes today (`wgpuDeviceCreateShaderModule`, `wgpuDeviceCreateRenderPipeline`, `wgpuDeviceCreateBuffer`, `wgpuQueueWriteBuffer`, `wgpuCommandEncoder*`, `wgpuRenderPassEncoder*`, `wgpuSurfaceConfigure`, etc.) and check each against `zunk/src/web/gpu.zig`. File issues upstream for anything missing.
2. **Shader format check**. Teak uses WGSL. Zunk's gpu.zig should pass WGSL through unmodified — confirm (WebGPU-native accepts WGSL in browsers).
3. **Input event parity**. Teak needs `WM_CHAR`-equivalent Unicode text input (not just keydown scan codes) for the greeter. Confirm `zunk.web.input` exposes a text-input channel distinct from key-down events.
4. **Async adapter/device pattern**. Our Win32 host spins: `while (adapter == null) wgpuInstanceProcessEvents(...)`. On web you can't spin — you have to yield. Understand how zunk sequences the adapter/device acquisition before `init` fires.
5. **Main-loop ownership**. Teak currently owns its loop. Under zunk, zunk owns the rAF loop and calls into `frame(dt)`. The Host interface needs to support both ownership models ("host drives" vs. "app drives").

### Teak → zunk feedback (what Teak needs from zunk)

- WGSL shader module creation (confirm present and ergonomic).
- Typed vertex buffer layouts / pipeline descriptors that match Teak's `teak.Vertex` struct.
- A way to upload a vertex buffer of `N * @sizeOf(Vertex)` bytes per frame without per-call allocation (Teak does this via `wgpuQueueWriteBuffer`).
- Text input event with Unicode codepoint (not raw keycode).
- Clipboard read/write (future, not blocking).

### Zunk → Teak feedback (what zunk will push back on)

- No blocking calls anywhere in the host-facing Teak API (we may have some; audit).
- All allocations explicitly sized — zunk's bundle-size story depends on no hidden heap growth.
- Exact `extern fn` naming conventions if Teak ends up declaring any (prefer: Teak never declares any, always goes through `zunk.web.*`).

### Concrete deliverables

- `docs/zunk-integration.md` — the audit from above. Living document.
- `examples/counter_greeter/` builds dual-target: `zig build ui` (native, wgpu-native) and `zig build web` (wasm, zunk). Same app code, different host.
- A cross-repo design doc or ADR for the wgpu abstraction shape (see task 3a's sub-decision).
- Shared understanding on Zig version bumps — if zunk moves to 0.16 first or vice versa, the other shouldn't be blocked for long. Coordinate with task 1.

### Governance / logistics

Same owner for both repos; "two-way communication" mostly means keeping the line between Teak-specific and general-purpose clean so future contributors to either repo (or to zunk as a standalone tool) aren't surprised:

- **Upstream preference.** When Teak needs a zunk feature, add it to zunk as a general-purpose feature, not as a Teak-specific hack. If Teak's need isn't generalizable, that's a signal the need is wrong.
- **No forking, no absorbing.** If zunk has a gap, PR it upstream. See `docs/journal/2026-04-16-zunk_teak_convo.md` §8 for the three-criteria test that must be met before reconsidering this — none hold today.
- **Cross-linked issues** when one project's decision affects the other. The owner-of-both may know; a future reader of either repo in isolation won't.
- **Shared `INTEGRATION.md`** in zunk listing known consumers (currently Teak + zunk's own example apps) and their minimum-version requirements.

### Independence commitment

Zunk must remain a general-purpose Zig wasm build tool even while Teak is its primary consumer. Three concrete commitments (also captured as standing action items in `docs/journal/2026-04-16-zunk_teak_convo.md`):

- **Never ship Teak-specific resolution rules** into zunk's 5-tier resolver. If Teak needs a special case, it's a general case (or it's a bug).
- **Never absorb zunk's HTML/JS generation into Teak.** The coupling is already at the cleanest possible layer (`zunk.installApp`); absorbing would only add mission creep. See `docs/journal/2026-04-16-zunk_teak_convo.md` §8 for the full analysis and the three criteria that would justify revisiting.
- **Never fork zunk into Teak's tree.** If zunk atrophies, vendor the minimum needed shims into `src/host/wasm/` and drop the dep — don't carry the whole toolchain.

The Rust precedent: iced doesn't absorb trunk. Teak shouldn't absorb zunk. Zig's build plugin model makes the integration cleaner than Rust's; take the win.

**Do before**: task 3a's actual `wasm.zig` implementation — the audit has to land first.
**Do after**: task 3b/c (library + examples extraction) so there's a clean consumer story to hand zunk.

---

## 7. ✅ HARDLINE spec: TEA + K philosophy lockdown

**Why**: Day-1 already showed how easy it is to drift (the simplifier quietly broke the double-buffer by collapsing two "identical" variables). As the surface grows, pressure to "just add an escape hatch" will mount. We need a document that (a) states the invariants, (b) enumerates the deliberate breaks we've *already* taken, and (c) sets the bar for any future break.

**Deliverables**: `docs/HARDLINE.md` — short, imperative, checkable.

**Proposed structure**:

1. **The core invariants** — things we will never violate:
   - All application state lives in `Model`. No hidden retained widget state.
   - Every state transition is a variant of `Msg`. No implicit mutation.
   - `view` is a pure function of `Model` → `[]Cmd`. No side effects, no I/O.
   - Layout, hit-test, and render are independent passes over `[]Cmd` + `[]Rect`. No shared mutable state between passes.
   - Per-frame data is arena-allocated and bulk-freed. No per-widget lifetime.

2. **The deliberate breaks** — named, bounded, justified:
   - **Comptime component stitching** (escape hatch 1). Bounded by: `validateComponent` must accept every component; no runtime reflection.
   - **TransientState** (escape hatch 2). Bounded by: three-rule gate (derivable / non-logical / safely losable). If a piece fails any rule, it goes in Model.
   - **Flat-buffer-with-stack layout** (escape hatch 3). Bounded by: fixed-depth stack, two O(n) linear passes, replaceable pass function.

3. **Forbidden patterns** — concrete things we will reject in PR review:
   - Widget-internal `static` state.
   - Closures-by-function-pointer-plus-context smuggling.
   - ID hashing for widget identity.
   - Virtual DOM diffing (we diff flat buffers, not trees).
   - Fine-grained reactive signals.
   - Lifecycle hooks (`onMount` / `onUnmount`).

4. **How to propose a new break**:
   - Name the problem concretely (not "it would be nice to...").
   - Show why existing mechanisms don't suffice.
   - Propose the narrowest possible extension.
   - Add it to this document under "deliberate breaks" with a bounded rule.

5. **Drift audit checklist** — run before every release:
   - No `var` statics in `src/` except the Host layer.
   - No `fn_ptr` fields on `Cmd` variants (msgs are data, not callbacks).
   - All `pub` surface area in `root.zig` has a feature doc (task 4).
   - `validateComponent` coverage stays at 100% of enforced invariants.

**This is the keystone doc.** Tasks 2 and 4 feed into it; task 5 backs it with test discipline.

**Do last** in this phase (after the restructure settles) — but *start drafting during* task 3 so the move doesn't smuggle in drift.

---

## Execution order

All seven phase tasks complete. This doc is now a historical record of
the cleanup/abstraction phase; next work opens a new plan.
