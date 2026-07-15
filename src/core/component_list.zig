//! ComponentList: a comptime-generated dynamic list of homogeneous
//! sub-components. Closes ergonomic gap 5 — apps no longer hand-roll a
//! `[]ChildModel` + manual dispatch + manual per-index msg wrapping.
//!
//! HARDLINE-wise this lives under §2 hatch 1 (comptime component
//! stitching). Like `Components()`, it synthesizes a Model / Msg /
//! update / view from a child component, runs comptime-only, and has
//! no fn pointers in its Msg variants.
//!
//! Composition:
//!
//!     const Cards = teak.ComponentList(BeamCard, 64);
//!     const App   = teak.Components(.{ .cards = Cards }, AppLevel);
//!
//! `App.Msg.cards` carries `Cards.Msg`:
//!   - `.clear`         — empty the list.
//!   - `.append: ChildModel` — push a new child (assigns a stable key).
//!   - `.remove_at: usize`   — remove by visual index.
//!   - `.child: { key, child_msg }` — route a child's Msg to the item
//!     carrying that stable key.
//!
//! Inside Cards.view, the framework recovers the composed `AppMsg`
//! type from the standard msgs struct (via `@TypeOf(msgs.clear)`) and
//! finds the AppMsg variant whose payload is `Cards.Msg` — that's how
//! per-item child msgs are constructed without the caller threading
//! the AppMsg type through.
//!
//! ## Stable per-item identity (consumer issue #1)
//!
//! Child Msgs route by a **stable key**, not the item's current index.
//! Each item gets a monotonic `u64` key at `append` time (`next_key`
//! counter on Model); the key travels with the item across insert /
//! remove / reorder. Because a focused widget is identified by the `Msg`
//! value it carries (see `input/focus.zig`), keying that Msg off the
//! stable key — instead of a bare index that shifts when items move —
//! keeps a child's focused field focused as the list changes around it.
//!
//! This is an **explicit Model field**, not ID hashing: HARDLINE §3 bans
//! hashing ancestors+labels for identity but explicitly sanctions
//! "persistent widget identity … on Model as an explicit field." The key
//! is that field; nothing is hashed.
//!
//! Helpers for wiring focus without hand-building wrapped Msgs:
//!   - `keyAt(model, i)` / `indexOfKey(model, key)` — index ⇄ key.
//!   - `childMsg(key, child_msg)` / `childAt(model, i, child_msg)` — build
//!     a `.child` Msg by key / by visual index.
//!   - `focusedMsgForKey(key, child_msg, AppMsg)` /
//!     `focusedMsgFor(model, i, child_msg, AppMsg)` — build the composed
//!     AppMsg an item's focusable child carries, so an app's `focusedMsg`
//!     hook round-trips with what `view` emits.

const std = @import("std");
const component_mod = @import("component.zig");

