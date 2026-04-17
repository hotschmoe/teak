# TEA + Command Buffer: A Zig-Native UI Framework

> *We have a new language. Let's build something new.*

## Motivation

Every generation of UI frameworks has been shaped by the language it was written in. Cocoa is inseparable from Objective-C's message passing. React is inseparable from JavaScript's closures. Elm Architecture is inseparable from Elm's algebraic types. Qt is inseparable from C++'s inheritance and a custom preprocessor bolted on top.

Zig is a genuinely new language with genuinely new properties. Porting an existing paradigm wholesale — reimplementing Qt in Zig, or shoehorning React's model into a language without closures — misses the opportunity. The interesting question is: *what UI paradigm would you invent if Zig were your only language?*

This document is an answer to that question. It may not be the best UI framework ever built. But it is an honest attempt to let the language lead the design, and in doing so, to explore ideas that might inspire others — in Zig or beyond.

## Goals

1. **Zig-idiomatic.** The framework should feel like Zig, not like a foreign paradigm forced into Zig syntax. If a design choice fights the language, we change the design, not the language.

2. **Comptime-leveraged.** Zig's compile-time metaprogramming is its most distinctive feature. The framework should use comptime not as a convenience but as a structural advantage — generating code, enforcing invariants, and eliminating boilerplate that other frameworks handle with macros, inheritance, or runtime reflection.

3. **LLM-friendly and predictable.** Modern development increasingly involves LLM-assisted code generation. The framework should have a shape that LLMs can reliably understand, predict, and extend. This means: regular patterns, explicit state, enumerated transitions, and linear code flow.

4. **Cross-platform via wgpu.** Native graphics on desktop, WebGPU via WASM on the web. One rendering backend, one codebase.

5. **Novel.** Not a port. Not a clone. Something new, shaped by the intersection of Zig's properties and the problem space of interactive UIs.

---

## The Zig Properties That Matter

Before choosing a paradigm, we have to name the forces. Zig gives us specific tools and denies us others, and both matter equally.

### Zig Gives Us

- **Comptime metaprogramming** — type inspection, code generation, `@typeName`, `@fieldName`, `@typeInfo`, inline loops over struct fields. A full compile-time evaluator, not a text macro system.
- **Tagged unions with exhaustive switching** — `union(enum)` types where the compiler enforces every variant is handled. This is Zig's answer to algebraic data types.
- **Explicit allocators** — every allocation site names its allocator. Arena allocators for bulk alloc/free. No hidden heap traffic.
- **Arena allocators** — allocate many things, free them all at once. Perfect for per-frame transient data.
- **`anytype` / duck-typing at comptime** — generic functions that operate on any type matching a structural contract, resolved and monomorphized at compile time.
- **First-class C interop** — `@cImport` directly. No bindings layer, no FFI ceremony.
- **WASM target** — first-class compilation to WebAssembly.
- **Packed structs and `MultiArrayList`** — SOA layouts, cache-friendly data organization.
- **Error unions and optionals** — explicit, type-safe error handling without exceptions.
- **Function pointers + context pointers** — the manual closure substitute.

### Zig Denies Us

- **Closures / capturing lambdas** — no implicit capture of surrounding scope.
- **Inheritance** — no class hierarchies, no virtual dispatch without manual vtables.
- **RTTI** — no runtime type information.
- **Operator overloading** — no custom syntax for domain-specific notation.
- **Implicit allocation** — nothing allocates without you asking.
- **Trait / interface dispatch** — no built-in mechanism without hand-rolled vtables.

### wgpu Constrains Us To

- A render loop (request frame → encode commands → submit → present).
- Command buffer encoding — you don't draw directly, you record drawing commands.
- GPU resources that lag CPU by a frame or two.
- A pipeline model that rewards batching draw calls.

---

## Paradigm Analysis

We evaluated six UI paradigms against Zig's properties. Here is what we found, and why each one either contributed to or was surpassed by the final design.

### Immediate Mode (IMGUI)

The classic. No persistent widget objects. The function call *is* the widget:

```zig
if (ui.button("Save")) save();
ui.slider("Speed", &state.speed, 0, 100);
```

**Zig fit:** Strong. No closures needed. State is the caller's. Explicit allocators mean the framework can be zero-alloc per frame. `anytype` enables generic widgets that operate on any field pointer. Comptime can auto-generate inspector panels from struct definitions.

**What we took from it:** The linear, imperative view function. The "call it and it draws" ergonomics. The principle that state lives in the application, not the framework.

