# Teak feature docs

One file per `pub` surface unit. The rule (from HARDLINE §5 drift audit):
anything marked `pub` in `src/teak.zig` needs a feature doc before it
can be blessed for 1.0.

A feature doc is a *contract*, not a tutorial. Tutorials live in
`examples/`; deep architecture notes live in `spec.md`. Docs here answer
four questions in the same order every time — so a reader skimming ten
of them builds the same mental map for each.

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
| Comptime component composition | [components.md](components.md) |
| Transient (presentation-only) state | [transient-state.md](transient-state.md) |
| Host interface (window + input) | [host.md](host.md) |
| Gpu interface (vertex upload + present) | [gpu.md](gpu.md) |
| Hit-test + hover-test | [hit-test.md](hit-test.md) |
| Layout engine | [layout.md](layout.md) |
| Focus traversal | [focus.md](focus.md) |

## Not yet documented

`Cmd` / `CmdBuffer` / the widget emitters (`button`, `text`, `textInput`,
`checkbox`, `radio`, `slider`, `pushGroup`, `pushScroll`) — the command
surface itself. Treated as stable-by-example for the prototype;
write a doc before adding a seventh widget variant.