pub fn ComponentList(comptime Child: type, comptime capacity: usize) type {
    component_mod.validateComponent(Child);

    return struct {
        const Self = @This();

        /// Inner indirection so `union(enum){.child: ChildEntry}` has
        /// a named payload type that humans can refer to. Routes by the
        /// item's stable `key`, not its shifting index.
        pub const ChildEntry = struct {
            key: u64,
            child_msg: Child.Msg,
        };

        pub const Model = struct {
            /// Items 0..len are live; the rest are stale storage.
            items: [capacity]Child.Model = [_]Child.Model{.{}} ** capacity,
            /// Parallel to `items`: `keys[i]` is the stable identity of
            /// `items[i]`, assigned at append time and carried through
            /// shifts. `0` is reserved as "no key".
            keys: [capacity]u64 = [_]u64{0} ** capacity,
            len: usize = 0,
            /// Next key to hand out. Monotonic; never reused within a
            /// list's lifetime, so a key uniquely identifies one item.
            next_key: u64 = 1,

            /// Slice the live portion of the list. Use for read-only
            /// iteration (rendering counters, summaries).
            pub fn slice(self: *const @This()) []const Child.Model {
                return self.items[0..self.len];
            }
        };

        pub const Msg = union(enum) {
            /// Drop every item. Capacity stays the same — the storage
            /// past `len` is just stale memory.
            clear,
            /// Push a fully-formed child onto the end. Silently drops
            /// the append if the list is at capacity (no allocation
            /// path — fixed-capacity storage is intentional).
            append: Child.Model,
            /// Remove the item at visual `idx` (shifts the tail down by
            /// one). Out-of-range indices are a no-op.
            remove_at: usize,
            /// Insert a fully-formed child *before* visual `idx` (shifts
            /// the tail up by one), assigning it a fresh stable key.
            /// `idx >= len` appends; a full list is a no-op. Existing
            /// items keep their keys, so a focused item below the
            /// insertion point stays focused.
            insert_at: InsertEntry,
            /// Swap the items (and their keys) at visual `a` and `b`.
            /// Keys travel with their items, so a focused item that moves
            /// stays focused. Out-of-range indices are a no-op.
            swap: SwapEntry,
            /// Forward a child's local Msg to the item carrying `key`.
            /// Unknown keys are a no-op (the item was removed).
            child: ChildEntry,
        };

        /// Payload for `.insert_at`.
        pub const InsertEntry = struct {
            idx: usize,
            model: Child.Model,
        };

        /// Payload for `.swap`.
        pub const SwapEntry = struct {
            a: usize,
            b: usize,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .clear => model.len = 0,
                .append => |item| {
                    if (model.len >= capacity) return;
                    model.items[model.len] = item;
                    model.keys[model.len] = model.next_key;
                    model.next_key += 1;
                    model.len += 1;
                },
                .remove_at => |i| {
                    if (i >= model.len) return;
                    var j = i;
                    while (j + 1 < model.len) : (j += 1) {
                        model.items[j] = model.items[j + 1];
                        model.keys[j] = model.keys[j + 1];
                    }
                    model.len -= 1;
                },
                .insert_at => |ins| {
                    if (model.len >= capacity) return;
                    const at = @min(ins.idx, model.len);
                    var j = model.len;
                    while (j > at) : (j -= 1) {
                        model.items[j] = model.items[j - 1];
                        model.keys[j] = model.keys[j - 1];
                    }
                    model.items[at] = ins.model;
                    model.keys[at] = model.next_key;
                    model.next_key += 1;
                    model.len += 1;
                },
                .swap => |s| {
                    if (s.a >= model.len or s.b >= model.len) return;
                    std.mem.swap(Child.Model, &model.items[s.a], &model.items[s.b]);
                    std.mem.swap(u64, &model.keys[s.a], &model.keys[s.b]);
                },
                .child => |c| {
                    const i = indexOfKey(model, c.key) orelse return;
                    Child.update(&model.items[i], c.child_msg);
                },
            }
        }

        // ── Stable-key helpers (pure) ──────────────────────────────────

        /// Stable key of the item at visual index `i`, or null if out of
        /// range.
        pub fn keyAt(model: *const Model, i: usize) ?u64 {
            if (i >= model.len) return null;
            return model.keys[i];
        }

        /// Visual index of the item carrying `key`, or null if no live
        /// item has it (removed / never existed).
        pub fn indexOfKey(model: *const Model, key: u64) ?usize {
            for (0..model.len) |i| {
                if (model.keys[i] == key) return i;
            }
            return null;
        }

        /// Build a `.child` Msg routed to the item carrying `key`.
        pub fn childMsg(key: u64, child_msg: Child.Msg) Msg {
            return .{ .child = .{ .key = key, .child_msg = child_msg } };
        }

        /// Build a `.child` Msg routed to the item at visual index `i`, or
        /// null if `i` is out of range. Resolves `i` to its stable key so
        /// the Msg stays valid even if the list shifts before it is
        /// dispatched.
        pub fn childAt(model: *const Model, i: usize, child_msg: Child.Msg) ?Msg {
            const key = keyAt(model, i) orelse return null;
            return childMsg(key, child_msg);
        }

        /// The composed AppMsg an item's focusable child carries, given the
        /// item's stable `key` and the child's focus Msg (e.g. `.focus`).
        /// Byte-identical to what `view` emits for that item, so an app's
        /// `focusedMsg` hook resolves to the right widget via
        /// `indexOfFocusMsg` and survives inserts / removes / reorders.
        pub fn focusedMsgForKey(
            key: u64,
            child_msg: Child.Msg,
            comptime AppMsg: type,
        ) AppMsg {
            const list_msg: Msg = .{ .child = .{ .key = key, .child_msg = child_msg } };
            // `@unionInit`'s field-name argument is already a comptime slot, so
            // `listTagName(AppMsg)` is forced to evaluate at comptime here —
            // no explicit `comptime` needed (and this toolchain rejects it as
            // redundant). The `view` call site, in a runtime scope, keeps its
            // explicit `comptime`.
            return @unionInit(AppMsg, listTagName(AppMsg), list_msg);
        }

        /// Like `focusedMsgForKey` but addressed by visual index, or null
        /// if `i` is out of range.
        pub fn focusedMsgFor(
            model: *const Model,
            i: usize,
            child_msg: Child.Msg,
            comptime AppMsg: type,
        ) ?AppMsg {
            const key = keyAt(model, i) orelse return null;
            return focusedMsgForKey(key, child_msg, AppMsg);
        }

        /// The name of the AppMsg variant whose payload is this list's
        /// `Msg` — the composed field the list was stitched under. Shared
        /// by `view` and the `focusedMsg*` helpers so both wrap identically.
        fn listTagName(comptime AppMsg: type) []const u8 {
            const app_info = @typeInfo(AppMsg).@"union";
            var name: []const u8 = "";
            var match_count: usize = 0;
            inline for (app_info.fields) |f| {
                if (f.type == Msg) {
                    name = f.name;
                    match_count += 1;
                }
            }
            if (match_count == 0) @compileError(
                "ComponentList: no variant of AppMsg carries Self.Msg. " ++
                    "ComponentList must be composed via Components(.{ .name = ComponentList(...) }).",
            );
            if (match_count > 1) @compileError(
                "ComponentList: multiple AppMsg variants carry Self.Msg — " ++
                    "two ComponentLists with the same Child+capacity in one composition. " ++
                    "Distinguish them by capacity or wrap one in a thin newtype.",
            );
            return name;
        }

        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            // msgs.clear is `AppMsg{ .<our_field> = .clear }` (built by
            // Components.buildMsgs). Its compile-time type is AppMsg.
            const AppMsg = @TypeOf(msgs.clear);
            const list_tag_name = comptime listTagName(AppMsg);

            const child_msg_info = @typeInfo(Child.Msg).@"union";

            for (0..model.len) |i| {
                // Build msgs for items[i]: one field per payloadless
                // Child.Msg variant, value = AppMsg{ .<list_tag_name> =
                // .{ .child = .{ .key = keys[i], .child_msg = .<variant> } } }.
                // Keying by the STABLE key (not `i`) is what lets a focused
                // child survive reordering — the focus Msg the leaf carries
                // moves with the item.
                const key = model.keys[i];
                var child_msgs: component_mod.MsgsStructFor(Child, AppMsg) = undefined;
                inline for (child_msg_info.fields) |f| {
                    if (f.type == void) {
                        const child_local: Child.Msg = @unionInit(Child.Msg, f.name, {});
                        const list_msg: Msg = .{ .child = .{ .key = key, .child_msg = child_local } };
                        @field(child_msgs, f.name) = @unionInit(AppMsg, list_tag_name, list_msg);
                    }
                }
                Child.view(&model.items[i], cb, child_msgs);
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd = @import("cmd.zig");

const Card = struct {
    pub const Model = struct { count: i32 = 0 };
    pub const Msg = union(enum) { increment, decrement, reset };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .increment => m.count += 1,
            .decrement => m.count -= 1,
            .reset => m.count = 0,
        }
    }

    pub fn view(m: *const Model, cb: anytype, msgs: anytype) void {
        _ = m;
        cb.button(msgs.increment, "+");
        cb.button(msgs.decrement, "-");
        cb.button(msgs.reset, "0");
    }
};

