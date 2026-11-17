//! Tests for declarative effects in the canonical loop (HARDLINE hatch 7):
//! `App.effects` / `App.effectMsg` against the scripted Host's effect
//! extension. See `docs/features/effects.md`.

const std = @import("std");
const t = std.testing;

const rig = @import("run_test.zig");
const fx = @import("core/effects.zig");

const Effect = fx.Effect;
const EffectResult = fx.EffectResult;
const Frame = rig.Frame;

/// One line per Msg the app saw, in order.
const Seen = struct {
    kind: enum { http, storage, clock, query, opened, cancelled, downloaded, dropped, pasted },
    id: u32 = 0,
    n: i64 = 0,
};

const FxApp = struct {
    pub const Model = struct {
        /// What the app currently wants; `effects()` returns this slice.
        want: [48]Effect = undefined,
        want_n: usize = 0,
        seen: [32]Seen = undefined,
        seen_n: usize = 0,
        last_http_err: []const u8 = "",
        last_http_body: []const u8 = "",
        thumb_len: usize = 0,
        pasted: []const u8 = "",

        fn push(m: *Model, s: Seen) void {
            m.seen[m.seen_n] = s;
            m.seen_n += 1;
        }
    };
    pub const Msg = union(enum) { http: fx.HttpResult, storage, clock, query, opened, cancelled, downloaded, dropped, pasted };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .http => |r| {
                m.push(.{ .kind = .http, .id = r.id, .n = r.status });
                m.last_http_err = r.err;
                m.last_http_body = r.body;
            },
            else => m.push(.{ .kind = std.meta.stringToEnum(@TypeOf(m.seen[0].kind), @tagName(msg)).? }),
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{});
        cb.popGroup();
    }
    pub fn effects(m: *const Model) []const Effect {
        return m.want[0..m.want_n];
    }
    pub fn effectMsg(m: *const Model, r: EffectResult) ?Msg {
        _ = m;
        return switch (r) {
            .http => |h| .{ .http = h },
            .storage_value => .storage,
            .clock => .clock,
            .query_value => .query,
            .file_opened => .opened,
            .file_cancelled => .cancelled,
            .downloaded => .downloaded,
            .dropped => .dropped,
            .pasted_text => .pasted,
        };
    }
};

const idle12: [12]Frame = @splat(.{});

fn want(m: *FxApp.Model, list: []const Effect) void {
    @memcpy(m.want[0..list.len], list);
    m.want_n = list.len;
}

fn step(p: anytype, n: usize) !void {
    for (0..n) |_| try p.rt.frame();
}










