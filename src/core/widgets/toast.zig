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

        /// Escape dismisses the newest toast that is not already leaving. Returns
        /// null for other keys or when nothing is showing. Call it AFTER the
        /// keys that open overlays / menus / dialogs so those consume Escape first.
        pub fn keyMsg(model: *const Model, key: @import("../../input/keys.zig").SpecialKey) ?Msg {
            if (key != .escape) return null;
            var i = model.len;
            while (i > 0) {
                i -= 1;
                if (!model.items[i].leaving) return .{ .dismiss = model.items[i].id };
            }
            return null;
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

fn frames(m: *T.Model, ms: u32) void {
    var left = ms;
    while (left > 0) {
        const dt = @min(left, 16);
        T.update(m, .{ .frame = dt });
        left -= dt;
    }
}
