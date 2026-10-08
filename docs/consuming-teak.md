# Consuming Teak from another repo

This walks from an empty repo to a working compute-and-display Teak app:
`build.zig.zon` → `build.zig` → `App` (Model/Msg/update/view) → `main`.
The goal is to get you shipping without reading three source files twice.

If you only remember one thing: **you write an `App` struct and call
`teak.run`; Teak owns the window loop.**

---

## 1. Declare the dependency

In your `build.zig.zon`, add Teak (pin a tag/commit + hash via
`zig fetch --save` so the build is reproducible):

```zig
.dependencies = .{
    .teak = .{
        .url = "git+https://github.com/hotschmoe/teak.git#<commit>",
        .hash = "...", // zig fetch --save fills this in
    },
},
```

The whole file, as `zig init` would generate it plus the Teak dependency:

```zig
.{
    .name = .myapp,                              // enum literal, not a string (Zig 0.17)
    .version = "0.0.0",
    .fingerprint = 0x0123456789abcdef,           // REQUIRED; run `zig build` once and copy the value
                                                 // the error message prints, then never change it
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        // URL form (a published teak):
        .teak = .{ .url = "git+https://github.com/hotschmoe/teak.git#<commit>", .hash = "..." },
        // or, for a local checkout, a RELATIVE path (absolute paths are rejected
        // by the package manager; use `../teak` or `../../teak`):
        // .teak = .{ .path = "../teak" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

Rules that bite: `.path` must be **relative** to the directory holding this file
(an absolute path is an error); `.fingerprint` is mandatory and must stay
stable; with `.url` you need the matching `.hash` (`zig fetch --save <url>`
writes both). Teak itself depends on `zunk` (web) by relative path, so when
you use a local checkout keep `zunk` next to it (`../zunk` from teak).

A pure-library consumer pays for nothing else. The `wgpu-native`
prebuilts are **lazy** deps of Teak — they're fetched only when you call
`teak.linkNativeWgpu` (the native UI path), never for `zig build test`.

## 2. Wire the build

Teak ships build helpers so you don't assemble platform + GPU modules by
hand. One call wires the native backend for whichever OS you target:
`teak.linkNativeWgpu` dispatches on the resolved target OS — **Windows**
(Win32 window + GDI text + `wgpu_native.dll`) or **Linux** (X11 window +
stb_truetype text + `libwgpu_native.so`), both rendering through
wgpu-native. The chosen pair is exposed under the stable import names
`teak-platform-native` / `teak-gpu-native`, so the same `ui_main.zig`
compiles on both.

```zig
const std = @import("std");
const teak = @import("teak"); // teak's build.zig is importable

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const teak_dep = b.dependency("teak", .{ .target = target, .optimize = optimize });

    // Native UI: dispatches on target OS (Win32 or X11) + wgpu. Adds the
    // teak / platform-native / gpu-native imports, links wgpu-native for the
    // target os+arch, installs the DLL (.dll) / shared object (.so).
    // Gate the `ui` step on hasNativeBackend so `zig build` configures on
    // any OS — the step is simply absent where there's no native backend.
    if (teak.hasNativeBackend(target.result.os.tag)) {
        const ui = b.addExecutable(.{
            .name = "myapp-ui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ui_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        teak.linkNativeWgpu(b, ui, .{});
        const ui_step = b.step("ui", "Run the UI");
        ui_step.dependOn(&b.addRunArtifact(ui).step);
    }

    // Pure-logic tests (no window): just import the teak module.
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "teak", .module = teak_dep.module("teak") }},
        }),
    });
    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

### Entry points, complete

Everything below is the whole file: copy it, replace `app.zig`'s `App`.
Import names are fixed by the link helpers: `teak`, `teak-platform-native` /
`teak-gpu-native` (native), `teak-platform-wasm` / `teak-gpu-web` (web),
`teak-platform-headless` / `teak-gpu-headless` (headless).

**Native window** (`src/ui_main.zig`; wired by `teak.linkNativeWgpu` above):

```zig
const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("My App", 900, 600);
    defer host.deinit();
    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 900, 600);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{});
}
```

**Web** (`src/web_main.zig`). The browser owns the frame loop (zunk calls the
three exports below), so build a `teak.Runtime` once and call `frame()` per
tick; `teak.run` is the same loop in a `while`:

```zig
const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-wasm");
const gpu_web = @import("teak-gpu-web");
const App = @import("app.zig");

/// REQUIRED: the default std.log sink does not compile for wasm32-freestanding.
pub const std_options: std.Options = .{ .logFn = platform.logFn };

const Host = platform.Host;
const Gpu = gpu_web.Gpu;
const Runtime = teak.Runtime(App, Host, Gpu);

comptime {
    teak.validateHost(Host);
    teak.validateGpu(Gpu);
}

// Exports cannot close over a struct, so the three live in module-level vars.
var host: Host = undefined;
var gpu: Gpu = undefined;
var runtime: Runtime = undefined;

export fn init() void {
    host = Host.init("My App", 900, 600) catch @panic("host init failed");
    host.activate();
    gpu = Gpu.init(host.nativeHandle(), 900, 600) catch @panic("gpu init failed");
    runtime = Runtime.init(std.heap.wasm_allocator, &host, &gpu, .{}) catch @panic("runtime init failed");
}

export fn resize(w: u32, h: u32) void {
    gpu.resize(w, h);
}

export fn frame(_: f32) void {
    runtime.frame() catch @panic("teak: frame failed (out of memory)");
}
```

