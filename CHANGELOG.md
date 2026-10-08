# Changelog

## Unreleased

### Core cleanup (idiomatic Zig + silent-failure hardening)

- **Frame diff is derived by reflection.** `cmdsEqual` now uses the generic
  `core/eql.zig` `deepEql` over `Cmd(Msg)` (slices by content, floats bitwise,
  `Msg` deep-compared): a new `Cmd` field can no longer be forgotten. Tests
  mutate every leaf of every variant. `SceneCmd.eql` is removed (breaking, but
  `deepEql` covers it); `CanvasPrimitive.eql` stays (revision-`key` shortcut).
- **Every pass is exhaustive over `Cmd` tags** (no `else =>`): a new variant
  fails to compile in layout, hit-test, focus, render, snapshot, a11y and
  scroll extent. The CLAUDE.md/AGENTS.md widget checklist is shortened.
- **OOM policy:** allocation `catch unreachable` (UB in release) replaced by
  `core/oom.zig`'s `oom()`, a `@panic` in every optimize mode. Emitters stay
  non-error-returning.
- **Loud capacities:** `MAX_BALANCE_DEPTH` 32 -> 64 (layout stacks and
  `ClipStack`). Stack overflow/underflow, `pushFormRow` nesting past 8 and a
  stray `popFormRow` now `@panic` in every mode. `teak.run` runs
  `validateBalance` every frame in every mode (was Debug only) and panics
  naming the offending cmd index. The resource table logs once when full
  (`Table.overflowed`).

### Changed (breaking)

- **Zig 0.17.0 is now required; 0.16 support is dropped.** See
  [docs/migration-0.17.md](docs/migration-0.17.md).
  - Array/string `**` repeats replaced with `@splat` (library, examples, tests).
  - Comptime component composition (`Components`, `ComponentList`) and the
    build-time web-font table use the parallel-array `@typeInfo` layout.
  - `@cImport` replaced by `b.addTranslateC` modules `wgpu-c` and `stb-c`,
    wired up in `linkNativeWgpu`, `linkWebWgpu`, `linkHeadless` and the
    library's own test steps.
  - `b.args` replaced by `Run.addPassthruArgs()` in every example build and in
    the docs.
  - `builtin.mode` comparisons use the lowercase `.debug` spelling.
  - `rich_zig` (counter_greeter) and zunk's `webzocket` / `rich_zig` pins moved
    to their 0.17 branches.
  - CI and docs updated to Zig 0.17.0.
