//! Toasts: transient notifications stacked in a corner that dismiss
//! themselves. Zero new Cmd variants: a non-modal `overlay` anchored at the
//! window's bottom-right holding one bordered card per toast.
//!
//! Auto-dismiss is a countdown in the Model driven by a declarative
//! `Sub.every(TICK_MS)` the app lists only while toasts are showing
//! (`Toast.active`): no wall clock in `update`, no timers hidden in the
//! widget, fully deterministic in tests.
//!
//! Each toast slides in from the right and fades, and slides / fades out when
//! it expires or is dismissed, with a `teak.anim.Tween` kept in its entry. The
//! tweens advance from the app's `animationMsg` (`Msg.frame`, dt in ms) while
//! `Toast.animating` is true; wire that like any other animation
//! (docs/features/animation.md). An app that never forwards frames still works:
//! toasts then appear fully shown and leave the moment they expire.
//!
//! ```zig
//! const Toasts = teak.widgets.toast.Toast(4, 80);          // 4 at once, 80 bytes each
//! // update:  .toast => |t| Toasts.update(&m.toasts, t),
//! //          .saved  => Toasts.push(&m.toasts, .success, "Saved", Toasts.default_ttl),
//! // subscribe: if (Toasts.active(&m.toasts)) -> .{ .every = .{ .interval_ms = toast.TICK_MS, .msg = .{ .toast = .tick } } }
//! //            if (Toasts.animating(&m.toasts)) -> .animation_frame
//! // animationMsg(m, dt): return .{ .toast = .{ .frame = dt } };
//! // view (last): Toasts.viewWith(&m.toasts, cb, msgs, .{ .window_w = w, .window_h = h });
//! ```

const std = @import("std");
const cmd = @import("../cmd.zig");
const component = @import("../component.zig");
const util = @import("util.zig");
const anim = @import("../anim.zig");

/// Suggested `Sub.every` interval; a toast's lifetime is counted in these ticks.
pub const TICK_MS: u32 = 250;

pub const Kind = enum { info, success, warning, danger };

/// Slide / fade durations in ms.
pub const enter_ms: u32 = 240;
pub const leave_ms: u32 = 180;
/// Ticks after which a leaving toast is dropped even without animation frames.
pub const leave_ticks: u8 = 2;

pub const ViewOpts = struct {
    window_w: f32,
    window_h: f32,
    /// Card width in px.
    width: f32 = 320,
    /// Distance from the window's bottom-right corner.
    margin: f32 = 16,
    /// Gap between stacked cards.
    gap: f32 = 8,
    /// Card height (fixed, so the stack's positions are known without layout).
    height: f32 = 44,
};

