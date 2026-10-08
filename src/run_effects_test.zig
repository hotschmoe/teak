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

test "effects: an http request round-trips and the Msg names the result" {
    const p = try rig.begin(FxApp, .{ .script = &idle12, .fx_auto_answer = true }, .{});
    defer p.destroy();
    want(&p.rt.model, &.{.{ .http = .{ .id = 1, .method = .post, .url = "http://x/y", .body = "{}" } }});

    try step(p, 1); // frame 1 submits
    try t.expectEqual(@as(usize, 1), p.host.fx_submitted_n);
    try t.expectEqualStrings("http://x/y", p.host.fx_submitted[0].http.url);
    try t.expectEqual(fx.HttpMethod.post, p.host.fx_submitted[0].http.method);
    try t.expectEqual(@as(usize, 0), p.rt.model.seen_n); // not answered yet

    try step(p, 1); // frame 2 delivers
    try t.expectEqual(@as(usize, 1), p.rt.model.seen_n);
    try t.expectEqual(@as(i64, 200), p.rt.model.seen[0].n);
    try t.expectEqualStrings("pong", p.rt.model.last_http_body);
    try t.expectEqualStrings("http", p.rt.last_msg);
}

test "effects: an id is issued once while listed, forgotten after delisting" {
    const p = try rig.begin(FxApp, .{ .script = &idle12 }, .{});
    defer p.destroy();
    const e: Effect = .{ .http = .{ .id = 5, .url = "u" } };
    want(&p.rt.model, &.{e});

    try step(p, 4);
    try t.expectEqual(@as(usize, 1), p.host.fx_submitted_n);

    p.rt.model.want_n = 0; // delisted: forgotten
    try step(p, 1);
    try t.expect(!p.rt.issued.contains(5));
    try step(p, 1);
    try t.expectEqual(@as(usize, 1), p.host.fx_submitted_n);

    want(&p.rt.model, &.{e}); // listed again: a new request
    try step(p, 1);
    try t.expectEqual(@as(usize, 2), p.host.fx_submitted_n);
}

test "effects: a result for a delisted id is dropped (cancellation)" {
    const p = try rig.begin(FxApp, .{ .script = &idle12 }, .{});
    defer p.destroy();
    want(&p.rt.model, &.{.{ .http = .{ .id = 8, .url = "u" } }});
    try step(p, 1);

    p.rt.model.want_n = 0;
    try step(p, 1);
    p.host.queueResult(.{ .http = .{ .id = 8, .status = 200 } }); // late answer
    try step(p, 1);
    try t.expectEqual(@as(usize, 0), p.rt.model.seen_n);
}

test "effects: submissions keep list order and results keep host order" {
    const p = try rig.begin(FxApp, .{ .script = &idle12, .fx_auto_answer = true }, .{});
    defer p.destroy();
    want(&p.rt.model, &.{
        .{ .storage_get = .{ .id = 1, .key = "k" } },
        .{ .http = .{ .id = 2, .url = "u" } },
        .{ .clock = .{ .id = 3 } },
        .{ .query_param = .{ .id = 4, .name = "n" } },
    });
    try step(p, 2);
    for (0..4) |i| try t.expectEqual(@as(u32, @intCast(i + 1)), p.host.fx_submitted[i].id());
    const kinds = [_]@TypeOf(p.rt.model.seen[0].kind){ .storage, .http, .clock, .query };
    try t.expectEqual(@as(usize, 4), p.rt.model.seen_n);
    for (kinds, 0..) |k, i| try t.expectEqual(k, p.rt.model.seen[i].kind);
}

test "effects: fire-and-forget effects are submitted and never answered" {
    const p = try rig.begin(FxApp, .{ .script = &idle12, .fx_auto_answer = true }, .{});
    defer p.destroy();
    want(&p.rt.model, &.{
        .{ .storage_set = .{ .id = 1, .key = "k", .value = "v" } },
        .{ .write_clipboard = .{ .id = 2, .text = "t" } },
    });
    try step(p, 4);
    try t.expectEqual(@as(usize, 2), p.host.fx_submitted_n);
    try t.expectEqual(@as(usize, 0), p.rt.model.seen_n);
}

