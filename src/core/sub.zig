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
                    // A slow frame can cross multiple timer boundaries.
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
