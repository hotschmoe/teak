# Hot reload (dev builds, native)

**Status**: `teak.dev` (`Plugin`, `Loader`, `runLoader`, `typeFingerprint`). Linux; `examples/todo` is the reference (`zig build dev`).
**Source**: `src/dev.zig`, `examples/todo/src/dev_lib_{native,headless}.zig`, `dev_main.zig`, `build.zig` (`dev` step).
**Tests**: `src/dev.zig` (fingerprints), `tools/hot_reload_check.sh` (end to end: build v1, add todos over the control channel, swap in a recoloured build, then a Model-type change).

## Use

```sh
cd examples/todo
zig build dev --watch            # libapp.so + the loader; rebuilds on every source change
./zig-out/bin/todo-dev           # stable host: window, GPU, control socket; swaps libapp.so in
```
`-Dbackend=headless` builds the offscreen variant (agents / CI). Edit `app.zig`, save: the next frame is the new build, todos intact.

## What lives where

| In `libapp.so` (replaced) | In the loader's `Env` (stays) |
|---|---|
| `App`, `Runtime(App)`: view / update / layout / frame diff | the `Host` (window, input queue, control socket, effects service) |
| the Model *values* are copied across (below) | the `Gpu` (device, surface, glyph + texture caches) |

The first library creates the `Env` (`Init.host` / `Init.gpu`); every later one only starts a new `Runtime` over it, so the window never flickers and the control channel (`TEAK_CONTROL`) stays connected. The loader executable contains no teak types: just `std.DynLib` and a C ABI (`teak_dev_*`).

## The swap (between two frames)

1. Copy the changed file to a fresh name and `dlopen` it (a same-path `dlopen` returns the old mapping). The mtime must be stable for 30 ms, so a half-written file is never loaded.
2. Reject (keep running the old build) on: not a teak plugin, ABI mismatch, or a different **Host/Gpu/RunOptions fingerprint** (teak itself was rebuilt: restart the loader).
3. Start the new `Runtime` over the same `Env`. If `typeFingerprint(App.Model)` matches, `memcpy` the Model and the hover / press / focus `TransientState` from the old runtime; otherwise the new Model starts from its defaults and the loader prints `reloaded: the Model type changed, state reset to defaults`.
4. Stop the old runtime with the old code. Old libraries are never unloaded: a Model can hold slices of string literals that live in the old image.

`typeFingerprint` hashes `@typeName`, size, and recursively every field's name, offset and type (union / enum members, array lengths, optionals; pointers by type name only, so recursive types terminate; anonymous aggregates skip their compiler-numbered name). Adding, removing, renaming or retyping a field, or changing a constant that sizes an array, resets; editing `view`, `update`, `commands`, themes, colours, labels does not.

## HARDLINE argument

This is the Host layer (§2 hatch 4): the reload boundary is *outside* every pass. Between frame N and N+1 the loader replaces which code a `Runtime` value is built from; inside a frame nothing changes. `view` stays pure (it never learns it was reloaded), all state is still the Model (a byte copy of a value whose type was proven identical), no new Cmd variant, no global, no hook the App must implement, and an App that never ships a `dev_lib` is unaffected (`src/dev.zig` is only analysed when referenced).

## Limits

* Pointers inside the Model into the **old Runtime's** memory (per-frame arenas, effect buffers) dangle; a Model that holds them was already invalid across frames. Pointers into string literals are fine (old images stay mapped).
* In-flight control commands (a `wait` mid-count) and subscription timers restart; the control connection survives.
* Each image has its own copy of std globals: the loader forwards the process environment (`teak_dev_set_environ`); anything else a library reads from std process state needs the same.
* Linux only. A reload costs one leaked mapping (a few MB); restart the loader now and then.
* Native window backend: build and structure identical to headless; exercised headlessly here (no display in CI). `zig build dev` on a desktop is the manual check.
