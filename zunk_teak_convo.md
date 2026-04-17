# Zunk ↔ Teak: Philosophy Friction Audit

**Date**: 2026-04-16
**Scope**: Does integrating zunk as Teak's web host cause friction with the explicit rules and philosophies set out in:
- `docs/init_convo/ui-framework-spec.md` (goals, Zig properties, LLM-friendliness)
- `docs/init_convo/ui-framework-refinement.md` (the three walls, bounded escape hatches)
- `docs/day1_recap.md` (validated scorecard, "no statics except Host" carve-out)
- `tasks.md` §5 (pitfalls), §6 (zunk co-dev), §7 (HARDLINE — keystone doc)

**Short answer**: No fundamental violation. Three well-bounded clarifications to HARDLINE are needed to bring the draft into alignment with the direction we're already committed to. Zunk becomes *an implementation of a deliberate escape hatch*, not a deviation from the spec.

---

## 1. Core invariants (HARDLINE §1) — all pass

| Invariant | Zunk interaction | Verdict |
|---|---|---|
| All app state in `Model`, no hidden widget state | Zunk exposes **input state** via shared memory. Same boundary as Win32 WNDPROC filling a queue — platform input, not widget state. Host translates → Msg. | Pass. Same shape as today. |
| Every transition is a `Msg` variant | Zunk never produces Msgs. It exposes polled inputs; the Host layer synthesizes Msgs. | Pass. |
| `view` is pure `Model → []Cmd` | Zunk sits below Host, never reaches view. | Pass. |
| Passes are independent over `[]Cmd` + `[]Rect` | Zunk is orthogonal to passes. | Pass. |
| Per-frame arena, bulk-freed | Zunk's README explicitly principles "no hidden heap growth." Harmonious. | Pass — reinforces the rule. |

---

## 2. Forbidden patterns (HARDLINE §3) — one naming collision

Four of the six listed forbidden patterns have zero zunk contact: static widget state, closures-by-fn-ptr smuggling, ID hashing for widgets, VDOM diffing, reactive signals. One real issue:

### Lifecycle hooks: widget vs. host

HARDLINE §3 draft forbids "Lifecycle hooks (`onMount` / `onUnmount`)". The intent is to forbid them at the **widget** level — React/Vue/Svelte's per-component `useEffect` creating hidden per-widget state implicitly.

Zunk has lifecycle **exports** at the **host/application** level: `init`, `frame(dt)`, `resize`, `cleanup`. That's structurally equivalent to Win32's `WinMain` + message pump + `WM_SIZE` + `WM_DESTROY` — the top-of-stack entry points a platform calls. Different layer, different semantics.

**Action**: rewrite HARDLINE §3 entry as:

