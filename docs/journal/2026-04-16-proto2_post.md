# Teak Proto 2 Postmortem

**Scope**: ~2,700 LOC across `cmd` / `layout` / `hit_test` / `render` / `transient` / `compose` + `counter` / `greeter` / `app` + Win32 wgpu host. Two commits on master (`a9d46f5` + `4ffbf19`) with one simplification pass between them.

## What's validated

**The core loop holds under composition.** `Model → view → []Cmd → layout → []Rect → render/hit-test` is identical whether the app has one widget or two independently-authored components. Adding Greeter alongside Counter didn't require touching any pass — they're genuinely independent.

**Comptime composition works.** `compose.Components(.{ .counter, .greeter }, AppLevel)` generates `Model`, `Msg`, `update` at comptime via `@Type` + `@typeInfo` + `@unionInit`. `buildMsgs` wraps payload-less variants via tag-name matching. Zero runtime routing cost — everything resolves to a direct switch arm. The compiler still enforces exhaustive Msg handling across the composed union.

**All-state-in-Model survives a stateful widget.** Text input keeps cursor, buffer, length explicit on `greeter.Model`. No hidden widget state, no IDs, no retained tree. Cursor movements, insert-at-middle, and backspace all work as pure `update` transitions. The `*const Model` view protocol prevents dangling slices into stack-copied fields — caught by the CLI canary (`input "f"` instead of `input "H"` → smoking gun).

**Flex layout as composition, not a widget property.** Wrapping greeter's view in a `pushGroup(.{ .flex = 1 })` from `app.view` gave flex behavior without coupling the greeter component to its parent's layout. This is the right factoring — widgets don't know their container.

**Keyboard routing without closures.** Text input carries only a `focus_msg`; keys become component Msgs at app level via `keyCharMsg` / `keySpecialMsg` based on `Model.focused`. This sidesteps the "Zig has no closures" problem entirely, and the app-level switch is more readable than embedded function pointers would have been.

**Double-buffered diff actually skips work.** Once fixed, the diff correctly skips ~99% of vertex rebuilds on idle frames (only the cursor-blink tick forces rebuilds while focused). String comparison (not pointer) is what makes this work with per-frame arena allocation.

**Press-then-release with drag-off cancel** — natural click semantics, no extra state beyond `press_target: ?usize`.

## Surprises that cost time

**Two variables that look identical but at different times are not redundant.** The simplifier collapsed `prev = current ^ 1` (pre-swap) and `prev_cur = current ^ 1` (post-swap) into one. They evaluated to different slot indices because `current` changed between the two captures. Result: diff compared current frame against itself, blank window until hover forced a rebuild.

*Lesson*: when simplifying, check the value across *time*, not just the expression.

**Ambiguous `Msg` in nested scope.** `pub const Msg = union(enum)` inside `AppLevel` collided with file-scope `pub const Msg = Composed.Msg`. Fix: `msg: @This().Msg` inside `AppLevel.update`. Worth remembering — Zig's name resolution in methods sees both enclosing and file scope.

**Model by value is silently dangerous.** Slices into `model.name[0..name_len]` dangle the moment `view` returns if `model` was passed by value. The CLI canary caught it because GPU rendering can't see a "printed slice with wrong bytes."

*Lesson*: for any component that builds slices of its own data, take `*const Model`, not `Model`.

**Arena-allocated strings need content comparison.** Pointer-eq is meaningless across frames because arenas reset. `std.mem.eql(u8, a.text.content, b.text.content)` is the only correct answer.

## Still open

- **Text rendering is a lie** — we draw colored placeholder quads, not glyphs. Monospace width approximation only.
- **`MAX_RECTS = 256`** — hardcoded cap. Fine for the proto, not for real UIs.
- **`focusIndex` is a linear scan for `.text_input`** — will break the moment we add a second focusable widget type.
- **No IME / multibyte / clipboard / scroll / tab-focus.**
- **Win32-only** — no platform abstraction yet.
- **No `Msg` with payload-carrying slices** — whether that survives the arena swap is untested. Probably needs a separate arena or copy-on-dispatch.

## Verdict on the architecture

The TEA + flat command buffer decomposition is paying for itself. Each file does one thing; the compiler catches missing Msg variants mechanically; adding a second component required zero changes to any pass. The comptime story is clean — generated code reads like hand-written code.

Remaining risk lives in the **host-integration layer** (`ui_main.zig` is 762 LOC — by far the biggest file), not the framework core. The double-buffer ping-pong belongs in a small abstraction rather than open-coded `current ^ 1` gymnastics — that's where the next bug will come from if we don't tighten it.
