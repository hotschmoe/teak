# Tables and lists at scale

**Status**: `teak.DataTable`, `teak.VarList`, `teak.TreeList`, `teak.Scroller` (all `pub` in `src/teak.zig`).
**Source**: `src/core/{data_table,var_list,tree_list,scroller}.zig`, `src/layout/virtual_rows.zig`.
**Example**: `examples/tables` (100 000-row table, 20 000-message variable-height list, 99 450-node tree).
**Tests**: colocated; run-loop tests for the two new hooks in `src/run_test.zig`.

Review M2 asks for "a 100k-row table that scrolls at the display rate". The components below get there by the same
rule everywhere: **a frame costs what is visible, not what exists.** Each one keeps only *view state* in the Model, takes the rows from a
`src` value the app passes at call time, and emits only the rows in the scroll window. They add no Cmd variant: the body is
`push_scroll` + `push_virtual_list` + ordinary groups and buttons, so layout, hit-test, render, a11y and the frame diff see
nothing new (HARDLINE §1, §3).

## Scroller: smooth wheel and fling

`Scroller` is plain data (`pos`, `target`, `vel`, `max`). A notched mouse wheel moves `target` and `pos` eases toward it
(`smooth_ms`, default 70); `fling(px/s)` coasts and decays (`friction_ms`, default 325); both stop dead at the ends. Time is a Msg,
exactly like `teak.anim`: while `sc.animating()` the app lists `Sub.animation_frame` and forwards the frame time
(`animationMsg`) to `step(dt_ms)`; at rest the subscription is dropped and the run loop idles again. Frame-rate independent,
replayable from a Msg log, no clock read anywhere. `shift(d)` moves content under the reader without motion (scroll anchoring).

## DataTable

```zig
const Table = teak.DataTable(.{ .max_rows = 131_072, .max_cols = 8 });
// Model: table: *Table.Model        (the permutation arrays are ~1 MB: allocate it, do not embed it in a stack Model)
// Msg:   table: Table.Msg
// update: .table => |t| Table.update(m.table, t, Rows{})        // Rows has compare(col, a, b) and cell(arena, col, row)
// hooks:  scrollMsg(TABLE_ID) -> .wheel     scrollLayoutMsg -> .viewport      canvasMsg -> Table.gripMsg(ev, GRIP_BASE)
//         modsMsg -> .mods                  keySpecialMsg -> Table.keyMsg(key, m.table.mods)
//         animationMsg -> .frame            subscribe -> animation_frame while m.table.animating()
// view:   Table.view(m.table, cb, &columns, Rows{}, msgs, .{ .id = TABLE_ID, .grip_base = GRIP_BASE });
```

* **Sorting.** Click a header: ascending, descending, off. `order` (display to data row) and `rank` (inverse) are rebuilt by a
  *stable* block sort over `u32` indices, so equal rows keep data order in both directions and the app's rows never move.
  100 000 rows sort in a few tens of ms (one click, not per frame).
* **Selection** is a bitset by *data* row, so it survives sorting. Click selects, Ctrl-click toggles, Shift-click extends from the
  anchor (range in display order); Up/Down/PageUp/PageDown/Home/End move the cursor (Shift extends, Ctrl-A selects all, Escape clears) and
  scroll it into view. Modifier keys reach `update` through the new `modsMsg` hook (below), so a click Msg needs no payload.
* **Resizing.** Each header cell ends in a 6 px interactive canvas (`canvasInteractive`, id `grip_base + col`); a drag sends `.grip{col, dx}`.
  Widths live in the Model (`min 24 px`).
* **Sticky header** is a sibling above the scroll region, not inside it. Alignment is per column; zebra and selection colours come from
  `cb.theme.palette`.
* **Cell text** is cut with an ellipsis to the column width in *characters* (`ViewOpts.char_w`, the font's advance): use a monospace
  face. Truncation never splits a code point. (Pixel-accurate proportional ellipsis needs the layout-time `textEllipsis` of the wrap work.)
* **Cost.** `view` emits header + ~30 rows x ncols buttons whatever `n_rows` is. Type-to-search is not included.

## VarList: rows of different heights

Fixed-extent virtualization cannot place row N without knowing the rows above it. `VarList` keeps `h[i]` (measured, 0 = unknown) and
`prefix[i]` (top of row i, using an estimate for unknown rows), finds the window by binary search and emits the rows at
`start_offset = prefix[first]` inside a virtual list that claims `prefix[n]` px (`VirtualListStyle.total_extent`).

Heights come from layout, not from the app guessing: `VirtualListStyle.id != 0` makes the runtime report the emitted rows' heights
(direct children, `layout/virtual_rows.zig`) through the new `virtualRowsMsg` hook whenever they change; `update` stores them and **re-anchors**:
the scroll offset shifts by exactly the change in the top row's position, so learning that rows above the viewport are taller does not move
what the reader sees. `insert` and `remove` anchor the same way (a chat that prepends history does not jerk; appending below the viewport does nothing).
`src.row(cb, i)` must emit exactly one top-level child per row.

## TreeList

Nodes are stored by the app in depth-first preorder with a depth per node (`src.depth(node)`, `src.label(arena, node)`); a node has children
iff the next node is deeper, so no pointers are needed. The Model holds the expanded bitset and the flattened `visible[]` list, rebuilt in
`update` on toggle (one O(n) scan that skips collapsed subtrees: ~0.1 ms for 100k nodes), never in `view`. Keyboard: Up/Down/PageUp/PageDown/Home/End,
Right expands then enters the first child, Left collapses then goes to the parent, Enter toggles; collapsing an ancestor of the selection selects the ancestor.

## New runtime hooks (documented in `run.zig`)

* `virtualRowsMsg(model, id, first_row, heights) ?Msg`: measured extents of a `VirtualListStyle.id` list's emitted rows, on change.
* `modsMsg(model, mods) ?Msg`: Shift/Ctrl/Alt/Meta whenever they change, dispatched before the frame's pointer and key routing.
* `VirtualListStyle` gained `total_extent`, `start_offset` (variable-height mode), `id`, and `align_cross`.

## Numbers (examples/tables, aarch64, ReleaseFast)

`zig build shot -Doptimize=ReleaseFast -- out.png --tab table --bench` jumps the scroll offset every frame (so every frame re-emits its rows) and times
a whole `Runtime.frame` (view + layout + render + upload + submit): about 2.4 ms for the 100k-row table, 0.6 ms for the variable list, 0.4 ms for the tree.
`tools/web-frame-bench.mjs` times every rAF callback in headless Chromium (software WebGPU): see the PR for the web figures.
