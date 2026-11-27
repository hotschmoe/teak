# Source notes

## src/sim

`teak.sim` drives `Runtime(App, Host(Metrics(Font)), Gpu)` on one thread. Two fresh runtimes
and two fresh generators start from the same seed in one process. No environment options or
control socket are enabled. Recording, snapshots and statistics use owned memory files.
Only the platform entry
point draws a seed, measures throughput and reads/writes traces. Simulation builds ReleaseSafe.
`--frames M` means M workload frames followed by 32 settling frames; the default is 1,000.
`-Dcommit=...` supplies provenance without running git at configure time. Reproduction requires
the same code and toolchain; cross-target reproducibility is not certified.

Use `zig build sim -- --app todo --seed 1`, `--frames 256`, or `--seeds 200` for consecutive
seeds beginning at the supplied seed. `--save zig-out/sim/run.jsonl` saves a successful run.
Failures print app, seed, zero-based frame, pass, checker and commit, then save the input prefix
to `zig-out/sim/<app>-<seed>.jsonl`. Replay with `zig build sim -- --replay <file>`. A separate
workload-length header permits replay of even a one-frame failing prefix. Traces contain time,
size, scale, pointer/buttons, text, keys, modifiers, shortcuts and focus loss. This is a new
simulator format, not an extension of input_record.zig or a golden-output check.

OS backends, event translation, IME, accessibility action delivery, secondary windows, GPU
pixels/drivers, glyph atlases, native shaping, backend faults, real effect services and allocation
failure remain outside this version. Live background checks remain necessary. Hashing knows
the active-length schemas used by these apps; new consumers must audit their container schemas.
No custom eql method or revision key suppresses data in this hash.
The runtime and existing app views still use their existing allocators and
growing frame arenas; static allocation for those modules is not claimed.
The CLI targets the build host even when the library target is cross-compiled. Replay leaves
generator-kind/event counters at zero because no workload is generated; outcome counters
still observe the recorded inputs.
Incremental/skipped frames are not compared with a fresh render. Repeating a hash establishes
repeatability, not visual correctness. Expensive checker work uses sim.verify, always on;
the runner rejects a verification-disabled build.

## src/sim/host.zig

Only Frame.advance_ms advances time, once per poll. Clipboard bytes, input queues, font state
and effect captures are owned. Every accepted effect is copied, including HTTP headers and
payload strings/bytes, then checked at shutdown against its submission digest. No effect is
performed outside the simulation. Deterministic HTTP, download, file, storage, clock and query
answers are delivered on later polls; the probe folds every result into its Model digest.
effects_issued counts accepted requests; effects_unanswered counts remaining replies.
Fire-and-forget requests are captured too. Bounds are 1,024
captures, 65,536 payload bytes, 1,024 headers and 8,192 clipboard bytes. Full storage skips the
operation and increments limits. Input bounds are checked before using InputQueue so its
logging overflow path cannot run. Unsupported dialogs/windows return cancellation/failure
and increment unsupported; IME is inactive. The Host must keep its address after capture.

Required Host/Gpu/App method names retain their contract spellings: the new group's initial
camel_case inventory is 32. There are no forwarding aliases. The platform CLI is held separately.

## src/sim/files.zig

The Host owns four named files, each limited to 64 MiB with a 128-byte name. Replace and
atomic both publish a complete new value after checking capacity; append preserves the prefix.
No filesystem is used. Limits return FileLimit and increment the table's limits counter;
a failed write preserves the old value. Reads return an allocator-owned copy as required by
FileIo. The runner calls this before the replay's frame loop. Shutdown copies the recording
into its reserved buffer without allocating. Config.file_bytes supplies the file storage;
the CLI reserves it once with the trace workspace and reuses it between completed passes.
Reads allocate the FileIo-owned copy at replay startup.
Writes allocate nothing. The table's address must remain stable while FileIo is retained.
Normal runs exercise recording replacement, atomic snapshot replacement, statistics append
and summary replacement. Reads are exercised by the optional recording replay; file_reads is
zero in normal runs because these apps have no other file reader. The owned
table borrows 256 MiB of address space off the stack. It owns no allocation.

## src/sim/metrics.zig

Metrics owns a Font.fromBytes face built from embedded IBMPlexMonoDefault.ttf, the existing
ASCII subset used by the web host. No native global face registry, font discovery, fallback
or measurement cache is used. Advances/vertical metrics come from the existing stb reader.
Measurement is deliberately unshaped: glyph advances, tracking and snapping, missing glyphs
through .notdef, and one regular face for every family/weight. Unicode workloads exercise
editing/wrapping/bidi, not Arabic shaping or native fallback. Replacing stb belongs to phase 3.

## src/sim/gpu.zig

The recording protocol is overlay -> vertices -> text -> images -> scenes, then presentation.
Presentation can reuse a staged frame; presentation before any upload fails. Overlay splits
and scene ranges must fit. Handles contain a generation and slot: every use/release checks
both generation and resource kind, including cached draws on repeated presentations. Stale,
double-released and wrong-kind handles fail. Shutdown requires created == released. Bounds
are 1,024 resources and 1,024 handles of each draw kind. Overflow is counted; draw overflow
fails. Vertices, text, images, scenes and the typed call transcript are folded by content.
There are no pixels, GPU allocations, texture atlases, real surfaces or backend faults.

## src/sim/hash.zig

Comptime visitors execute through an explicit 1,024-job stack without runtime recursion.
A 16-million-visit bound returns HashLimit. Structs exclude padding/comptime fields; tagged
unions include tag and active payload; optionals include presence; arrays/slices include
length and contents. Single-item plain-data pointers are dereferenced: addresses and sharing
identity never enter the hash. Many-item/C pointers, functions and opaque values are compile
errors. Cycles exhaust the visit bound. Integers are canonical little-endian; float bits
retain negative zero and NaN payloads. Packed structs include declared backing bits. No eql
override is honored. Full-width integer/float arrays have an equivalent bulk path on little-
endian targets. Length-bearing array fields hash their active prefix, including its length.
The schemas are integer `<field>_len` siblings (items, nodes, labels, input, history, name,
search, pending UTF-8, undo bytes and subscriptions); buf/items/text with len; undo recs with n;
events/heights with count; table order/rank with n_rows; tree visible with n_visible; list h
with n and prefix with n+1. Notes log/log_len use log_n, and each log row uses log_len[row].
Thus uninitialized editor undo records, pending UTF-8, subscriptions, table search/permutations,
tree visible capacity and notes log capacity are never inspected. Command/rect/vertex buffers
and draw arrays are supplied as used slices, not backing allocations. Remaining arrays are
fixed-size values (colors, matrices, mesh coordinates, menu selections, bitsets), initialized
in full by these apps; the entire value is state. Unsupported length schemas in a new App
require an explicit mapping before simulation: arbitrary user containers cannot be inferred.
Wyhash is diagnostic hashing, with the usual possibility of collisions.
Vectors, error sets and error unions are not supported by this first walker and fail to
compile rather than being omitted. The exercised example Models do not need those kinds.

## src/sim/input.zig

A frame holds at most 48 events and a virtual time delta. Text selects a fixed UTF-8 corpus:
ASCII task/space, é日, Hebrew שלום, and e plus a combining acute. Events own no external
pointer. The entry point reserves frame and fingerprint buffers before simulation.

## src/sim/workload.zig

SplitMix64 is owned state. A named table chooses actions; gesture continuations complete
before another action. Clicks have separate down/up frames. Drags move across two frames
and then release or lose focus. Text clicks/releases a visible text field before typing when
one is available. Targets are biased 90% toward suitable visible previous-frame rectangles;
other targets include empty space. Candidate storage holds 2,048 points and truncation is
counted. Three quarters of targeted clicks prefer less-visited flat command indices; the
remaining quarter samples uniformly. No hashed or persistent widget identity is introduced.
Raw buttons include middle/right; modifiers include Shift/Ctrl/Alt/Meta. Bursts contain 4–13
triples of pointer move, varied key and sampled UTF-8 text in one poll (12–39 events).
mixed_bursts and burst_pointer/keys/text count frames and actual events of all three kinds.
Idle jumps cover 1–300,000 ms. Sizes include 0x0, 1x1, 24x12, 320x240, 1280x800, 1600x1000;
scale spans 0.5–3.0. InputQueue's normal aggregation and characters-before-special-keys
routing apply. Per-event chronology within a poll has no separate oracle.

| Action | Weight | Action | Weight |
|---|---:|---|---:|
| move | 10 | click | 24 |
| drag | 8 | wheel | 8 |
| tab | 7 | shift_tab | 4 |
| enter | 10 | escape | 3 |
| arrow | 7 | edit | 5 |
| shortcut | 5 | text_ascii | 15 |
| text_multibyte | 3 | text_rtl | 3 |
| text_combining | 3 | burst | 4 |
| idle | 5 | resize | 4 |
| scale | 2 | focus_loss | 2 |
| press | 2 | release | 2 |
| modifiers | 2 | | |

## src/sim/check.zig

No-stop catches returned errors and uses the CLI panic handler to save input. There is no
hang watchdog or artifact guarantee after an external kill. Determinism compares each
frame's Model, commands, rectangles, vertices, Gpu state/transcript and generated input
digest independently across fresh runtimes and generators. Input hashes include delivered
InputState, virtual clock and scale, rather than the generator's pre-aggregation encoding.
Quiet frames still get checkers.

