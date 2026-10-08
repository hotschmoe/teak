//! Scroll position with smooth wheel and kinetic (fling) motion, as plain data.
//!
//! HARDLINE-clean: a `Scroller` lives in the app's Model; nothing is retained
//! by the framework and no clock is read. Time enters as a Msg the same way
//! `teak.anim` does: while `animating()` the app lists `Sub.animation_frame`
//! and forwards the frame time (`animationMsg`) to `step(dt_ms)`; once the motion
//! settles `animating()` is false, the sub is dropped and the loop idles again.
//!
//!     // Model:     sc: teak.Scroller = .{},
//!     // scrollMsg: .wheel => |dy| m.sc.wheel(dy)
//!     // layout:    m.sc.setExtent(viewport_h, content_h)       (scrollLayoutMsg)
//!     // animation: .frame => |dt| m.sc.step(dt)
//!     // view:      scroll_y = m.sc.pos
//!     // subscribe: if (m.sc.animating()) &.{.animation_frame} else &.{}
//!
//! Two motions share the state:
//!   * smooth wheel: `wheel(dy)` moves a *target*; `pos` eases toward it with an
//!     exponential of time constant `smooth_ms` (a notched mouse wheel glides
//!     instead of jumping; a trackpad's small deltas feel unchanged).
//!   * fling: `fling(px_per_s)` (e.g. the release velocity of a drag) coasts and
//!     decays with time constant `friction_ms`.
//! Both stop dead at the ends (no overscroll) and settle exactly.

const std = @import("std");

pub const Scroller = struct {
    /// Current offset in px (what `view` reads).
    pos: f32 = 0,
    /// Where smooth wheel motion is heading.
    target: f32 = 0,
    /// Fling velocity, px per second (0 when not coasting).
    vel: f32 = 0,
    /// Largest valid offset: `max(0, content - viewport)`.
    max: f32 = 0,
    /// Wheel easing time constant (ms); 0 disables smoothing (instant).
    smooth_ms: f32 = 70,
    /// Fling decay time constant (ms).
    friction_ms: f32 = 325,

    const eps_px: f32 = 0.25;
    const eps_vel: f32 = 12;

    /// Report the viewport and content extent (from `scrollLayoutMsg`); clamps.
    pub fn setExtent(self: *Scroller, viewport: f32, content: f32) void {
        self.max = @max(0, content - viewport);
        self.pos = std.math.clamp(self.pos, 0, self.max);
        self.target = std.math.clamp(self.target, 0, self.max);
    }

    /// A wheel / trackpad delta (px, positive = down). Cancels a fling.
    pub fn wheel(self: *Scroller, dy: f32) void {
        self.vel = 0;
        self.target = std.math.clamp(self.target + dy, 0, self.max);
        if (self.smooth_ms <= 0) self.pos = self.target;
    }

    /// Shift the content under the viewport by `d` px without any visible motion
    /// (scroll anchoring: rows above the viewport changed height or were inserted).
    pub fn shift(self: *Scroller, d: f32) void {
        self.pos = std.math.clamp(self.pos + d, 0, @max(self.max, self.pos + d));
        self.target = std.math.clamp(self.target + d, 0, @max(self.max, self.target + d));
    }

    /// Jump (scrollbar drag, keyboard reveal): no animation.
    pub fn jumpTo(self: *Scroller, y: f32) void {
        self.vel = 0;
        self.pos = std.math.clamp(y, 0, self.max);
        self.target = self.pos;
    }

    /// Smoothly move to `y`.
    pub fn glideTo(self: *Scroller, y: f32) void {
        self.vel = 0;
        self.target = std.math.clamp(y, 0, self.max);
        if (self.smooth_ms <= 0) self.pos = self.target;
    }

    /// Start coasting at `px_per_s` (positive = down).
    pub fn fling(self: *Scroller, px_per_s: f32) void {
        self.vel = px_per_s;
        self.target = self.pos;
    }

    /// Whether `step` still has work to do (keep `Sub.animation_frame` listed).
    pub fn animating(self: *const Scroller) bool {
        return @abs(self.vel) > eps_vel or @abs(self.target - self.pos) > eps_px;
    }

    /// Advance by `dt_ms` of frame time.
    pub fn step(self: *Scroller, dt_ms: u32) void {
        const dt: f32 = @floatFromInt(dt_ms);
        if (@abs(self.vel) > eps_vel) {
            // Exact integral of v(t) = v0 * exp(-t / tau): frame-rate independent.
            const decay = @exp(-dt / self.friction_ms);
            self.pos += self.vel * (self.friction_ms / 1000) * (1 - decay);
            self.vel *= decay;
            if (self.pos <= 0 or self.pos >= self.max) {
                self.pos = std.math.clamp(self.pos, 0, self.max);
                self.vel = 0;
            }
            self.target = self.pos;
            if (@abs(self.vel) <= eps_vel) self.vel = 0;
            return;
        }
        self.vel = 0;
        const gap = self.target - self.pos;
        if (@abs(gap) <= eps_px) {
            self.pos = self.target;
            return;
        }
        const k = if (self.smooth_ms <= 0) 1 else 1 - @exp(-dt / self.smooth_ms);
        self.pos += gap * k;
        if (@abs(self.target - self.pos) <= eps_px) self.pos = self.target;
    }
};

