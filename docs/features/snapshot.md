# `teak.snapshot` — LLM-readable GUI serialization

`src/core/snapshot.zig`. Re-exported as `teak.snapshot` (namespace) plus
`teak.SnapshotOptions`, `teak.SnapshotHeader`, `teak.writeSnapshot`,
`teak.snapshotAlloc`, `teak.expectSnapshot`.

## Why

A Teak frame is *fully* described by the `[]Cmd` + `[]Rect` (+ optional
`TransientState`) triple: the command buffer is what `view` emitted, the
rects are what layout resolved, and the transient state is the
hover/press/focus overlay. That triple already **is** the ground truth of
what's on screen. `snapshot` serializes it to text so an agent developing
a Teak app can *see* the GUI as data instead of a screenshot — and so a
view can be golden-tested headlessly, with no Host and no GPU.

The serializer is **pure, deterministic, and allocation-free** (writes
through a caller-provided writer). No pointers, no timestamps, no clock
reads — the same triple always produces the same bytes. Any time-varying
context (frame counter, last-msg name) is caller-supplied via the header.

## API

```zig
pub fn write(writer: anytype, cmds: anytype, rects: []const Rect, opts: SnapshotOptions) !void
pub fn snapshotAlloc(allocator, cmds, rects, opts) ![]u8      // caller owns the slice
pub fn expectSnapshot(cmds, rects, opts, expected: []const u8) !void  // golden-test helper

pub const SnapshotOptions = struct {
    transient: ?*const TransientState = null,  // adds [hover]/[press]/[focus] by cmd index
    header: ?Header = null,
};
pub const Header = struct {
    window_w: f32 = 0,
    window_h: f32 = 0,
    frame: u32 = 0,
    last_msg: []const u8 = "",
};
```

`cmds` is any `[]const Cmd(Msg)` — taken as `anytype` like the layout
passes, since only Msg-independent fields are read. `rects[i]` pairs with
`cmds[i]`; a short `rects` slice yields zero-rects for the tail rather
than erroring (mirrors the layout/render pairing contract).

## Format spec

One line per cmd. `pop_*` cmds are **not** emitted — they only dedent.
Each open container (`push_group` / `push_scroll` / `push_overlay` /
`push_virtual_list`) indents its children two spaces. Every line is:

```
<tag> (x,y,w,h) <salient payload> <markers>
```

- **Rect** `(x,y,w,h)` — integers (rounded from f32), so sub-pixel jitter
  never changes the bytes and diffs stay small.
- **Salient payload** per tag:

  | tag | payload |
  |-----|---------|
  | `group` | `vertical` / `horizontal`; ` bg` when a fill is set |
  | `scroll` | direction; `scroll_x=N` / `scroll_y=N` when non-zero |
  | `overlay` | `layer=1` (the single non-base z-layer); ` [modal]` when set |
  | `virtual_list` | `total=N extent=M visible=[start,end)` |
  | `text` | `"content"` |
  | `rich_text` | `"content"` (flattened — spans index into it) |
  | `image` | `handle=N` |
  | `button` | `"label"`; ` [disabled]` |
  | `text_input` | `"content" cursor=N`; `sel=[lo,hi)`; ` [disabled]` |
  | `checkbox` | `[x]` / `[ ]` then `"label"` |
  | `radio` | `(o)` / `( )` then `"label"` |
  | `slider` | `value=0.NN` (2 decimals) |
  | `divider` | (rect only) |

- **Markers** (only when `opts.transient` is set), appended in a fixed
  order for determinism: ` [hover]`, ` [press]`, ` [focus]` — for the cmd
  whose index matches `hover_index` / `press_index` / `focus_index`. A
  focused text input therefore shows `[focus]` iff `focus_index` points at
  it; there is no separate per-widget focus flag.

Strings are double-quoted with control chars escaped (`\n`, `\t`, `\r`,
`\"`, `\\`), so a multi-line label can never break the one-line-per-cmd
invariant.

An optional header line precedes everything when `opts.header` is set:

```
window=800x600 frame=1 last_msg=inc
```

### Example

```
window=800x600 frame=1 last_msg=inc
group (0,0,800,600) vertical
  group (8,8,196,36) horizontal
    button (8,8,60,36) "Help"
    button (76,8,60,36) "+"
    button (144,8,60,36) "-"
  text (8,52,80,20) "Count: 0"
  text_input (8,80,784,512) "name" cursor=4
```

