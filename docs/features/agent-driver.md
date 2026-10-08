# Agent driver: control channel, record/replay, inspector

**Status**: `pub` as `teak.control`, `teak.input_record`, `teak.inspector`, `teak.headless.serve`; tool `tools/teak_drive.zig` (`zig build drive` -> `zig-out/bin/teak-drive`).
**Source**: `src/control.zig`, `src/input_record.zig`, `src/core/inspector.zig`, `src/platform/control_socket.zig`, hooks in `src/run.zig`.
**Tests**: `zig build test` (protocol end to end over a real socket, record -> replay equality, inspector panel, X11 injection when `DISPLAY` is set).

Three tools that let a coding agent (or a shell script, or CI) *use* a running teak app instead of guessing from source: read the GUI as text or pixels, operate it through the real input path, replay a session deterministically, and see why the layout looks the way it does.

## 1. The control channel

Opt-in, one socket per app. Start the app with `TEAK_CONTROL=<unix socket path>` (or `RunOptions.control_path`; env wins). The Host owns the socket (`controlListen` / `controlRecv` / `controlSend`, implemented by the headless and X11 hosts through `platform/control_socket.zig`); a Host without that surface (Win32, wasm today) simply never enables it. Protocol: one JSON object per line, one reply per command.

```
-> {"cmd":"click","selector":{"role":"checkbox","label":"milk"}}
<- {"ok":true,"target":{"role":"checkbox","index":9,"label":"buy milk","rect":[24,113.3,93.4,20]},"frame":20,"last_msg":"toggle"}
```

| command | does |
|---|---|
| `snapshot` | the frame as `teak.snapshot` text (`"snapshot":"..."`) |
| `tree` | a11y tree: `nodes:[{i,index,role,label,rect,focusable,clickable,focused,disabled,checked?,value?}]` |
| `click` / `hover` | selector (below); a click is move, press, release, settle (one frame each) |
| `type {text}` | typed characters, 32 bytes per frame |
| `key {name,count?}` | a `teak.SpecialKey` tag: `enter`, `tab`, `escape`, `backspace`, `ctrl_a`, ... |
| `scroll {dx,dy,selector?}` | wheel (positive `dy` scrolls content down) |
| `screenshot {path}` | PNG of the last frame; needs an offscreen Gpu (headless), an error elsewhere |
| `msglog {n?}` | the last Msgs as text (oldest first, `.add(\"milk\")` style) |
| `state` | the app's `debugState(*const Model, *std.Io.Writer)` hook output (error if absent) |
| `wait {frames}` / `wait {until_text,timeout_frames?}` | hold N frames / until the snapshot contains the text |
| `info`, `inspect {on?}`, `quit` | version + window size; toggle the inspector; close the app |

**Selectors**: `{"role":"button","label":"add"}` (role is an a11y role; label is a case-insensitive substring), `{"index":12}` (cmd index from `snapshot`/`tree`), or `{"x":10,"y":20}`; `nth` picks a later match. Selectors resolve against the latest frame's visible, unoccluded nodes (the same tree a screen reader sees); no match is a clean `{"ok":false,"error":...}`. Selector members may sit at the top level of the command or under `"selector"`.

Commands execute one at a time. Multi-frame commands reply after the last step's frame has been built, so the reply reflects the result.

### HARDLINE

* **No second mutation path.** Every command that changes the app injects an input event (`Host.injectInput`) into the Host's own input queue; it is polled, routed against the previous frame's layout, hit-tested and dispatched by exactly the code real input uses. Nothing here calls `update` or touches the Model.
* Read commands read what the pure passes already produced. `debugState` only receives `*const Model`.
* `control.zig` is loop orchestration (like `run.zig`): it imports pure passes and duck-types the Host/Gpu; core is untouched and has no platform imports.
* The channel keeps bookkeeping (the command in flight, a 32-entry Msg ring of formatted text); it holds no application state and is safely losable.

## 2. Record / replay