test "wheel glides toward the target and settles exactly, then idles" {
    var s: Scroller = .{};
    s.setExtent(100, 1100);
    s.wheel(300);
    try std.testing.expect(s.animating());
    try std.testing.expectEqual(@as(f32, 0), s.pos); // nothing moves until time passes
    var t: u32 = 0;
    while (s.animating() and t < 5000) : (t += 16) s.step(16);
    try std.testing.expectEqual(@as(f32, 300), s.pos);
    try std.testing.expect(!s.animating());
    try std.testing.expect(t < 1000);
}

test "smooth wheel is monotonic and never overshoots" {
    var s: Scroller = .{};
    s.setExtent(100, 1100);
    s.wheel(240);
    var last: f32 = 0;
    for (0..200) |_| {
        s.step(16);
        try std.testing.expect(s.pos >= last and s.pos <= 240);
        last = s.pos;
    }
}

test "targets clamp to the extent and a smaller content re-clamps pos" {
    var s: Scroller = .{};
    s.setExtent(100, 400);
    s.wheel(10_000);
    try std.testing.expectEqual(@as(f32, 300), s.target);
    s.jumpTo(280);
    s.setExtent(100, 200);
    try std.testing.expectEqual(@as(f32, 100), s.pos);
    s.wheel(-10_000);
    try std.testing.expectEqual(@as(f32, 0), s.target);
}

test "fling coasts, decays, stops at the end and settles" {
    var s: Scroller = .{};
    s.setExtent(100, 10_100);
    s.fling(2000);
    s.step(100);
    try std.testing.expect(s.pos > 165 and s.pos < 180); // 2000 * 0.325 * (1 - e^(-100/325))
    const v1 = s.vel;
    s.step(100);
    try std.testing.expect(s.vel < v1 and s.vel > 0);
    var t: u32 = 0;
    while (s.animating() and t < 20_000) : (t += 16) s.step(16);
    try std.testing.expect(!s.animating());
    try std.testing.expect(s.pos > 620 and s.pos < 650); // v * tau = 650, minus the stopped tail

    // Flung into the end: stops dead there.
    s.jumpTo(9990);
    s.fling(5000);
    s.step(200);
    try std.testing.expectEqual(@as(f32, 10_000), s.pos);
    try std.testing.expect(!s.animating());
}

test "smooth_ms = 0 is instant, and a wheel cancels a fling" {
    var s: Scroller = .{ .smooth_ms = 0 };
    s.setExtent(100, 1100);
    s.wheel(50);
    try std.testing.expectEqual(@as(f32, 50), s.pos);
    s.fling(1000);
    s.wheel(10);
    try std.testing.expectEqual(@as(f32, 0), s.vel);
}
