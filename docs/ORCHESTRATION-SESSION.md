# Teak + zunk: 12-hour orchestration session (kickoff prompt)

> **How to use:** start a new Claude Code session in `~/github` with model **Opus 5.5** (`/model`, effort
> high), and paste everything below the line as the first message (or say "read
> `~/github/teak/docs/ORCHESTRATION-SESSION.md` and execute it"). The session orchestrates **Sonnet 5.5**
> sub-agents for about 12 hours.

---

You are the **orchestrator** for a ~12-hour engineering session on **teak**, the owner's Zig GPU UI framework
(`~/github/teak`), and **zunk**, the owner's Zig wasm/WebGPU toolchain (`~/github/zunk`). You plan, dispatch
and verify. **Sonnet 5.5 sub-agents** (Agent tool, `model: "sonnet"`) do the implementation. You stay
responsible for quality: you read diffs, run gates, look at screenshots, and decide what merges. The owner is
not watching continuously. Keep going until the time budget is spent or the work is genuinely done, then write
the final report.

## 1. Context: read these first (yourself, before dispatching anything)

1. `~/github/teak/docs/REVIEW-2026-10.md`: the strategic review (Oct 2026). Verdict: continue, positioned as
   *the small, Zig-native, LLM-drivable, GPU-accelerated (native wgpu + WebGPU-on-web) UI framework for
   tool-style apps*. It contains the measured 0.17 migration inventory (§5.1), a verified bug (§3.5), the
   feature-gap list (§3.8) and the M0–M5 roadmap (§6). This session executes M0 completely, as much of M1–M5
   as time allows, and starts a 2.5D/3D track.
2. `~/github/teak/README.md`, `llms.txt` (audit-enforced public API), `docs/HARDLINE.md` (non-negotiable
   design invariants), `docs/cookbook.md`, `docs/pitfalls.md`, `spec.md`, `tasks.md`, and `CLAUDE.md` / `AGENTS.md` if present.
3. `~/github/zunk/README.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`.
4. Open issues: `gh issue list -R hotschmoe/teak` (#1, #2, #4–#8) and `gh issue list -R hotschmoe/zunk`.
5. Dogfood reference: the Kerf app built on teak in one day lives in the kerf repo at tag
   `archive/bakeoff-2026-10-05`, path `apps/teak/` (`git -C ~/github/kerf show archive/bakeoff-2026-10-05:apps/teak/NOTES.md`).
   Its gaps (single-line chat input, raw-JSON inspector, no native clipboard or file picker) are this
   session's acceptance targets. The Kerf engine itself (Zig) is `~/github/kerf/engines/zig`. Its mesh and
   drawing JSON outputs are good real-world content for widget and 3D demos.
6. The owner's earlier stack notes: `~/github/stack-strategy-teak-rust-numen.md`.

## 2. Goals (in priority order; all three run in parallel tracks)

**A. Clean up, idiomatic Zig, optimize.** Zig **0.17** (installed at `~/tools/zig-aarch64-linux-0.17.0/zig`;
0.16 stays at `~/tools/zig-aarch64-linux-0.16.0/zig`; std source in each `lib/std`. Read std instead of
guessing APIs). Migrate teak + zunk + the owner's deps `rich_zig` and `webzocket` (both are owner repos under
`hotschmoe/`, also checked out in `~/github/`) to 0.17 idiomatically: no long-lived compat shims except the
review's isolated reflection shim if it's still needed. **Windows ARM64:** the owner develops teak on a Windows ARM64 (Snapdragon X Elite) machine, using the
x86_64 `zig.exe` under emulation because Zig 0.16's aarch64-windows compiler segfaults (see `CLAUDE.md` and
`docs/zig-016-win-arm64-crash.md`). The 0.17 release notes say the LLVM bug breaking aarch64-windows binaries,
including the compiler, has been worked around. Verify that on a GitHub `windows-11-arm` runner, with the compiler
running natively and an optimized teak example running. If it holds, drop the workaround from `CLAUDE.md` and the
docs. Update every "Requires Zig 0.16" reference to 0.17.