**Why it's not enough:** Stateful widgets (text inputs, scroll positions, animation timers, focus tracking) need to survive across frames. Classic IMGUI solves this with ID hashing and hidden state caches — a retained-mode subsystem smuggled in through a side channel. This hidden state is implicit, hard to debug, and exactly the kind of thing Zig's philosophy rejects. You end up maintaining a secret hash map of widget state that doesn't appear anywhere in the user's code, and when IDs collide, the bugs are silent and baffling.

For LLMs, the linear view code is excellent, but the ID/state caching is a trap. LLMs will generate broken ID hierarchies because the rules are implicit and contextual.

### Retained Mode (Traditional Widget Trees)

Qt, GTK, Cocoa. Build a persistent tree of widget objects, mutate properties, the framework redraws dirty subtrees.

**Zig fit:** Poor. Widget trees demand polymorphism. In Zig, that means either a `union(enum)` that grows enormous as widget types are added, or manual vtables that lose exhaustive switching. Both are awkward. The synchronization problem — keeping app state and widget state in agreement — is worse without closures or property bindings.

**What we took from it:** Nothing directly. Retained mode's strengths (layout engines, accessibility, platform integration) come from decades of platform-specific infrastructure, not from the paradigm itself.

**Why it lost:** It fights the language at every level. Polymorphism without inheritance is painful. Synchronization without closures or bindings is manual and error-prone. Scattered mutation sites make LLM comprehension difficult — the widget tree is built imperatively across many functions, and understanding which node is being modified where requires tracking object identity through time. This is the worst fit for Zig.

### Elm Architecture (TEA / Model-View-Update)

Purely functional cycle: a Model (state), a View function (Model → UI), and an Update function (Model × Msg → Model).

**Zig fit:** Remarkably strong, for a paradigm born in a functional language.

The critical insight: **Zig's tagged unions are Elm's message types.** A `union(enum)` with exhaustive `switch` gives you the same guarantee Elm gets from its algebraic data types — every possible state transition is enumerated and the compiler verifies you handle all of them. Zero runtime cost.

```zig
const Msg = union(enum) {
    increment,
    decrement,
    set_name: []const u8,
};

fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .set_name => |n| model.name = n,
    }
}
```

No closures needed. Event handlers don't capture state; they name a message variant. Comptime can generate `Msg` types from `Model` annotations, validate update exhaustiveness, and produce serializers for the entire message history — giving you Elm's time-travel debugger for free.

**What we took from it:** The entire state management layer. Model-as-struct, Msg-as-tagged-union, Update-as-switch is the core of our design.

**Where TEA alone falls short:** Traditional TEA builds a virtual DOM and diffs it. Virtual DOM allocation and tree diffing are unnecessary overhead when you have a GPU render loop already running at 60fps. We replace the virtual DOM with something better suited to wgpu.

### Reactive / Signals / Fine-Grained Reactivity

Solid.js, Leptos, SwiftUI. State wrapped in "signals" with automatic dependency tracking and recomputation.

**Zig fit:** Adversarial in classic form. Signals require a runtime dependency graph (dynamic allocation, pointer chasing) and closure-based subscriptions (no closures in Zig). 

A comptime-static variant is conceivable — resolve the dependency DAG at compile time, generate optimal update code with no runtime tracking. But this sacrifices dynamic reactivity (no creating signals at runtime) and adds conceptual overhead for marginal benefit over TEA. The dependency relationships are implicit, which hurts LLM comprehension: predicting update cascades and debugging stale values is hard even for humans.

**What we took from it:** The *idea* of dirty-checking. If the Model hasn't changed, the view hasn't changed. But we handle this at a coarser granularity with command buffer diffing rather than fine-grained signal tracking.

**Why it lost:** The abstraction cost is high, the Zig fit is poor without heavy comptime machinery, and the benefit over TEA is marginal once you remove dynamic signal creation. The implicit dependency graph is also the least LLM-friendly pattern we evaluated.

### Entity-Component-System (ECS)

Bevy UI style. Widgets are entities, properties are components, layout and rendering are independent systems operating on flat data arrays.

**Zig fit:** Strong at the data layer. `MultiArrayList` gives you SOA storage natively. Systems are plain functions over slices — no closures, no inheritance, no virtual dispatch. Cache lines are happy. Comptime can generate archetype storage and component queries.

**What we took from it:** The multi-pass architecture. Layout, hit-testing, and rendering as independent passes over shared data is an ECS idea. We adopted this for our command buffer passes.