test "ComponentList passes validateComponent" {
    component_mod.validateComponent(ComponentList(Card, 8));
}

test "ComponentList.update: append + child dispatch + clear" {
    const Cards = ComponentList(Card, 4);
    var m: Cards.Model = .{};
    try std.testing.expectEqual(@as(usize, 0), m.len);

    Cards.update(&m, .{ .append = .{ .count = 0 } });
    Cards.update(&m, .{ .append = .{ .count = 5 } });
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqual(@as(i32, 5), m.items[1].count);

    Cards.update(&m, Cards.childAt(&m, 0, .increment).?);
    Cards.update(&m, Cards.childAt(&m, 0, .increment).?);
    try std.testing.expectEqual(@as(i32, 2), m.items[0].count);

    Cards.update(&m, Cards.childAt(&m, 1, .decrement).?);
    try std.testing.expectEqual(@as(i32, 4), m.items[1].count);

    Cards.update(&m, .clear);
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "ComponentList.update: remove_at shifts tail down" {
    const Cards = ComponentList(Card, 4);
    var m: Cards.Model = .{};
    Cards.update(&m, .{ .append = .{ .count = 1 } });
    Cards.update(&m, .{ .append = .{ .count = 2 } });
    Cards.update(&m, .{ .append = .{ .count = 3 } });
    Cards.update(&m, .{ .remove_at = 1 });
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqual(@as(i32, 1), m.items[0].count);
    try std.testing.expectEqual(@as(i32, 3), m.items[1].count);
    // Keys shift alongside items: item 2 (key 2) was removed, so the
    // survivors keep keys 1 and 3.
    try std.testing.expectEqual(@as(?u64, 1), Cards.keyAt(&m, 0));
    try std.testing.expectEqual(@as(?u64, 3), Cards.keyAt(&m, 1));
}

test "ComponentList.update: out-of-range remove_at is no-op" {
    const Cards = ComponentList(Card, 4);
    var m: Cards.Model = .{};
    Cards.update(&m, .{ .append = .{ .count = 1 } });
    Cards.update(&m, .{ .remove_at = 99 });
    try std.testing.expectEqual(@as(usize, 1), m.len);
}

test "ComponentList: append silently drops past capacity" {
    const Cards = ComponentList(Card, 2);
    var m: Cards.Model = .{};
    Cards.update(&m, .{ .append = .{} });
    Cards.update(&m, .{ .append = .{} });
    Cards.update(&m, .{ .append = .{} }); // capacity hit, dropped
    try std.testing.expectEqual(@as(usize, 2), m.len);
}

test "ComponentList: child dispatch on out-of-range idx is no-op" {
    const Cards = ComponentList(Card, 4);
    var m: Cards.Model = .{};
    Cards.update(&m, .{ .append = .{ .count = 7 } });
    // Unknown key → no-op (nothing routes to it).
    Cards.update(&m, Cards.childMsg(999, .increment));
    try std.testing.expectEqual(@as(i32, 7), m.items[0].count);
}

test "ComponentList composes via Components + child msgs route to items[idx]" {
    const Cards = ComponentList(Card, 4);
    const App = component_mod.Components(.{ .cards = Cards }, null);

    var m: App.Model = .{};
    App.update(&m, .{ .cards = .{ .append = .{ .count = 0 } } });
    App.update(&m, .{ .cards = .{ .append = .{ .count = 0 } } });
    try std.testing.expectEqual(@as(usize, 2), m.cards.len);

    // Increment card 1 three times (addressed by visual index → key).
    App.update(&m, .{ .cards = Cards.childAt(&m.cards, 1, .increment).? });
    App.update(&m, .{ .cards = Cards.childAt(&m.cards, 1, .increment).? });
    App.update(&m, .{ .cards = Cards.childAt(&m.cards, 1, .increment).? });
    try std.testing.expectEqual(@as(i32, 0), m.cards.items[0].count);
    try std.testing.expectEqual(@as(i32, 3), m.cards.items[1].count);
}

test "ComponentList.view: emits child cmds with composed-AppMsg routing" {
    const testing = std.testing;
    const Cards = ComponentList(Card, 4);
    const App = component_mod.Components(.{ .cards = Cards }, null);

    var m: App.Model = .{};
    App.update(&m, .{ .cards = .{ .append = .{ .count = 0 } } });
    App.update(&m, .{ .cards = .{ .append = .{ .count = 0 } } });

    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    App.view(&m, &cb);

    // Each card emits 3 buttons; 2 cards = 6 buttons total.
    try testing.expectEqual(@as(usize, 6), cb.cmds.items.len);

    // First card's increment button → AppMsg{ .cards = .{ .child = .{ .key = 1, .child_msg = .increment } } }.
    const m0 = cb.cmds.items[0].button.msg;
    try testing.expectEqual(@as(u64, 1), m0.cards.child.key);
    try testing.expectEqual(Card.Msg.increment, m0.cards.child.child_msg);

    // Fourth cmd is the second card's increment (stable key 2).
    const m3 = cb.cmds.items[3].button.msg;
    try testing.expectEqual(@as(u64, 2), m3.cards.child.key);
    try testing.expectEqual(Card.Msg.increment, m3.cards.child.child_msg);

    // Driving the second card's increment through update raises its count.
    App.update(&m, m3);
    try testing.expectEqual(@as(i32, 1), m.cards.items[1].count);
}

test "ComponentList.Model.slice() exposes only live items" {
    const Cards = ComponentList(Card, 8);
    var m: Cards.Model = .{};
    Cards.update(&m, .{ .append = .{ .count = 10 } });
    Cards.update(&m, .{ .append = .{ .count = 20 } });
    Cards.update(&m, .{ .append = .{ .count = 30 } });

    const s = m.slice();
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(i32, 10), s[0].count);
    try std.testing.expectEqual(@as(i32, 30), s[2].count);
}

