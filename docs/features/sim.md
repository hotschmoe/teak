# Deterministic simulation

`teak.sim` runs the real Runtime with a virtual Host and recording Gpu, without windows or
wgpu. The Host measures embedded IBM Plex Mono bytes and captures effects without answering.

```sh
zig build sim -- --app todo --seed 1
zig build sim -Dcommit=<commit> -- --app gallery --seed 1 --frames 1000
zig build sim -- --app notes --seed 1 --frames 256 --seeds 200
zig build sim -- --app todo --seed 1 --save zig-out/sim/run.jsonl
zig build sim -- --replay zig-out/sim/run.jsonl
zig build sim-heavy
```

Applications: todo, counter_greeter, tree, gallery, tables, notes, and probe (all effect kinds
and resource churn). Omitting seed draws and prints a 64-bit seed. Each run executes two fresh
runtimes and prints throughput, event counts and observed outcomes. A 32-frame idle tail is
added after the workload.
The parent directory must exist for an explicit --save path. Failure artifacts create
zig-out/sim automatically.

Checkers cover panics/errors, determinism, view purity, Host/Gpu lifetime, idle scheduling,
finite layout, scroll bounds, hit containment and frozen-buffer focus traversal. Tree permits
scrolling beyond its content and can fail the scroll checker; that failure is not suppressed.

Consumers instantiate sim.Host(sim.Metrics(Font)) with the existing teak-text Font provider,
choose sim.Gpu, preallocate sim.input.Frame and sim.check.Fingerprint slices, and call
sim.runner.simulate(App, HostType, allocator, config). Config carries seed, workload length,
buffers and Progress. The App is used unchanged.

This does not cover OS backends, GPU pixels, native shaping, effect responses, IME, secondary
windows, allocation failure or implementation comparison. Read [SRC.md](../../SRC.md#srcsim)
for hashing, weights, checker decisions, reachability and limits. Current tidy conflicts remain
visible; build-step availability does not mean the complete blocking gate is green.
