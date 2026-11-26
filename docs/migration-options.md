# Startup options

Replace `teak.RunOptions` with `teak.Options`. There is no compatibility alias.
Runtime option fields retain their names and defaults.

Native entry points receive `std.process.Init`, build the options once, and pass the same
value to the Host and runtime. Put app defaults in the builder's second argument so the
environment retains precedence:

```zig
pub fn main(init: std.process.Init) !void {
    const options = try teak.options_from_environment(init, .{});
    var host = try platform.Host.init("Example", 900, 500, options);
    defer host.deinit();
    var gpu = try gpu_native.Gpu.initWithOptions(host.nativeHandle(), 900, 500, .{
        .scale = host.scaleFactor(),
        .gpu_fallback = options.gpu_fallback,
    });
    defer gpu.deinit();
    try teak.run(App, init.gpa, &host, &gpu, options);
}
```

`Runtime.init(gpa, host, gpu, options)` accepts the same value. Native Hosts on Linux,
Windows and macOS add Options as the fourth `init` argument. Headless Host initialization is
`Host.init(gpa, width, height, options)`. Pass `options.gpu_fallback` to native GPU
`initWithOptions` or `initOffscreen` through `InitOptions.gpu_fallback`.

Headless entry points build options once and put them in `ShotOptions.run` or
`ServeOptions.run`, including calls to `shotCli`, `shot`, `idleCheck`, `latencyCheck` and
`serve`. These helpers receive supplied options; they do not consult the process environment.
`teak.headless.envScale(default, options.scale)` now takes the captured string explicitly.
It keeps the headless scale range; X11 and Wayland keep their own scale parsing.

Web entry points keep `Host.init(title, width, height)` and pass `teak.Options{}` to
`Runtime.init`. Do not call the environment builder on web or in a simulator.
CLI canaries that use only pure view/layout passes need no options builder.

Hot-reload loaders call `teak.dev.runLoader(init, path, options)`. Direct `Loader.init`
callers replace the final environment-pointer argument with Options. Plugin factories
become `Init.host(gpa, options)` and `Init.gpu(host, options)`. Rebuild both the loader and
plugin for ABI version 2. Each environment instance keeps its settings across reloads.

Direct native text users call `text.face.configure(options)` before measuring; direct
`Font.loadSystem` callers add Options as the second argument. Existing registries and caches
remain process-wide; their ownership is outside this migration.

Options contain borrowed slices, no allocator. Keep `std.process.Init.environ_map` and
`init.arena` alive until every Host, runtime, plugin and worker using them has stopped.
The builder allocates only its environment entry array in that startup arena, and returns
`OutOfMemory` or `EnvironmentTooLarge` (over 65,536 entries) instead of truncating it.
Custom and simulated callers may provide slices with the same lifetime directly.

Environment variable spellings and unset behavior are unchanged. Non-empty path overrides
win over app defaults. Flags use their previous parsing: `0` disables inspect/continuous/HUD;
other non-empty strings enable them; GPU fallback checks its first byte. Cocoa debug and
Wayland's viewport switch depend on presence, including empty values. Backend selection
still treats even an empty `TEAK_BACKEND` as forced. Query parameters keep argv precedence
over captured `TEAK_<NAME>` values. Picker children receive the captured environment.
Later environment mutations no longer affect running instances.