// ── Per-item focus (stable keys) ────────────────────────────────────

const focus = @import("../input/focus.zig");

/// A focusable child: one text input whose focus click carries the
/// composed AppMsg. Exercises the stable-key focus story.
const Field = struct {
    pub const Model = struct { value: u8 = 0 };
    pub const Msg = union(enum) { focus };
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype, msgs: anytype) void {
        cb.textInput(msgs.focus, "", 0);
    }
};

/// Append `n` fields to the composed model.
fn appendFields(comptime App: type, m: *App.Model, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) App.update(m, .{ .fields = .{ .append = .{} } });
}

test "per-item focus: helper round-trips with indexOfFocusMsg + focusMsgAt" {
    const testing = std.testing;
    const Fields = ComponentList(Field, 8);
    const App = component_mod.Components(.{ .fields = Fields }, null);

    var m: App.Model = .{};
    appendFields(App, &m, 3);

    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    App.view(&m, &cb);
    const cmds = cb.cmds.items;

    // Three text inputs, one per field, in visual order.
    try testing.expectEqual(@as(usize, 3), cmds.len);

    // For each visual index, the helper's focus Msg resolves back to that
    // index, and the leaf at that index carries exactly that Msg.
    for (0..3) |i| {
        const fm = Fields.focusedMsgFor(&m.fields, i, .focus, App.Msg).?;
        try testing.expectEqual(@as(?usize, i), focus.indexOfFocusMsg(cmds, fm));
        try testing.expectEqual(@as(?App.Msg, fm), focus.focusMsgAt(cmds, i));
    }
}