test "effects: a busy host is retried each frame until it accepts" {
    const p = try rig.begin(FxApp, .{ .script = &idle12, .fx_mode = .busy }, .{});
    defer p.destroy();
    want(&p.rt.model, &.{.{ .open_file = .{ .id = 1 } }});
    try step(p, 3);
    try t.expectEqual(@as(usize, 3), p.host.fx_submitted_n); // offered every frame
    try t.expect(!p.rt.issued.contains(1));

    p.host.fx_mode = .accepted;
    try step(p, 3);
    try t.expectEqual(@as(usize, 4), p.host.fx_submitted_n); // taken once, then left alone
    try t.expect(p.rt.issued.contains(1));
}

test "effects: an unsupported effect is answered with its failed result" {
    const p = try rig.begin(FxApp, .{ .script = &idle12, .fx_mode = .unsupported }, .{});
    defer p.destroy();
    want(&p.rt.model, &.{
        .{ .http = .{ .id = 1, .url = "u" } },
        .{ .open_file = .{ .id = 2 } },
        .{ .storage_set = .{ .id = 3, .key = "k", .value = "v" } },
    });
    try step(p, 3);
    try t.expectEqual(@as(usize, 2), p.rt.model.seen_n); // set has no answer
    try t.expectEqual(@as(i64, 0), p.rt.model.seen[0].n);
    try t.expect(p.rt.model.last_http_err.len > 0);
    try t.expectEqual(@as(@TypeOf(p.rt.model.seen[0].kind), .cancelled), p.rt.model.seen[1].kind);
    // Answered once, not every frame.
    try t.expectEqual(@as(usize, 3), p.host.fx_submitted_n);
}

test "effects: more listed ids than the table holds wait for a free slot" {
    const p = try rig.begin(FxApp, .{ .script = &idle12 }, .{});
    defer p.destroy();
    var list: [40]Effect = undefined;
    for (&list, 0..) |*e, i| e.* = .{ .clock = .{ .id = @intCast(i + 1) } };
    want(&p.rt.model, &list);
    try step(p, 3);
    try t.expectEqual(@as(usize, 32), p.host.fx_submitted_n);

    // Delist the first 8: the waiting 8 get their turn.
    want(&p.rt.model, list[8..]);
    try step(p, 1);
    try t.expectEqual(@as(usize, 40), p.host.fx_submitted_n);
}

test "effects: unsolicited drops and pastes reach effectMsg without effects()" {
    const png = "\x89PNG";
    const thumb: [16]u8 = @splat(0);
    const script = [_]Frame{
        .{},
        .{ .fx_result = .{ .dropped = .{
            .kind = .image,
            .name = "shot.png",
            .mime = "image/png",
            .bytes = png,
            .width = 1568,
            .height = 900,
            .thumb_rgba = &thumb,
            .thumb_w = 2,
            .thumb_h = 2,
        } } },
        .{ .fx_result = .{ .pasted_text = .{ .text = "hello" } } },
        .{},
    };
    // An app that only listens: `effectMsg` without `effects`.
    const Listener = struct {
        pub const Model = struct { img_w: u32 = 0, thumb: usize = 0, text_len: usize = 0, drops: u32 = 0 };
        pub const Msg = union(enum) { drop: fx.Drop, paste: usize };
        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .drop => |d| {
                    m.drops += 1;
                    m.img_w = d.width;
                    m.thumb = d.thumb_rgba.len;
                },
                .paste => |n| m.text_len = n,
            }
        }
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{});
            cb.popGroup();
        }
        pub fn effectMsg(_: *const Model, r: EffectResult) ?Msg {
            return switch (r) {
                .dropped => |d| .{ .drop = d },
                .pasted_text => |p| .{ .paste = p.text.len },
                else => null,
            };
        }
    };
    const p = try rig.play(Listener, &script);
    defer p.destroy();
    try t.expectEqual(@as(u32, 1), p.rt.model.drops);
    try t.expectEqual(@as(u32, 1568), p.rt.model.img_w);
    try t.expectEqual(@as(usize, 16), p.rt.model.thumb);
    try t.expectEqual(@as(usize, 5), p.rt.model.text_len);
}

test "effects: a result nobody asked for is dropped, unsolicited ones never are" {
    const p = try rig.begin(FxApp, .{ .script = &idle12 }, .{});
    defer p.destroy();
    try step(p, 1);
    p.host.queueResult(.{ .clock = .{ .id = 99, .unix_ms = 0, .utc_offset_min = 0 } });
    try step(p, 1);
    try t.expectEqual(@as(usize, 0), p.rt.model.seen_n);
    p.host.queueResult(.{ .pasted_text = .{ .text = "x" } });
    try step(p, 1);
    try t.expectEqual(@as(usize, 1), p.rt.model.seen_n);
}