**Why it lost as the primary paradigm:** Ergonomics. "Put a button here" becomes spawning an entity with five component insertions. Simple things are verbose. The compositional power of ECS is best suited to problems with truly emergent behavior (game entities, simulations), not to structured UI hierarchies where a developer knows the exact layout they want. The indirection between "I want a button" and the resulting entities/components also hurts LLM predictability.

### Command Buffer / Retained-Immediate Hybrid

This is the novel contribution. Inspired by how wgpu itself works.

UI code emits commands into a flat buffer. Layout, hit-testing, and rendering are separate passes over that buffer. The buffer is arena-allocated per frame and bulk-freed.

```zig
fn view(model: Model, cmd: *CmdBuffer) void {
    cmd.push_group(.{ .layout = .vertical, .padding = 8 });
    cmd.text("Count: {}", .{model.count});
    cmd.button("increment", "+");
    cmd.button("-", .decrement);
    cmd.pop_group();
}
```

**Zig fit:** Ideal. The command buffer is a flat array of tagged unions — Zig's bread and butter. Arena-allocated per frame. No tree, no pointers, no indirection. Passes are independent functions over `[]Cmd` slices. The entire UI for a frame is a value type: serializable, comparable, loggable.

It mirrors wgpu's own architecture: you don't draw to the screen, you record commands, then submit them. Anyone who understands wgpu already understands this mental model.

**What we took from it:** The entire rendering/view layer.

**Why it wins over IMGUI rendering:** IMGUI draws inline — the widget call immediately emits vertices. This couples view logic to rendering and makes layout dependent on call order. Command buffers decouple emission from consumption: emit all commands, then lay them out, then render. Multi-pass layout (measuring, then positioning) becomes trivial.

---

## The Design: TEA Core + Command Buffer Rendering

The final architecture combines TEA's state management with command-buffer rendering.

### State Layer: TEA

The application state is a struct. Every possible state transition is a variant of a tagged union. The update function is a switch.

```zig
const Model = struct {
    count: i32 = 0,
    name: []const u8 = "world",
    input_cursor: usize = 0,
    scroll_y: f32 = 0,
};

const Msg = union(enum) {
    increment,
    decrement,
    set_name: []const u8,
    cursor_move: usize,
    scroll: f32,
};

fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .set_name => |n| model.name = n,
        .cursor_move => |pos| model.input_cursor = pos,
        .scroll => |dy| model.scroll_y += dy,
    }
}
```

**Stateful widgets are solved, not hidden.** A text input's cursor position is a field in the Model. Scroll offsets are in the Model. Animation progress is in the Model. There is no hidden widget state cache. Everything is visible, inspectable, and serializable.

**Undo/redo is free.** Log the `Msg` history. Replay from the beginning to any point. This is Elm's time-travel debugger, available because the entire state transition space is explicit.

### View Layer: Command Buffer

The view function emits commands into a flat, arena-allocated buffer. It does not draw anything. It does not allocate persistent state. It runs every frame.

```zig
fn view(model: Model, cmd: *CmdBuffer) void {
    cmd.push_group(.{ .layout = .vertical, .gap = 8 });

    cmd.text("Hello, {s}!", .{model.name});
    cmd.text("Count: {d}", .{model.count});

    cmd.push_group(.{ .layout = .horizontal, .gap = 4 });
    cmd.button(.increment, "+");
    cmd.button(.decrement, "-");
    cmd.pop_group();

    cmd.text_input(.set_name, model.name, .{
        .cursor = model.input_cursor,
    });

    cmd.pop_group();
}
```

Commands are a tagged union:

```zig
const Cmd = union(enum) {
    push_group: GroupStyle,
    pop_group,
    text: TextCmd,
    button: ButtonCmd,
    text_input: TextInputCmd,
    image: ImageCmd,
    spacer: f32,
    custom: CustomCmd,
};
```

### Passes

After the view function fills the command buffer, independent passes process it:

```
view(model, &cmds)
        │
        ▼
  ┌─────────────┐
  │  []Cmd flat  │   ← arena-allocated tagged unions
  │    buffer    │
  └──────┬──────┘
         │
    ┌────┼─────────────────┐
    ▼    ▼                 ▼
 layout  hit_test       render
  pass    pass            pass
    │       │               │
    ▼       ▼               ▼
 []Rect   ?Msg     wgpu draw calls
```

Each pass is a plain function: `fn layout_pass(cmds: []Cmd, constraints: Constraints) []Rect`. No callbacks, no closures, no object graphs. An LLM can reason about each pass independently.

### Double Buffering and Diffing