test "per-item focus: Tab traversal walks fields in visual order and wraps" {
    const testing = std.testing;
    const Fields = ComponentList(Field, 8);
    const App = component_mod.Components(.{ .fields = Fields }, null);

    var m: App.Model = .{};
    appendFields(App, &m, 3);

    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    App.view(&m, &cb);
    const cmds = cb.cmds.items;

    try testing.expectEqual(@as(?usize, 0), focus.nextFocusable(cmds, null));
    try testing.expectEqual(@as(?usize, 1), focus.nextFocusable(cmds, 0));
    try testing.expectEqual(@as(?usize, 2), focus.nextFocusable(cmds, 1));
    try testing.expectEqual(@as(?usize, 0), focus.nextFocusable(cmds, 2)); // wrap
    try testing.expectEqual(@as(?usize, 1), focus.prevFocusable(cmds, 2));
}

/// Re-view helper: rebuild the cmd buffer against the current model.
fn viewInto(comptime App: type, m: *const App.Model, cb: anytype) void {
    cb.reset();
    App.view(m, cb);
}

test "per-item focus: survives remove-before the focused item" {
    const testing = std.testing;
    const Fields = ComponentList(Field, 8);
    const App = component_mod.Components(.{ .fields = Fields }, null);

    var m: App.Model = .{};
    appendFields(App, &m, 3); // keys 1, 2, 3

    // Focus the LAST field (visual index 2, stable key 3). The app would
    // stash this Msg value in its own focus field.
    const focused = Fields.focusedMsgFor(&m.fields, 2, .focus, App.Msg).?;

    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    viewInto(App, &m, &cb);
    try testing.expectEqual(@as(?usize, 2), focus.indexOfFocusMsg(cb.cmds.items, focused));

    // Remove the FIRST field — everything below shifts up by one index.
    App.update(&m, .{ .fields = .{ .remove_at = 0 } });
    viewInto(App, &m, &cb);

    // The stored focus Msg (key 3) still resolves — now to index 1. A
    // bare-index Msg would have pointed at the wrong (or a missing) field.
    try testing.expectEqual(@as(?usize, 1), focus.indexOfFocusMsg(cb.cmds.items, focused));
    // And the helper for the item now at index 1 reproduces the same Msg.
    try testing.expectEqual(
        @as(?App.Msg, focused),
        Fields.focusedMsgFor(&m.fields, 1, .focus, App.Msg),
    );
}

