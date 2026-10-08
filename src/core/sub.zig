//! Subscriptions — declarative timers / external-event listeners.
//!
//! HARDLINE §2 escape hatch 6. The app declares
//!
//!     pub fn subscribe(model: *const Model) []const Sub
//!
//! which is a **pure function** of model: no I/O, no wall-clock, no
//! allocation outside the per-frame arena. It returns a slice of `Sub`
//! values the runtime should service this frame. The runtime fires the
//! carried `Msg` through the normal `update` loop when a sub's
//! condition is met — so a sub is NOT a reactive signal (§3 forbids
//! those); observers are still the next frame's `view`.
//!
//! Two variants in MVP:
//!
//! - `.every(interval_ms, msg)` — fires whenever the host crosses a
//!   `now / interval_ms` boundary since the last frame. Approximate
//!   cadence (within one frame); fine for cursor blink, autosave
//!   timer ticks, polling.
//! - `.at(deadline_ms, msg)` — fires exactly once per frame transition
//!   where `last_frame_ms < deadline_ms <= now_ms`. `deadline_ms` is on
//!   the host's monotonic clock (see `Host.nowMs()`). The app uses
//!   this for "fire X after 500ms of idle" by setting deadline =
//!   nowMs + 500 in model, then emitting `.at(model.deadline, msg)`
//!   until the runtime fires it.
//!
//! Both variants stay STATELESS at the framework level — no sub-key
//! deduplication, no last-fired tracking. The runtime decides "fire or
//! not" purely from (`now_ms`, `last_frame_ms`, sub data). This means
//! - `every` can skip a tick if the frame was slow, or fire twice in
//!   one frame if it was very slow (both fires go through update).
//! - `at` fires exactly once, on the crossing frame where
//!   `last_frame_ms < deadline_ms <= now_ms`, then auto-stops: once
//!   `last_frame_ms` advances past the deadline the window never re-opens,
//!   so no cleanup is needed. To fire again, re-arm with a new, later
//!   `deadline_ms` in `subscribe()`.
//!
//! See `docs/features/subscriptions.md` for the design rationale.

const std = @import("std");

/// Longest frame step `animationMsg` is given; a stalled frame must not make
/// an animation jump to its end.
pub const max_animation_dt_ms: u32 = 100;

/// True if any listed sub is `.animation_frame`.
pub fn wantsAnimationFrame(comptime Msg: type, subs: []const Sub(Msg)) bool {
    for (subs) |sub| if (sub == .animation_frame) return true;
    return false;
}

pub fn Sub(comptime Msg: type) type {
    return union(enum) {
        every: struct { interval_ms: u32, msg: Msg },
        at: struct { deadline_ms: u64, msg: Msg },
        /// Ask the run loop for a frame callback: while listed, every frame
        /// calls the App's `animationMsg(model, dt_ms) ?Msg` (dt = Host-clock
        /// ms since the previous frame, capped at `max_animation_dt_ms`) and
        /// idle skipping is suspended. List it only while an animation is
        /// active (see `core/anim.zig`).
        animation_frame,
    };
}

/// Walk `subs` and call `dispatch(msg)` for each that should fire this
/// frame. `last_frame_ms` and `now_ms` come from the host's monotonic
/// clock; on the first frame, pass `last_frame_ms = now_ms` (no subs
/// fire on the very first tick — they need a window to compare).
///
/// `dispatch` is an `anytype` carrying a `call(msg)` method — a value (or
/// pointer to one) whose bound context travels *inside* it, not through
/// module-level statics. `runSubs` invokes `dispatch.call(msg)` for each
/// fired sub. It's NOT a Cmd-borne fn pointer (§3 forbids those) — this is
/// a runtime helper, not part of the Cmd protocol. Passing the context by
/// value keeps `runSubs` (and its caller `run`) free of retained mutable
/// state, so two concurrent `run` calls can't cross-wire their models.
pub fn runSubs(
    comptime Msg: type,
    subs: []const Sub(Msg),
    last_frame_ms: u64,
    now_ms: u64,
    dispatch: anytype,
) void {
    if (now_ms <= last_frame_ms) return;
    for (subs) |sub| {
        switch (sub) {
            .every => |e| {
                if (e.interval_ms == 0) continue;
                const last_tick = last_frame_ms / e.interval_ms;
                const now_tick = now_ms / e.interval_ms;
                if (now_tick > last_tick) {
                    // Fire once per crossed boundary (typically 1; can
                    // be more if the frame was slow).
                    var i: u64 = 0;
                    while (i < (now_tick - last_tick)) : (i += 1) {
                        dispatch.call(e.msg);
                    }
                }
            },
            .at => |a| {
                if (last_frame_ms < a.deadline_ms and a.deadline_ms <= now_ms) {
                    dispatch.call(a.msg);
                }
            },
            // Serviced by the run loop (it needs the App's `animationMsg` hook).
            .animation_frame => {},
        }
    }
}