Two arenas alternate each frame. Frame N's commands live in arena A; frame N+1's commands go into arena B. Because commands are flat arrays of tagged unions, diffing is a linear scan, not a tree walk. If nothing changed, skip the render pass entirely.

After diffing, the old arena is bulk-freed. Zero per-widget deallocation. Zero fragmentation.

### Comptime

This is where the design becomes distinctly Zig. Comptime is not an optimization — it's a structural feature.

**Auto-generated views from Model types.** Given a struct, comptime can emit a default inspector panel: a slider for every `f32`, a checkbox for every `bool`, a text field for every `[]const u8`. Useful for debug tools and rapid prototyping.

**Msg validation.** Comptime can verify that every variant of `Msg` is handled in `update`. If you add a message and forget the switch arm, it won't compile — but we can additionally generate a compile error with a human-readable message naming the missing variant.

**Serialization for free.** Comptime can generate JSON or binary serializers for both `Model` and `Msg`. Undo/redo, save/load, network sync, and time-travel debugging all fall out of this.

**Command metadata.** Comptime can attach accessibility labels, debug names, and test identifiers to commands based on the `Msg` variant and field names they reference.

---

## LLM Friendliness

This deserves its own section because it is a first-class design goal, not an afterthought.

### Why This Pattern Is LLM-Predictable

The entire application follows one pattern:

1. **Add a field to Model.** (The new state.)
2. **Add a variant to Msg.** (The new transition.)
3. **Add a switch arm to update.** (The new behavior.)
4. **Add `cmd.*` calls to view.** (The new UI.)

Every feature addition follows these four steps, in this order. An LLM can mechanically produce correct code for each step because:

- The Model is a flat struct — the LLM knows every field.
- The Msg is an exhaustive tagged union — the LLM knows every possible event.
- The update is a switch — the LLM knows exactly where to add logic.
- The view is linear command emission — the LLM pushes commands in order.

There is no hidden state. No callback graph. No implicit dependency tracking. No inheritance hierarchy to navigate. No framework lifecycle methods to remember. The LLM sees the entire state space and transition space in one place.

### What LLMs Struggle With (And How We Avoid It)

| LLM failure mode             | Our mitigation                                      |
| ---------------------------- | --------------------------------------------------- |
| Losing track of mutable state scattered across objects | All state in one Model struct |
| Generating broken callback/closure chains | No closures. Messages are data. |
| Misunderstanding widget identity/ID systems | No ID hashing. Widgets are commands. |
| Missing implicit framework lifecycle hooks | No lifecycle. Just update and view. |
| Producing inconsistent event wiring | Msg union enforces exhaustive handling. |

---

## Why Something New?

The pragmatic argument for porting an existing framework is: it's proven, it has an ecosystem, the design problems are solved. But there are counter-arguments.

**Languages shape paradigms.** Objective-C's message dispatch made Cocoa possible. JavaScript's closures and prototypal inheritance made React possible. Elm's algebraic types and purity made TEA possible. Zig's comptime, tagged unions, and explicit allocation make *this* possible — whatever "this" turns out to be. Porting React to Zig gives you React with worse ergonomics. Building from Zig's strengths gives you something React can't express.

**Novel work inspires.** Elm Architecture was a PhD experiment that reshaped how millions of developers think about UI state. Immediate mode was a 2005 conference talk that spawned an entire ecosystem. Even ideas that don't win outright change how the next generation of frameworks are designed. A Zig-native UI paradigm, even an imperfect one, adds to the design vocabulary of the field.

**The best time to experiment is now.** Zig's ecosystem is young. There is no entrenched incumbent, no backwards-compatibility burden, no "we've always done it this way." The cost of being wrong is low. The potential upside of being interestingly right is high.

We're not claiming this is the final answer. We're claiming it's a genuinely new question, asked in a language that enables genuinely new answers, and that the asking is worthwhile.

---

## Summary

| Layer            | Paradigm          | Zig mechanism                     |
| ---------------- | ----------------- | --------------------------------- |
| State            | TEA               | struct + `union(enum)` + `switch` |
| View             | Command buffer    | `[]Cmd` in arena allocator        |
| Layout           | Multi-pass        | `fn([]Cmd) []Rect`                |
| Rendering        | wgpu              | Command encoder from `[]Rect`     |
| Input            | Hit-test pass     | `fn([]Cmd, []Rect, Mouse) ?Msg`   |
| Metaprogramming  | Comptime          | Type reflection + code generation |
| LLM integration  | Mechanical pattern| struct → union → switch → cmds    |

---

*This document is a living design. The ideas here are meant to be challenged, extended, and proven or disproven by implementation.*