View purity hashes Model, emits/hashes a fresh view, checks Model again, emits a second view
and compares commands/themes and Model. Runtime commands are not used as the second view:
post-layout Msgs may legitimately have changed Model since the runtime emitted that view.

Layout checks all rectangles, including structural commands, for finite coordinates and
finite/non-negative sizes. Scroll offsets must be finite/non-negative and no greater than
content minus viewport, with 0.02 px arithmetic tolerance. Text areas allow the existing 2 px
horizontal caret margin. Upper bounds defer while layout_dirty: extent Msgs have updated
Model, but the shown commands deliberately belong to the preceding state. Containment is
omitted because overlays, scrolled content, explicit overflow, virtual lists and transformed
canvases invalidate blanket containment.

Hit-test probes the pointer, four rotating rectangle centres, and points 0.125 px beyond
their left/right/bottom bounds. A returned index must exist and contain the point, using the
library's inclusive edges. An independent slow oracle walks candidates backward, rescans each
candidate's preceding commands to find open ancestors, and intersects their scalar bounds.
Only scrolls and overlays clip; ordinary groups and virtual lists do not. Empty clips reject
all points. Overlays retain ancestor scroll clipping and outrank all base widgets. Later modal
backdrops cover earlier overlay targets; later children cover their backdrop. Enabled leaves,
pointer-only canvas/scene targets and modal consumption are classified independently; both
index and optional Msg must match. This is quadratic sampled geometry, not all-point proof.

Focus checks text/navigation indices against an independent leaf classification. For frozen
commands, forward/reverse traversal must visit the independently enumerated Tab stops exactly
once and wrap in the modal scope. Modal-scope selection uses the framework helper and is not
independently checked.

## src/sim/live_focus.zig

At eligible sampling frames (frame number 1 modulo 32), the generator has no pending gesture,
the Host has no queued input/held buttons, and layout has no pending reconciliation. At least
two Tab stops start a live cycle through ordinary Runtime.frame calls with only Tab and zero
elapsed time. A primer Tab establishes a starting stop when focus is absent, outside the modal
scope or on a pointer-focused button excluded from Tab order. N subsequent Tabs must visit
each independently enumerated stop exactly once and return to that start. A signature includes
each stop's command index and Msg; a changed set during Tab frames explicitly exempts that
attempt and increments focus_set_changed. Gallery's combobox is the explicit exception:
focus opens its modal option list, changing both the available stops and traversal scope.
focus_cycles counts completed cycles, focus_tabs counts delivered probe Tabs, and focus_pending
reports a cycle cut off by the workload bound.
The 2,048-stop limit skips starting a cycle and increments limits. Ordinary workload generation
resumes between cycles; the settling tail never generates probe input. Sampled cycles are not
a claim about every possible reachable state, all starting widgets, or reverse live traversal.

## src/sim/recording.zig

This module only names the input recording and snapshot memory files. `--record-check 1`
passes the first run's memory recording to a fresh Runtime's ordinary `replay_path` at
initialization. There is no simulator decoder, queue reconstruction or trace-based clock
override. SimHost's optional `replay_value` mirrors the supplied input, clock and scale for
the input fingerprint. Per-frame hashes must match; failures name record_replay. Every
blocking fixed seed and sim-heavy app enables the check. Simulator JSONL trace replay remains
independent and can reproduce the workload that caused a recording checker failure.

## src/sim/runner.zig

Resources are checked after frames and Runtime shutdown. The 32-frame settling tail starts
with focus loss. After that final input, eight consecutive frames without a listed subscription
or pending effect must reach quiet; after the first quiet frame they must stay quiet. A listed
subscription or pending effect resets that deadline and increments idle_exempt. Accepted
fire-and-forget effects are not pending. idle_grace counts eligible busy frames before the
deadline; idle_checked counts observed quiet frames. If eligibility starts near the run's end,
the counters can expose an incomplete observation. Blink presentations are permitted: quiet
describes scheduling. This is bounded observation, not infinite liveness. The deadline starts
when eligibility begins, not at workload end: a subscription may stop in the final tail frames.

Click/text/Tab counters come from actual runtime dispatch/traversal sites. Text counts bytes
dispatched to a focused text leaf. Scroll changes ignore zero-offset structural regions;
creating a scroll command does not fake coverage. Group drag start and focus-loss cancellation
use actual runtime drag state. Canvas/text selection capture cancellation is not checked.
skipped_unchanged counts busy frames reusing vertices; quiet skips are separate. A zero
counter is printed for review, not automatically failed: the generic runner cannot know an
app's reachability.

Todo has no scroll-offset handler, effects or resources. Counter_greeter has no scrolling,
group drag, resources or effects. Tree has no text/group drag/resources/effects. Tables has
no text leaf, group drag, resources or effects. Notes has text/scrolling but no group drag,
resources or effects. Gallery has text/scrolling/resources but no group drag/effects; no text
or resource activity in its default run would be a workload gap. Limits normally remain zero
in the examples; probe pressures capture storage. Dialog/secondary/IME results are out of scope.

## src/sim/probe.zig

A small real Runtime app complements the examples: one button changes all nine effects and
alternates two resources. HTTP/clipboard strings borrow mutable Model storage, so retaining
caller slices instead of copying them fails capture lifetime validation. The Host supplies
deterministic responses, including binary file bytes; every delivered answer changes the
Model digest through Msg/update. Its single Tab stop cannot move focus to another widget. Text, scrolling and
group drag are unreachable. This is an end-to-end app, not canned assertions about mocks.

## src/sim/trace.zig

Versioned JSON Lines encodes the header and used events, excluding unused capacity. Startup
parsing validates sample indices, finite coordinates/scales, dimensions and capacities before
polling the Host. Replay runs recorded inputs twice and does not compare archived expected
hashes. Cross-commit replay can demonstrate a fix, but is not a compatibility guarantee.

## src/sim/sim.zig

The namespace exports Host/Metrics factories, Gpu, input, memory-file limits, workload,
checkers, hashing, runner,
trace and probe. Consumers supply their App and allocator to runner.simulate, preallocate
frames/fingerprints and provide Progress for diagnostics. Host(Metrics(Font)) takes the
existing teak-text Font provider. No app wrapper or hidden TEA state is installed.

## src/platform/sim/main.zig

The blocking script runs 128 workload frames per app, all with seed 1.
The former three CLI canaries move to the background script, keeping eight blocking paths
including the wasm compile canary. Real OS/GPU paths remain background work.

The entry point owns startup allocations, seed generation, throughput, trace I/O and the
panic diagnostic pointer. Workspace reserves 128 MiB for traces (its first 64 MiB also holds
the completed recording) and 256 MiB for reusable memory-file storage. Persisting a failed
recording precedes trace serialization because the recording and trace buffers overlap.
The two entry-point globals hold the active Diagnostics pointer
and a panic-report reentrancy guard; they let a library assertion save its input prefix without
changing the library's panic contract. Neither is app or simulator state. Bounds are
100,000 workload frames plus the
settling tail and 128 MiB of trace data. Initialization has an empty first frame reserved
so an App.init panic is replayable. Tables' Model.init allocates three page_allocator objects
without teardown; an explicit cleanup callback frees those objects after Runtime teardown.
No example is adapted for simulation. Counter_greeter uses its exact existing rich_zig pin,
lazily wired only by the root build.

## src/assert.zig

The rewrite's owned `assert` uses an ordinary conditional panic, including in
ReleaseFast and ReleaseSmall (D6). Keeping it at the source root makes it usable
by core modules without a dependency on tools. Tidy imports it through a build
module; `teak.assert` shares the implementation with the separate text module
without importing the same source file into two modules.
The assertion primitive cannot assert its own implementation without recursion;
its one-statement body is exempt from assertion demand and credit. It is held
independently in `tools/tidy_ratchet.zon`. No operating error is asserted.

## tools/tidy.zig

`zig build tidy` measures source with Zig 0.17.1's `std.zig.Ast`. The blocking
`test` step runs tidy before the Bash CLI canaries in `tools/test-e2e.sh`;
compilation can run in parallel. Tidy is a build lint, not another end-to-end
test. `-- --table` prints Markdown rows, source totals and repository totals. The longest-function total
is a maximum; other totals sum groups, including their separate deficits.
Wall time uses the awake clock and includes discovery, git and ratchet checking.

The program is copied between zunk and teak. All repository policy lives in the
typed `config` block at its top: source roots, skipped directory names, group
rules, generated-file markers, script exclusions and additional banned helper
names. A compiled block keeps this policy small, checked by Zig and colocated
with the program; a separately parsed configuration file would add another
input and failure path. The ratchet remains runtime data so tightening does not
recompile the tool. There is no shared package or repository-name detection.

Teak's style scope is `src/**/*.zig`, `tools/**/*.zig`, `examples/*/src/**/*.zig`,
`build.zig` and `examples/*/build.zig`. Root patterns ending in `/` include
descendants; other patterns match exactly. One `*` matches an example directory.
Groups are each direct directory under `src`, `src/*.zig`, `tools`, `examples`,
and the root build file. Group rules match prefixes in order; `directory`
selects the next directory component when present, otherwise the rule's name.
Discovery skips `.git`, `.zig-cache`, `zig-out`, `zig-pkg`, `.archive`,
and `node_modules`, and does not follow symlinks. A file with `GENERATED`
or `Generated by` in its first eight lines is excluded and named in every report.

