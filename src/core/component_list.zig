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
            items: [capacity]Child.Model = @splat(.{}),
            /// Parallel to `items`: `keys[i]` is the stable identity of
            /// `items[i]`, assigned at append time and carried through
            /// shifts. `0` is reserved as "no key".
            keys: [capacity]u64 = @splat(0),
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
            inline for (app_info.field_names, app_info.field_types) |field_name, field_type| {
                if (field_type == Msg) {
                    name = field_name;
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
            const AppMsg = @TypeOf(msgs.clear);
            const list_tag_name = comptime listTagName(AppMsg);

            const child_msg_info = @typeInfo(Child.Msg).@"union";

            for (0..model.len) |i| {
                // Stable keys keep focused children attached through reorder.
                const key = model.keys[i];
                var child_msgs: component_mod.MsgsStructFor(Child, AppMsg) = undefined;
                inline for (child_msg_info.field_names, child_msg_info.field_types) |field_name, field_type| {
                    if (field_type == void) {
                        const child_local: Child.Msg = @unionInit(Child.Msg, field_name, {});
                        const list_msg: Msg = .{ .child = .{ .key = key, .child_msg = child_local } };
                        @field(child_msgs, field_name) = @unionInit(AppMsg, list_tag_name, list_msg);
                    }
                }
                Child.view(&model.items[i], cb, child_msgs);
            }
        }
    };
}


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



/// Re-view helper: rebuild the cmd buffer against the current model.
fn viewInto(comptime App: type, m: *const App.Model, cb: anytype) void {
    cb.reset();
    App.view(m, cb);
}






const text_field_mod = @import("text_field.zig");

const LoadRow = struct {
    const TF = text_field_mod.TextField(16);
    pub const Model = struct { p: TF.Model = .{}, a: TF.Model = .{} };
    pub const Msg = union(enum) {
        /// Clicks on the two inputs (payloadless: ComponentList wires these).
        focus_p,
        focus_a,
        /// Edits routed to one field.
        p: TF.Msg,
        a: TF.Msg,
    };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .focus_p, .focus_a => {},
            .p => |x| TF.update(&m.p, x),
            .a => |x| TF.update(&m.a, x),
        }
    }
    pub fn view(m: *const Model, cb: anytype, msgs: anytype) void {
        cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4 });
        cb.textInputSelected(msgs.focus_p, m.p.content(), m.p.cursor, m.p.selection_anchor, cb.theme.text_input);
        cb.textInputSelected(msgs.focus_a, m.a.content(), m.a.cursor, m.a.selection_anchor, cb.theme.text_input);
        cb.popGroup();
    }
};

const LoadRows = ComponentList(LoadRow, 8);
const LoadComp = component_mod.Components(.{ .rows = LoadRows }, null);

/// The app: composed model + "which row's which field has focus".
const LoadApp = struct {
    pub const Which = enum { p, a };
    pub const Model = struct {
        comp: LoadComp.Model = .{},
        focus: ?struct { key: u64, field: Which } = null,
    };
    pub const Msg = LoadComp.Msg;

    /// Learn focus from the row's focus click, then delegate.
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .rows => |rm| switch (rm) {
                .child => |c| switch (c.child_msg) {
                    .focus_p => m.focus = .{ .key = c.key, .field = .p },
                    .focus_a => m.focus = .{ .key = c.key, .field = .a },
                    else => {},
                },
                else => {},
            },
        }
        LoadComp.update(&m.comp, msg);
    }

    fn childAppMsg(key: u64, child: LoadRow.Msg) Msg {
        return .{ .rows = LoadRows.childMsg(key, child) };
    }

    /// `teak.run` hooks.
    pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
        const f = m.focus orelse return null;
        return childAppMsg(f.key, switch (f.field) {
            .p => .{ .p = .{ .char = c } },
            .a => .{ .a = .{ .char = c } },
        });
    }

    pub fn focusedMsg(m: *const Model) ?Msg {
        const f = m.focus orelse return null;
        return LoadRows.focusedMsgForKey(f.key, switch (f.field) {
            .p => .focus_p,
            .a => .focus_a,
        }, Msg);
    }

    fn rowOf(m: *const Model, key: u64) ?*const LoadRow.Model {
        const i = LoadRows.indexOfKey(&m.comp.rows, key) orelse return null;
        return &m.comp.rows.items[i];
    }
};

fn inputIndices(cmds: anytype, out: []usize) usize {
    var n: usize = 0;
    for (cmds, 0..) |c, i| {
        if (c == .text_input) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

