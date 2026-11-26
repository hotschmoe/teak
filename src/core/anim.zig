//! Model-driven animation: tweens, easing curves and interpolation.
//!
//! HARDLINE-clean by construction: a `Tween(T)` is plain data that lives in
//! the app's `Model`; nothing is retained by the framework, `view` stays a
//! pure function of the Model (it reads `tween.value()`), and no wall clock
//! is read anywhere. Time enters the Model the same way every other event
//! does — as a Msg:
//!
//!     // Model:   open: teak.anim.Tween(f32) = .still(0),
//!     // Msg:     frame: u32,                    // dt in ms
//!     // update:  .frame => |dt| m.open.advance(dt),
//!     //          .toggle => m.open.start(if (m.shown) 0 else 1, 200, .out_cubic),
//!     // subscribe: return if (m.open.active()) &.{.animation_frame} else &.{};
//!     // animationMsg(m, dt): return .{ .frame = dt };
//!
//! While any `Sub.animation_frame` is listed the run loop calls the App's
//! `animationMsg(model, dt_ms)` every frame (dt is the Host-clock time since
//! the previous frame, capped at `max_dt_ms`) and keeps frames flowing; when
//! the app stops listing it (the tween finished) the loop goes idle again
//! (`Options.idle_skip`). Because dt is a Msg, an animation replays
//! deterministically from a Msg log.

const std = @import("std");

/// Easing curves: map linear progress `t` in [0, 1] to eased progress.
pub const Ease = enum {
    linear,
    in_quad,
    out_quad,
    in_out_quad,
    in_cubic,
    out_cubic,
    in_out_cubic,
    /// Overshoots the target slightly, then settles.
    out_back,
};

/// Eased progress for linear `t` (clamped to [0, 1]); 0 -> 0 and 1 -> 1 for
/// every curve.
pub fn ease(kind: Ease, t_in: f32) f32 {
    const t = std.math.clamp(t_in, 0, 1);
    return switch (kind) {
        .linear => t,
        .in_quad => t * t,
        .out_quad => 1 - (1 - t) * (1 - t),
        .in_out_quad => if (t < 0.5) 2 * t * t else 1 - 2 * (1 - t) * (1 - t),
        .in_cubic => t * t * t,
        .out_cubic => 1 - std.math.pow(f32, 1 - t, 3),
        .in_out_cubic => if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 3) / 2,
        .out_back => blk: {
            const c1: f32 = 1.70158;
            const c3 = c1 + 1;
            const u = t - 1;
            break :blk 1 + c3 * u * u * u + c1 * u * u;
        },
    };
}

/// Linear interpolation of `a` -> `b` at `t` (not clamped, so eased overshoot
/// works). Works for floats, integers (rounded), arrays and vectors of
/// those (colors are `[4]f32`), and structs whose fields are all such types
/// (a `Rect`, a style). Bools and enums switch at `t >= 0.5`.
pub fn lerp(comptime T: type, a: T, b: T, t: f32) T {
    switch (@typeInfo(T)) {
        .float => return a + (b - a) * @as(T, @floatCast(t)),
        .int => {
            const af: f64 = @floatFromInt(a);
            const bf: f64 = @floatFromInt(b);
            return @intFromFloat(@round(af + (bf - af) * t));
        },
        .bool, .@"enum" => return if (t >= 0.5) b else a,
        .array => |info| {
            var out: T = undefined;
            for (&out, a, b) |*o, x, y| o.* = lerp(info.child, x, y, t);
            return out;
        },
        .vector => {
            const Elem = @typeInfo(T).vector.child;
            var out: T = undefined;
            inline for (0..@typeInfo(T).vector.len) |i| out[i] = lerp(Elem, a[i], b[i], t);
            return out;
        },
        .@"struct" => |info| {
            var out: T = undefined;
            inline for (info.field_names, info.field_types) |name, F| {
                @field(out, name) = lerp(F, @field(a, name), @field(b, name), t);
            }
            return out;
        },
        else => @compileError("anim.lerp: unsupported type " ++ @typeName(T)),
    }
}

/// An interpolation from `from` to `to` over `duration_ms`, advanced by
/// `advance(dt_ms)` and read with `value()`. Plain data: keep it in the Model.
pub fn Tween(comptime T: type) type {
    return struct {
        const Self = @This();

        from: T,
        to: T,
        duration_ms: u32 = 0,
        elapsed_ms: u32 = 0,
        easing: Ease = .out_cubic,

        /// An inactive tween resting at `v`.
        pub fn still(v: T) Self {
            return .{ .from = v, .to = v };
        }

        /// Begin moving toward `target` from wherever the tween is *now*
        /// (`value()`), so retargeting mid-flight never jumps.
        pub fn start(self: *Self, target: T, duration: u32, easing: Ease) void {
            self.* = .{ .from = self.value(), .to = target, .duration_ms = duration, .easing = easing };
        }

        /// Move the clock forward; saturates at the end.
        pub fn advance(self: *Self, dt_ms: u32) void {
            self.elapsed_ms = @min(self.duration_ms, self.elapsed_ms +| dt_ms);
        }

        /// True while the tween has time left (keep `animation_frame` listed).
        pub fn active(self: Self) bool {
            return self.elapsed_ms < self.duration_ms;
        }

        /// Linear progress in [0, 1] (1 once finished or zero-length).
        pub fn progress(self: Self) f32 {
            if (self.duration_ms == 0) return 1;
            return @as(f32, @floatFromInt(self.elapsed_ms)) / @as(f32, @floatFromInt(self.duration_ms));
        }

        /// The current interpolated value.
        pub fn value(self: Self) T {
            return lerp(T, self.from, self.to, ease(self.easing, self.progress()));
        }
    };
}

const testing = std.testing;