`held_files` in `tools/tidy_ratchet.zon` is a hand-maintained list of source
paths. Each file has its own group, excluded from its directory's counts, and
must meet every style target independently of its stored numbers. It must
exist, be in scope and not be skipped or generated. Duplicate and noncanonical
paths fail. Updates preserve the entire list, including when a file is missing;
they never remove entries. Teak holds `tools/tidy.zig`, `src/assert.zig`,
`src/options.zig`, `src/platform/native_fonts.zig` and `src/platform/sim/main.zig`.
`src/platform/native_io.zig` still has an
assertion deficit of two and is not held. Seam inventories may be nonzero;
style targets are zero, with longest function at most 70. Moving a held file
out of a group also moves its assertion demand and surplus credit.

The columns mean:

- `files`, `lines`, `functions`: included files, physical lines (a final newline
  adds no empty line), and function declarations with bodies. Bodiless
  prototypes and function pointer types are excluded. `type_functions` is the
  subset with explicit return expression `type`; it remains in `functions`.
- `long_lines`: lines exceeding 100 Unicode code points, including comments
  and ordinary quoted literals. Tabs count as one column; display widths are
  not modeled. A line whose AST token is `multiline_string_literal_line` goes
  into `literal_long_lines` instead. This reports embedded JavaScript, shaders
  and other multiline data without ratcheting them as Zig style violations.
- `long_functions`, `longest_function`: physical span from `fn` through the
  closing body token, inclusive of signatures, comments and blank lines. Type
  constructors are exempt from both metrics; their methods count.
- `assertions`: calls whose final identifier is `assert`, regardless of receiver.
  Ownership belongs to the innermost function, including nested methods.
  `trivial_functions` counts bodies with exactly one top-level AST statement,
  including a lone return or the owned assert's conditional panic. Such functions
  contribute neither assertion demand nor credit. Other functions require two
  assertions on average within their group: `assertion_deficit` is
  `max(0, 2 * nontrivial_functions - assertions_in_nontrivial_functions)`.
  Extra assertions in one nontrivial function can cover another's deficit.
  `functions_no_assert` still reports all bodies with no assertion calls.
  Sites sample under-asserted nontrivial functions, rather than numeric deficits.
- `usize_fields`, `sized_fields`: struct fields typed `usize` or `?usize`, versus
  explicit `uN`/`iN` or their optional form. Tuple fields count. Union members,
  enum tags, aliases, pointers, arrays and slices do not. `isize` is not `usize`.
- `self_recursion`: functions calling themselves. `mutual_recursion`: unordered
  function pairs with calls in both directions, once per pair. Bounded stacks
  assign container scopes and function ownership; measurements scan the flat
  AST. Bare names resolve through enclosing containers to file scope. Field
  calls resolve through a uniquely named local container, `self`, `Self`, or
  the caller's first parameter. Ambiguous names, imports, aliases, function
  pointers, arbitrary receiver types, indirect calls and cycles longer than two
  are not resolved. The first-parameter heuristic can mistake a function-pointer
  field for a method. Comptime and syntactically bounded recursion still count.
- `while_true`: while nodes with literal `true` conditions. This neither proves
  other loops bounded nor inspects exits within these loops.
- `camel_case`: lowercase-initial function names with an uppercase ASCII letter,
  excluding type constructors. Escaped identifiers are not normalized.
- `allocation`, `clock`, `environment`, `threads`, `files_io`, `processes`: potential banned
  calls, once per category per call. One call can count in several categories.
  These expose seams; they do not prove an allocation happens after startup.
- `globals`: container-member `var` declarations at file scope or in any struct,
  union or enum, including containers declared inside functions (static locals).
  `threadlocal` and extern variables count; `const`, instance fields and ordinary
  call-local variables do not. Membership comes from the AST, independent of
  function ownership. Each declaration counts once, even inside generic types.
  This inventory exposes persistent state for the simulator's repeated runs;
  it does not distinguish a cache from a registry or prove semantic determinism.
- `scripts`: git-tracked `.sh`, `.py`, `.mjs`, `.js` and `.ps1` files throughout
  the repository. Teak configures no script exclusions. Untracked Zig files are
  measured too. `tests` counts AST test declarations in every discovered
  nongenerated Zig file, even outside style scope. Held files' tests belong to
  their individual group; all other tests and all scripts belong to `repository`,
  so totals do not double-count. The stored test count is a ratchet like the
  others: zero here, and in a repository that still has tests it can only fall.
- `clock` includes `std.Io.Timestamp.now`; `threads` includes `io.concurrent` and
  `io.async` task spawns, by method name.

The standard allocation field-call names are `alloc`, `alignedAlloc`,
`allocSentinel`, `allocWithOptions`, `allocAdvanced`, `create`, `realloc`, `remap`,
`dupe`, `dupeZ`, `dupeSentinel`, `allocPrint`, `allocPrintSentinel`, `append`,
`appendSlice`, `appendNTimes`, `appendFlattened`, `ensureTotalCapacity`,
`ensureTotalCapacityPrecise`, `ensureUnusedCapacity`, `addOne`, `addManyAsSlice`,
`resize`, `put`, `getOrPut`, `fetchPut`, `putNoClobber`, `initCapacity`,
`toOwnedSlice`, `toOwnedSliceSentinel`, `readFileAlloc`, `readFileAllocOptions`,
`utf16LeToUtf8Alloc` and `createMap`. `join` and `concat` also match through
`std.fs` or `std.mem`. Bounded forms such as `appendAssumeCapacity`,
`putAssumeCapacity` and `bufPrint` are excluded. Receiver types are not inferred:
GPU `resize` and our bounded `Buffer.append` can be false positives; aliases and
wrappers with different names can be missed. Native resource creation allocates too.

Clock calls contain `std.time` or `Io.Clock`, or use the clock/timestamp names
in `clock_names`: libc and kernel clock queries, `sleep`, `nanosleep`, `usleep`,
Windows timing and Mach time. `std.Io.sleep` counts as clock access. Environment
names cover libc `getenv` and setters, standard environment helpers and Windows
get/set APIs, plus `init.environ_map` and `minimal.environ` chains. Thread calls
contain `std.Thread` or `Io.Threaded`, use `pthread_`/`thrd_` APIs, clone or thread
helpers; raw futex operations count too. Clone counts as both thread and process
access because flags determine what it creates.

File calls contain `std.fs` except `std.fs.path`, `Io.Dir`, `Io.File`, or use the
standard file names in `file_names`. Path helpers operate on strings and do not
count as IO; allocating `join` still counts as allocation. `stdio_names` adds
libc stdio, including `fopen`/`fopen64`, `fread`, `fwrite`, `fclose`, seeking,
stdio output, temporary files and pipe streams, plus `dlopen`/`dlclose`/`dlsym`.
`std.DynLib` calls count as file access. `raw_file_names` covers descriptor IO,
metadata, directories, links, mappings, sync and file watches through `std.c`,
`std.posix` and `std.os.linux`. Common names such as `read`, `close` and `remove`
require a raw receiver, so an application collection's `remove` is not file IO.
Raw reads/closes of sockets also count: descriptor kind is not inferred.

`processes` covers `std.process.spawn`, `run`, `replace`, libc/kernel exec,
fork, spawn, wait, process identity and signals, and Windows process launch APIs.
It counts call sites, not the number of children. `popen`/`pclose` count as both
file and process access. Ambiguous `wait`/`kill` require a raw receiver or bare
call; child instance `wait`/`kill` are not inferred, while their spawn is counted.

Token chains ignore whitespace and comments. One file-level `const` alias to a
field-access namespace is recognized for raw APIs, `std.Thread`, `std.DynLib`
and `std.process`. This is lexical inventory: it does not resolve local shadows,
alias chains, arbitrary receivers, imports, syscall numbers, function pointers,
native extern calls with other names or differently named application wrappers.
Name-only matching can overcount same-named application methods. The arrays in
the program are the complete name lists, reviewed against Zig 0.17.1's standard
sources; they also cover common libc externs a program can declare itself.

Teak adds allocation helpers `snapshotAlloc`, `allocInit`, `allocRect`,
`allocUpperString`, `grow`, `growBuffer`, `growPages`, `growRuns`, `initAllocator`,
and environment helpers `envVar`, `envFlag`, `envInt`, `envValue`, `envSet`.
There are no extra file helpers. Tidy necessarily uses allocation, a clock,
files and git; held files allow and ratchet these seam inventories and globals.

Every discovered `build.zig.zon` must have the same decoded
`minimum_zig_version`, including tool manifests. Missing values, invalid syntax
and disagreements fail independently of ratchets. This checks manifest agreement,
not CI's installer or agreement between separately reported repositories.

`-- --table --root <path>` opens another tree read-only, measures all discovered
Zig files (including root-level files), and groups them by first directory or
`*.zig`. It never reads or writes a ratchet or applies teak's held list. The
same directory and generated exclusions apply. Scripts use filesystem discovery
there, including untracked files, because fetched packages need not have git
metadata. Tests are reported without enforcing zero. `--root` and `--update`
cannot be combined. Use this for rich_zig and the fetched webzocket package;
their source and manifests are never modified.

