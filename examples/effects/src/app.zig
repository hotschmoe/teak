//! Effects example: every `teak.Effect` in one window, each with a visible
//! result.
//!
//! The app never performs I/O. A button's `update` arm puts an `Effect` into
//! `Model.reqs`; `effects()` lists them; the host does the work; the answer
//! arrives in `effectMsg` as a Msg and `update` writes it into a result line.
//! Pastes and drops arrive the same way, with no request behind them.
//!
//! Try it:
//!   web:     zig build web, serve dist/, open it (optionally ?who=you&api=http://localhost:8104/)
//!   native:  zig build ui -- --who=you --api=http://127.0.0.1:8104/   (TEAK_OPEN=file for Open)
//! Ctrl+V pastes text, Ctrl+C copies, and an image or file dropped on the
//! window shows up under "Drop".

const std = @import("std");
const teak = @import("teak");

const EffectResult = teak.EffectResult;
const FileOpened = @FieldType(EffectResult, "file_opened");
const StorageValue = @FieldType(EffectResult, "storage_value");
const QueryValue = @FieldType(EffectResult, "query_value");
const Clock = @FieldType(EffectResult, "clock");
const Downloaded = @FieldType(EffectResult, "downloaded");
const Cancelled = @FieldType(EffectResult, "file_cancelled");

pub const key_note = "teak.effects.note";
pub const thumb_max = 64;

