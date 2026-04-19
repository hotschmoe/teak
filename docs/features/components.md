# Comptime component composition

**Status**: `pub` in `src/teak.zig` as `Components`, `validateComponent`, and (via `teak.component.buildMsgs`) `buildMsgs`.
**Source**: `src/core/component.zig`
**Tests**: colocated — four `test "compose: ..."` blocks covering Model generation, Msg routing, view wrapping, and AppLevel extension.

Escape hatch 1 in [HARDLINE §2](../HARDLINE.md#escape-hatch-1-comptime-component-stitching). Read HARDLINE's bounds before proposing changes to this file.

## Contract

A **component** is any type exposing:

```zig
pub const Model = struct { ... };                                // default-initialisable
pub const Msg   = union(enum) { ... };                           // tagged union
pub fn update(model: *Model, msg: Msg) void;
pub fn view(model: *const Model, cb: anytype, msgs: anytype) void;
```

`view` takes `*const Model`, **not** `Model` by value. See [pitfalls.md](../pitfalls.md#1-component-view-taking-model-by-value) — by-value parameters dangle slices stored in `Cmd`.

### `validateComponent(comptime T: type) void`

Comptime-asserts the four decls exist with the right shape. Used by `Components` automatically; callable standalone when defining a bare component that won't (yet) be composed.

Compile-error format — always prefixed with the component type name:

```
Component 'MyWidget' is missing a 'Model' type
Component 'MyWidget'.Msg must be a TAGGED union, i.e. union(enum)
Component 'MyWidget'.update must take (*Model, Msg)
```

### `Components(comptime components: anytype, comptime AppLevel: ?type) type`

Returns a type with generated `Model`, `Msg`, `update`, `view`. `components` is an anonymous struct whose field names become the variant names of the composed `Msg` and the field names of the composed `Model`:

```zig
const App = teak.Components(.{
    .counter = Counter,
    .greeter = Greeter,
}, AppLevel); // or null

var model: App.Model = .{};           // counter: Counter.Model, greeter: Greeter.Model
App.update(&model, .{ .counter = .inc });
App.view(&model, &cb);
```

`AppLevel` (optional) extends the generated `Model` with extra fields and the generated `Msg` with extra variants. `AppLevel.update(model: *App.Model, msg: AppLevel.Msg)` is called for those variants. Field-name collisions with component names compile-error.

### `buildMsgs(comptime Comp, comptime variant_name, comptime AppMsg)`

Builds an anonymous struct with one field per payloadless variant of `Comp.Msg`, each holding a pre-wrapped `AppMsg`. `Components.view` calls this automatically. Exposed publicly so apps can hand-compose views that mix component emitters with app-level overrides.

## Invariants

- **Routing is total.** If `App.Msg` carries a component's tag, `App.update` calls that component's `update` — no other dispatch path exists.
- **No runtime reflection.** All name matching and union construction is comptime.
- **Order preserved.** Fields of `App.Model` and variants of `App.Msg` appear in the order given to `Components`.
- **No hidden state.** `App.Model` is a plain struct; nothing stashed behind a widget ID.

## Non-goals / known limits

- `buildMsgs` only wraps **payloadless** variants. A variant like `.append: u8` is skipped — the component's `view` must construct those `AppMsg` values explicitly (or use the manual composition path).
- AppLevel's `Msg` and each component's `Msg` share a flat variant namespace in the generated `App.Msg`. Collisions compile-error via the underlying `@Union` builder.
- The generated `Msg` tag type is `u16`. A composition with more than 65,535 combined variants would overflow — not a practical concern.
- Nested `Components` inside an AppLevel is untested. Use at your own risk until a test lands.

## Test coverage target

The colocated tests cover the happy path end-to-end. Before expanding this feature:

- **Negative validator tests.** Add a commented-out block per `@compileError` path with the expected message — HARDLINE §5 asks for 100 % validator coverage.
- **Nested composition.** One test with `Components` inside an AppLevel field, to confirm routing works through two layers.
- **Variant payload wrapping.** A test that a component's `.append: u8` variant gets wrapped correctly when driven through `App.update`.
