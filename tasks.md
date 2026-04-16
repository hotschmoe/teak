# Teak: Next-Phase Task List

Working document for the cleanup/abstraction phase after proto 2. Ordering is the user's proposed sequence; dependencies are called out where they matter.

---

## 1. Migrate to Zig v0.16.0

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

## 2. Documentation cleanup + consolidation

**Why**: We have `docs/init_convo/` (4 original-design MDs), `docs/proto_2.md` (phase plan), `docs/proto2_post.md` (postmortem), `docs/day1_recap.md` (review), and `CLAUDE.md`. Already sprawling after one day.

**Deliverables**:
- `docs/archive/` for historical-only documents. Move `docs/init_convo/*` in.
- Distill `spec.md` (or keep `ui-framework-spec.md`) as the *current* living spec — superseded by task 7's HARDLINE doc eventually.
- Collapse `proto_2.md` + `proto2_post.md` + `day1_recap.md` into a single `docs/journal/` directory (dated entries) or a `history.md` narrative. Keep them as source of truth for *what happened* but out of the root docs view.
- Root-level `README.md` with: what Teak is, build commands, where to read next.
- `CLAUDE.md` stays at root (Claude Code looks for it there) but should point at the spec/README rather than restating.

**Rule going forward**: new MDs land in `docs/journal/YYYY-MM-DD-topic.md` unless they're one of the canonical docs (README, spec, HARDLINE, tasks, CLAUDE).

---

## 3. New file structure: framework / host / example split

**Why**: `src/` currently mixes framework core, Win32 host, composed demo, and CLI demo. To support (a) more hosts, (b) consumption as a library, and (c) multiple example apps, this has to be untangled.

**Target layout** (draft — refine during implementation):

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

## 4. Document "library-candidate" features

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

## 5. Pitfalls + test-and-validate playbook

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

## 6. Open two-way communication with zunk

**Why**: Zunk (WebAssembly / Zig native solution) and Teak (Zig-native UI) overlap at the WASM host target. Shared roadmap / shared pain points / shared test surface will mature both faster than either alone.

**Note**: I (Claude) don't have enough context on zunk to scope this properly. Before starting: please drop a short paragraph or link about what zunk is, who maintains it, and what "two-way communication" means in practice (shared repo? cross-linked issues? design sync doc?).

**Placeholder deliverables** (fill in once scoped):
- Identify zunk's current WASM entry-point / loader contract.
- Prototype Teak's `host/wasm.zig` against zunk's API.
- Shared design doc or cross-repo issue tracker for the wasm boundary.
- Agreement on Zig version bump cadence so neither project blocks the other.

**Do before**: task 3a's `wasm.zig` implementation — need zunk's contract first.

---

## 7. HARDLINE spec: TEA + K philosophy lockdown

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

## Suggested execution order

```
1 (Zig 0.16)
    ↓
2 (docs consolidation)
    ↓
3 (restructure: host / lib / examples)  ← largest task, spawn subtasks
    ↓
4 (feature docs) + 5 (pitfalls) + 7 (HARDLINE) — parallel
    ↓
6 (zunk) — once 3a is landed and we know the wasm host shape
```

Task 7 (HARDLINE) should have a stub drafted during task 3 even if finalized later — the restructure is exactly when drift is most likely.