/// A fixed text buffer the Model owns (results are copied out of the host's
/// slices, which die when `update` returns).
fn Text(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), comptime fmt: []const u8, args: anytype) void {
            self.len = if (std.fmt.bufPrint(&self.buf, fmt, args)) |out| out.len else |_| cap; // overflow keeps the truncated text
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Model = struct {
    next_id: u32 = 100,
    /// The requests currently listed; `effects()` returns them. A request
    /// leaves when its result arrives. Fire-and-forget ones stay until the
    /// next one of their kind replaces them (they are issued only once).
    reqs: [10]teak.Effect = undefined,
    n_reqs: usize = 0,

    api: Text(160) = .{},
    url: Text(200) = .{},
    note: Text(64) = .{},
    saves: u32 = 0,

    who: Text(100) = .{},
    http: Text(200) = .{},
    download: Text(100) = .{},
    file: Text(220) = .{},
    stored: Text(100) = .{},
    clock: Text(100) = .{},
    clip: Text(100) = .{},
    dropped: Text(220) = .{},
    pasted: Text(160) = .{},

    thumb: [thumb_max * thumb_max * 4]u8 = undefined,
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,

    pub fn init() Model {
        var m: Model = .{};
        m.api.set("http://localhost:8104/", .{});
        m.who.set("(asking...)", .{});
        m.http.set("-", .{});
        m.download.set("-", .{});
        m.file.set("-", .{});
        m.stored.set("(asking...)", .{});
        m.clock.set("-", .{});
        m.clip.set("-", .{});
        m.dropped.set("nothing dropped yet", .{});
        m.pasted.set("-", .{});
        // Startup parameters and the saved note, asked for once.
        m.append(.{ .query_param = .{ .id = m.takeId(), .name = "who" } });
        m.append(.{ .query_param = .{ .id = m.takeId(), .name = "api" } });
        m.append(.{ .storage_get = .{ .id = m.takeId(), .key = key_note } });
        return m;
    }

    fn takeId(m: *Model) u32 {
        m.next_id += 1;
        return m.next_id;
    }

    /// List `e`, replacing a request of the same kind that is still listed.
    fn put(m: *Model, e: teak.Effect) void {
        for (m.reqs[0..m.n_reqs]) |*r| {
            if (std.meta.activeTag(r.*) == std.meta.activeTag(e)) {
                r.* = e;
                return;
            }
        }
        m.append(e);
    }

    fn append(m: *Model, e: teak.Effect) void {
        if (m.n_reqs == m.reqs.len) return;
        m.reqs[m.n_reqs] = e;
        m.n_reqs += 1;
    }

    /// The parameter name a listed `query_param` request `id` asked for.
    fn askedName(m: *const Model, id: u32) []const u8 {
        for (m.reqs[0..m.n_reqs]) |r| {
            if (r.id() == id and r == .query_param) return r.query_param.name;
        }
        return "";
    }

    /// Stop listing request `id`.
    fn done(m: *Model, id: u32) void {
        for (m.reqs[0..m.n_reqs], 0..) |r, i| {
            if (r.id() != id) continue;
            std.mem.copyForwards(teak.Effect, m.reqs[i .. m.n_reqs - 1], m.reqs[i + 1 .. m.n_reqs]);
            m.n_reqs -= 1;
            return;
        }
    }

    fn call(m: *Model, comptime path: []const u8, method: teak.HttpMethod, timeout_ms: u32) void {
        m.url.set("{s}{s}", .{ m.api.slice(), path });
        m.http.set("waiting for {s} ...", .{m.url.slice()});
        m.put(.{ .http = .{
            .id = m.takeId(),
            .method = method,
            .url = m.url.slice(),
            .headers = &json_headers,
            .body = if (method == .post) "{\"hello\":\"teak\"}" else "",
            .timeout_ms = timeout_ms,
        } });
    }
};

const json_headers = [_]teak.Header{.{ .name = "content-type", .value = "application/json" }};

pub const Msg = union(enum) {
    // Buttons.
    get,
    post,
    refuse,
    timeout,
    download,
    open,
    save,
    load,
    clock,
    copy,
    // Answers.
    http_done: teak.HttpResult,
    downloaded: Downloaded,
    opened: FileOpened,
    cancelled: Cancelled,
    stored: StorageValue,
    queried: QueryValue,
    clocked: Clock,
    dropped: teak.Drop,
    pasted: []const u8,
    // Ctrl+C / Ctrl+V through the Host clipboard.
    clip_paste: []const u8,
    clip_copy,
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .get => m.call("index.html", .get, 20_000),
        .post => m.call("echo", .post, 20_000),
        .refuse => {
            m.api.set("http://127.0.0.1:9/", .{}); // nothing listens on port 9
            m.call("", .get, 5_000);
        },
        .timeout => m.call("index.html", .get, 1),
        .download => {
            m.download.set("asked for hello.txt ...", .{});
            m.put(.{ .download = .{ .id = m.takeId(), .name = "hello.txt", .mime = "text/plain", .bytes = "hello from teak effects\n" } });
        },
        .open => {
            m.file.set("waiting for a file (click or press a key if the browser needs a gesture) ...", .{});
            m.put(.{ .open_file = .{ .id = m.takeId(), .accept = ".json,.txt,.md,image/*" } });
        },
        .save => {
            m.saves += 1;
            m.note.set("saved #{d}", .{m.saves});
            m.put(.{ .storage_set = .{ .id = m.takeId(), .key = key_note, .value = m.note.slice() } });
        },
        .load => m.put(.{ .storage_get = .{ .id = m.takeId(), .key = key_note } }),
        .clock => m.put(.{ .clock = .{ .id = m.takeId() } }),
        .copy => {
            m.clip.set("copied: teak effects clipboard test", .{});
            m.put(.{ .write_clipboard = .{ .id = m.takeId(), .text = "teak effects clipboard test" } });
        },

        .http_done => |r| {
            m.done(r.id);
            if (r.status == 0) {
                m.http.set("status 0 - {s}", .{r.err});
            } else {
                const body = r.body[0..@min(r.body.len, 48)];
                m.http.set("status {d}, {d} bytes: {s}", .{ r.status, r.body.len, std.mem.trim(u8, body, " \r\n") });
            }
        },
        .downloaded => |d| {
            m.done(d.id);
            m.download.set("{s}", .{if (d.ok) "downloaded hello.txt" else "download failed"});
        },
        .opened => |f| {
            m.done(f.id);
            var head: [40]u8 = undefined;
            const n = @min(f.bytes.len, head.len);
            for (f.bytes[0..n], head[0..n]) |b, *o| o.* = if (b >= 0x20 and b < 0x7f) b else '.';
            m.file.set("{s} ({s}, {d} bytes) {s}", .{ f.name, f.mime, f.bytes.len, head[0..n] });
        },
        .cancelled => |c| {
            m.done(c.id);
            m.file.set("no file chosen", .{});
        },
        .stored => |s| {
            m.done(s.id);
            if (s.value) |v| m.stored.set("{s}", .{v}) else m.stored.set("(nothing saved)", .{});
        },
        .queried => |q| {
            const asked = m.askedName(q.id);
            m.done(q.id);
            if (std.mem.eql(u8, asked, "api")) {
                if (q.value) |v| m.api.set("{s}", .{v});
            } else if (q.value) |v| m.who.set("{s}", .{v}) else m.who.set("(not given)", .{});
        },
        .clocked => |c| {
            m.done(c.id);
            const secs: u64 = @intCast(@max(0, @divFloor(c.unix_ms, 1000)));
            const day = std.time.epoch.EpochSeconds{ .secs = secs };
            const ymd = day.getEpochDay().calculateYearDay();
            const md = ymd.calculateMonthDay();
            const ds = day.getDaySeconds();
            m.clock.set("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC, offset {d} min (unix ms {d})", .{
                ymd.year,             @backingInt(md.month),   md.day_index + 1,
                ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
                c.utc_offset_min,     c.unix_ms,
            });
        },
        .dropped => |d| {
            m.dropped.set("{s} {s} ({s}), {d} bytes, {d}x{d}, thumb {d}x{d}", .{
                @tagName(d.kind), d.name, d.mime, d.bytes.len, d.width, d.height, d.thumb_w, d.thumb_h,
            });
            const n = @min(d.thumb_rgba.len, m.thumb.len);
            @memcpy(m.thumb[0..n], d.thumb_rgba[0..n]);
            m.thumb_w = if (n == d.thumb_rgba.len) d.thumb_w else 0;
            m.thumb_h = if (n == d.thumb_rgba.len) d.thumb_h else 0;
        },
        .pasted => |t| m.pasted.set("pasted_text: {s}", .{t[0..@min(t.len, 120)]}),
        .clip_paste => |t| m.pasted.set("Ctrl+V via Clipboard.read: {s}", .{t[0..@min(t.len, 120)]}),
        .clip_copy => m.clip.set("Ctrl+C wrote to the clipboard", .{}),
    }
}

