# Commands, shortcuts and the command palette

**Status**: `pub` in `src/teak.zig` as `Command`, `CommandList`, `CommandPalette`, `PaletteViewOpts`, `Key`, `Chord`, `ShortcutPlatform` (the rest under `teak.commands`).
**Source**: `src/core/commands.zig`, `src/input/keys.zig` (`Key`, `Chord`), `src/platform/input_queue.zig` (`pushShortcut`), hooks in `src/run.zig` (`routeChords`), host key maps in `x11.zig` / `win32.zig` / `wasm.zig`.
**Tests**: `src/core/commands.zig`, `src/input/keys.zig`, `src/platform/input_queue.zig`, `src/run_test.zig` ("commands: ..."), `examples/kerf_viewer` (palette + shortcuts).

## The table

An App declares what it can do as data, a pure function of the Model:

```zig
pub fn commands(m: *const Model, list: *teak.CommandList(Msg)) void {
    const C = teak.Chord;
    list.add(.{ .id = "file.save", .label = "Save", .shortcut = C.ctrl(.s), .enabled = m.dirty, .msg = .save });
    list.add(.{ .id = "palette", .label = "Command Palette", .shortcut = C.ctrlShift(.p),
                .alt_shortcut = C.ctrl(.k), .hidden = true, .msg = .{ .palette = .focus } });
}
```

`Command(Msg)`: `id` (stable), `label`, `shortcut` / `alt_shortcut` (stored by value: a slice of a temporary would dangle), `enabled`, `hidden` (kept out of the palette), `msg`. A command is a Msg: running it dispatches `msg` through `update` (HARDLINE: no callbacks). `Chord.mod` is the platform's primary modifier (Ctrl on Windows/Linux/X11, Cmd on macOS where the host folds it), so one table serves every platform; `Chord.format(w, .pc | .mac)` prints "Ctrl+Shift+P" / "Cmd+Shift+P".

## What `teak.run` does

Hosts report `InputState.chords`: a Ctrl- or Alt-modified key, or an F-key, in addition to the usual `chars` / `keys` (Ctrl+C is both `keys = [.ctrl_c]` and `Chord{ .c, .mod }`). Before any widget key handling, the loop matches each chord against the **enabled** rows (rebuilding the table after each dispatch) and dispatches the match. A claimed chord's text and its overlapping special key (`Chord.special()`: Ctrl+A/C/X/V/Y/Z, word jumps, plain F12) are **swallowed** for that frame, so Ctrl+S never reaches a focused text field. Unclaimed chords change nothing.

## Menus

`Command.menuLabel(arena, platform, column)` gives "Save    Ctrl+S" for a single-string menu row; `Command.primaryShortcut()` and `Chord.format` give the text for a menu item's own shortcut column (e.g. a menubar item's `.shortcut`). Build the menu from the same table and the shortcut shown is the shortcut that works.

## Command palette

`teak.CommandPalette(cap)`: a modal overlay with a query field and the enabled, non-hidden commands fuzzy-filtered (in-order subsequence, case-insensitive, spaces ignored), each row "label ... shortcut". Built on `Combobox` (same Model / Msg / update; `.focus` opens it, `.select(i)` carries the palette option index), zero new Cmd variants. Wiring, as in `examples/kerf_viewer`:

```zig
const Palette = teak.CommandPalette(24);
// Model: palette: Palette.Model = .{}, win: [2]f32       Msg: palette: Palette.Msg, palette_run: usize
.palette => |pm| Palette.update(&m.palette, pm),
.palette_run => |i| { Palette.update(&m.palette, .close); /* rebuild list */ if (list.paletteCommand(i)) |c| update(m, c.msg); },
// hooks: while open, route chars/keys to the palette
pub fn keyCharMsg(m, c) ?Msg { if (m.palette.open) return .{ .palette = Palette.charMsg(c) }; ... }
pub fn keySpecialMsg(m, k) ?Msg { if (m.palette.open) { ...Palette.keyMsg(&m.palette, k, &list, .{}) -> .select(i) => .{ .palette_run = i } } ... }
// view, last:   Palette.viewPalette(&m.palette, cb, &list, .{ .focus, .close, .selectMsg }, .{ .window_w, .window_h });
```

Matches stay in table order (no ranking): put frequent commands first.

## Agents

The control channel has `{"cmd":"shortcut","chord":"ctrl+shift+p"}` (injects a chord through the host, matched by `commands` like a real key press).

## Limits

Two shortcuts per command. Shortcuts name physical keys (US-layout punctuation); Shift-modified punctuation and AltGr combinations are not reported. Win32/X11/web only report chords while the window has focus.