`TEAK_RECORD=<file>` (or `RunOptions.record_path`) writes the Host's per-frame `InputState` stream: one text line per frame that had input, keyed by the runtime's frame number (format in `src/input_record.zig`). Inputs, not Msgs: a Msg may borrow slices that die with its frame, and replaying inputs re-runs the real routing so a recording survives Msg changes. `TEAK_REPLAY=<file>` (or `replay_path`) feeds it back through `Host.injectInput` on the same frame numbers. On the headless Host the clock is fake (16 ms/frame), so a headless recording replays to an identical final snapshot, timers included; the test `record a scripted todo session, replay it...` asserts it. A recording made on a real Host replays the inputs but not its wall-clock timing.

## 3. `teak-drive`

```sh
zig build drive                              # zig-out/bin/teak-drive
cd examples/todo && zig build drive          # todo-drive (headless) + todo-ui (X11)
TEAK_CONTROL=/tmp/todo.sock examples/todo/zig-out/bin/todo-drive &
teak-drive --socket /tmp/todo.sock tree
teak-drive --socket /tmp/todo.sock click --role text_input
teak-drive --socket /tmp/todo.sock type buy milk
teak-drive --socket /tmp/todo.sock key enter
teak-drive --socket /tmp/todo.sock screenshot /tmp/todo.png
teak-drive --socket /tmp/todo.sock quit
```

`teak-drive help` lists every command; `launch` starts an app with a socket; exit status is 1 when the app answers `{"ok":false}`.

### MCP server: `teak-drive mcp`

Stdio JSON-RPC 2.0 (newline-delimited), MCP protocol `2024-11-05`+. Register it with a coding agent, e.g. `claude mcp add teak -- /path/to/teak-drive mcp`. Tools: `launch_app` (`example` or `binary`, `mode` headless|x11, `display`, `args`, `cwd`), `snapshot`, `tree`, `click`, `hover`, `type`, `key`, `scroll`, `screenshot` (writes a PNG and returns its path; `include_image: true` also returns the pixels as an MCP image block), `msglog`, `state`, `wait`, `quit`. `launch_app example=todo` builds `examples/todo` on first use (`zig build drive`) and finds the repo root from the binary's location (override with `TEAK_ROOT`). An app launched in `x11` mode opens a window on `$DISPLAY`; screenshots work only in headless mode.

### Making your app drivable

Headless (screenshots, CI): a 10-line `drive_main.zig` + the `drive` build step shown in `examples/todo` (`teak.linkHeadless` + `teak.headless.serve(App, Host, Gpu, gpa, .{})`). Windowed: nothing, the normal `teak.run` entry already honors `TEAK_CONTROL` on X11. To let agents read your Model, add `pub fn debugState(m: *const Model, w: *std.Io.Writer) void` to the App.

## 4. Dev inspector

`TEAK_INSPECT=1` (or `RunOptions.inspect`, the `inspect` control command, or F12 when `RunOptions.inspect_hotkey` is on, the default in Debug builds) draws a panel over the app: frame and cmd counts, view / layout / render milliseconds of the previous frame, the hovered cmd (index, rect, style dump) with a highlight outline, the widget tree (a11y roles), and the last 20 Msgs. `teak.inspector.appendInspector(cb, cmds, rects, data, opts)` is a pure function that emits ordinary overlay cmds from data the loop hands it; the loop appends it after the app's `view`, from the previous frame, and `snapshot`/`tree` over the control channel exclude it so the agent sees the app, not the tool.

**HARDLINE hatch 2 justification.** Whether the panel is shown, the Msg ring and the timings are *presentation data owned by the loop*, in the same class as `press_target`, the canvas capture and the snapshot sink: derivable-or-losable (dropping them across a frame is a cosmetic glitch), never read by `update`, `view`, layout or hit-test (the panel is appended *after* `view` and is a pure function of its inputs), written by the host loop only. It is not a new escape hatch and no `Model` field is involved. Timings are measured in `run.zig` (outside core), never in `view`, and only while the inspector is on.