pub fn effects(m: *const Model) []const teak.Effect {
    return m.reqs[0..m.n_reqs];
}

pub fn effectMsg(_: *const Model, r: EffectResult) ?Msg {
    return switch (r) {
        .http => |h| .{ .http_done = h },
        .downloaded => |d| .{ .downloaded = d },
        .file_opened => |f| .{ .opened = f },
        .file_cancelled => |c| .{ .cancelled = c },
        .storage_value => |s| .{ .stored = s },
        .query_value => |q| .{ .queried = q },
        .clock => |c| .{ .clocked = c },
        .dropped => |d| .{ .dropped = d },
        .pasted_text => |p| .{ .pasted = p.text },
    };
}

/// Ctrl+V / Ctrl+C go through the Host clipboard; the text a paste event
/// carried is what `read` returns, and such a paste is not also delivered as
/// `pasted_text`.
pub const keyNeedsClipboard = teak.keyNeedsClipboard;

pub fn handleClipboard(m: *Model, key: teak.SpecialKey, clip: teak.Clipboard) void {
    switch (key) {
        .ctrl_v => {
            const t = clip.read();
            if (t.len > 0) update(m, .{ .clip_paste = t });
        },
        .ctrl_c, .ctrl_x => {
            clip.write("teak effects Ctrl+C");
            update(m, .clip_copy);
        },
        else => {},
    }
}

// ── View ───────────────────────────────────────────────────────────

fn row(cb: anytype, msg: Msg, label: []const u8, result: []const u8) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 12, .align_cross = .center });
    cb.pushGroup(.{ .padding = 0, .width = 150 });
    cb.button(msg, label);
    cb.popGroup();
    cb.text(result);
    cb.popGroup();
}

pub fn view(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    cb.pushGroup(.{ .padding = 20, .gap = 10 });
    cb.text("Teak effects: every request is data the app lists; the host answers with a Msg");
    cb.text(std.fmt.allocPrint(arena, "?who= {s}    api base: {s}", .{ m.who.slice(), m.api.slice() }) catch "");
    cb.divider();

    row(cb, .get, "HTTP GET", m.http.slice());
    row(cb, .post, "HTTP POST", "");
    row(cb, .refuse, "HTTP refused", "");
    row(cb, .timeout, "HTTP 1 ms timeout", "");
    row(cb, .download, "Download", m.download.slice());
    row(cb, .open, "Open file", m.file.slice());
    row(cb, .save, "Storage save", m.note.slice());
    row(cb, .load, "Storage load", m.stored.slice());
    row(cb, .clock, "Clock", m.clock.slice());
    row(cb, .copy, "Clipboard write", m.clip.slice());
    cb.divider();

    cb.text("Drop an image or file on the window, or press Ctrl+V:");
    cb.text(m.dropped.slice());
    cb.text(m.pasted.slice());
    if (m.thumb_w > 0) thumbnail(m, cb, arena);
    cb.popGroup();
}