/// `cap` toasts at once, each holding up to `text_cap` bytes (longer text is truncated).
pub fn Toast(comptime cap: usize, comptime text_cap: usize) type {
    return struct {
        pub const capacity = cap;
        /// 4 seconds at `TICK_MS`.
        pub const default_ttl: u16 = 16;

        pub const Entry = struct {
            id: u32 = 0,
            kind: Kind = .info,
            text: [text_cap]u8 = @splat(0),
            len: u16 = 0,
            /// Ticks left; 0 means "sticky until dismissed".
            ttl: u16 = 0,
            /// How shown the card is, 0 (off to the right, transparent) .. 1.
            show: anim.Tween(f32) = anim.Tween(f32).still(1),
            /// Sliding out; removed once `show` reaches 0.
            leaving: bool = false,
            /// Ticks spent leaving: an app that never forwards animation
            /// frames still sees the toast removed (after `leave_ticks`).
            leave_age: u8 = 0,
        };

        pub const Model = struct {
            items: [cap]Entry = @splat(.{}),
            /// Oldest first; the newest is drawn last (bottom of the stack).
            len: usize = 0,
            next_id: u32 = 1,
        };

        pub const Push = struct {
            kind: Kind = .info,
            text: []const u8,
            ttl: u16 = default_ttl,
        };

        pub const Msg = union(enum) {
            /// Show a toast (the text is copied immediately).
            push: Push,
            /// Remove the toast with this id (its dismiss button).
            dismiss: u32,
            /// One `TICK_MS` elapsed.
            tick,
            /// Advance the slide / fade tweens by `dt` ms (from `animationMsg`).
            frame: u32,
            clear,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .push => |p| push(model, p.kind, p.text, p.ttl),
                .dismiss => |id| for (model.items[0..model.len]) |*e| {
                    if (e.id == id) leave(e);
                },
                .tick => {
                    var i: usize = 0;
                    while (i < model.len) {
                        const e = &model.items[i];
                        if (e.leaving) {
                            e.leave_age +|= 1;
                            if (e.leave_age >= leave_ticks) {
                                removeAt(model, i);
                                continue;
                            }
                        } else if (e.ttl == 1) {
                            e.ttl = 0;
                            leave(e);
                        } else if (e.ttl > 1) e.ttl -= 1;
                        i += 1;
                    }
                },
                .frame => |dt| {
                    var i: usize = 0;
                    while (i < model.len) {
                        const e = &model.items[i];
                        e.show.advance(dt);
                        if (e.leaving and !e.show.active()) {
                            removeAt(model, i);
                            continue;
                        }
                        i += 1;
                    }
                },
                .clear => model.len = 0,
            }
        }

        /// Start sliding `e` out.
        fn leave(e: *Entry) void {
            if (e.leaving) return;
            e.leaving = true;
            e.show.start(0, leave_ms, .in_cubic);
        }

        /// Add a toast directly (from the app's own `update`). `ttl` in ticks;
        /// 0 = sticky. A full stack drops its oldest toast.
        pub fn push(model: *Model, kind: Kind, text: []const u8, ttl: u16) void {
            if (model.len == cap) removeAt(model, 0);
            var e: Entry = .{ .id = model.next_id, .kind = kind, .ttl = ttl };
            e.show = anim.Tween(f32).still(0);
            e.show.start(1, enter_ms, .out_cubic);
            model.next_id +%= 1;
            const n = @min(text.len, text_cap);
            @memcpy(e.text[0..n], text[0..n]);
            e.len = @intCast(n);
            model.items[model.len] = e;
            model.len += 1;
        }

        fn remove(model: *Model, id: u32) void {
            for (model.items[0..model.len], 0..) |e, i| {
                if (e.id == id) return removeAt(model, i);
            }
        }

        fn removeAt(model: *Model, i: usize) void {
            std.mem.copyForwards(Entry, model.items[i .. model.len - 1], model.items[i + 1 .. model.len]);
            model.len -= 1;
        }

        /// True while any toast has a countdown running or is leaving: the app lists the
        /// tick subscription only then, so an idle app wakes for nothing.
        pub fn active(model: *const Model) bool {
            for (model.items[0..model.len]) |e| if (e.ttl > 0 or e.leaving) return true;
            return false;
        }

        /// True while any slide / fade is in flight: the app lists
        /// `Sub.animation_frame` only then.
        pub fn animating(model: *const Model) bool {
            for (model.items[0..model.len]) |e| if (e.show.active()) return true;
            return false;
        }

        /// Component-contract view (cards need msgs for the dismiss button).
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            _ = model;
            _ = cb;
            _ = msgs;
        }

        /// The stack, bottom-right. `msgs.dismissMsg(id)` builds the app Msg
        /// for a card's close button (a comptime fn like `Dropdown`'s `selectMsg`).
        /// Call it last in `view` so the cards are drawn over everything.
        pub fn viewWith(model: *const Model, cb: anytype, msgs: anytype, o: ViewOpts) void {
            const pal = cb.theme.palette;
            const n = model.len;
            for (model.items[0..n], 0..) |e, i| {
                const t = std.math.clamp(e.show.value(), 0, 1.2);
                const a = std.math.clamp(t, 0, 1);
                if (a <= 0.01) continue;
                // Newest at the bottom; each card keeps its slot while others come and go.
                const from_bottom: f32 = @floatFromInt(n - 1 - i);
                const slide = (1 - t) * (o.width + o.margin);
                cb.pushOverlay(.{
                    .x = o.window_w - o.margin + slide,
                    .y = o.window_h - o.margin - from_bottom * (o.height + o.gap),
                    .anchor_x_frac = 1,
                    .anchor_y_frac = 1,
                    .width = o.width,
                    .height = o.height,
                    .padding = 0,
                    .gap = 0,
                });
                const accent = fade(kindColor(pal, e.kind), a);
                cb.pushGroup(.{
                    .direction = .horizontal,
                    .padding = 10,
                    .gap = 8,
                    .bg = fade(pal.bg_panel, a),
                    .border = accent,
                    .border_width = 2,
                    .width = o.width,
                    .height = o.height,
                    .align_cross = .center,
                });
                cb.textStyled(util.frameStr(cb, e.text[0..e.len]), cb.theme.typography.body, fade(pal.fg, a));
                cb.spacer(1);
                var st = cb.theme.button;
                st.min_width = 28;
                st.height = 28;
                st.h_padding = 6;
                st.label_align = .center;
                st.bg = fade(st.bg, a);
                st.fg = fade(st.fg, a);
                if (st.border) |b| st.border = fade(b, a);
                if (st.hover_fg) |h| st.hover_fg = fade(h, a);
                st.hover_bg = fade(st.hover_bg, a);
                if (e.leaving) {
                    cb.buttonStyledDisabled(msgs.dismissMsg(e.id), "x", st);
                } else {
                    cb.buttonStyled(msgs.dismissMsg(e.id), "x", st);
                }
                cb.popGroup();
                cb.popOverlay();
            }
        }
    };
}

