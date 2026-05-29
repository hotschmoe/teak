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

A pure-library consumer pays for nothing else. The `wgpu-native`
prebuilts are **lazy** deps of Teak — they're fetched only when you call
`teak.linkWin32Wgpu` (the native UI path), never for `zig build test`.

## 2. Wire the build

Teak ships build helpers so you don't assemble platform + GPU modules by
hand. One call per target:

```zig
const std = @import("std");
const teak = @import("teak"); // teak's build.zig is importable

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const teak_dep = b.dependency("teak", .{ .target = target, .optimize = optimize });

    // Native UI: Win32 + wgpu. Adds the teak / platform-win32 / gpu-native
    // imports, links wgpu-native for the target arch, installs the DLL.
    const ui = b.addExecutable(.{
        .name = "myapp-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    teak.linkWin32Wgpu(b, ui, .{});
    const ui_step = b.step("ui", "Run the UI");
    ui_step.dependOn(&b.addRunArtifact(ui).step);

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

`teak.linkWebWgpu(b, exe, .{})` is the wasm + WebGPU equivalent; it
registers `web` / `web-run` steps.

> **Note (build portability):** `linkWin32Wgpu` `@panic`s if the resolved
> target isn't Windows. If you want `zig build test` to work on a
> non-Windows dev box, keep the UI executable behind a Windows-target
> check, or only add it when `target.result.os.tag == .windows`.

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
    var buf: [32]u8 = undefined;
    cb.text(std.fmt.bufPrint(&buf, "Count: {d}", .{m.count}) catch "Count: ?");
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
const platform = @import("teak-platform-win32");
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
| `wheelMsg` | `(*const Model, f32) ?Msg` | mouse-wheel scroll |
| `focusedMsg` | `(*const Model) ?Msg` | focus ring + cursor blink **and** Tab/Shift+Tab nav |
| `submitMsg` | `(*const Model) ?Msg` | Enter-to-submit |
| `themeFor` | `(*const Model) Theme` | per-frame theme (e.g. dark/light toggle) |
| `windowTitle` | `(*const Model) ?[]const u8` | dynamic title bar ("* unsaved") |
| `Model.init` | `() Model` | non-default initial state |

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

Composable components (compose via `teak.Components(.{...})`):
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