/// The dropped image's preview, one canvas rect per pixel at 2x.
fn thumbnail(m: *const Model, cb: anytype, arena: std.mem.Allocator) void {
    const scale: f32 = 2;
    const prims = arena.alloc(teak.CanvasPrimitive, m.thumb_w * m.thumb_h) catch return;
    for (prims, 0..) |*p, i| {
        const px = m.thumb[i * 4 ..][0..4];
        p.* = .{ .filled_rect = .{
            .x = @as(f32, @floatFromInt(i % m.thumb_w)) * scale,
            .y = @as(f32, @floatFromInt(i / m.thumb_w)) * scale,
            .w = scale,
            .h = scale,
            .color = .{ @as(f32, @floatFromInt(px[0])) / 255, @as(f32, @floatFromInt(px[1])) / 255, @as(f32, @floatFromInt(px[2])) / 255, @as(f32, @floatFromInt(px[3])) / 255 },
        } };
    }
    const style: teak.CanvasStyle = .{ .width = @as(f32, @floatFromInt(m.thumb_w)) * scale, .height = @as(f32, @floatFromInt(m.thumb_h)) * scale, .bg = .{ 0.1, 0.1, 0.1, 1 } };
    cb.canvasLabeled(style, prims, "dropped image thumbnail");
}

// ── Tests ──────────────────────────────────────────────────────────

test "init asks for the startup parameters and the saved note, and each leaves when answered" {
    var m = Model.init();
    try std.testing.expectEqual(@as(usize, 3), m.n_reqs);
    try std.testing.expectEqualStrings("who", m.reqs[0].query_param.name);
    const id = m.reqs[0].id();
    update(&m, .{ .queried = .{ .id = id, .value = "ada" } });
    try std.testing.expectEqual(@as(usize, 2), m.n_reqs);
    try std.testing.expectEqualStrings("ada", m.who.slice());
}

test "a button lists one http request and the answer clears it and shows the status" {
    var m = Model.init();
    m.n_reqs = 0;
    update(&m, .get);
    try std.testing.expectEqual(@as(usize, 1), m.n_reqs);
    try std.testing.expectEqualStrings("http://localhost:8104/index.html", m.reqs[0].http.url);
    const id = m.reqs[0].id();
    update(&m, .{ .http_done = .{ .id = id, .status = 200, .body = "<html>" } });
    try std.testing.expectEqual(@as(usize, 0), m.n_reqs);
    try std.testing.expectEqualStrings("status 200, 6 bytes: <html>", m.http.slice());
    update(&m, .{ .http_done = .{ .id = 0, .status = 0, .err = "timeout after 1 ms" } });
    try std.testing.expectEqualStrings("status 0 - timeout after 1 ms", m.http.slice());
}

test "a dropped image keeps its thumbnail only when it is complete" {
    var m = Model.init();
    const px: [6][4]u8 = @splat(.{ 255, 0, 0, 255 });
    update(&m, .{ .dropped = .{ .kind = .image, .name = "a.png", .mime = "image/png", .bytes = "xx", .width = 30, .height = 20, .thumb_rgba = std.mem.asBytes(&px), .thumb_w = 3, .thumb_h = 2 } });
    try std.testing.expectEqual(@as(u32, 3), m.thumb_w);
    try std.testing.expectEqual(@as(u8, 255), m.thumb[0]);
}

test "clock formats the unix time" {
    var m = Model.init();
    update(&m, .{ .clocked = .{ .id = 1, .unix_ms = 1_700_000_000_000, .utc_offset_min = 60 } });
    try std.testing.expect(std.mem.startsWith(u8, m.clock.slice(), "2023-11-14 22:13:20 UTC, offset 60 min"));
}

test "the view lays out under the stub measurer" {
    const m = Model.init();
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    view(&m, &cb);
    try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
}