and in `build.zig` (after the native block; `teak.linkWebWgpu` registers the
`web` and `web-run` steps, output in `dist/`):

```zig
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding, .abi = .none });
    const web_exe = b.addExecutable(.{
        .name = "myapp-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = wasm_target,
            .optimize = .ReleaseFast,
        }),
    });
    teak.linkWebWgpu(b, web_exe, .{}); // .{ .fonts = ..., .strip = true } are the options
```

**Headless screenshot / tests** (no display; needs a Vulkan device and a TTF).
`build.zig`:

```zig
    if (target.result.os.tag == .linux) {
        const shot_exe = b.addExecutable(.{
            .name = "myapp-shot",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/shot_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        teak.linkHeadless(b, shot_exe, .{});
        const shot_run = b.addRunArtifact(shot_exe);
        shot_run.addPassthruArgs();
        b.step("shot", "zig build shot -- out.png").dependOn(&shot_run.step);
    }
```

`src/shot_main.zig`:

```zig
const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const path = teak.headless.pathArg(init, "shot.png");
    try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
        .width = 900,
        .height = 600,
        .steps = &.{
            .{ .frames = 2 },
            .{ .click = .{ 120, 80 } },     // move, press, release (a frame between each)
            .{ .chars = "hello" },
            .{ .frames = 1 },
        },
    });
}
```

Script ordering: inside one frame the headless Host delivers all queued
**characters before special keys** (that is how a real `InputState` is shaped:
`chars` then `keys`). To interleave, put a `.frames = 1` between the steps.

> **Web logging.** The default `std.log` sink does not compile for
> `wasm32-freestanding` (it pulls in `std.Io.Threaded`), and teak itself logs
> (e.g. when the resource table is full). Every web entry point must declare
> `pub const std_options: std.Options = .{ .logFn = platform.logFn };`
> (`platform` = `teak-platform-wasm`; it forwards to `zunk.web.logFn`, which
> writes to the browser console).

> **Cross-platform note.** Native UI runs on **Win32** (Windows) and
> **X11** (Linux); the **wasm + WebGPU** path covers the browser.
> `linkNativeWgpu` `@panic`s for any other target OS, so gate the UI exe
> behind `teak.hasNativeBackend(target.result.os.tag)` (true for
> windows/linux) — then `zig build test` / `web` still configure on any
> dev box. Building the Linux UI needs **no X11 dev package** (libX11 is
> `dlopen`ed at runtime); at runtime it needs `libX11.so.6`, a Vulkan
> driver, and a monospace TTF (DejaVuSansMono by default; override with
> the `TEAK_FONT` env var). Wayland is not supported directly — X11 apps
> run under XWayland.
>
> `teak.linkWin32Wgpu` still exists as a **deprecated** Windows-only alias
> (it asserts a Windows target and forwards to `linkNativeWgpu`); migrate
> to `linkNativeWgpu`.

## 3. Write the App

An `App` is a Zig struct (a file works — `@This()` is the struct) exposing
four required decls:

```zig
const std = @import("std");
const teak = @import("teak");

pub const Model = struct { count: i32 = 0 };

pub const Msg = union(enum) { inc, dec, reset };

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .inc => m.count += 1,
        .dec => m.count -= 1,
        .reset => m.count = 0,
    }
}

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });
    cb.text(std.fmt.allocPrint(cb.arena.allocator(), "Count: {d}", .{m.count}) catch "Count: ?");
    cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 0 });
    cb.button(.inc, "+");
    cb.button(.dec, "-");
    cb.popGroup();
    cb.button(.reset, "Reset");
    cb.popGroup();
}
```

That's the whole app loop's worth of logic. `update` is the only place
`Model` changes; `view` is a pure function of `Model` that emits commands.
A `view` should start with a container (`pushGroup` / `pushScroll`) — the
layout treats the first command as the root.

> **Footgun:** dynamic strings must be built into `cb.arena` (as above),
> never a stack buffer. `std.fmt.bufPrint(&buf, …)` returns a slice into a
> local `buf` that is freed when `view` returns; the Cmd stores that slice
> and the layout / render passes read it *after* the return — a
> use-after-return. Any slice you store on a Cmd must borrow from `Model`
> or from `cb.arena.allocator()`.

### Adding a feature is mechanical

1. add a field to `Model`, 2. add a variant to `Msg`, 3. add a switch arm
to `update`, 4. add `cb.*` calls in `view`. The compiler's exhaustive
switch makes step 3 un-skippable.

## 4. Run it

`ui_main.zig` is now ~10 lines — `teak.run` is the loop every consumer
used to hand-copy:

```zig
const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-native"); // Win32 or X11, per target OS
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try platform.Host.init("My App", 900, 500);
    defer host.deinit();
    var gpu = try gpu_native.Gpu.init(host.nativeHandle(), 900, 500);
    defer gpu.deinit();

    try teak.run(App, gpa, &host, &gpu, .{});
}
```