The ratchet is parsed with `std.zon`. Its metric-name header fixes numeric row
order. Stored metrics are long lines/functions, longest function, deficit,
usize fields, recursion, literal infinite loops, camelCase, banned-call counts,
globals, scripts and tests. Sizes, assertions, trivial functions and literal long lines
are reported only. Every stored number must match exactly. Decreases fail until
`-- --update` records them; increases are refused even by update. A raise is
legitimate in four cases: a count that was always there has become
visible (tidy learned to see it, or an implicit operation was made explicit); a
call moved from one group into another, lowering the first by at least as much;
or a long function in old code was split, adding a function to the assertion
average; or names are dictated by an existing interface, going to zero when
that interface is renamed. The stored number is then edited by hand and explained.
Held-file regrouping can likewise remove surplus assertion credit from a group;
this accounting change needs an explained hand edit. New metrics are seeded by
hand. Replacing tidy itself re-seeds only its seam inventories; its style stays
at target. The complete snapshot is validated before writing. A new group must
start with zero long lines/functions, deficit, usize fields, recursion,
while-true, camelCase and tests,
and longest function at most 70. Seam counts may be nonzero. Existing debt is
seeded once by hand; update cannot bootstrap it. Removed groups measure zero
until update drops them. Failures name group, metric, before/after and at most
twenty current file:line samples. Vanished sites have no remaining location.

One startup allocation reserves `State`; it is released at shutdown. Limits:
2 MiB per input, 4,096 files/directories/held paths, 65,536 entries per directory,
2,048 functions and 4,096 containers per file, 524,288 tokens/nodes, nesting
depth 256, 128 groups, 512 bytes per path, 20 sites per metric/group, 256 KiB
report buffer and 64 MiB parser scratch. Git output is capped at 2 MiB and
4,096 names. Limits return named errors and fail; nothing is silently omitted.
No owned heap memory is acquired after startup. The standard AST/ZON parser
requests temporary allocations from the reserved scratch, reused between inputs.
This compiler-workspace exception permits the required standard parser API
without arena growth. Standard IO and process internals are outside that owned
workspace guarantee. Traversal uses a bounded queue; syntax ownership uses
bounded stacks. The standard parser may recurse; tidy's functions do not.

Baseline reconciliation against the lexical scan of `293ee2c` was checked by
running the AST tool on an archived copy of that commit's `src` and running the
original lexer on both versions. The comparison is:

| src metric | published baseline | AST at 293ee2c | current AST |
|---|---:|---:|---:|
| ordinary functions | 2398 | 2249 | 2265 |
| type constructors (separate subset) | 55 | 55 | 55 |
| functions over 70 | 34 | 34 | 35 |
| longest ordinary function | 477 | 477 | 477 |
| lines over 100 | 1839 | 1330 | 1341 |
| usize fields | 185 | 190 | 190 |
| sized integer fields | 624 | 598 | 604 |
| assertion calls | 9 | 9 | 9 |
| while (true) | 20 | 20 | 20 |

The function difference is entirely scope: generated Unicode/protocol/compose
files contribute 149 ordinary functions (1 + 147 + 1). For the same nongenerated
files the old lexer and AST agree exactly, both at baseline and now. Current
ordinary functions add sixteen: twelve in root source, two in core and two in
platform. Tidy's `functions` column includes the 55 constructors too, giving
2,320. Generated files also account for all 509 excluded overlength lines
(357 + 151 + 1); current source adds eleven, nine in root source and two in
platform. The extra long function is `writeGatesJson` in `headless_run.zig`;
`frame` also grew from 104 to 105 lines. The 3% sized-field discrepancy is a
definition/scope difference: the lexer includes union payloads, while tidy only
measures actual struct fields. At the old commit, excluded sized union fields
are 2 root, 16 core and 5 platform; the other 3 are the generated compose table's
`Entry` fields. For usize, excluding 7 core union payloads and including 12 GPU
tuple struct fields missed by the lexer changes 185 to 190. This is not
unexplained source drift.

## src/core/pointer.zig

Canvas coordinates are local logical pixels, except layout events, which carry the window-space origin and size. Pointer capture retains move and release events until the last held button is released. A drag target of zero means no target.

## src/text/shaper.zig

Fallback searches registered families, then the app chain and system last-resort list. For right-to-left shaping, an output-full result consumes the unresumable source tail; callers must size the output for the run. Kerning finalizes a base glyph when the next base is known. Default-ignorable code points draw nothing. Available precomposed glyphs take precedence over combining marks; otherwise marks have zero advance and missing marks are dropped.

## src/gpu/wgpu_c.zig

Native requests complete during `wgpuInstanceProcessEvents`, with callbacks storing their result through `userdata1`. The device requests adapter limits rather than defaults because software adapters may not support the defaults. `TEAK_GPU_FALLBACK=1` selects a software adapter.

## src/text/hb_shaper.zig

Bidirectional RTL runs remain RTL regardless of guessed script, and RTL run groups are emitted in reverse order. Tracking is disabled for joining scripts. When a run exceeds the output buffer, it is split at a code point boundary so shaping can resume.

## src/gpu/web_scene.zig

Triangle runs read one packed record per instance; line segments use stride zero so they share their item's record. Each section cap uses stencil parity followed by a cap quad that clears the stencil. The grid is depth-tested and the gizmo is always on top.

## src/gpu/web.zig

The image cache grows to 65,536 live images and falls back to a tinted placeholder when full. Scene targets render offscreen and their composite bind groups are rebuilt when targets change. Overlay staging separates base and overlay records: each layer draws solids, images, scene composites, then text, so opaque overlays cover base text. This order matches the native GPU core.

The zunk atlas uses a downward y-axis from the baseline; glyph pixel (0,0) is at `(pen + bearing_x, baseline - bearing_y)`. The solid vertex buffer is also bound read-only in the fragment stage for SDF records.

## src/gpu/wgpu_core.zig

Image handles are slot indices plus one; zero is the sentinel. Scene bind groups are rebuilt when the offscreen target generation changes. Secondary windows share the device, queue, pipelines and caches; rendering rewrites the screen-size uniform for each surface. The swapchain format is fixed to BGRA8Unorm, so a backend that does not support it must query surface capabilities before selecting a format.

Native resource release order is bind groups, views, textures, then vertex buffers. A presented frame texture must be released before reconfiguring the surface; holding it prevents DX12 swapchain resize. The screen-size uniform must be rewritten even for the primary window after a secondary window is rendered.

The solid vertex buffer is bound in the fragment stage for SDF records. The glyph sampler uses nearest magnification to avoid re-blurring rasterized antialiasing and linear minification. Each layer draws solids, images, scene composites and then text; the overlay follows the base so it covers base text. Scene targets use device resolution and are composited 1:1.

## src/gpu/wgpu_scene.zig

Triangle runs read packed records per instance, while lines use stride zero so every segment shares its item's record. Section caps use stencil parity and a cap quad that clears the stencil. The grid is depth-tested and the gizmo is always on top.


## examples/counter_greeter/build.zig

The ARM64 feature override compensates for Zig's missing Windows i8mm detection. The native UI step exists only when Teak has a backend for the selected target; web and CLI builds do not require it.

## examples/todo/build.zig

The native UI and headless driver are enabled only for supported targets. The Linux development loader swaps rebuilt `libapp.so` while retaining compatible model state; see `docs/features/hot-reload.md`.

## examples/chrome/build.zig

The web `-Dstress=N` option substitutes the glyph-atlas stress app with N monospace text runs for the normal Chrome example.

## tools/bench/main.zig

The vector-canvas benchmark builds world-space frame geometry once; its view reuses the segments and node dots under a pan and zoom transform.

## tools/gen_api.zig

The API generator excludes module aliases nested inside modules and emits only names and kinds for nested public types and constants. Public Zig doc comments supply the generated reference and are retained.

## tools/gen_unicode.zig

Line-break and bidirectional classes apply Unicode file defaults before explicit entries. East Asian wide and fullwidth values set bit 7. Paired brackets pack as `cp | pair << 21 | is_close << 42` in code-point order.

## tools/audit.zig

The static-variable check uses column-zero declarations to distinguish module state from indented locals. Public exports are checked against `llms.txt` by substring, deliberately allowing wording to vary. Generated API docs are checked against `tools/gen_api.zig`; module trees must list non-test source files.

## tools/ci_gates.zig

`zig build gates` is the last stage of the background gate and never blocks a PR. For each example with a `src/shot_main.zig` it runs a ReleaseSmall `shot -- --gates-json` (idle per state, one click latency, memory of the first state), then `ui-install` and `web` for the unstripped native exe size and the wasm size under Node's brotli at quality 11. It writes `zig-out/gates/ci-gates.json`.

Idle is looser here than the `--idle-check` flag. An `expect_busy` state (`"*"` exempts the example) is reported and never fails. Every other state must be quiet at the end of the 125-frame window, so a one-shot timer that fires and finishes passes while a subscription still firing fails. A strict state must also be fully quiet: no busy frame, and every present a caret blink. Without `strict_states` the strict set is `initial`, or the first state. `scene3d` is exempt because its orbit subscribes every frame on purpose.

The latency budget is one frame: input is routed against the previous frame, so the Msg and the new view land in the `frame()` that delivers the click. A measured value fails when it exceeds its budget by more than `alert_over_pct`, in integer arithmetic (110 against 100 at 10% passes, 111 fails). Wasm brotli is the portable budget. Native exe size, RSS and committed bytes depend on the host triple and the Vulkan driver, so they live under `platforms."<arch>-<os>"`; a zero budget or a host triple with no entry is reported as skipped and never fails. `--update-budgets` writes the measured numbers for the host that ran, so budgets must be seeded on the machine that enforces them.

