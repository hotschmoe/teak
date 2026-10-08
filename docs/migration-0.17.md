# Migrating to Zig 0.17

Teak (and zunk, rich_zig and webzocket) now require **Zig 0.17.0**. Zig 0.16 is
no longer supported. There is no API change in teak's public surface; the
changes below are in how you build and in any build-time reflection you wrote
yourself.

## For consumers

- **`build.zig.zon`**: set `.minimum_zig_version = "0.17.0"`. Re-pin `teak`,
  `zunk` and (if you use it) `rich_zig` to commits that contain their 0.17
  migration.
- **`build.zig`**: `b.args` is gone. Replace

  ```zig
  if (b.args) |args| run.addArgs(args);
  ```

  with `run.addPassthruArgs();`. Every `examples/*/build.zig` shows the new form.
- **Optimize mode names** are lowercase: `.debug`, `.safe`, `.fast`, `.small`
  (`std.builtin.OptimizeMode` keeps its name; the old `.ReleaseFast` etc. are
  deprecated aliases). `builtin.mode == .Debug` becomes `.debug`.
- `teak.linkNativeWgpu`, `linkWebWgpu` and `linkHeadless` keep their
  signatures. Internally the wgpu-native and stb_truetype headers are now
  imported through `b.addTranslateC` modules named `wgpu-c` / `stb-c`
  (`@cImport` was removed from the language); consumers do not need to do
  anything.

## Language changes you may hit in app code

- Array and string repetition with `**` is gone. Use `@splat`:
  `var buf: [64]u8 = @splat(0);`, `items: [N]Item = @splat(.{})`. For a repeated
  multi-element pattern use an array of arrays: `const px: [4][4]u8 = @splat(.{ 255, 0, 0, 255 });`
  then `std.mem.asBytes(&px)`.
- `@typeInfo` now stores struct, union, enum and function data as parallel
  arrays: `field_names`, `field_types`, `field_attrs` (and `field_values` for
  enums, `param_types` for functions). The old `.fields` / `.params` slices of
  records are gone, as are `std.meta.fields` and friends. Code that reflects
  over a component's `Model` or `Msg` should iterate
  `inline for (info.field_names, info.field_types) |name, T|`. The comptime
  composition in `core/component.zig` and `core/component_list.zig` shows the
  pattern; it passes `field_attrs` straight through to `@Struct` / `@Union`.
- `std.EnumSet(E).initEmpty()` is now `.empty`.
- `@enumFromInt` / `@intFromEnum` are `@fromBackingInt` / `@backingInt` (run
  `zig fmt` and it upgrades them).

## Cleanup renames

The core cleanup renamed no public declarations (names already follow the Zig
style guide). Behaviour changes to know about:

- `SceneCmd.eql` was removed; use `core/eql.zig`'s `deepEql(SceneCmd(Msg), a, b)`
  (or `teak.runtime.cmdsEqual` on a slice).
- `teak.MAX_BALANCE_DEPTH` is 64 (was 32).
- Unbalanced / too-deep cmd buffers now panic in release builds too (the
  per-frame balance check used to be Debug-only); a stray `popFormRow` panics
  instead of being ignored.

