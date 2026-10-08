# Teak feature docs

One file per `pub` surface unit. The rule (from HARDLINE §5 drift audit):
anything marked `pub` in `src/teak.zig` needs a feature doc before it
can be blessed for 1.0.

A feature doc is a *contract*, not a tutorial. Tutorials live in
`examples/`; task-oriented recipes ("add X to my app") live in the
[cookbook](../cookbook.md); deep architecture notes live in `spec.md`. Docs
here answer four questions in the same order every time — so a reader
skimming ten of them builds the same mental map for each.

## Template

```markdown
# <Feature name>

**Status**: <`pub` in `src/teak.zig` | internal | `pub` but not re-exported>
**Source**: `src/<path>.zig`
**Tests**: `src/<path>.zig` test block | `test/integration_test.zig` | n/a

## Contract

Signatures, pre/post conditions, caller obligations. Compile-error
format if the feature is a comptime validator.

## Invariants

What the feature guarantees to callers. What it does NOT guarantee.

## Non-goals / known limits

Explicit boundaries. Things a naive reader might assume work but don't.

## Test coverage target

What must be tested for this feature to stay honest. Links to existing
tests; names the gaps.
```

## Current docs

| Feature | Doc |
|---|---|
| **Consuming Teak (start here)** | [../consuming-teak.md](../consuming-teak.md) |
| Application loop (`teak.run`) | [run.md](run.md) |
| Subscriptions (declarative timers `Sub` / `subscribe`) | [subscriptions.md](subscriptions.md) |
| Declarative effects (`Effect` / `effects` / `effectMsg`: HTTP, files, storage, paste/drop) | [effects.md](effects.md) |
| Widgets: disabled / NumericField / Dropdown / setTitle | [widgets.md](widgets.md) |
| Canvas: charts & custom 2D drawing | [canvas.md](canvas.md) |
| 3D scenes + declarative resources | [scene3d.md](scene3d.md) |
| Fixed-column monospace tables (`teak.table`) | [tables.md](tables.md) |
| Comptime component composition | [components.md](components.md) |
| Transient (presentation-only) state | [transient-state.md](transient-state.md) |
| Host interface (window + input) | [host.md](host.md) |
| Gpu interface (frame structure, MSAA, scenes, images) | [gpu.md](gpu.md) |
| Headless native runs: scripted input -> PNG | [headless.md](headless.md) |
| Visual regression (golden screenshots, `zig build vreg`) | [visual-regression.md](visual-regression.md) |
| Hit-test + hover-test | [hit-test.md](hit-test.md) |
| Layout engine | [layout.md](layout.md) |
| Focus traversal | [focus.md](focus.md) |
| Text: engine overview, supported subset, fonts, shaping, editing, IME (`FontSpec`, `TextMeasurer`, `Shaper`) | [text.md](text.md) |
| Multi-line editing (`text_area`, `TextArea`, `textMsg`) | [text-area.md](text-area.md) |
| Text engine design record (glyph atlas, shaper, wrap, editor; PR status table) | [text-engine.md](text-engine.md) |
| Golden snapshot tests + live `TEAK_SNAPSHOT` | [snapshot.md](snapshot.md) |
| Ergonomic helpers (Theme, mixedText, ComponentList, …) | [ergonomic-helpers.md](ergonomic-helpers.md) |
| Functional gaps (8 features) — yolo push | [functional-gaps.md](functional-gaps.md) |

## Not yet documented

`Cmd` / `CmdBuffer` / the widget emitters (`button`, `text`, `textInput`,
`checkbox`, `radio`, `slider`, `pushGroup`, `pushScroll`) — the command
surface itself. Treated as stable-by-example for the prototype;
write a doc before adding a seventh widget variant.