## tools/win32_live/driver.zig

A synthetic Alt tap and shared input queue allow the background driver to take foreground; topmost ordering avoids runner setup windows. A black screen capture falls back to the compositor's window pixels. The drag source offers only its real COM interfaces: claiming IMarshal corrupts cross-process drag. OLE requires actual relative mouse events, and a synthetic button press would capture input in the app instead of its drag loop.

Cross-process `DoDragDrop` can block inside OLE on CI runners before reaching the app's drop target. The drag scenario is opt-in through `TEAK_LIVE_DRAG=1` and has a watchdog.

## tools/showcase.sh

Showcase generation requires Zig, Vulkan, Chromium, the tools npm dependencies and Pillow; the HarfBuzz shot additionally needs Noto script fonts. `WEBSHOT_ANGLE=vulkan` selects Vulkan where needed; see `docs/showcase.md`.

## tools/showcase.py

`SHOWCASE_MAC` and `SHOWCASE_WIN` supply screenshots from other hosts. The HiDPI crop uses device pixels without resampling.

## tools/release.sh

`tools/release.sh VERSION` changes the version in `build.zig.zon`, commits, tags and pushes it. The release workflow requires the tag to match the manifest version.

## tools/web-frame-bench.mjs

The benchmark times main-thread animation callbacks while scrolling a headless web example. SwiftShader rasterization runs off-thread, so its result excludes GPU cost. Install the tools npm dependencies and pass the distribution directory; `WEBSHOT_ANGLE=vulkan` selects Vulkan where needed.

## tools/web-startup.mjs

The startup profile reports medians from navigation, resource timing and zunk performance marks. Baseline and candidate distributions are sampled alternately with a fresh browser per run. `first-cb` measures the end of the first animation callback without requiring marks, so older builds remain comparable.

## tools/web-ime-test.mjs

The Chromium acceptance driver exercises focused, preedit, committed and canceled IME composition states through DevTools. It checks the hidden field's focus, page errors and pixel differences, allowing for caret blinking. It takes a distribution directory, output prefix and `--click X,Y`; exit codes are 0 for success, 1 for a failed check and 2 for usage.

## tools/webshot.mjs

The smoke check serves a web distribution in headless Chromium and rejects page errors or a blank canvas. Chromium is selected by `--chrome`, then `CHROME_PATH`, then PATH. Some Mali hosts need `WEBSHOT_ANGLE=vulkan`. Exit codes are 0 for success, 1 for a failed check and 2 for usage.

## tools/qa/web.mjs

The visual QA web driver extends the web smoke check with query parameters, scripted actions and device scale factor options.

## tools/a11yprobe.mjs

The probe exercises the browser accessibility tree and DOM mirror for the todo and notes examples; `dump` prints the tree without assertions. It exits with 0 for success, 1 for a failed check or page error, and 2 for usage. See `docs/features/a11y.md`.

## tools/qa/web.py

`web.py [example|all] [out-dir]` drives each selected web distribution through `tools/qa/web.mjs` at 1x and 2x device scale.

## tools/qa/run.sh

`tools/qa/run.sh [out-dir]` renders native and web examples at 1x and 2x. It needs Zig, Vulkan, Chromium and the tools npm dependencies; some hosts need `WEBSHOT_ANGLE=vulkan`. The default output directory is `/tmp/qa`.

## shaders/image.wgsl

The image tint arrives through the vertex stream; white is passthrough and tint alpha controls opacity.

## shaders/scene_grid.wgsl

The fullscreen grid intersects a world plane and writes depth so geometry can occlude it. Grid levels fade as cells become too small, and the grid dissolves before the far plane.

## shaders/scene.wgsl

Per-item placement uses `scene_pass.Packed` (80 bytes); normals use the linear transform and are normalized after interpolation. Plane layer depth bias orders coplanar sheets. Screen-space sprites retain pixel size; other sprites use billboard, axis-locked or fixed planes. Section caps invert stencil for kept faces and clear it while drawing the cap where parity is odd. Lines use one instance per segment, stride zero for the item transform, and extend half a width at each end to avoid gaps.

## shaders/glyph.wgsl

Each glyph instance uses raw 32-bit attributes shared by native and web. Positions are device pixels, while the screen uniform is logical size, so clip-space division uses `screen * scale`. Flag bits 0–1 select coverage, distance field or RGBA; bits 16–31 encode quad scale in 1/256 units. Coverage uses exact pixel-aligned fetches; distance fields use bilinear sampling and a derivative-sized edge transition. Colour glyphs use their own RGB and instance alpha.

## shaders/quad.wgsl

Solids, antialiased canvas edges and SDF quads share a stream to preserve painter order. Vertex alpha selects solid (`>= 0`), SDF (`-1`) or antialiased edge (`<= -1.5`, with opacity `-2 - a`); the SDF vertex's red field indexes a six-vertex header containing the 36-float record defined in `src/render/sdf.zig`. UVs are pixel offsets from the rect centre. Radii are ordered bottom-right, top-right, bottom-left, top-left with y increasing downward. Derivatives size antialiasing to a device pixel; gradients and shadows use dither to reduce 8-bit banding.

## examples/gallery/src/page_data.zig

The tree uses one Tab stop at its first row. Arrow keys move focus between rows, and Enter or Space toggles a folder.

## examples/chrome/src/shot_main.zig

Screenshot states advance 40 frames to settle the quick-keys popover; its mid-slide state uses deterministic 16 ms frames. Clear colour follows the selected theme. Stress labels are formatted before timing to exclude allocation.

## examples/tables/src/shot_main.zig

The screenshot path forces `idle_skip = false` for its timing run. Gate measurements go through `shotCli` with the default loop and an untouched Model: `initial` is the table tab and `list` is one click on the List tab.

## examples/scene_layers/src/shot_main.zig

The default PNG is one scripted shot. Gate measurements use named states: `initial` is the resting frame and `row` repeats the screenshot's click.

## examples/kerf_viewer/src/shot_main.zig

Scripted window positions target the 1280×800 showcase layout.

## examples/kerf_viewer/src/draw/tess.zig

End ramps are emitted only for lines at least two pixels wide; hard ends on thinner text and hatch strokes avoid extra geometry. In screen coordinates, fill is left of travel for both positively oriented outer loops and negatively oriented holes, so numeric right is outward.

## src/core/cmd.zig

Accessibility hints let composite patterns built from primitive commands expose roles and state to platform mirrors; the default semantic hint leaves the primitive role unchanged. Overlays draw above and hit-test before base content; zero dimensions are measured from children, and an optional backdrop message carries click-outside handling without function pointers. Virtual lists claim total scroll extent while emitting only the visible window and are intended inside a scroll region. Rich-text spans refer to contiguous byte ranges in per-frame data. Canvas coordinates are local logical pixels; the renderer translates and clips them, while primitives remain plain data allocated for the frame. Scene commands produce offscreen-rendered draw records that are composited into the leaf rectangle. Command-buffer balance validation checks matching push/pop kinds as well as depth, because crossed pairs can otherwise silently produce incorrect layout. Form-row nesting is limited to eight in-flight rows.

## src/layout/engine.zig

The measure pass initializes every output rectangle, including structural pop commands that
own no geometry. Those entries previously retained allocation poison/uninitialized bytes,
which whole-frame comparisons and the simulator's rectangle checks could consume.

Layout uses bottom-up measurement and top-down positioning; frames with wrapped text or shrinkable nodes also resolve widths top-down and remeasure heights bottom-up. Container accumulators carry child totals between passes, avoiding rescans. Flex consumes main-axis leftover before justification, and cross-axis stretch uses the container's inner extent. Overlays do not contribute to parent measurement. Virtual lists claim their full logical extent even when only a visible window is emitted. A flex scroll starts with zero main-axis size unless explicitly sized so overflow remains possible. Layout stack overflow, underflow and empty reads panic in every optimization mode; the passes attach the command index when checking bounds. See `docs/features/layout.md`.

Grid passes rescan direct children while skipping subtrees via `Rect.end`, visiting each command only a bounded number of times; column scratch has fixed capacity and rows use one running accumulator. Positioned scroll children are offset and clipped by render and hit-test, while overlays do not advance the parent cursor. Rich-text measurement uses each span's font and defaults for uncovered bytes.

## src/render/build.zig

Base rendering pushes a zero clip for overlay children, defensively suppressing them until the overlay pass. A group's panel and text-selection highlights are emitted before their contents so painter order places content on top. Missing image handles render tinted placeholders. Disabled controls omit interaction feedback, focus, selection and caret. IME preedit comes from `TransientState`, draws inline with an underline, and is committed through the normal text-input message path; the caret moves to the end of the preedit. Canvas primitives use the intersection of their own rect and enclosing scroll or overlay clip; rotated polylines additionally use data-space Liang–Barsky clipping.

## src/core/dropdown.zig

Dropdown state is app-owned model data (`open` and selected index); option labels remain app-owned. The component emits existing button and modal-overlay primitives, with messages as data and the selection constructor supplied only at compile time. The three-argument component view has no option slice and shows the placeholder; applications use `viewWith` to supply labels. Open-list panels and rows fill the viewport width so clicks beside short labels select the row instead of falling through to the modal backdrop. See HARDLINE §1 and §3.

