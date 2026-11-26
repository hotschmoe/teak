# Host clock and file capability

Existing application entry points and Options signatures stay the same. Teak's native and
headless Hosts supply the new optional capabilities; web supplies neither. Custom Hosts
may omit both: statistics then use `nowMs() *| std.time.ns_per_ms`, and file features are
silently unavailable. To support them, implement `now_ns(*const Host) u64` and/or
`files(*Host) teak.FileIo` as documented in [host.md](features/host.md#runtime-file-capability).
The file context must outlive Runtime. Returned file bytes belong to the supplied allocator;
write arguments are borrowed for the duration of the call. No native provider is selected
implicitly for a custom Host.

Direct `teak-text` users replace `face.configure(options)` with `face.configure(source)`.
`face.Source` holds Options and two loaders:

```zig
primary(allocator: std.mem.Allocator, options: teak.Options) anyerror![]u8
extra(allocator: std.mem.Allocator, options: teak.Options, index: u16) anyerror!?[]u8
```

Both return owned font bytes, freed through the supplied allocator when faces are released.
The primary loader returns the first readable primary face. Extra indices 0..3 are override
slots, 4..23 are the ordered system fallback slots; absent slots return null or an error.
Parsing stays in `Font.fromBytes`; neither loader should parse a Font. Options slices must
remain alive until faces are released. Existing process-wide registry/cache ownership is
unchanged. Configure before measuring or rasterizing.
The registry retains the first Source until `releaseFaces`, as it previously retained the
first configured fallback paths. Explicit primary overrides apply at the first primary load.

`Font.loadSystem(allocator, source: ?face.Source)` now requires the supplied loader rather
than Options; null permits embedded fallback bytes only. Direct file helpers
`face.readAbsolute` and `face.windowsFontCandidate` are removed. Use entry-point I/O and
`Font.fromBytes`, or supply a Source. Embedded clients can keep using `setFallbackBytes`,
`registerFace` and `registerFallbackFace` without a Source.
`fallback.checkEnv` is removed too; the Source's extra loader selects override paths.

Direct `frame_stats.Sink.init` callers add the third argument `?teak.FileIo`; null disables
the sink. The target-based `frame_stats.fs_capable` flag is removed: availability is a Host
capability. Native font discovery is in `src/platform/native_fonts.zig`; the benchmark
entry point now receives that provider explicitly from its build configuration.
