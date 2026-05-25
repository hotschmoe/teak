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
//!   - `.append: ChildModel` — push a new child.
//!   - `.remove_at: usize`   — remove by index.
//!   - `.child: { idx, child_msg }` — route a child's Msg to items[idx].
//!
//! Inside Cards.view, the framework recovers the composed `AppMsg`
//! type from the standard msgs struct (via `@TypeOf(msgs.clear)`) and
//! finds the AppMsg variant whose payload is `Cards.Msg` — that's how
//! per-index child msgs are constructed without the caller threading
//! the AppMsg type through.

const std = @import("std");
const component_mod = @import("component.zig");

pub fn ComponentList(comptime Child: type, comptime capacity: usize) type {
    component_mod.validateComponent(Child);

    return struct {
        const Self = @This();

        /// Inner indirection so `union(enum){.child: ChildEntry}` has
        /// a named payload type that humans can refer to.
        pub const ChildEntry = struct {
            idx: usize,
            child_msg: Child.Msg,
        };

        pub const Model = struct {
            /// Items 0..len are live; the rest are stale storage.
            items: [capacity]Child.Model = [_]Child.Model{.{}} ** capacity,
            len: usize = 0,

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
            /// Remove the item at `idx` (shifts the tail down by one).
            /// Out-of-range indices are a no-op.
            remove_at: usize,
            /// Forward a child's local Msg to `items[idx]`. Out-of-range
            /// indices are a no-op.
            child: ChildEntry,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .clear => model.len = 0,
                .append => |item| {
                    if (model.len >= capacity) return;
                    model.items[model.len] = item;
                    model.len += 1;
                },
                .remove_at => |i| {
                    if (i >= model.len) return;
                    var j = i;
                    while (j + 1 < model.len) : (j += 1) {
                        model.items[j] = model.items[j + 1];
                    }
                    model.len -= 1;
                },
                .child => |c| {
                    if (c.idx >= model.len) return;
                    Child.update(&model.items[c.idx], c.child_msg);
                },
            }
        }

        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            // msgs.clear is `AppMsg{ .<our_field> = .clear }` (built by
            // Components.buildMsgs). Its compile-time type is AppMsg.
            const AppMsg = @TypeOf(msgs.clear);

            // Find the AppMsg variant whose payload type is our Msg.
            // That's our composed field name — the same name we'd use
            // in `@unionInit(AppMsg, <name>, list_msg)`.
            const app_info = @typeInfo(AppMsg).@"union";
            comptime var list_tag_name: []const u8 = "";
            comptime var match_count: usize = 0;
            inline for (app_info.fields) |f| {
                if (f.type == Msg) {
                    list_tag_name = f.name;
                    match_count += 1;
                }
            }
            if (match_count == 0) @compileError(
                "ComponentList.view: no variant of AppMsg carries Self.Msg. " ++
                    "ComponentList must be composed via Components(.{ .name = ComponentList(...) }).",
            );
            if (match_count > 1) @compileError(
                "ComponentList.view: multiple AppMsg variants carry Self.Msg — " ++
                    "two ComponentLists with the same Child+capacity in one composition. " ++
                    "Distinguish them by capacity or wrap one in a thin newtype.",
            );

            const child_msg_info = @typeInfo(Child.Msg).@"union";

            for (0..model.len) |i| {
                // Build msgs for items[i]: one field per payloadless
                // Child.Msg variant, value = AppMsg{ .<list_tag_name> =
                // .{ .child = .{ .idx = i, .child_msg = .<variant> } } }.
                var child_msgs: component_mod.MsgsStructFor(Child, AppMsg) = undefined;
                inline for (child_msg_info.fields) |f| {
                    if (f.type == void) {
                        const child_local: Child.Msg = @unionInit(Child.Msg, f.name, {});
                        const list_msg: Msg = .{ .child = .{ .idx = i, .child_msg = child_local } };
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

    Cards.update(&m, .{ .child = .{ .idx = 0, .child_msg = .increment } });
    Cards.update(&m, .{ .child = .{ .idx = 0, .child_msg = .increment } });
    try std.testing.expectEqual(@as(i32, 2), m.items[0].count);

    Cards.update(&m, .{ .child = .{ .idx = 1, .child_msg = .decrement } });
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
    Cards.update(&m, .{ .child = .{ .idx = 99, .child_msg = .increment } });
    try std.testing.expectEqual(@as(i32, 7), m.items[0].count);
}

test "ComponentList composes via Components + child msgs route to items[idx]" {
    const Cards = ComponentList(Card, 4);
    const App = component_mod.Components(.{ .cards = Cards }, null);

    var m: App.Model = .{};
    App.update(&m, .{ .cards = .{ .append = .{ .count = 0 } } });
    App.update(&m, .{ .cards = .{ .append = .{ .count = 0 } } });
    try std.testing.expectEqual(@as(usize, 2), m.cards.len);

    // Increment card 1 three times.
    App.update(&m, .{ .cards = .{ .child = .{ .idx = 1, .child_msg = .increment } } });
    App.update(&m, .{ .cards = .{ .child = .{ .idx = 1, .child_msg = .increment } } });
    App.update(&m, .{ .cards = .{ .child = .{ .idx = 1, .child_msg = .increment } } });
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

    // First card's increment button → AppMsg{ .cards = .{ .child = .{ .idx = 0, .child_msg = .increment } } }.
    const m0 = cb.cmds.items[0].button.msg;
    try testing.expectEqual(@as(usize, 0), m0.cards.child.idx);
    try testing.expectEqual(Card.Msg.increment, m0.cards.child.child_msg);

    // Fourth cmd is the second card's increment.
    const m3 = cb.cmds.items[3].button.msg;
    try testing.expectEqual(@as(usize, 1), m3.cards.child.idx);
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