Opening sets the keyboard cursor to the selection; reveal waits for keyboard movement because the toggle message carries no viewport geometry. A stale cursor is clamped before movement so shrinking the option list cannot push the reveal offset beyond its maximum. Scrolling lists nest a scroll region inside the overlay; render and hit-test intersect both clips, and scroll calculations use `ITEM_HEIGHT` regardless of theme button height.

## src/platform/win32.zig

Integer `MAKEINTRESOURCE` identifiers may be odd and must not be represented as aligned UTF-16 pointers. Per-monitor DPI awareness makes Windows report physical pixels; the Host converts them to logical units. OLE `RegisterDragDrop` receives files, images and Unicode text from `IDataObject`; image conversions live in `win32_data.zig` and produce PNG data limited to 1,568 pixels plus an RGBA thumbnail. IME preedit is read through Imm APIs in UTF-16 units, while committed characters arrive through `WM_CHAR`. UI Automation queries run on a worker thread and share the published tree under `g_a11y_lock`; interface vtable pointers identify their owning provider. The truncated VARIANT layout is used only for the integer, BSTR and boolean values the bridge returns. These platform-owned surfaces remain behind the Host boundary; see HARDLINE §2 and §3.

The UIA snapshot copies arena-backed nodes into locked fixed storage because queries can arrive after the frame ends; it truncates beyond 256 nodes, and individual labels are capped at 512 bytes. Primary and secondary windows share the thread's Win32 message queue but keep separate input queues. Vertical wheel deltas are inverted to match Host coordinates. Alt alone and F10 are consumed for menu activation, while other Alt combinations continue to the system. The IME mirror is a 256-byte UTF-8 buffer and truncates at code point boundaries.

UIA control patterns enqueue actions from the worker thread for `Host.pollA11yActions` to deliver through the normal update path. Only the root delegates to `UiaHostProviderFromHwnd`; fragment children return null. The root provider is a process-lifetime singleton; `WM_GETOBJECT` returns its Simple interface and UIA queries the other interfaces as needed. Its static `AddRef` is safe because module storage owns the provider lifetime.

The Host adopts Windows' suggested rectangle on DPI change, triggering resize and layout, and forces a frame after invalidation even while idle. It suppresses the system IME window while rendering preedit inline; committed text still flows through `DefWindowProcW` and `WM_CHAR`, and the preedit mirror clears at commit. The UIA critical section is initialized per Host lifetime and deleted after listeners disconnect. Input edges survive the message pump, including the initial resize set during initialization.

Published UIA labels and values are copied out of the per-frame arena; labels that do not fit in the shared heap are cleared. Change notification uses the tree length and focused command as a coarse signal. Secondary input slices alias their queue until the next poll, and clearing a closed slot permits immediate ID reuse. Unclaimed Ctrl+V becomes a text or image paste.

## src/platform/wasm.zig

The accessibility mirror sends parents-first, little-endian 64-byte records and a UTF-8 heap synchronously to the zunk DOM shim. Record offsets are: command index 0, role 4, label offset/length 8/12, integer x/y/w/h 16–31, numeric state 32, flags 36, value offset/length 40/44, selection start/end 48/52, parent index 56 (`0xffffffff` for root), and heading/tree level 60. Role codes are defined by `wireRole` and must match zunk. The single-threaded Host reuses fixed buffers of 512 records and 32 KiB of strings; overflow nodes or strings are dropped, with oversized strings leaving an unlabeled record. Actions return in 16-byte records containing kind, command index, string offset and string length; the run loop turns them into input.

Zunk supplies both held input state and per-frame edges, including both edges for a click contained in one frame; wheel units are CSS pixels and positive means down/right. Touch client coordinates match canvas CSS coordinates because the canvas fills the page. Meta acts as Ctrl for chords but remains Meta in reported modifiers. Text arrives as whole UTF-8 code points and is revalidated. Browser file dialogs are asynchronous and gesture-gated, so the synchronous Host variants cannot provide them. Effect result slices remain valid until the next `pollInputs`.

## src/input/hit_test.zig

The independent simulator oracle found gallery seed 3, frame 91: at (1240, 740), an earlier
overlay leaf (104) won over a later modal backdrop (107). Encountering a modal under the point
now clears earlier layer candidates for click, wheel and drag routing. This affects any app
that stacks a modal after another overlay, rather than only gallery.

Overlay hits take precedence over the base layer. A modal overlay containing the pointer consumes the click even when no interactive leaf or backdrop message claims it; nested modals respect the parent clip, and later overlays win in painter order. Hover must claim the modal backdrop too: the Host compares the press target with the release hover before dispatching the hit, so omitting the backdrop there prevents click-outside handling. Decorative canvas and scene leaves pass clicks through unless they expose a click message or pointer surface. Disabled controls are non-interactive. Command-tag switches are exhaustive so new variants require classification.

## src/run.zig

The idle dispatch baseline precedes window/modifier hooks. Previously a modifier-only Msg
could change Model and still report quiet because its dispatch happened before the baseline.
The simulator checks that a quiet frame dispatched no Msg, including during the workload.

The simulator's Host supplies `now_ns` from its virtual clock, so frame statistics see
simulated time. InputState.focus_lost cancels an active group drag through its ordinary Msg,
clears armed presses/sliders and drops capture. The simulator emits it; native event translation
has not been changed. click_dispatches, text_dispatches and tab_moves only observe routing.

The entry point supplies `Options`; runtime initialization never resolves environment
overrides. Every time reading comes from the Host: optional `now_ns` supplies
monotonic nanoseconds for statistics, otherwise `nowMs() *| ns_per_ms` supplies
whole-millisecond precision. Native and headless Hosts preserve the previous awake-clock
statistics; headless animation/subscription time remains the independent fake `nowMs`.
Snapshot serialization stays here; `Host.files()` receives the destination and bytes in
atomic mode. Missing file capability silently disables snapshots, recording, replay and
statistics, as the web target did before. The control screenshot path encodes PNG bytes
without calling the entry-point file writer, then uses the same Host capability.

Input is routed using the previous frame's commands and rectangles, which describe what the user actually saw. Idle frames can redraw the cached frame solely for caret blinking without rerunning view or layout. A live secondary window reuses GPU scratch buffers, so the primary frame must rebuild while one is open; resource-table changes also force staging even if commands compare equal. Snapshot output is written on the first frame and content or window transitions, not on cosmetic blink ticks. Outstanding effects and a listening control channel keep input polling active at frame rate, because the Host cannot wake on the control socket itself. `Runtime.post` is how the owner of a hand-written loop delivers a Msg from outside (a sampler, a socket); the frame after a post always builds.

Keyboard navigation keeps text focus in the Model and uses loop navigation focus for non-text controls. Enter invokes `submitMsg` when provided except in a focused text area, where it remains a newline key. Modal backdrops can consume clicks without producing messages. Pointer capture ends on the last release and is dropped if its canvas disappears. Effect reconciliation forgets no-longer-listed effects before issuing new ones. Long window titles compare against the stored truncated prefix so they do not trigger a title update every frame. A user-closed secondary window is suppressed from reopening until the application's window intent changes. See HARDLINE §1 and §2.

Keyboard focus can also produce hover notifications for tooltips. The menu key and Shift+F10 use the context-menu hook when present; focused text-area motion resolves against wrapped layout. Clipboard chords query `clipboardText` and dispatch `clipboardMsg`. Captured canvases receive wheel events regardless of pointer location, and hover entry/exit is suspended during capture.

## src/platform/x11.zig

Xlib ABI declarations target 64-bit platforms: Display is opaque; Window, Atom, KeySym and Time are unsigned long; Bool is int. Display scale is resolved before window creation so logical dimensions can be converted to physical pixels. Window-close messages must match both the `WM_PROTOCOLS` type and `WM_DELETE_WINDOW` payload. Input methods may add event masks and get first refusal on each event; committed text is dropped rather than split when the queue overflows. Shortcut events are delivered alongside navigation, while Ctrl or Alt chords do not enter text. Without an input method, Unicode and Latin-1 keysyms map to code points and remaining input uses `XLookupString`. Wheel buttons 4–7 map to Host down/right-positive axes. Expose events force a redraw even while idle. Xcursor must be unloaded after closing the display. Clipboard INCR transfers arrive in property-change chunks; an unclaimed Ctrl+V is delivered asynchronously as text or an image.

## src/core/component.zig

A component provides default-initializable `Model`, tagged-union `Msg`, `update(*Model, Msg)` and `view(*const Model, cb, msgs)`. The view receives a Model pointer because slices emitted into commands may refer to Model storage and must outlive the call. Composed model fields require defaults; validation reports missing defaults at the component boundary. The generated buffer and message parameters are generic, so validation checks the concrete Model parameter and return type. See HARDLINE §2 hatch 1.

## src/core/component_list.zig

List messages carry stable item keys rather than array indices so focused children survive insertion, removal and reordering. A row with multiple text fields can expose separate focus variants; the app stores the item key and field in its Model and routes focused messages using the key. Message tags are selected at compile time.

## src/platform/wayland.zig

Wayland clipboard writes are non-blocking and unfinished bytes are handled by `pumpWrites`, so a slow reader cannot stall a frame. A reader that quits during transfer must not terminate the process. `TEAK_WL_NO_VIEWPORT=1` forces integer buffer scaling for compositor debugging. Unclaimed Ctrl+V begins an asynchronous paste; initial window setup waits for configure and scale announcements. `waitEvents` blocks in `poll` on the display fd between `prepare_read` and `cancel_read` and reads nothing, so `pollInputs` still sees every event; it wakes early for client-side key repeat and for clipboard transfers on their own fds. It has not been run against a live compositor.