test "per-item focus: survives insert-before the focused item" {
    const testing = std.testing;
    const Fields = ComponentList(Field, 8);
    const App = component_mod.Components(.{ .fields = Fields }, null);

    var m: App.Model = .{};
    appendFields(App, &m, 3); // keys 1, 2, 3

    // Focus the MIDDLE field (visual index 1, stable key 2).
    const focused = Fields.focusedMsgFor(&m.fields, 1, .focus, App.Msg).?;

    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    viewInto(App, &m, &cb);
    try testing.expectEqual(@as(?usize, 1), focus.indexOfFocusMsg(cb.cmds.items, focused));

    // Insert a new field at the front — the focused item shifts down.
    App.update(&m, .{ .fields = .{ .insert_at = .{ .idx = 0, .model = .{} } } });
    viewInto(App, &m, &cb);

    // Focus follows the key to its new visual index 2.
    try testing.expectEqual(@as(?usize, 2), focus.indexOfFocusMsg(cb.cmds.items, focused));
}

test "per-item focus: survives a swap that moves the focused item" {
    const testing = std.testing;
    const Fields = ComponentList(Field, 8);
    const App = component_mod.Components(.{ .fields = Fields }, null);

    var m: App.Model = .{};
    appendFields(App, &m, 3); // keys 1, 2, 3

    // Focus the FIRST field (visual index 0, stable key 1).
    const focused = Fields.focusedMsgFor(&m.fields, 0, .focus, App.Msg).?;

    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    viewInto(App, &m, &cb);
    try testing.expectEqual(@as(?usize, 0), focus.indexOfFocusMsg(cb.cmds.items, focused));

    // Swap first and last — the focused item moves to the end.
    App.update(&m, .{ .fields = .{ .swap = .{ .a = 0, .b = 2 } } });
    viewInto(App, &m, &cb);

    try testing.expectEqual(@as(?usize, 2), focus.indexOfFocusMsg(cb.cmds.items, focused));
    // The key travelled with the item: index 2 now holds key 1.
    try testing.expectEqual(@as(?u64, 1), Fields.keyAt(&m.fields, 2));
}

test "ComponentList.update: insert_at shifts tail up and assigns a fresh key" {
    const Cards = ComponentList(Card, 4);
    var m: Cards.Model = .{};
    Cards.update(&m, .{ .append = .{ .count = 1 } }); // key 1
    Cards.update(&m, .{ .append = .{ .count = 3 } }); // key 2
    Cards.update(&m, .{ .insert_at = .{ .idx = 1, .model = .{ .count = 2 } } }); // key 3

    try std.testing.expectEqual(@as(usize, 3), m.len);
    try std.testing.expectEqual(@as(i32, 1), m.items[0].count);
    try std.testing.expectEqual(@as(i32, 2), m.items[1].count);
    try std.testing.expectEqual(@as(i32, 3), m.items[2].count);
    // Existing items keep their keys; the inserted one gets the fresh key.
    try std.testing.expectEqual(@as(?u64, 1), Cards.keyAt(&m, 0));
    try std.testing.expectEqual(@as(?u64, 3), Cards.keyAt(&m, 1));
    try std.testing.expectEqual(@as(?u64, 2), Cards.keyAt(&m, 2));

    // insert_at past the end appends; a full list is a no-op.
    Cards.update(&m, .{ .insert_at = .{ .idx = 99, .model = .{ .count = 9 } } });
    try std.testing.expectEqual(@as(usize, 4), m.len);
    try std.testing.expectEqual(@as(i32, 9), m.items[3].count);
    Cards.update(&m, .{ .insert_at = .{ .idx = 0, .model = .{ .count = 7 } } }); // full → drop
    try std.testing.expectEqual(@as(usize, 4), m.len);
}
