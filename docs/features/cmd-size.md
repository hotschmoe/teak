# Cmd size: moving large payloads out-of-line

Status: **implemented.** Large payloads (`push_group`, `push_overlay`, `button`,
`text_input`, `text_area`, `checkbox`, `radio`, `slider`, `canvas`, `scene3d`) are
held as `*const T` into the per-frame arena; `Cmd` shrank from 480 B to 72 B. The
emitters build them through `CmdBuffer.box(.tag, payload)` (arena-only, no
per-widget free); `Cmd.eql` follows those pointers so the frame diff compares
content, never addresses. Measure with `zig build bench`. The numbers below are
from the design prototype (`bench-cmdsize`, since removed).

## Why look at it

`@sizeOf(Cmd(Msg)) == 240`. The union is as big as its largest payload
(`text_input` 232 B, `button` 224 B, `scene3d` 184 B, `push_overlay` 116 B,
`checkbox`/`radio` 112 B, `push_group` 92 B), but a typical frame is dominated
by tiny cmds: `pop_group` is 0 B of payload, `text` 48 B. Every pass streams
the whole `[]Cmd`, so a 50k-row screen (250k cmds) is a 60 MB buffer, and
most of each 240-byte slot is padding for the rare big variant.

A symbolised `perf` profile of `zig build bench` (50k rows, ReleaseFast;
`perf record` + `nm`, mapping file offset + 0x1010000 to vaddr):

| function | share of CPU |
|---|---|
| `run.cmdsEqual` | 27.5% |
| `render.build.buildLayer` | 25.1% |
| `LayoutEngine.doLayout` (+ `placeChild`, `pushChildren`) | 12.1% (+6.7%) |
| `hit_test.hitTestLayer` | 8.7% |
| `ArrayList(Cmd).append` (emit, 240 B copy) | 7.3% |

The first, fourth and fifth are pure streaming over cmd memory.

## The idea

Keep the union inline only for variants whose payload is <= 64 B (`text`,
`rich_text`, `image`, `push_scroll`, `push_virtual_list`, `divider`,
`pop_*`); store the rest (`push_group`, `push_overlay`, `button`,
`text_input`, `checkbox`, `radio`, `slider`, `canvas`, `scene3d`) in the
per-frame arena and hold an 8-byte `*const T` in the union. Result: **72 B**
per Cmd (3.3x smaller; a stricter ~64 B needs `rich_text`/`image` out too).

HARDLINE check: still a flat tagged-union buffer, arena-only, no fn pointers,
no identity; the pointer is a per-frame arena address exactly like the
`[]const u8` slices already inside `text`/`button`.

## Prototype numbers

`zig build bench-cmdsize`, ReleaseFast, aarch64, mix of `push_group`, `text`,
`button`, `pop_group` (ms per pass, 200k cmds; arena allocation included in
emit; slim equality has no memcmp fast path, so it is conservative):

| pass | fat (240 B) | slim (72 B) | speedup |
|---|---|---|---|
| emit (append) | 6.7 | 3.7 | 1.8x |
| tag walk (hit-test shaped) | 0.98 | 0.85 | 1.15x |
| frame diff (equal buffers) | 9.0 | 3.0 | 3.0x |

At 40k cmds: emit 1.43 -> 0.83, walk 0.17 -> 0.12, diff 1.84 -> 0.61. At 4k
cmds (L2-resident) the gap closes, as expected for a bandwidth effect.

## Estimated win on the real pipeline

From the bench table (50k rows, 33.5 ms/frame total): diff 8.5 -> ~3 ms,
the `append` share of view 4.3 -> ~2.5 ms, and the layout/hit/render passes
read 3.3x fewer bytes per cmd (they additionally chase one pointer for big
variants, so assume only 10-25% off their ~19 ms). Estimate: **~33 ms ->
~23-25 ms (-25..30%) at 50k rows; ~0 at <= 1k rows** (everything fits in
cache; the whole frame is < 1 ms there). Memory per 250k-cmd frame: 60 MB ->
~18 MB inline + ~14 MB arena payloads.

## Costs and risks

* Source churn: every construction site (`cb.cmds.append(.{ .button = ... })`,
  tests with Cmd literals) and every pass that copies a payload by value.
  Captures such as `.button => |b|` keep working with `b.msg` (auto-deref).
* `core/eql.zig` follows `.one` pointers only for a dedicated `Boxed(T)` type
  (struct wrapping the pointer with an `eql` decl), so app `Msg`s keep
  address semantics. The mutation test (`run_test.zig`) covers it unchanged.
* One arena allocation per big widget (bump pointer: ~ the same cost as the
  240-byte copy it replaces, see emit above).
* Locality: a pass that touches the payload of *every* cmd (render) trades a
  sequential stream for pointer chasing into an arena that was also written
  sequentially, so prefetch still works; measure before committing.

## Recommendation

Worth scheduling only if 10k+ row screens (tables, logs, virtual-list-free
dumps) are a goal; for typical UIs (<= 1k cmds) the frame is already well
under 1 ms. If scheduled: land it as one PR that touches only `cmd.zig`, the
emitters and `deepEql`'s `Boxed` hook, with `zig build bench` before/after.