## src/input/a11y.zig

The tree builder collects overlay nodes first; a modal overlay suppresses base-layer nodes so assistive technology does not expose controls blocked from input. Containers that do not emit a node pass their nearest emitted ancestor through to descendants. Overlay bounds respect the parent clip, and the overlay establishes a clip for its children, matching hit-test behavior. Queued actions retain text storage until the action queue empties, so compaction does not invalidate offsets.

## src/render/canvas_tess.zig

Line clipping trims centre lines to the clip rectangle; a thick quad can extend up to half its thickness past a trimmed endpoint. Polygon ear clipping falls back to a fan if no further ear is found. Triangle-list clipping uses a bounds pass and then per-triangle clipping with two scratch polygons. NaN endpoints must be rejected before Liang–Barsky comparisons because NaNs would otherwise pass the comparisons and produce invalid vertices. With downward y, positive signed area is clockwise on screen and the outside is left of each edge.

## src/platform/cocoa.zig

The view is layer-backed by a CAMetalLayer sized and scaled by AppKit. If a presented frame was dropped while a window was occluded, becoming visible requests a rebuild through the resize input because idle frames otherwise do not redraw. The non-blocking event pump lets Core Animation commit. Unclaimed Cmd+V becomes a text or PNG paste, while other Cmd or Ctrl chords do not enter text. Marked IME text is kept as UTF-8 with a byte-indexed caret and is never truncated within a code point.

## src/headless_run.zig

This module is an entry-point toolkit around Runtime, not code below Runtime. Its direct
I/O stays: `/proc/self/status` for process memory, stdout for CLI results, PNG output,
and the serve loop's real sleep. None of those helpers is called by Runtime or control;
control uses only the pure PNG encoder. Gpu readback is through the supplied Gpu.

`idleCheck` samples process memory after the idle window and before the offscreen Gpu is released, so the figure includes the driver. Committed bytes are `RssAnon + VmSwap`: private pages, including swapped ones. `latencyAfterClick` compares hashes of the frame snapshot without its transient header, so hover, press and caret phase do not count as a change; the snapshot is taken before the next `frame()` because command bytes die when the frame arena resets. A control that already presents a new view on mouse-down reports one frame and still receives the release. `--gates-json` only measures; pass and fail policy belongs to `tools/ci_gates.zig`.

## src/control.zig

Record/replay uses supplied FileIo. Replay reads at startup with a 64 MiB limit and rejects
old/unknown versions. A session captures ordered Host results for every frame. Its in-memory
publication is all-or-nothing: a failed frame never extends the complete stream. The file is
written every 32 complete records, on control `quit`, and at shutdown: the first write
replaces it and later writes append only the new frames, so a flush costs the same at frame
100,000 as at frame 32. A crash can leave a partial last frame; replay runs up to it and then
fails. Neither mode implies fsync. A write failure disables recording and reports once.
Recorded effect submissions are not performed during replay; their outcomes and subsequent
result bytes take the normal delivery path. Clipboard reads are captured before effect polls.
The record path borrows from Options, whose strings already outlive Runtime; no path copy is
needed. Session buffers are reserved together at startup.
The inspector's control state is captured after control processing. Raw control requests,
replies and screenshots are driver scheduling/outputs; injected input is captured after polling.

Commands are driven over frames: a click separates press and release because routing uses
the previous frame's layout. Text uses conservative 32-byte batches; the Host accepts 256
bytes. Selector offsets are relative to the node centre.

The socket starts listening during initialization; commands wait until the first frame has
been built, so selectors see laid-out commands. Replay supplies results starting at frame zero.

## src/input_record.zig

Pure format types, bounds and frame header parsing/writing. Version 2 begins with an exact
ASCII version line, followed by binary length-prefixed frame records, including quiet frames.
Each payload preserves Host call order. Unknown tags/versions, malformed values, missing or
extra calls and nonconsecutive frame numbers return errors. No old-format fallback exists.
Limits and integer/slice encoding are in docs/migration-recording.md.

## src/record_codec.zig

An explicit 1,024-job stack walks plain-data values with a one-million-visit bound. Jobs
carry typed visitors; payloads are scheduled, never recursively visited. Structs follow
declaration order, arrays and slices preserve order, enums/unions validate tags, and floats
retain their exact bits. Decoding reserves slices from the startup scratch buffer, aligned
to at most 16 bytes. It copies no pointers or padding and allocates nothing.

## src/record_session.zig

One startup reservation supplies the 1 MiB frame buffer, 1 MiB decoded-slice scratch and,
when recording, 64 MiB complete-stream buffer. No buffer grows. Every frame is validated
before routing on replay, then decoded into stable per-frame scratch as calls consume it.
Limit exhaustion stops recording once, counts it, and retains the complete prefix. Decode
failures latch a typed frame error; no failed replay calls the outside world as fallback.
Snapshot/statistics file-write success or failure is recorded when it happens inside a frame.
Replay reproduces a recorded failure without writing; successful outputs can still be written
locally. A local replay-output failure is logged without changing the recorded sink outcome.
Recorder persistence itself stays outside its own transcript, avoiding self-recording flushes.
Logical time and every statistics clock sample are separate transcript entries. The
measurer returned during initialization is wrapped at the first frame, when Runtime has
its final address. Recorded measurements make layout independent of local font metrics.
This wrapper is an ordinary Host interface value; Cmds and Models carry no callbacks.

## src/input/keys.zig

Shift-modified motion extends selection; Shift+Tab traverses focus backward. Plain Enter may submit, while Shift+Enter remains a newline key delivered to the app. Ctrl-modified motion and deletion operate by word or document boundary. F10 and a bare Alt tap request menu-bar activation; the Menu key and Shift+F10 request a context menu at the focused widget. The application decides whether to act on these requests.

## src/gpu/text_stage.zig

Colour glyphs use RGBA atlas pages and mode 2; their own colour is sampled instead of tinting coverage. Resolved atlas entries are reused across frames only while page generation and subpixel bin match. Fallback clusters use bin zero. The shaped-run cache uses open addressing and is cleared wholesale when its pools fill; without cross-frame caching a run is shaped into a pool reused by the next draw. SDF instance flags encode mode in bits 0–1 and quad scale in bits 16–31.

## src/core/text_field.zig

Each `TextField(N)` capacity has a distinct message type with the same shape. Key-dispatch helpers use compile-time field types and union construction to wrap local messages in an application's composed message.

## src/core/data_table.zig

Sorting is stable for equal rows in either direction. The header stays fixed outside the body scroll region. The table exposes one Tab stop on the cursor row's first cell, or the first displayed row when needed; application key routing then moves the table cursor.

## src/text/measure.zig

Cache entries compare text and every font field; the hash selects a slot but is not identity. The cache is cleared when the face table changes, and runs longer than `max_text` bypass it. Native builds use a larger two-way table; wasm uses a small table and an all-zero initial representation to avoid occupying the data section. Short ASCII runs bypass hashing and cache lookup.

## src/platform/host.zig

`FileIo` is a platform-neutral capability, not a file handle. Optional `Host.files()`
returns a context plus read/write functions; reads return caller-allocator-owned bytes,
and writes consume borrowed bytes synchronously. No capability or native implementation
is installed implicitly. The optional `now_ns` clock is separate from logical `nowMs`.

Optional Host surfaces are validated only when declared. A missing scale factor defaults to 1.0; effect submission and result polling are paired. The Host clock supplies subscriptions and other time-dependent services without reading time in `view`. Accessibility actions are polled before input routing. See HARDLINE §2 hatch 4 and §3.

## src/gpu/scene_pass.zig

The grid fades before its far plane. Gizmo rotation is recovered by normalizing the view-projection rows after removing projection scale; the perspective w row is the negative third view row.

## src/platform/native_effects.zig

Storage roots, picker choice, open/download overrides and dynamic `TEAK_<NAME>` parameters
come from the startup options. Query parameters retain argv precedence and Windows
case-insensitive environment names. Changes to the process environment after startup no
longer change effects. File and command-line access remain for later seam work.

Hosts with native clipboards intercept clipboard effects before the shared service. Windows UTC offsets combine the base bias with the active standard or daylight adjustment; current rules are used for the queried instant. Completed effects are delivered asynchronously by the Host.

## src/core/unicode.zig

Backward grapheme scanning can restart without prior context between adjacent ASCII bytes other than CR followed by LF. Kana and half-width kana count as letters even when their UAX #14 line-break class is NS or CJ.

## src/core/debug_overlay.zig

Overlay lines are formatted before commands are appended: callers can pass the command buffer's own slice, and appending first could reallocate it while it is being read.

## src/core/numeric_field.zig

`NumericField(config)` exposes the component Model, Msg, update and view plus value, validity, content and formatting accessors.

## src/platform/control_socket.zig

An overlong input line is discarded through its newline. Replies are single lines and the server sends no unsolicited messages, so a received chunk cannot contain another reply.

## src/platform/file_picker.zig

The dialog subprocess needs an allocating `Io` and receives the entry point's captured
environment, including display, session-bus and XDG variables needed by the desktop toolkit.
Its local `Io` starts with an empty environment; the child receives an explicit map.
Zenity and kdialog return status 1 for cancellation and 0 with the selected path on stdout.

## src/options.zig

