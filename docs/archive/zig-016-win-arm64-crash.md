# Zig 0.16.0 Windows ARM64 Compiler Crash

**Status:** Blocker. `zig build` cannot complete on `aarch64-windows` with Zig 0.16.0 on this machine.

**Machine:** Snapdragon X Elite (Oryon CPU), Windows 11, `aarch64-windows` native host.

**Summary:** Zig 0.16.0 segfaults during compilation on any target — including a trivial `pub fn main() void {}` — whenever LLVM codegen is involved (which on `aarch64-windows` is always, since the self-hosted backend returns `UnsupportedCOFFArchitecture`). Migrating teak's source to 0.16.0 APIs can be done statically, but it cannot be verified locally until this is fixed.

## Reproduction

```zig
// test.zig
pub fn main() void {}
```

```
$ zig version
0.16.0

$ zig build-exe test.zig
warning(zcu): unexpected EOF reading cached ZIR for …\lib\ubsan_rt.zig
warning(zcu): unexpected EOF reading cached ZIR for …\lib\ubsan_rt.zig
Segmentation fault (exit 139)
```

No compile error is emitted; the process dies via SIGSEGV before any user code is analyzed.

## Symptoms

- Exit code 139 (SIGSEGV / 0xC0000005).
- Stderr consistently contains `warning(zcu): unexpected EOF reading cached ZIR for <stdlib file>` — the specific file varies across runs (`ubsan_rt.zig`, `std/std.zig`, `std/buf_set.zig`, `std/BitStack.zig`).
- Zero-byte files appear in `%LOCALAPPDATA%\zig\z\` — zig truncates the cache entry, starts writing, then crashes mid-write; the next invocation reads the truncated file as an unexpected-EOF warning and crashes again.

## What Still Works

- `zig version`, `zig env`, `zig help` — all clean.
- `zig ast-check test.zig` — clean. Parsing / AST is fine.
- Build-runner compilation (`build.exe`) — succeeds. The `build.zig` itself compiles; the segfault is downstream, inside the spawned sub-compilation.

## What Has Been Ruled Out

| Hypothesis | How it was tested | Result |
|---|---|---|
| Winget install is corrupt | Downloaded zig-aarch64-windows-0.16.0.zip directly from ziglang.org and ran from the extracted tree | Same segfault |
| 0.16.0 release has a regression fixed on master | Tried `0.16.0-dev.3153+d6f43caad` master build from ziglang.org/builds | Same segfault |
| Stale local cache (`.zig-cache`) | Deleted `.zig-cache` and rebuilt | Same segfault |
| Stale global cache (`%LOCALAPPDATA%\zig`) | Deleted the entire global cache directory | Regenerates zero-byte files on next run, same segfault |
| Multi-threaded codegen race (ziglang/zig#11871) | `zig build-exe -j1` | Same segfault; `-fsingle-threaded` also fails |
| UBSan runtime is the trigger | `-fno-ubsan-rt -fno-sanitize-c` | Same segfault |
| Target auto-detection quirk (`zig env` shows malformed `aarch64-windows.win11_dt...win11_dt-gnu`) | Explicit `-target aarch64-windows-gnu` and `-target aarch64-windows-msvc` | Same segfault |
| Debug build specific | `-O ReleaseFast` | Same segfault |
| Output writing (file locks, AV scan) | `-fno-emit-bin`, `zig build-obj` | Same segfault — crash is before emit |
| Project code triggers it | `pub fn main() void {}` in an otherwise-empty dir | Same segfault — project code is not involved |
| LLVM path specifically | `-target x86_64-linux` (uses self-hosted backend, no LLVM) | Produces a partial output file, then still segfaults during link/finalize — but the crash moves, strongly suggesting LLVM is at least one of the crashing paths |

## Likely Root Cause

A bug in Zig 0.16.0's LLVM codegen path on `aarch64-windows`. The ZIR-cache EOF warnings are a downstream symptom: zig opens a cache file for writing, truncates it, and crashes in LLVM before the write completes, leaving a 0-byte file that the next run reads and warns about.

This may be related to [ziglang/zig#11871](https://github.com/ziglang/zig/issues/11871) ("unexpected EOF reading cached ZIR when running test-cases multi-threaded") — but that issue's workaround (single-threaded) does not help here, so the underlying LLVM crash is likely the real cause rather than the cache race.

## Upstream Tracking

Already filed: **[Codeberg ziglang/zig#31865 — "0.16.0 `aarch64-windows` binary is broken"](https://codeberg.org/ziglang/zig/issues/31865)**, opened 2026-04-15 by Zig maintainer alexrp. Labeled as a regression; milestoned for 0.17.0. Triage note from marselester: x86_64→aarch64 cross-compilation works, so the native aarch64-windows bootstrap binary itself is miscompiled.

Do **not** file a duplicate. GitHub is a mirror — Codeberg is the primary tracker for 0.16.0+. If adding a comment to #31865 is ever useful, the value-add from this machine is the LLVM-codegen specificity (crash happens mid-compile, not at startup) and the ZIR-EOF cache symptom, both of which are more detailed than the summary in the original report.

## Local Workarounds

1. **Downgrade to 0.15.2** until 0.16.1 ships a fix.
2. **Cross-compile from another machine** (x86_64-windows or Linux host) targeting `aarch64-windows`.
3. Watch ziglang.org/builds/ for dev builds newer than 3153 and retest periodically.

## Static Migration Done

Even though builds can't be verified here, these 0.15.2→0.16.0 source changes have been applied to teak so the project is ready the moment a working compiler lands:

- `src/main.zig`: `std.heap.GeneralPurposeAllocator(.{})` → `std.heap.DebugAllocator(.{})`
- `src/ui_main.zig`: same rename
- `.gitignore`: added `zig-pkg/` (new 0.16.0 project-local package cache directory)

No other APIs used by teak are affected by 0.16.0's breaking changes (IO restructuring, `@Type` → specific builtins, vector indexing, packed-union restrictions, etc. — teak doesn't touch any of these).