Then a code-quality pass:
- error handling instead of `catch unreachable`
- checked casts
- allocator discipline
- comptime tables instead of hand-maintained lists (e.g. the review's `cmdsEqual` and the 9-place widget checklist)
- dead code
- `zig fmt`
- naming per the Zig style guide
- doc comments on the public API

Profile and optimize the hot paths (layout, text, render submission, web glue size). Measure before and after.

**B. Fix every known bug and fill gaps. The rule: if you see it, fix it.** Do not defer fixes you discover.
If an agent finds a bug outside its task, it either fixes it in the same PR (if small and in its area) or
reports it to you, and you dispatch a fix immediately. Known list to start from:
- the silent 256-text-run cap (review §3.5, native and web)
- one GPU texture per string (move to a glyph atlas)
- `publishA11yTree` never called
- X11 clipboard and file drop (#4)
- Win32 effects, headless host and letter-spacing (#5)
- UTF-8 `TextField`, Home/End/Delete and word jumps, multi-line text area (#6)
- X11 IME and image-cache eviction (#7)
- flex shrink and text wrap (#8)
- dropdown/picker (#2)
- indexed focus in `ComponentList` (#1)
- wgpu-native v25 → current (v29)
- CI is Linux-only

Close the GitHub issues you fix (reference the PR).

**C. Mature it for real users: feature parity with established UI frameworks, higher definition, more tooling and features.** Benchmark the feature set against egui, Dear ImGui, iced, Slint and Flutter for *tool-style apps*, and close the gaps that matter:

- **Text (M1, the make-or-break milestone):**
  - a real text engine: shaping (at least kerning and ligatures for Latin; a pluggable shaper interface), wrapping, bidi-safe cursor movement
  - multi-line `TextArea` with selection, clipboard, undo/redo and IME
  - mouse caret and selection
  - rich text spans
  - a glyph atlas with SDF or MSDF for crisp scaling
- **Higher definition:**
  - HiDPI and per-monitor scale factors
  - MSAA or analytic AA for vector shapes
  - crisp text at any zoom (SDF/MSDF atlas)
  - rounded rects, borders, shadows and gradients done in the shader
  - a theme and token system that can still express the retro look Kerf uses (`~/github/kerf/spec/DESIGN.md`)
- **Widgets:**
  - virtualized lists and tables (100k rows), tree, tabs, menus/menubar, context menu, dialog/modal, tooltip,
    dropdown/combobox, slider, checkbox, radio, toggle, number field, color picker, progress, split panes and
    docking basics, scroll areas with momentum, drag and drop, toast/notifications, a date field if cheap
  - charts are a stretch goal (the canvas already exists)
- **Interaction:** focus management and keyboard navigation everywhere, shortcuts/commands, animations and
  transitions (a time-based `Msg`, keeping HARDLINE: no hidden state), cursor shapes, file pickers
  (native + web), clipboard (text + image).
- **Accessibility (M3):** a11y tree published on every platform that has a bridge; web DOM mirror wired; roles,
  labels and focus order.
- **Platforms (M4, as time allows):** Wayland backend, macOS (wgpu Metal) backend. CI on Linux + Windows + web
  (headless Chromium WebGPU) at minimum; macOS if runners allow.
- **Tooling (M5, LLM-native developer experience is teak's differentiator, so invest here):**
  - a dev inspector overlay (widget tree, layout boxes, Msg log, frame timings)
  - time-travel and replay of Msg streams
  - `TEAK_SNAPSHOT` / `zig build shot` extended to a **visual regression suite** with golden PNGs
  - an **MCP server or CLI** that lets an LLM agent drive a running teak app (list widgets, click, type, read state, screenshot)
  - hot reload if feasible
  - an example gallery app showcasing every widget (native + web)
  - `llms.txt` kept audit-green and expanded with recipes

**D. Start the 2.5D / 3D track (one dedicated agent, then more if it goes well).**

Design a `teak.scene` 3D layer that composes with the 2D command buffer and keeps HARDLINE: scene state lives
in `Model`, and `view` emits declarative scene commands. The repo already has `examples/scene3d` and zunk's 3D
surface (depth, indexed/instanced draws, MSAA, offscreen readback) from zunk PR #18.

**Milestone 1, a `Viewport3D` widget:**
- meshes (indexed, instanced), flat and Lambert materials, feature-edge lines
- orbit/pan/zoom camera with ortho and perspective
- picking (ID buffer readback) and a section-cut plane with caps
- a grid and an axis gizmo
- native + web

Acceptance: render a Kerf mesh JSON (`kerf mesh <doc>` from `~/github/kerf/engines/zig/zig-out/bin/kerf`, or the
goldens under `~/github/kerf/engines/zig/tests/golden/*/mesh.json`) with orbit, pick and cut, in a teak example.

**Milestone 2 (2.5D):** a layered 2D-in-3D canvas (tilted planes, sprites, depth sorting) for diagram and CAD
use. Write the design in `docs/features/scene.md` first and get it right before scaling up.

## 3. Operating rules

- **Concurrency:** run about 4–6 Sonnet agents at a time on independent areas. Give each agent its own git
  worktree (`isolation: "worktree"` or explicit `git worktree add`) and its own branch, so they never collide.
  Define file ownership in every brief, and serialize work that touches the same core files (`core/`,
  renderer, `component.zig`). Prefer a pipeline: when an agent finishes, verify and merge, then dispatch the
  next.
- **Briefs** must be self-contained:
  - context and links to the docs above
  - the exact scope and file ownership
  - acceptance criteria and the gates
  - the "fix what you see" rule
  - git rules (branch, small commits, no force-push)
  - reporting format (≤ 20 lines)
- **Gates for every merge** (keep a script, e.g. `tools/gate.sh`, that runs them all):
  - teak: `zig build test`, `zig build test-wasm`, `zig build audit` (llms.txt/HARDLINE), `zig build test-gpu`
    where a GPU is present (this box has Mali via Vulkan; headless WebGPU uses SwiftShader), and every
    example's `zig build` + `zig build web`
  - zunk: `zig build test`
  - `zig fmt --check`
  - **visual check:** you or the agent must LOOK at screenshots (`zig build shot` native, and headless
    Chromium for web: `~/github/kerf/tools/shot.mjs --webgpu`, see `~/github/kerf/tools/README.md` for the
    flags) of every changed example
  - performance numbers where relevant
  - Windows cross-compile `-Dtarget=x86_64-windows-gnu`
- **Git and GitHub:** work on branches and open PRs with `gh pr create`. Merge after the gates pass and you've
  reviewed the diff (`gh pr merge --merge --delete-branch`). The owner authorizes you to merge your PRs to
  master/main in teak, zunk, rich_zig and webzocket for this session, and to push branches and close
  issues. Never force-push master, never rewrite published history, never delete branches you didn't
  create. Every commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` (or
  Opus for your own commits).
  - teak depends on zunk by path (`../zunk`), and CI checks zunk out as a sibling. Merge zunk changes first
    when teak depends on them.
  - Once the 0.17 deps are released, pin `rich_zig`/`webzocket` by commit hash in `build.zig.zon`.
- **HARDLINE:** `docs/HARDLINE.md` is the design contract. A change that needs a new escape hatch or an
  invariant change must be argued in the PR and recorded in HARDLINE (the review notes hatches 7 and 8 were
  added recently). Don't silently drift into retained-mode or React patterns.
- **Public API:** keep `llms.txt` audit-green. Breaking API changes are allowed when they're clearly better,
  but each one gets a short migration note in `docs/` and a CHANGELOG entry.
- **Quality bar:** idiomatic Zig 0.17, tests for every fix and feature, no TODO left for something you could fix
  now, deterministic rendering for golden tests, and screenshots that look professional.
- **Kerf compatibility:** the Kerf teak app (archive branch) is the dogfood target. Toward the end, restore it
  as `examples/kerf_viewer` or a similar teak example. It should load Kerf drawing and mesh JSON fixtures
  and show section, iso and 3D with a multi-line chat/notes area. That's the proof the framework can carry a
  real tool app. Don't modify the kerf repo itself.

## 4. Suggested plan (adapt as you learn)

| Hours | Work |
|---|---|
| 0–1 | You: read context, run all gates on master, record a baseline (test counts, wasm sizes, frame times, screenshot set) in `docs/SESSION-2026-10.md`. Dispatch: (1) 0.17 migration of webzocket + rich_zig + zunk → teak, reusing the review's inventory; (2) CI expansion (Windows + web + 0.17 jobs); (3) 256-run cap + glyph atlas design spike. |
| 1–4 | After 0.17 lands, run parallel tracks: text engine (M1) · bug/issue sweep (#1, #2, #4–#8, a11y wiring) · cleanup/idiom/perf pass over `core/` and the renderer · tooling (inspector overlay + visual regression suite) · 3D `Viewport3D` design doc and first slice. |
| 4–8 | Widgets wave (virtual list/table, menus, dialogs, dropdown, tabs, tree, sliders, split panes) · HiDPI/MSAA/SDF polish · wgpu-native upgrade · MCP/agent-driver tool · 3D milestone 1 completion. |
| 8–11 | Platforms (Wayland, then macOS if feasible) · a11y wave · example gallery (native + web) · `examples/kerf_viewer` dogfood · 2.5D start · docs (cookbook, llms.txt, HARDLINE updates). |
| 11–12 | Stabilize: full gate run on every platform you can, final screenshots, release notes/CHANGELOG, tag a teak release if the owner's versioning allows (check how releases are cut; otherwise leave tags to the owner), and write the final report. |

Every ~2 hours, append a checkpoint to `docs/SESSION-2026-10.md`: merged PRs, gate status, metrics vs
baseline, screenshots, decisions, and what's next. Commit it.

## 5. Final report (end of session)

Finish `docs/SESSION-2026-10.md` with:
- an executive summary
- before/after metrics (tests, LOC, wasm and native sizes, frame times, platforms)
- merged PRs and closed issues
- the feature-parity matrix vs egui/ImGui/iced/Slint/Flutter (✓/partial/✗)
- screenshots (gallery and kerf_viewer, native + web)
- the 3D track status
- remaining risks
- a recommended next session plan

Also post a short summary as the final message in the session.