fn fade(c: [4]f32, a: f32) [4]f32 {
    return .{ c[0], c[1], c[2], c[3] * a };
}

fn kindColor(pal: anytype, kind: Kind) [4]f32 {
    return switch (kind) {
        .info => pal.accent,
        .success => .{ 0.35, 0.78, 0.45, 1 },
        .warning => .{ 0.95, 0.75, 0.25, 1 },
        .danger => pal.danger,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text_mod = @import("../text.zig");

const T = Toast(3, 16);
const TMsg = union(enum) { toast: T.Msg };
fn dismiss(id: u32) TMsg {
    return .{ .toast = .{ .dismiss = id } };
}
const tmsgs = .{ .dismissMsg = dismiss };

test "toast: satisfies the component contract" {
    component.validateComponent(T);
}

test "toast: push copies and truncates text; ids are unique" {
    var m: T.Model = .{};
    T.push(&m, .info, "hello", 4);
    T.push(&m, .danger, "this text is far too long for the buffer", 0);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqualStrings("hello", m.items[0].text[0..m.items[0].len]);
    try testing.expectEqualStrings("this text is far", m.items[1].text[0..m.items[1].len]);
    try testing.expect(m.items[0].id != m.items[1].id);
}

fn frames(m: *T.Model, ms: u32) void {
    var left = ms;
    while (left > 0) {
        const dt = @min(left, 16);
        T.update(m, .{ .frame = dt });
        left -= dt;
    }
}

test "toast: ticks count down; an expired toast slides out and is removed after its tween" {
    var m: T.Model = .{};
    T.push(&m, .info, "a", 2);
    T.push(&m, .warning, "sticky", 0);
    try testing.expect(T.active(&m));
    T.update(&m, .tick);
    try testing.expectEqual(@as(usize, 2), m.len);
    T.update(&m, .tick); // "a" expires: it starts leaving, it is not gone yet
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expect(m.items[0].leaving);
    frames(&m, leave_ms + enter_ms);
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqualStrings("sticky", m.items[0].text[0..m.items[0].len]);
    try testing.expect(!T.active(&m)); // only a sticky toast: no timer needed
    T.update(&m, .tick);
    try testing.expectEqual(@as(usize, 1), m.len);
}

test "toast: without animation frames a leaving toast is still dropped after a couple of ticks" {
    var m: T.Model = .{};
    T.push(&m, .info, "a", 1);
    T.update(&m, .tick); // expires -> leaving
    try testing.expect(T.active(&m)); // still ticking so it can be dropped
    T.update(&m, .tick);
    T.update(&m, .tick);
    try testing.expectEqual(@as(usize, 0), m.len);
    try testing.expect(!T.active(&m));
}

test "toast: slides in and fades; animating() is true only while a tween runs" {
    var m: T.Model = .{};
    T.push(&m, .info, "hi", 0);
    try testing.expect(T.animating(&m));
    try testing.expectEqual(@as(f32, 0), m.items[0].show.value());
    frames(&m, enter_ms / 2);
    const mid = m.items[0].show.value();
    try testing.expect(mid > 0.3 and mid < 1);
    frames(&m, enter_ms);
    try testing.expectEqual(@as(f32, 1), m.items[0].show.value());
    try testing.expect(!T.animating(&m));
}

test "toast: dismiss starts the exit tween; the toast leaves when it finishes" {
    var m: T.Model = .{};
    T.push(&m, .info, "one", 0);
    T.push(&m, .info, "two", 0);
    T.push(&m, .info, "three", 0);
    frames(&m, enter_ms + 16);
    const id_two = m.items[1].id;
    T.update(&m, .{ .dismiss = id_two });
    try testing.expectEqual(@as(usize, 3), m.len);
    try testing.expect(m.items[1].leaving);
    frames(&m, leave_ms + 16);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqualStrings("three", m.items[1].text[0..m.items[1].len]);
    T.update(&m, .{ .dismiss = 9999 }); // unknown id: no-op
    try testing.expectEqual(@as(usize, 2), m.len);
}

test "toast: a full stack drops the oldest" {
    var m: T.Model = .{};
    T.push(&m, .info, "1", 0);
    T.push(&m, .info, "2", 0);
    T.push(&m, .info, "3", 0);
    T.push(&m, .info, "4", 0);
    try testing.expectEqual(@as(usize, 3), m.len);
    try testing.expectEqualStrings("2", m.items[0].text[0..m.items[0].len]);
    try testing.expectEqualStrings("4", m.items[2].text[0..m.items[2].len]);
}

test "toast: Msg.push works through update" {
    var m: T.Model = .{};
    T.update(&m, .{ .push = .{ .kind = .success, .text = "Saved" } });
    try testing.expectEqual(Kind.success, m.items[0].kind);
    try testing.expectEqual(T.default_ttl, m.items[0].ttl);
}

test "toast: view is empty with no toasts; otherwise a bottom-right overlay of cards" {
    var m: T.Model = .{};
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    T.viewWith(&m, &cb, tmsgs, .{ .window_w = 800, .window_h = 600 });
    try testing.expectEqual(@as(usize, 0), cb.cmds.items.len);

    T.push(&m, .info, "Saved", 0);
    frames(&m, enter_ms + 16);
    T.viewWith(&m, &cb, tmsgs, .{ .window_w = 800, .window_h = 600 });
    const ov = cb.cmds.items[0].push_overlay;
    try testing.expectEqual(@as(f32, 784), ov.x);
    try testing.expectEqual(@as(f32, 584), ov.y);
    try testing.expectEqual(@as(f32, 1), ov.anchor_x_frac);
    try testing.expect(!ov.modal);
    // the close button carries the toast's id
    var found = false;
    for (cb.cmds.items) |c| switch (c) {
        .button => |b| {
            try testing.expectEqual(dismiss(m.items[0].id), b.msg);
            found = true;
        },
        else => {},
    };
    try testing.expect(found);
}

test "toast: view slides a new card in from the right and fades it" {
    var m: T.Model = .{};
    T.push(&m, .info, "Saved", 0);
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    T.viewWith(&m, &cb, tmsgs, .{ .window_w = 800, .window_h = 600 }); // t = 0: invisible
    try testing.expectEqual(@as(usize, 0), cb.cmds.items.len);
    frames(&m, enter_ms / 2);
    T.viewWith(&m, &cb, tmsgs, .{ .window_w = 800, .window_h = 600 });
    const ov = cb.cmds.items[0].push_overlay;
    try testing.expect(ov.x > 784 and ov.x < 784 + 340); // part-way in
    const g = cb.cmds.items[1].push_group;
    try testing.expect(g.bg.?[3] > 0 and g.bg.?[3] < 1); // part-way faded
}

test "toast: stacked cards keep fixed slots, newest at the bottom" {
    var m: T.Model = .{};
    T.push(&m, .info, "one", 0);
    T.push(&m, .info, "two", 0);
    frames(&m, enter_ms + 16);
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    T.viewWith(&m, &cb, tmsgs, .{ .window_w = 800, .window_h = 600 });
    var ys: [2]f32 = undefined;
    var n: usize = 0;
    for (cb.cmds.items) |c| switch (c) {
        .push_overlay => |ov| {
            ys[n] = ov.y;
            n += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(f32, 584), ys[1]); // newest at the bottom
    try testing.expectEqual(@as(f32, 584 - (44 + 8)), ys[0]);
}

test "toast: snapshot golden" {
    var m: T.Model = .{};
    T.push(&m, .success, "Saved", 0);
    T.push(&m, .danger, "Upload failed", 0);
    frames(&m, enter_ms + 16);
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.popGroup();
    T.viewWith(&m, &cb, tmsgs, .{ .window_w = 500, .window_h = 300 });
    var rects: [32]engine.Rect = undefined;
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 500, 300, text_mod.monoMeasurer());
    try snapshot.expectSnapshot(cb.cmds.items, rects[0..n], .{},
        \\group (0,0,500,300) vertical
        \\overlay (164,188,320,44) layer=1
        \\  group (164,188,320,44) horizontal bg border
        \\    text (174,200,50,20) "Saved"
        \\    group (232,210,206,0) vertical
        \\    button (446,198,28,28) "x"
        \\overlay (164,240,320,44) layer=1
        \\  group (164,240,320,44) horizontal bg border
        \\    text (174,252,130,20) "Upload failed"
        \\    group (312,262,126,0) vertical
        \\    button (446,250,28,28) "x"
        \\
    );
}