`teak.run` handles: double-buffered command buffers, the press-target
mousedown/up dance, keyboard + wheel + clipboard routing, Tab/Shift+Tab
focus traversal, Enter-to-submit, the frame-diff that skips redundant GPU
uploads, layout, transient (hover/press/focus) state, and present.

## 5. Opt into more (optional App decls)

`teak.run` checks for these with `@hasDecl` — add only what you need. None
are required; an app without them just doesn't get that behavior.

| Decl | Signature | Enables |
|------|-----------|---------|
| `keyCharMsg` | `(*const Model, u8) ?Msg` | typed characters → Msg |
| `keySpecialMsg` | `(*const Model, SpecialKey) ?Msg` | arrows/backspace/etc → Msg |
| `keyNeedsClipboard` + `handleClipboard` | `(SpecialKey) bool` / `(*Model, SpecialKey, Clipboard) void` | cut/copy/paste |
| `wheelMsg` | `(*const Model, f32) ?Msg` | mouse-wheel scroll (when no canvas / scroll region took it) |
| `canvasMsg` | `(*const Model, CanvasEvent) ?Msg` | pan / zoom / drag over `cb.canvasInteractive` canvases — see [features/canvas.md](features/canvas.md#interactive-canvases-pan--zoom--drag) |
| `scrollMsg` | `(*const Model, id: u32, dx: f32, dy: f32) ?Msg` | wheel over a `ScrollStyle.id != 0` region |
| `scrollLayoutMsg` | `(*const Model, id, viewport_w, viewport_h, content_w, content_h: f32) ?Msg` | scroll region viewport + content size (clamp offsets, scrollbars) |
| `focusedMsg` | `(*const Model) ?Msg` | focus ring + cursor blink **and** Tab/Shift+Tab nav |
| `submitMsg` | `(*const Model) ?Msg` | Enter-to-submit |
| `themeFor` | `(*const Model) Theme` | per-frame theme (e.g. dark/light toggle) |
| `windowTitle` | `(*const Model) ?[]const u8` | dynamic title bar ("* unsaved") |
| `secondaryWindow` | `(*const Model) ?SecondaryWindowSpec` | a second top-level window (title + size), open when non-null |
| `secondaryView` | `(*const Model, *CmdBuffer(Msg)) void` | the secondary window's view (pairs with `secondaryWindow`) |
| `secondaryClosedMsg` | `(*const Model) ?Msg` | Msg dispatched when the user OS-closes the secondary window |
| `subscribe` | `(*const Model) []const Sub(Msg)` | declarative timers — `run` services them each frame via `runSubs` on `Host.nowMs()` |
| `effects` | `(*const Model) []const Effect` | declarative effects (HTTP, files, storage, clock, clipboard, query params) — see [effects.md](features/effects.md) |
| `effectMsg` | `(*const Model, EffectResult) ?Msg` | answers to effects and unsolicited drops / pastes become Msgs |
| `Model.init` | `() Model` | non-default initial state |

`teak.run` also folds the Host's IME composition snapshot into the render
pass' transient state automatically — no opt-in decl. The
`secondaryWindow` trio lets `run` own a detached window's full lifecycle
(open / render / close) from data + Msgs; see
[features/run.md](features/run.md#secondary-window). The canonical example
is `counter_greeter`'s "Stats" window.

`focusedMsg` returns the focus `Msg` of the currently-focused widget (the
same Msg that widget's focus click dispatches). Teak maps it to a cmd
index by *value* (`indexOfFocusMsg`), so focus survives conditionally
rendered or reordered widgets — see [features/focus.md](features/focus.md).

## 6. Widgets you get

Emitted via `cb.*` in `view` (see [features/widgets.md](features/widgets.md)
and the API on `CmdBuffer`):

- `text` / `heading` / `textMuted` / `textDanger` / `textMono` / `mixedText`
- `button` / `buttonDisabled`
- `textInput` / `textInputSelected` / `textInputDisabled`
- `checkbox`, `radio`, `slider`, `divider`, `image`, `richText`
- containers: `pushGroup`/`popGroup`, `pushScroll`/`popScroll`,
  `pushOverlay`/`popOverlay`, `pushVirtualList`/`popVirtualList`,
  `pushFormRow`/`popFormRow`

Composable components (compose via `teak.Components(.{...}, null)`):
`TextField(cap)`, `NumericField(config)`, `Dropdown(cap)`,
`ComponentList(Child, cap)`.

## 7. Compose multiple components

For a multi-widget app, `Components` stitches child `Model`/`Msg`/`update`/
`view` into one app automatically:

```zig
const App = teak.Components(.{
    .counter = @import("counter.zig"),
    .name = teak.TextField(64),
    .qty = teak.NumericField(.{ .min = 0, .max = 999 }),
}, AppLevel); // AppLevel = optional app-wide state + Msgs
```

See [features/components.md](features/components.md). The canonical
end-to-end example is
[`examples/counter_greeter`](../examples/counter_greeter/).
