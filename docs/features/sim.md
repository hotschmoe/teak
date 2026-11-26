# Deterministic simulation

`teak.sim` runs the real Runtime with a virtual Host and recording Gpu, without windows or
wgpu. The Host measures embedded IBM Plex Mono bytes and captures effects without answering.

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

The Host owns four memory files (256 KiB each, names up to 128 bytes). Recording, snapshots
and statistics run through the real runtime sinks with no real file. The optional recording
roundtrip check currently fails: the recorder omits resize, scale, focus loss, elapsed time and
shortcut chords and final button state/edge order, and truncates text/keys below the Host's
limits. Todo seed 1 fails at frame 1
because probe time is zero. This check stays outside blocking/background seeds; the recorder
has not been extended. Simulator JSONL traces retain all those facts for exact replay.

Consumers instantiate sim.Host(sim.Metrics(Font)) with the existing teak-text Font provider,
choose sim.Gpu, preallocate sim.input.Frame and sim.check.Fingerprint slices, and call
sim.runner.simulate(App, HostType, allocator, config). Config carries seed, workload length,
buffers and Progress, plus a 256 KiB recording buffer and a pointer to its used length. The
App uses its normal Model/Msg/view/update without a simulation adapter.

This does not cover OS backends, GPU pixels, native shaping, effect responses, IME, secondary
windows, allocation failure or implementation comparison. Read [SRC.md](../../SRC.md#srcsim)
for hashing, active-capacity schemas, weights, checker decisions, reachability and limits.
The file-read copy adds one allocation seam; its unapproved 0 -> 1 tidy movement remains
visible, so the complete blocking gate is currently red on that inventory alone.