> **Per-widget lifecycle hooks** (`onMount` / `onUnmount` on individual commands). Host-level entry points — `init` / `frame` / `resize` / `cleanup` — are allowed and belong to the Host escape hatch (§2, break #4).

### Handle tables — not a violation

Zunk uses integer handles for opaque JS/GPU objects (adapter, device, buffer). That's not widget-ID hashing; it's the same shape wgpu-native already uses (`WGPUAdapter` is an opaque pointer). No rule violation, no doc change needed.

---

## 3. Deliberate breaks (HARDLINE §2) — add a fourth: the Host layer

Current draft lists three bounded escape hatches:
1. Comptime component stitching
2. TransientState
3. Flat-buffer-with-stack layout

It omits the one `docs/day1_recap.md` already implicitly carved out: *"No `var` statics in `src/` except the Host layer."* That clause is load-bearing for zunk integration. Promote it to a named escape hatch:

> **Host layer** (escape hatch 4). Bounded by:
> (a) Platform-mutable state (window handles, GPU resources, input queues) is allowed **only** inside `src/host/*`.
> (b) Host must be replaceable — swapping `win32.zig` for `wasm.zig` must not require any change in `src/*.zig` above it.
> (c) No platform type leaks into the framework-facing API (no `HWND`, no `zunk.web.gpu.Handle`, no `c.WGPUDevice` in `root.zig` exports).
> (d) Framework code never imports `host/*` or `zunk.*` directly; dependency arrow points inward only.

This pre-authorizes zunk integration at the philosophy level without loosening anything. Task 3a's acceptance criterion ("swapping `win32.zig` for a stub shouldn't require touching anything in `src/*.zig` above it") already encodes (b); HARDLINE should inherit it.

---

## 4. Drift risks to pre-empt (HARDLINE §3 additions)

The *real* risk isn't that zunk's API is philosophically wrong — it's that convenience will tempt us to smuggle platform concerns upward. Three temptations worth forbidding explicitly, added as bullets under forbidden patterns:

1. **Component code importing `zunk.*` or `host.*`.** Breaks escape-hatch 4(d). Components stay platform-agnostic.
2. **`view()` reading wall-clock time** (e.g., `zunk.web.app.performanceNow()` inside view). Breaks invariant 3 (view is pure). Animation `t` values live in TransientState, advanced from `frame(dt)` at the host boundary.
3. **Leaking zunk's handle types into the `Vertex` / `Cmd` / render-pipeline API.** The wgpu backend abstraction (task 3a sub-decision) isolates this; HARDLINE should forbid the direct leak as a backstop.

---

## 5. Task 5 (pitfalls) — three zunk-specific entries

Add to `docs/pitfalls.md` when task 5 lands:

| Pitfall | Detection | Fix |
|---|---|---|
| Spin-wait in host init (`while (adapter == null) ...`) — deadlocks browser tab | Web canary: page hangs on load, no frames emitted | Move adapter/device acquisition to zunk's pre-`init` path; host runs only after device is ready |
| Zunk's 5-tier resolver silently stubs an unresolved import | Check `--report-json` in CI; fail build if any `[stub]` entries exist | Name imports per zunk's conventions; add missing ones to `bridge.js` or upstream into zunk |
| Reading `zunk.web.input` state mid-frame (after `frame(dt)` started consuming it) | Input appears to "tear" — same key registers twice in one frame or skip | Poll once at top of `frame`, snapshot to locals, never re-read |

---

## 6. Task 6 (zunk co-dev) — already clean

Task 6 as written is already harmonious with HARDLINE. The wgpu-abstraction sub-decision in task 3a is the only place philosophy and integration meet, and the rule is already there: *"narrow enough that both back it."* No changes to task 6 needed — but when drafting `docs/zunk-integration.md` (task 6 deliverable), link it to HARDLINE's new Host escape-hatch rule for traceability.

---

## 7. Cross-reference: spec goals and day-1 scorecard

- **Spec goal 1 (Zig-idiomatic)**: zunk's polling-input model + `extern fn` imports fit cleanly — no closures required, no hidden runtime. Reinforces, doesn't dilute.
- **Spec goal 3 (LLM-friendly / 4-step pattern)**: zunk is invisible to the 4-step loop (field → variant → arm → cmd). Component authoring never sees a zunk import. LLM predictability preserved.
- **Spec goal 4 (cross-platform via wgpu)**: zunk is the mechanism that turns day-1 recap's "partial" into complete.
- **Refinement walls**: untouched. Zunk doesn't interact with composition, TransientState policy, or the layout passes.
- **Day-1 "no statics except Host" carve-out**: zunk integration *depends* on this carve-out. Formalizing it as escape hatch 4 is overdue.

---

## 8. Integration logistics and "should we absorb zunk?"

### How the integration actually works

Zunk is consumed as a **Zig build dependency**, not a globally-installed CLI. Evidence from `../zunk/examples/particle-life/`:

**`build.zig.zon`** — declared like any other Zig dep:
```zig
.dependencies = .{ .zunk = .{ .path = "../.." } },   // or a git URL
```

**`build.zig`** — imports zunk and calls one function:
```zig
const zunk = @import("zunk");
// ... user builds their wasm exe as normal ...
zunk.installApp(b, zunk_dep, exe, .{});
```

**What `zunk.installApp` does** (`zunk/build.zig:54-82`): takes the consumer's wasm compile step, pulls the zunk CLI as a dep artifact via `dep.artifact("zunk")`, and wires it as a run-artifact into the build graph — one step for `zig build install` (emit `dist/`) and one for `zig build run` (emit + serve).

**Developer experience**: clone Teak, `zig build run`. Zig's package fetcher pulls zunk source, zunk's own `build.zig` compiles the zunk CLI as a dep artifact, Teak's wasm compiles, zunk CLI runs against the wasm, HTML/JS are emitted, dev server starts. One command, no global state, no PATH entries, no user-visible `zunk` command.

This is **cleaner than Rust's trunk** (user-installed CLI outside cargo). Zunk is a Zig build plugin — the cleanest integration surface Zig offers.

### Ownership clarification

Same owner (hotschmoe) for both repos. This changes the "co-dev" framing slightly:

- "Cross-linked issues" etc. still applies — it's not internal-only even if one person holds both commit bits. A future contributor reading either repo in isolation still needs the breadcrumbs.
- Upstreaming zunk PRs is automatic (same committer, same review).
- **But the priority question becomes real.** When Teak needs a zunk feature, the same person must decide whether to (a) add it as a general-purpose zunk feature, (b) hack it into Teak's `host/wasm.zig`, or (c) fork. Stated commitment: always (a). Never hack Teak-specific behavior into zunk's resolver or code generator.

**Stated goal**: Teak is the primary focus, but zunk should stand on its own two feet — as a general-purpose Zig wasm build tool for others, or at minimum as inspiration for how Zig projects can leverage comptime + WASM introspection. Teak being zunk's primary consumer is fine; Teak being zunk's only raison d'être is not.

### Why Teak should not absorb zunk's HTML/JS generation

Three reasons, in priority order:

1. **The coupling is already at the cleanest possible layer.** `zunk.installApp(b, ...)` is the whole integration. There's no "integration tax" to remove by absorbing — folding zunk in just renames the function.
2. **Mission creep against HARDLINE aesthetic.** Absorbing zunk means Teak ships a WASM binary analyzer, a 5-tier name/signature resolver, a JS code generator, an HTML generator, a dev server, a file watcher, a WebSocket live-reload protocol, and content-hashed deploy tooling. **None of that is a UI framework.** Day-1 recap's *"the framework is smaller than the OS adapter"* aesthetic dies immediately.
3. **Generalization flywheel.** Other Zig wasm projects (zunk's existing examples — `audio-demo-1`, `audio-demo-2`, `imgui-demo`, `input-demo`, `particle-life` — and any future consumers) surface resolver bugs and naming-convention gaps that Teak then benefits from for free. Absorbing zunk starves that feedback loop.

The Rust precedent is the same shape: iced doesn't absorb trunk. iced is a UI library; trunk is a web build tool; they meet at the user's `index.html` and that's it. Teak-and-zunk is structurally identical, just cleaner because Zig's build plugin model replaces the HTML handshake.

### When absorption would be right

Three criteria, any one sufficient:

1. **Zunk goes unmaintained.** No commits for 6+ months, Teak-blocking bugs left unresolved, no reasonable path to fixes. Vendor the narrow parts Teak needs (probably just the `zunk.web.gpu` shim and `zunk.web.input`) into `src/host/wasm/` and drop the dep entirely.
2. **Zunk's resolver needs Teak-specific rules that don't generalize.** If we find ourselves patching zunk's general-purpose resolver with Teak-specific hacks, the abstraction is wrong. Fix it in zunk if possible; vendor if not.
3. **Coordination cost exceeds separation value.** If keeping two repos in sync becomes more expensive than collapsing them, collapse.

**None hold today.** The right move is narrow dependency surface + upstream contributions.

### Framing commitment

> *Teak is a UI framework. Zunk is a web build toolchain. They're sibling projects because Zig makes the integration surface (a build plugin) trivial. The coupling is narrower than "wasm-bindgen + trunk + hand-written HTML" is in Rust-land — take the win, don't expand the scope.*

---

## Bottom line

Zunk doesn't challenge the TEA + K philosophy — it challenges the **completeness** of the HARDLINE draft. Three additions bring the document into alignment with the direction we're committing to anyway:

1. Disambiguate "lifecycle hooks" (widget-level forbidden, host-level allowed).
2. Add **Host** as the fourth deliberate escape hatch, with four bounds (a)–(d).
3. Add three "no leaks upward" forbidden patterns (no zunk imports in components, no wall-clock in view, no platform handle types in framework API).

With those in place, zunk becomes an implementation of escape hatch 4, not a deviation from the spec. The philosophy holds; the document just needs to admit what day-1 recap already knows: the Host layer is the one place platform reality lives, and that's fine as long as it stays there.

---

## Action items

Inputs for when task 7 (HARDLINE) is drafted:

- [ ] Add escape hatch 4 (Host layer) with bounds (a)–(d) under §2.
- [ ] Rewrite "lifecycle hooks" entry under §3 to distinguish widget-level from host-level.
- [ ] Add three "no leaks upward" forbidden patterns under §3 (imports, wall-clock in view, handle-type leakage).

Inputs for task 5 (pitfalls):

- [ ] Add the three zunk-specific pitfalls from §5.

Inputs for task 6 (zunk integration doc):

- [ ] Link `docs/zunk-integration.md` to HARDLINE escape hatch 4 once both exist.

Standing commitments for future Teak ↔ zunk work:

- [ ] Never ship Teak-specific resolution rules into zunk. If Teak needs a special resolver case, it's a general case (or a bug).
- [ ] Never fork zunk into Teak's tree. If zunk atrophies, vendor the *minimum* needed shims into `src/host/wasm/` and drop the dep entirely — don't absorb the toolchain.
- [ ] When zunk-generated code feels confusing, add to `docs/pitfalls.md` — don't absorb zunk to "fix" legibility.

Companion docs: `tasks-wasm.md` (concrete gaps), `tasks.md` (phase plan).
