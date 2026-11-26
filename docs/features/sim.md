# Deterministic simulation

`teak.sim` runs the real Runtime with a virtual Host and recording Gpu, without windows or
wgpu. The Host measures embedded IBM Plex Mono bytes and supplies deterministic effect replies.

```sh
zig build sim -- --app todo --seed 1
zig build sim -Dcommit=<commit> -- --app gallery --seed 1 --frames 1000
zig build sim -- --app notes --seed 1 --frames 256 --seeds 200
zig build sim -- --app todo --seed 1 --save zig-out/sim/run.jsonl
zig build sim -- --replay zig-out/sim/run.jsonl
zig build sim -- --app todo --seed 1 --record-check 1
zig build sim-heavy
```

Applications: todo, counter_greeter, tree, gallery, tables, notes, and probe (all effect kinds
and resource churn). Omitting seed draws and prints a 64-bit seed. Each run executes two fresh
runtimes and prints throughput, event counts and observed outcomes. A 32-frame idle tail is
added after the workload.
The parent directory must exist for an explicit --save path. Failure artifacts create
zig-out/sim automatically.

Checkers cover panics/errors, determinism, view purity, Host/Gpu lifetime, idle scheduling,
finite layout, scroll bounds, hit containment, an independent sampled painter/clip oracle,
frozen-buffer focus traversal and sampled live Runtime Tab cycles. Live cycles report completed,
changed-set exemptions and unfinished attempts. Mixed bursts deliver pointer, key and text
events together, with separate event counters.

The Host owns four memory files (64 MiB each, names up to 128 bytes), reserved at startup.
Recording, snapshots and statistics run through the real runtime sinks with no real file.
`--record-check 1` runs the second pass through Runtime's ordinary `replay_path`, using the
first pass's recording. All frame hashes must match. SimHost's optional `replay_value` observes
delivered input, clocks and scale for the input fingerprint; it does not decode recordings.
The blocking fixed seeds and every app in `sim-heavy` enable this check. Simulator JSONL
traces remain a separate format for generating and reproducing checker failures.

Consumers instantiate sim.Host(sim.Metrics(Font)) with the existing teak-text Font provider,
choose sim.Gpu, preallocate sim.input.Frame and sim.check.Fingerprint slices, and call
sim.runner.simulate(App, HostType, allocator, config). Config carries seed, workload length,
buffers and Progress, plus a 64 MiB recording buffer, its used-length pointer, and
`file_bytes` with `sim.files.storage_bytes_max` (256 MiB) bytes. The caller retains these
buffers through both passes; the CLI reserves file storage once for the whole campaign. The
App uses its normal Model/Msg/view/update without a simulation adapter.

This does not cover OS backends, GPU pixels, native shaping, real effect services, IME, secondary
windows, allocation failure or implementation comparison. Read [SRC.md](../../SRC.md#srcsim)
for hashing, active-capacity schemas, weights, checker decisions, reachability and limits.
Recording limits contribute to `limits`; a stopped recording is a valid complete prefix.
See [recording migration](../migration-recording.md) for the format, limits and replay scope.
