# Visual regression (golden screenshots)

**Status**: tooling (`tools/vreg.zig`, `zig build vreg`); built on `teak.headless` (`shotCli`, `encodePng`, `decodePng`).
**Source**: `tools/vreg.zig`, `src/headless_run.zig`, each `examples/*/src/shot_main.zig`, goldens in `test/golden/`.
**Tests**: `zig build test` (compare logic in `tools/vreg.zig`, PNG round-trip in `headless_run.zig`); CI jobs `vreg` and `vreg-web`.

## What it checks

Every example has `zig build shot -- out.png [--state <name>]` (`-- --list` prints the states). A state is a
scripted input run (`teak.headless.Step`) against the real App on the headless wgpu backend, so a golden
covers layout, text, hit-routing (clicks that must land), and render together.

`zig build vreg` renders every state of every example and compares with `test/golden/<example>-<state>.png`.
A pixel *differs* when any RGB channel is off by more than `--tol`; a shot fails when more than `--budget`
pixels differ (or the size changed). Failures write `zig-out/vreg/<name>.actual.png` and `<name>.diff.png`
(expected image dimmed; differing pixels red, within-tolerance noise dark yellow) and print a table with
counts, max delta and the bounding box of the change.

```
zig build vreg                             # all examples, native
zig build vreg -- --examples todo,tree     # a subset
zig build vreg -- --state three_items      # one state name
zig build vreg -- --web                    # web builds in headless Chromium vs test/golden/web/<example>.png
zig build vreg -- --update                 # rewrite goldens that fail (or are missing)
```

Native shots need a Vulkan device (lavapipe works); `--web` needs Chromium/Chrome (`CHROME_PATH`) and
`cd tools && npm ci` (puppeteer-core). On a host with a hardware driver whose ANGLE-swiftshader cannot
create a display, set `WEBSHOT_ANGLE=vulkan`. scene3d has no web golden: its orbit runs on the wall clock.

## Tolerances

Defaults (`tools/vreg.zig`): native `--tol 24 --budget 150`, web `--tol 32 --budget 600`. They are chosen
so the Mali-vs-lavapipe antialiasing difference passes while a 1 px layout shift (a shifted button is ~290
differing pixels) or a missing text row fails. Deliberate-regression checks (todo example, raw `--tol 0 --budget 0`): widening one gap by 1 px shifted the Add
button and changed 290 pixels (bbox 148..208 x 48..84), over the native budget of 150; commenting out the title text
reflowed the page (12,760+ pixels). Same-box reruns are bit-identical (0 noisy pixels), so any difference is real
except GPU/driver AA on CI. Tighten
a single run with `--tol 0 --budget 0` to see the raw difference.

## When a change is intentional (the `--update` workflow)

Anything that changes rendering (glyph atlas, theme colours, layout metrics, a widget redesign) fails vreg
until the goldens move:

1. `zig build vreg` and open `zig-out/vreg/*.diff.png` and `*.actual.png` (LOOK at them).
2. `zig build vreg -- --update` (add `--web` for the web goldens).
3. LOOK at every changed `test/golden/*.png` before committing; goldens define "correct", so a golden
   that looks wrong is a bug to report, not to enshrine.
4. Commit the PNGs with the change. Goldens are produced on the maintainer box; if CI (lavapipe) fails by a
   hair after an update, regenerate from the CI artifact instead of loosening the tolerance.

## Known issues recorded in goldens

- Web buttons place the label ~3 px higher than native (`textBaseline = 'top'` vs the ascent baseline);
  visible in `test/golden/web/{todo,tree,counter_greeter,effects}.png`. Fix, then `--update --web`.
- counter_greeter's light theme keeps the dark `clear_color`, so its text is unreadable; no golden is kept for it.

## Cookbook

See [cookbook recipe 15](../cookbook.md): add a golden screenshot test for your own example.