/// Milliseconds from `now_ms` until the next sub would fire, or null when no
/// sub is armed (every `.every` has interval 0 and every `.at` deadline has
/// passed). A Host that blocks while the app is idle uses it as the wait
/// timeout so timers still fire on time.
pub fn nextDueMs(comptime Msg: type, subs: []const Sub(Msg), now_ms: u64) ?u64 {
    var best: ?u64 = null;
    for (subs) |sub| {
        const due: u64 = switch (sub) {
            .every => |e| if (e.interval_ms == 0) continue else e.interval_ms - now_ms % e.interval_ms,
            .at => |a| if (a.deadline_ms > now_ms) a.deadline_ms - now_ms else continue,
            .animation_frame => 0,
        };
        best = if (best) |b| @min(b, due) else due;
    }
    return best;
}

test "nextDueMs: nearest of every/at, null when nothing is armed" {
    const Msg = union(enum) { t };
    const subs = [_]Sub(Msg){
        .{ .every = .{ .interval_ms = 100, .msg = .t } },
        .{ .at = .{ .deadline_ms = 1030, .msg = .t } },
        .{ .at = .{ .deadline_ms = 10, .msg = .t } }, // already passed
        .{ .every = .{ .interval_ms = 0, .msg = .t } },
    };
    try std.testing.expectEqual(@as(?u64, 20), nextDueMs(Msg, &subs, 1010)); // every: 1100-1010=90; at: 20
    try std.testing.expectEqual(@as(?u64, 50), nextDueMs(Msg, &subs, 1050)); // every: 50; at: 0 -> skipped? deadline 1030 passed
    try std.testing.expectEqual(@as(?u64, null), nextDueMs(Msg, &[_]Sub(Msg){}, 5));
}

// ── Tests ──────────────────────────────────────────────────────────

test "runSubs: .every fires once per crossed interval" {
    const Msg = union(enum) { tick };
    const subs = [_]Sub(Msg){.{ .every = .{ .interval_ms = 100, .msg = .tick } }};

    var fire_count: u32 = 0;
    // The dispatcher carries its context (the counter pointer) as a field —
    // no module-level statics — and exposes it through `call(msg)`.
    const Counter = struct {
        count: *u32,
        fn call(self: @This(), _: Msg) void {
            self.count.* += 1;
        }
    };
    const counter = Counter{ .count = &fire_count };

    // 50 → 90: no crossing of 100.
    runSubs(Msg, &subs, 50, 90, counter);
    try std.testing.expectEqual(@as(u32, 0), fire_count);

    // 90 → 110: crosses 100 once.
    runSubs(Msg, &subs, 90, 110, counter);
    try std.testing.expectEqual(@as(u32, 1), fire_count);

    // 110 → 320: crosses 200 and 300 → 2 fires.
    runSubs(Msg, &subs, 110, 320, counter);
    try std.testing.expectEqual(@as(u32, 3), fire_count);
}

test "runSubs: .at fires exactly once when deadline is crossed" {
    const Msg = union(enum) { done };
    const subs = [_]Sub(Msg){.{ .at = .{ .deadline_ms = 500, .msg = .done } }};

    var fire_count: u32 = 0;
    const Counter = struct {
        count: *u32,
        fn call(self: @This(), _: Msg) void {
            self.count.* += 1;
        }
    };
    const counter = Counter{ .count = &fire_count };

    // 0 → 400: no fire.
    runSubs(Msg, &subs, 0, 400, counter);
    try std.testing.expectEqual(@as(u32, 0), fire_count);

    // 400 → 500: crosses to exactly the deadline — fires.
    runSubs(Msg, &subs, 400, 500, counter);
    try std.testing.expectEqual(@as(u32, 1), fire_count);

    // 500 → 600: deadline already passed, doesn't fire again. The app
    // is responsible for removing the sub from subscribe() to prevent
    // a re-fire when the same deadline is re-emitted.
    runSubs(Msg, &subs, 500, 600, counter);
    try std.testing.expectEqual(@as(u32, 1), fire_count);
}

test "runSubs: zero interval is a no-op (avoid div-by-zero)" {
    const Msg = union(enum) { tick };
    const subs = [_]Sub(Msg){.{ .every = .{ .interval_ms = 0, .msg = .tick } }};

    var fire_count: u32 = 0;
    const Counter = struct {
        count: *u32,
        fn call(self: @This(), _: Msg) void {
            self.count.* += 1;
        }
    };
    const counter = Counter{ .count = &fire_count };

    runSubs(Msg, &subs, 0, 1000, counter);
    try std.testing.expectEqual(@as(u32, 0), fire_count);
}