(The `text_input` fills the remaining vertical space because inputs
default to `flex = 1`; that is exactly the kind of layout fact a snapshot
makes visible. Verbatim output of the in-file "realistic composed view
golden" test.)

Grep `button (` to list every button and where it sits; grep a label to
locate one widget; diff two snapshots to see exactly what a `Msg` changed.

## The golden-test recipe

This is the canonical way to test a `view` with no Host — **view →
layout (mono measurer) → snapshot → compare**:

```zig
test "my view golden" {
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();

    var m: Model = .{};
    view(&m, &cb);

    var rects: [64]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(
        rects[0..cb.cmds.items.len], cb.cmds.items,
        800, 600, teak.monoMeasurer(),   // stub 10px/char, 20px line — no Host needed
    );

    try teak.expectSnapshot(cb.cmds.items, rects[0..cb.cmds.items.len], .{},
        \\group (0,0,800,600) vertical
        \\  ...expected lines...
        \\
    );
}
```

`expectSnapshot` is styled after `std.testing.expectEqualStrings`: on a
mismatch it prints a readable line-level diff and fails the test. Because
the mono measurer is deterministic and Host-free, the golden is stable
across machines. A real end-to-end example lives in the
`counter_greeter` test suite ("app: snapshot golden — real view at a
fixed Model").

To capture a fresh golden after an intentional view change, dump the
actual once with `snapshotAlloc` + `std.debug.print`, eyeball it, and
paste it back into the multiline literal.

## How an agent should use this

**Today (headless golden tests).** When you build or modify a Teak view,
add/refresh an `expectSnapshot` golden. The one-line-per-widget format
means a behavior change shows up as a small, reviewable diff — you assert
the *entire* screen as one text block, catching layout regressions,
missing widgets, wrong labels, and stale state without a single
screenshot. Pass `.{ .transient = &ts }` to also assert hover/press/focus,
and `.{ .header = ... }` to pin window size / frame / last-msg for
context.

To "see" the current GUI while iterating: lay the view out and print
`snapshotAlloc` — the text tells you what's on screen and where.

**Live `TEAK_SNAPSHOT` streaming (implemented).** `teak.run` mirrors the
current frame's snapshot to a file so an agent driving a *running* app can
observe live state transitions — click a button in the app, the file
changes, the agent greps the diff. Data out, not pixels. The pure
serializer above is the foundation; `run` just drives it each changed
frame.

### Enabling it

Two ways, env wins:

```zig
// Explicit, in code:
try teak.run(App, gpa, &host, &gpu, .{ .snapshot_path = "/tmp/app.snap" });
```

```sh
# Or from the environment — overrides the option, read once at run() start:
TEAK_SNAPSHOT=/tmp/app.snap zig build ui
```

Then, from anywhere, read the live GUI as text:

```sh
cat /tmp/app.snap        # the whole screen, right now
grep 'button (' /tmp/app.snap   # every button and where it sits
```

The file is the exact `snapshot.write` output — the same grep-able,
one-line-per-widget format documented above, with a header line
(`window=WxH frame=N last_msg=<tag>`). `last_msg` is the `@tagName` of the
last `Msg` `run` dispatched, so a diff tells you both *what changed* and
*which transition caused it*.

### Guarantees

- **Atomic.** Each frame is written to `<path>.tmp` then renamed over
  `<path>`, so a reader never observes a torn or half-written file.
- **Change-gated.** The file is rewritten only when the frame content
  actually changes — `run` reuses the same primary frame-diff signal
  (`cmds` / `rects` / transient hover-press-focus) that gates its vertex
  rebuild, minus the cosmetic cursor-blink tick (which the snapshot
  doesn't show). Idle frames never touch disk. The very first frame and
  any secondary-window open/close transition also force a write. (You can
  confirm no idle rewrite happened by reading `frame=N` in the header: it
  stamps the frame of the *last content change*, not the latest idle
  frame.)
- **No per-frame allocation.** The serialization buffer is reused across
  frames, bulk-managed like the vertex/text upload lists.
- **Fail-safe.** If the path can't be opened or written, `run` logs one
  `std.log.warn` and disables the sink for the rest of the run. A broken
  snapshot sink never crashes or slows the app.

### Secondary windows

If the app has a secondary window open (`secondaryWindow` / `secondaryView`),
its snapshot is appended below the primary's under a marker line:

```
window=800x600 frame=12 last_msg=open_stats
group (0,0,800,600) vertical
  ...primary widgets...
=== secondary "Stats" ===
group (0,0,360,200) vertical
  ...secondary widgets...
```

### wasm / freestanding

The sink is gated on the target having a host filesystem, so a
`wasm32-freestanding` build compiles it out entirely (the web backend
hand-rolls its own loop and never calls `teak.run` anyway). The pure
serializer in `src/core/snapshot.zig` stays available on every target for
the headless golden loop above.

### How `run` writes without libc or a threaded `Io`

`run` is generic host-loop glue with a fixed signature — it has no `Io`
handle threaded in and cannot assume the consumer links libc. So the sink
routes its file writes and its `TEAK_SNAPSHOT` read through
`std.Options.debug_io` / `std.Options.debug_threaded_io`, the
globally-available diagnostic `Io` std itself uses. This keeps the feature
working in every build that reaches `run` — including the library test
runner, which links no libc — with no change to the `teak.run` signature.
```