`from_environment` is the sole environment reader in `src/`. It runs once from each native
entry point, applies overrides to consumer defaults and captures name/value pairs for dynamic
query parameters and picker children. Options own no allocator or mutable process handle.
Strings borrow the process initialization map; the entry array lives in its startup arena.
Both must outlive hosts, runtimes, reload images and effect workers. More than 65,536 entries
returns `EnvironmentTooLarge`; allocation failure is returned. Web and simulated callers use
explicit options without invoking the builder. Empty values retain the previous per-variable
semantics, including presence-only Cocoa debug and Wayland viewport switches.

## src/text/face.zig

Native Host startup supplies a Source containing captured options and two byte loaders.
Text owns parsing and the existing caches; it never opens a file or chooses a system path.
Primary overrides resolve at startup; default loading stays lazy. Embedded fallback bytes
take precedence over the source. Without either, only registered faces are available.
Source options borrow the entry point's startup storage. Registry/cache ownership stays
for the later phase 1 step. The first configured source remains until release, preserving
the old first-configuration fallback paths across Hosts; explicit primary overrides still
apply on the first primary load.

## src/text/fallback.zig

The cache retains four explicit faces, four source-supplied override slots and twenty
source-supplied system slots, preserving face ids and search order. It asks the configured
source for bytes on the first miss and remembers failed slots. Embedded web faces work
without a source. Discovery belongs to native_fonts; parsing and cache ownership stay here.

## src/dev.zig

The loader is an entry point around the loop. Its image open/close, mtime polling, copy
and debounce/poll sleeps stay here; Runtime never invokes it. Plugins still obtain all
loop I/O through their injected Host. Loading shared libraries can itself create threads
inside the OS or dependency implementation; Teak starts no thread in this module.

ABI version 2 passes Options into `envOpen`; each environment instance owns its copy and
reuses it across reloads. The loader builds the options once. Plugins no longer receive or
install a process environment in std globals. The environment fingerprint includes Options.

## src/frame_stats.zig

The sink formats bytes and retains samples without filesystem access. It creates/truncates
the CSV through FileIo at startup, appends buffered rows at 16 KiB and shutdown, and
replaces the summary at shutdown. The stderr summary remains a diagnostic. Failures
disable CSV writing after one warning. Existing growable buffers and sample allocation
remain outside this seam change.

## src/platform/native_io.zig

Native/headless Hosts export one shared implementation of the optional file and statistics
clock functions. Reads enforce the caller's positive byte limit. Replace truncates; atomic
writes a sibling `.tmp` then renames it; append writes at the existing file length without
creating a missing file. Each operation closes its handles before returning. Paths remain
relative to cwd unless absolute. Atomic temporary paths use a stack buffer sized to
std.Io.Dir.max_path_bytes and return NoSpaceLeft if the sibling does not fit.
The awake statistics clock preserves the previous clamp of negative readings to zero.

## src/platform/native_fonts.zig

All native font discovery lives here: Options.font_path, Windows directory candidates,
the ordered Unix/macOS primary probes, four nonempty colon-separated fallback overrides,
and twenty system fallback paths. Reads share native_io and retain the 32 MiB font limit.
Missing primary candidates continue to the next path; allocation failure returns to the
text caller. Empty files fail. Unlike the former libc fread loop, read errors are returned
rather than treated as end-of-file. Fonts remain lazy except for explicit primary overrides.

## src/core/widgets/split.zig

Focused-divider arrow keys adjust by `key_step`; Home and End request the minimum and maximum first-pane sizes, clamped by update.

## src/core/widgets/tooltip.zig

The tooltip prefers the widget's lower-left side, flipping above or right-aligned near the lower or right edge of the window.

## build.zig

Consumer helpers resolve lazy wgpu and zunk dependencies on Teak's builder, where the dependencies are declared. Host text measurement and GPU rasterization share the same stb module so metrics agree. X11 loads libX11 through `std.DynLib` and therefore needs libc's dlopen path; the executable itself must link libc. Wasm uses a libc shim for stb. Native GPU libraries are installed beside the executable and found through the platform runtime search path. The Windows ARM64 native-target workaround adds i8mm because Zig's detection misses it. Web applications with registered faces omit the built-in default; embedded faces are used for shaping while page font preloads do not block startup.

## examples/counter_greeter/src/app.zig

The composed application keeps focus in its app-level Model; the Host translates keyboard input into the focused component's messages. The greeter's focus click routes through app-level state rather than its component update. The help overlay is modal with a backdrop message and uses a fixed 900×500 backdrop; a real window-sized backdrop should use Host dimensions. Clipboard chords are serviced by the Host's clipboard path rather than ordinary key dispatch. The stats window is app intent consumed by the Host.

## examples/todo/src/app.zig

Row messages carry the current Model index. Deletion shifts items to preserve order; drag insertion accounts for the source removal shifting later indices. The count is a polite accessibility live region. Its text is allocated in the frame arena because a stack slice would outlive its buffer before layout.

## examples/tree/src/app.zig

Tree nodes are stored in preorder; a collapsed ancestor hides following deeper nodes until its
subtree ends. View iterates by pointer because commands borrow label slices from Model storage.
The outer scroll has an id; scrollLayoutMsg routes measured viewport/content heights into a
scroll_extent Msg. Update stores those heights and clamps both wheel/key deltas and extent
changes to [0, max(0, content - viewport)]. This covers collapse and resize without making view
read layout. The id-bearing region routes wheels through pointerMsg; the former global
wheelMsg is removed. A fixed-size empty scroll is used as a spacer. The prior zero-only clamp failed
tree seed 1 at frame 10 with scroll_y=654; the checker is unchanged.

## examples/kerf_viewer/src/app.zig

A URL request already in flight owns the request state, so only plain queries are chained. In the focused chat text area, Enter sends and Shift+Enter inserts a newline. Gizmo-cap clicks select a camera axis; other viewport clicks pick a part. Open shells use outline-only section rendering to avoid stencil-parity streaks. See `kerf/spec/DESIGN.md` §1 for the palette and header treatment.

## examples/chrome/src/app.zig

The popover intentionally overlaps the parts table so its opaque backdrop exercises occlusion of underlying text. Retro table rows use one pixel of padding because borders do not take layout space. The popover opens over 400 ms and closes faster.

## examples/vector_canvas/src/app.zig

Moment diagrams use the parabola of a uniformly loaded simple span. When a diagram changes sign, zero crossings split it into one filled polygon per lobe. Drawing order is braces, members, overlays, then node dots; view reuses slices owned by the Model.

## examples/scene_layers/src/app.zig

Sheet frame vectors use world units per sheet unit; a factor of 0.8 displays a 120×80 page at 96×64 inches. See `kerf/spec/DESIGN.md` for the palette.

## examples/sysmon

The App never reads the OS: `ui_main.zig` owns a `sys.Sampler`, reads the machine once a second and hands the reading to the Runtime with `Runtime.post`; the Model copies it. `sys.zig` holds the data types and turns two readings of cumulative counters into rates, so a backend only reports what the OS gives it. Process CPU is a share of the whole machine (one busy core of twenty is 5%). Processes are kept sorted by pid so a table row keeps its index while the process set is unchanged; when it changes, the table is reloaded and the selection is carried over by pid.

Linux reads `/proc` and `/sys/class/hwmon` through raw syscalls and allocates nothing; kernel threads are skipped (no address space), and only whole disks are summed because a partition's sectors are already in its disk's row. Windows uses `NtQuerySystemInformation` (per-core times, the process list), `GlobalMemoryStatusEx` and `K32GetPerformanceInfo`, `IOCTL_DISK_PERFORMANCE` on `\\.\PhysicalDriveN` opened with no access rights, and `GetIfTable2` without the filter-layer rows that repeat an adapter's counters; struct layouts are asserted at compile time. On both systems network traffic is summed over the adapters backed by hardware (a `device` link in sysfs, a physical connector on Windows) so a bridge, a virtual switch or a container's interface is not counted on top of the card behind it; a machine with no such adapter, as some virtual machines are, counts every adapter but the loopback. Windows reports no temperatures: they need WMI or vendor drivers. There is no GPU page: utilisation is vendor-specific on both systems. The headless shot feeds synthetic samples by default so the picture is the same everywhere; `--live` uses the real sampler.

## examples/tables/src/app.zig

The large Model arrays are heap allocated because the Runtime may otherwise exceed the Windows 1 MiB stack. One frame-time message advances whichever scroller is moving.

## examples/viewport/src/app.zig

Zoom keeps the world point under the cursor fixed. Grid labels are world-space scalable text, so one distance-field glyph set serves zoom levels from 0.2× to 8× without rerasterizing.

## examples/fonts/src/app.zig

Unsupported script glyphs fall back to browser canvas text on web and the missing-glyph box on native. Web colour emoji use RGBA atlas pages; native currently lacks a colour-font strike decoder.

## examples/counter_greeter/src/rich_zig_adapter.zig

The parsed text owns its plain buffer in the frame arena. It must not be deinitialized before the emitted slices are consumed; arena reset frees it in bulk.

## examples/kerf_viewer/src/draw/pick.zig

Picking considers text, fills, linework and interiors in that order. Linework chooses the nearest path with topmost ties; interiors choose the smallest enclosing region.

## src/gpu/glyph_atlas.zig

Allocation tries existing pages from newest to oldest, then opens a page, then resets the oldest page unused in the current frame. Dirty rectangles include padding to clear stale texels, and stale hash slots retain their probe chain.
