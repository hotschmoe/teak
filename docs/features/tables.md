# Fixed-column tables

**Status**: `pub` in `src/teak.zig` as `table` (namespace), `Table`, `TableColumn`, `TableRowStyle`, `CellAlign`, `fitCell`.
**Source**: `src/core/table.zig`
**Tests**: colocated: `fitCell` padding / truncation / UTF-8 / ellipsis edge cases and a golden snapshot of a header + body table.

With a monospace font, columns need no pixel math: pad every cell to its column's character width and the cells line up. `teak.table` is that, as pure helpers. No new Cmd variant, no state: a row is one horizontal `push_group` of `text` cmds, so layout, hit-test and render treat it like any other view output. (Scrollbars are not here: the app draws thin bars itself from the scroll metrics the host reports.)

```zig
const parts: teak.Table = .{
    .columns = &.{
        .{ .title = "PART", .chars = 18 },
        .{ .title = "QTY", .chars = 4, .cell_align = .right },
        .{ .title = "MM", .chars = 7, .cell_align = .right },
    },
};
const head: teak.TableRowStyle = .{ .color = muted, .rule = ink };   // 1px rule under the header
const body: teak.TableRowStyle = .{ .color = ink };
const picked: teak.TableRowStyle = .{ .color = paper, .bg = ink };    // selected row

// in view():
parts.header(cb, head);
for (m.parts, 0..) |p, i| {
    const qty = std.fmt.allocPrint(cb.arena.allocator(), "{d}", .{p.qty}) catch "?";
    parts.row(cb, &.{ p.name, qty, p.length_str }, if (i == m.selected) picked else body);
}
```

## Clickable rows

`Table.row` emits plain `text` cmds, which are not interactive: **a `teak.Table`
row cannot be clicked**. Two ways to get selectable rows:

* Wrap the cells in a clickable widget yourself: emit the row as a
  `cb.buttonStyled(.{ .select = i }, label, flat_style)` with the
  monospace line you build by padding each cell with `fitCell` and concatenating
  (arena-allocated), keeping the look with a flat `ButtonStyle` (transparent `bg`, `hover_bg` = your highlight).
* For anything beyond a handful of rows, header sorting, column grips, row
  selection and scrolling, use `teak.DataTable` / `teak.VarList` /
  `teak.TreeList` ([tables-at-scale.md](tables-at-scale.md)): their `msgs.row(display)`
  Msg fires when a row is clicked.

## API

| Item | Meaning |
|---|---|
| `Column{ title, chars, cell_align }` | content width in characters; `cell_align` = `.left` / `.right` / `.center` |
| `Table{ columns, gutter = 1, ellipsis = "\u{2026}" }` | the column set + blank characters between columns + the truncation marker |
| `Table.header(cb, style)` / `Table.row(cb, cells, style)` | emit one row; `cells[i]` goes in column `i` (missing = blank, extra ignored) |
| `Table.totalChars()` | characters in a full row; multiply by the font's glyph width to size a container |
| `RowStyle{ font = mono, color, bg, rule, pad_x = 4, pad_y = 2, height = 0 }` | per-row look; use a different style per row kind (header, selected, diff add/remove) |
| `fitCell(alloc, text, width, align, ellipsis, trailing)` | the string primitive: exactly `width` columns (+ `trailing` blanks), cut with the ellipsis when long |
| `table.columns(s)`, `table.prefixBytes(s, cols)` | UTF-8 column counting |

## Behavior and limits

- **Arena strings.** `row` / `header` allocate the padded cell strings from `cb.arena` (they live until the next `reset`), like any other per-frame slice. `fitCell` returns an owned slice from whatever allocator you give it.
- **Columns are UTF-8 code points**, one column each; an invalid byte counts as one. A truncated cell never splits a multi-byte character. Wide (CJK) and combining characters are not modeled.
- **Why each cell is its own `text` cmd**: per-cell hit-testing or color stays possible, and the cell's measured width is exactly `chars * glyph width` in a monospace face, so no fixed-width groups are needed. The first `columns.len - 1` cells carry the gutter as trailing blanks.
- **Row width**: a row group stretches under an `align_cross = .stretch` parent, so `bg` spans the container; wrap a long table in a `push_scroll`.
- `monoMeasurer` counts bytes, so the default `"\u{2026}"` ellipsis measures 3 columns there; set `.ellipsis = "~"` (or `"..."`) in headless tests if you assert widths.
