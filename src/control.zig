//! Agent control channel + input record/replay, driven from `Runtime.frame`.
//! See docs/features/agent-driver.md.
//!
//! ## What it is
//!
//! An opt-in way for an out-of-process driver (`tools/teak-drive`, an LLM
//! agent through MCP, a shell script) to look at and operate a running teak
//! app. The wire protocol is one JSON object per line over a Unix socket the
//! Host owns (`Host.controlListen` / `controlRecv` / `controlSend`; see
//! `platform/control_socket.zig`). The runtime enables it with
//! `RunOptions.control_path` or the `TEAK_CONTROL=<socket path>` env var, and
//! only when the Host implements the optional control surface. Otherwise
//! nothing here runs.
//!
//! ## Where this sits (HARDLINE)
//!
//! * **No second mutation path.** Every command that changes the app does so
//!   by injecting input events (`Host.injectInput`) that join the Host's real
//!   input queue and are routed, hit-tested and dispatched by exactly the code
//!   real input uses. Nothing here calls `App.update` or touches the Model.
//! * Read-only commands (`snapshot`, `tree`, `msglog`, `state`) read the
//!   frame the pure passes already produced; the optional `debugState` App
//!   hook only reads `*const Model`.
//! * This file is loop orchestration, like `run.zig`: it imports only pure
//!   passes plus the duck-typed Runtime/Host/Gpu, never a backend.
//!
//! ## Execution model
//!
//! One command at a time (the driver is synchronous). Commands that need
//! frames (`click`, `type`, `wait`, ...) compile to a list of small steps, one
//! per frame, executed from `beforePoll` (injection happens before the Host
//! polls) and finished from `afterFrame` (the reply is sent once the last step's
//! frame has been built, so it reflects the result). Instant commands answer
//! within the same tick.

const std = @import("std");
const builtin = @import("builtin");

const a11y = @import("input/a11y.zig");
const snapshot = @import("core/snapshot.zig");
const keys = @import("input/keys.zig");
const pointer = @import("core/pointer.zig");
const record = @import("input_record.zig");
const headless_run = @import("headless_run.zig");
const teak = @import("teak.zig");
const inspector = @import("core/inspector.zig");

/// Compact one-line rendering of a Msg (see `inspector.fmtValue`).
pub const fmtValue = inspector.fmtValue;

/// The target has a host filesystem + environment (not wasm/freestanding).
const fs_capable = builtin.os.tag != .freestanding;

/// Msgs kept for the `msglog` command and the inspector.
pub const ring_n = 32;
const ring_w = 160;

/// One step of a multi-frame command.
const Act = union(enum) {
    move: [2]f32,
    down: pointer.Button,
    up: pointer.Button,
    wheel: [2]f32,
    key: keys.SpecialKey,
    /// UTF-8 in `pool[off..][0..len]`.
    chars: struct { off: u32, len: u32 },
    /// A frame with no input (lets effects / subs settle).
    nop,
    /// Hold for `n` more frames.
    wait: u32,
    /// Hold until the frame snapshot contains `pool[off..][0..len]`, for at
    /// most `left` more frames.
    wait_text: struct { off: u32, len: u32, left: u32 },
    /// Write the offscreen frame as a PNG to `pool[off..][0..len]`.
    screenshot: struct { off: u32, len: u32 },
};

/// Loop-owned bookkeeping for the control channel and record/replay. Holds no
/// application state.
pub const State = struct {
    gpa: std.mem.Allocator,
    /// The socket is listening: commands are served.
    active: bool = false,
    /// Format every dispatched Msg into the ring (control or inspector on).
    log_msgs: bool = false,
    /// `frame()` calls so far; the key of record/replay lines.
    frame_no: u32 = 0,
    /// Last window size the loop saw.
    width: u32 = 0,
    height: u32 = 0,

    // ── command in flight ──
    busy: bool = false,
    acts: std.ArrayList(Act) = .empty,
    act_i: usize = 0,
    /// Owned bytes referenced by `acts` (typed text, needles, paths).
    pool: std.ArrayList(u8) = .empty,
    /// JSON members (with trailing comma) spliced into the final reply.
    note: std.ArrayList(u8) = .empty,
    line_buf: [16 * 1024]u8 = undefined,

    // ── Msg ring ──
    ring: [ring_n][ring_w]u8 = undefined,
    ring_len: [ring_n]u8 = @splat(0),
    ring_total: u32 = 0,

    // ── record ──
    rec_path: ?[]u8 = null,
    rec_buf: std.ArrayList(u8) = .empty,
    rec_lines_unflushed: u32 = 0,
    tracker: record.Tracker = .{},

    // ── replay ──
    replay_data: ?[]u8 = null,
    replay_pos: usize = 0,

    /// Inspector panel is shown (`TEAK_INSPECT`, F12, or the `inspect` command).
    inspect: bool = false,
    /// Command count of each frame buffer BEFORE the inspector's overlay was
    /// appended, so the next frame inspects the app's cmds only.
    app_len: [2]usize = .{ 0, 0 },
    /// Pass timings of the previous frame (milliseconds), shown by the inspector.
    timings: inspector.Timings = .{},

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        if (self.rec_path != null) self.flushRecording();
        if (self.rec_path) |p| self.gpa.free(p);
        if (self.replay_data) |d| self.gpa.free(d);
        self.rec_buf.deinit(self.gpa);
        self.acts.deinit(self.gpa);
        self.pool.deinit(self.gpa);
        self.note.deinit(self.gpa);
    }

    /// Replay file fully consumed (or none loaded).
    pub fn replayDone(self: *const State) bool {
        const d = self.replay_data orelse return true;
        return self.replay_pos >= d.len;
    }

    /// Write the recording so far to its file.
    pub fn flushRecording(self: *State) void {
        if (comptime !fs_capable) return;
        const path = self.rec_path orelse return;
        std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = self.rec_buf.items }) catch
            std.log.warn("teak: could not write recording \"{s}\"", .{path});
        self.rec_lines_unflushed = 0;
    }

    /// The most recent Msgs, oldest first (`n` newest at most).
    pub fn msgAt(self: *const State, age: usize) ?[]const u8 {
        // age 0 = newest.
        const have = @min(self.ring_total, ring_n);
        if (age >= have) return null;
        const slot = (self.ring_total - 1 - age) % ring_n;
        return self.ring[slot][0..self.ring_len[slot]];
    }

    pub fn msgCount(self: *const State) usize {
        return @min(self.ring_total, ring_n);
    }

    /// Record the Msg `msg` (formatted as text) in the ring.
    pub fn logMsg(self: *State, comptime Msg: type, msg: Msg) void {
        const slot = self.ring_total % ring_n;
        var w = std.Io.Writer.fixed(&self.ring[slot]);
        fmtValue(&w, msg) catch {}; // a full slot truncates
        self.ring_len[slot] = @intCast(w.buffered().len);
        self.ring_total +%= 1;
    }
};

// ── Setup ──────────────────────────────────────────────────────────

/// Owned dupe of environment variable `name` if set and non-empty.
fn envVar(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (comptime !fs_capable) return null;
    const threaded = std.Options.debug_threaded_io orelse return null;
    var map = threaded.environ.process_environ.createMap(gpa) catch return null;
    defer map.deinit();
    const v = map.get(name) orelse return null;
    if (v.len == 0) return null;
    return gpa.dupe(u8, v) catch null;
}

/// The Host implements the whole optional control surface.
fn hasControl(comptime Host: type) bool {
    return @hasDecl(Host, "controlListen") and @hasDecl(Host, "controlRecv") and
        @hasDecl(Host, "controlSend") and @hasDecl(Host, "injectInput");
}

/// Resolve options + environment (env wins) and start whatever is asked for.
/// Failures degrade to "feature off" with a log line, never a crash.
pub fn start(st: *State, host: anytype, opts: anytype) void {
    if (comptime !fs_capable) return;
    const gpa = st.gpa;

    // Control channel.
    if (comptime hasControl(@TypeOf(host.*))) {
        const env = envVar(gpa, "TEAK_CONTROL");
        defer if (env) |e| gpa.free(e);
        if (env orelse opts.control_path) |path| {
            if (host.controlListen(path)) {
                st.active = true;
                st.log_msgs = true;
            } else std.log.warn("teak: control channel disabled — could not listen on \"{s}\"", .{path});
        }
    }

    // Inspector.
    if (opts.inspect) st.inspect = true;
    if (envVar(gpa, "TEAK_INSPECT")) |v| {
        defer gpa.free(v);
        st.inspect = !std.mem.eql(u8, v, "0");
    }
    if (st.inspect) st.log_msgs = true;

    // Record.
    const rec_env = envVar(gpa, "TEAK_RECORD");
    if (rec_env orelse (if (opts.record_path) |p| gpa.dupe(u8, p) catch null else null)) |p| {
        st.rec_path = p;
    }

    // Replay.
    const rp_env = envVar(gpa, "TEAK_REPLAY");
    defer if (rp_env) |e| gpa.free(e);
    if (rp_env orelse opts.replay_path) |path| {
        if (comptime !@hasDecl(@TypeOf(host.*), "injectInput")) {
            std.log.warn("teak: replay disabled — this Host cannot inject input", .{});
        } else if (std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, gpa, .limited(64 * 1024 * 1024))) |data| {
            st.replay_data = data;
        } else |_| {
            std.log.warn("teak: replay disabled — could not read \"{s}\"", .{path});
        }
    }
}

// ── Inspector support (called from Runtime) ────────────────────────

/// Monotonic nanoseconds, or 0 when the inspector is off or the target has
/// no clock (so the normal path never reads one).
pub fn stamp(st: *const State) u64 {
    if (comptime !fs_capable) return 0;
    if (!st.inspect) return 0;
    const now = std.Io.Clock.awake.now(std.Options.debug_io);
    return @intCast(now.nanoseconds);
}

pub fn msBetween(a: u64, b: u64) f32 {
    if (a == 0 or b < a) return 0;
    return @as(f32, @floatFromInt(b - a)) / 1_000_000.0;
}

pub fn toggleInspect(st: *State) void {
    st.inspect = !st.inspect;
    if (st.inspect) st.log_msgs = true;
}

/// Append the inspector overlay for the frame being built into `cb`, from the
/// previous frame `prev` (cmds, rects), then remember where the app's own
/// cmds end in `cb` so the next frame skips the overlay.
pub fn appendInspectorFor(rt: anytype, cb: anytype, cur: u1, prev: u1, window_w: f32, window_h: f32) void {
    const st = &rt.ctl;
    st.app_len[cur] = cb.cmds.items.len;
    if (!st.inspect) return;
    const n = @min(st.app_len[prev], rt.rects[prev].items.len);
    const arena = cb.arena.allocator();
    const want = @min(st.msgCount(), 20);
    const msgs = arena.alloc([]const u8, want) catch return;
    for (msgs, 0..) |*m, k| m.* = st.msgAt(want - 1 - k).?;
    const hover = if (rt.ts.hover_index) |h| (if (h < n) h else null) else null;
    inspector.appendInspector(cb, rt.bufs[prev].cmds.items[0..n], rt.rects[prev].items[0..n], .{
        .window_w = window_w,
        .window_h = window_h,
        .frame = rt.ts.frame_counter,
        .hover_index = hover,
        .focus_index = rt.ts.focus_index,
        .msgs = msgs,
        .timings = st.timings,
    }, .{});
}

// ── Per-frame hooks (called from Runtime.frame) ────────────────────

/// Before the Host is polled: replayed input, then the control channel.
pub fn beforePoll(rt: anytype) void {
    const st = &rt.ctl;
    replayTick(rt);
    if (comptime !hasControl(@TypeOf(rt.host.*))) return;
    if (!st.active) return;
    while (true) {
        if (st.busy) {
            stepAct(rt);
            return;
        }
        const line = rt.host.controlRecv(&st.line_buf) orelse return;
        handleLine(rt, line);
    }
}

/// After the Host is polled: capture the frame's input into the recording.
pub fn afterPoll(rt: anytype, input: anytype) void {
    const st = &rt.ctl;
    st.width = input.width;
    st.height = input.height;
    if (st.rec_path == null) return;
    const r = st.tracker.observe(st.frame_no, input) orelse return;
    var aw: std.Io.Writer.Allocating = .fromArrayList(st.gpa, &st.rec_buf);
    record.writeLine(&aw.writer, &r) catch {};
    st.rec_buf = aw.toArrayList();
    st.rec_lines_unflushed += 1;
    if (st.rec_lines_unflushed >= 32) st.flushRecording();
}

/// After the frame is built and presented: finish the command in flight.
pub fn afterFrame(rt: anytype) void {
    const st = &rt.ctl;
    defer st.frame_no +%= 1;
    if (comptime !hasControl(@TypeOf(rt.host.*))) return;
    if (!st.active or !st.busy) return;
    if (st.act_i < st.acts.items.len) {
        switch (st.acts.items[st.act_i]) {
            .wait_text => |*w| {
                if (frameContains(rt, st.pool.items[w.off..][0..w.len])) {
                    st.act_i += 1;
                } else if (w.left == 0) {
                    return fail(rt, "timeout: text not found in the frame", .{});
                } else w.left -= 1;
            },
            .screenshot => |s| {
                takeScreenshot(rt, st.pool.items[s.off..][0..s.len]) catch |e| {
                    return fail(rt, "screenshot failed: {s}", .{@errorName(e)});
                };
                st.act_i += 1;
            },
            else => {},
        }
    }
    if (st.act_i >= st.acts.items.len) finish(rt);
}

fn replayTick(rt: anytype) void {
    const st = &rt.ctl;
    const data = st.replay_data orelse return;
    if (comptime !@hasDecl(@TypeOf(rt.host.*), "injectInput")) return;
    while (st.replay_pos < data.len) {
        const end = std.mem.indexOfScalarPos(u8, data, st.replay_pos, '\n') orelse data.len;
        const line = data[st.replay_pos..end];
        const parsed = record.parseLine(line) catch {
            std.log.warn("teak: replay stopped — bad line \"{s}\"", .{line});
            st.replay_pos = data.len;
            return;
        };
        const r = parsed orelse {
            st.replay_pos = @min(end + 1, data.len);
            continue;
        };
        if (r.frame > st.frame_no) return; // a later frame: wait for it
        st.replay_pos = @min(end + 1, data.len);
        if (r.frame < st.frame_no) continue; // missed (replay started late)
        if (r.mods) |m| rt.host.injectInput(.{ .mods = m });
        if (r.move) |m| rt.host.injectInput(.{ .move = m });
        const btns = [_]pointer.Button{ .left, .middle, .right };
        for (btns) |b| if (buttonSet(r.down, b)) rt.host.injectInput(.{ .down = b });
        for (btns) |b| if (buttonSet(r.up, b)) rt.host.injectInput(.{ .up = b });
        if (r.wheel[0] != 0 or r.wheel[1] != 0) rt.host.injectInput(.{ .wheel = r.wheel });
        if (r.chars_len > 0) rt.host.injectInput(.{ .chars = r.charsSlice() });
        for (r.keysSlice()) |k| rt.host.injectInput(.{ .key = k });
    }
}

fn buttonSet(b: pointer.Buttons, which: pointer.Button) bool {
    return switch (which) {
        .left => b.left,
        .middle => b.middle,
        .right => b.right,
        .none => false,
    };
}

// ── Command execution ──────────────────────────────────────────────

fn stepAct(rt: anytype) void {
    const st = &rt.ctl;
    if (st.act_i >= st.acts.items.len) return;
    const host = rt.host;
    switch (st.acts.items[st.act_i]) {
        .move => |p| host.injectInput(.{ .move = p }),
        .down => |b| host.injectInput(.{ .down = b }),
        .up => |b| host.injectInput(.{ .up = b }),
        .wheel => |w| host.injectInput(.{ .wheel = w }),
        .key => |k| host.injectInput(.{ .key = k }),
        .chars => |c| host.injectInput(.{ .chars = st.pool.items[c.off..][0..c.len] }),
        .nop => {},
        .wait => |*n| {
            if (n.* > 1) {
                n.* -= 1;
                return;
            }
        },
        .wait_text, .screenshot => return, // resolved in afterFrame
    }
    st.act_i += 1;
}

fn reply(rt: anytype, bytes: []const u8) void {
    rt.host.controlSend(bytes);
    rt.host.controlSend("\n");
}

fn fail(rt: anytype, comptime fmt: []const u8, args: anytype) void {
    const st = &rt.ctl;
    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error";
    w.writeAll("{\"ok\":false,\"error\":") catch return;
    std.json.Stringify.encodeJsonString(msg, .{}, w) catch return;
    w.writeAll("}") catch return;
    reply(rt, aw.written());
    resetCommand(st);
}

fn resetCommand(st: *State) void {
    st.busy = false;
    st.acts.clearRetainingCapacity();
    st.pool.clearRetainingCapacity();
    st.note.clearRetainingCapacity();
    st.act_i = 0;
}

/// Reply `{"ok":true, <note>, "frame":N, "last_msg":".."}` for the finished command.
fn finish(rt: anytype) void {
    const st = &rt.ctl;
    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"ok\":true,") catch return;
    w.writeAll(st.note.items) catch return;
    w.print("\"frame\":{d},\"last_msg\":", .{st.frame_no}) catch return;
    std.json.Stringify.encodeJsonString(rt.last_msg, .{}, w) catch return;
    w.writeAll("}") catch return;
    reply(rt, aw.written());
    resetCommand(st);
}

const Json = std.json.Value;

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getNum(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn handleLine(rt: anytype, line: []const u8) void {
    const st = &rt.ctl;
    var parsed = std.json.parseFromSlice(Json, st.gpa, line, .{}) catch {
        return fail(rt, "invalid JSON", .{});
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return fail(rt, "expected a JSON object", .{}),
    };
    const cmd = getStr(obj, "cmd") orelse return fail(rt, "missing \"cmd\"", .{});

    resetCommand(st);
    if (std.mem.eql(u8, cmd, "ping") or std.mem.eql(u8, cmd, "info")) {
        return cmdInfo(rt);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        return cmdSnapshot(rt);
    } else if (std.mem.eql(u8, cmd, "tree")) {
        return cmdTree(rt);
    } else if (std.mem.eql(u8, cmd, "msglog")) {
        return cmdMsglog(rt, if (getNum(obj, "n")) |n| @intFromFloat(@max(n, 0)) else ring_n);
    } else if (std.mem.eql(u8, cmd, "state")) {
        return cmdState(rt);
    } else if (std.mem.eql(u8, cmd, "quit")) {
        if (comptime @hasDecl(@TypeOf(rt.host.*), "requestClose")) rt.host.requestClose();
        st.flushRecording();
        return replyOk(rt, "");
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        const on = if (obj.get("on")) |v| (v == .bool and v.bool) else !st.inspect;
        st.inspect = on;
        if (on) st.log_msgs = true;
        return replyOk(rt, if (on) "\"inspect\":true," else "\"inspect\":false,");
    } else if (std.mem.eql(u8, cmd, "click")) {
        return cmdClick(rt, obj);
    } else if (std.mem.eql(u8, cmd, "hover")) {
        return cmdHover(rt, obj);
    } else if (std.mem.eql(u8, cmd, "type")) {
        return cmdType(rt, obj);
    } else if (std.mem.eql(u8, cmd, "key")) {
        return cmdKey(rt, obj);
    } else if (std.mem.eql(u8, cmd, "scroll")) {
        return cmdScroll(rt, obj);
    } else if (std.mem.eql(u8, cmd, "wait")) {
        return cmdWait(rt, obj);
    } else if (std.mem.eql(u8, cmd, "screenshot")) {
        return cmdScreenshot(rt, obj);
    }
    fail(rt, "unknown command \"{s}\"", .{cmd});
}

fn replyOk(rt: anytype, note: []const u8) void {
    const st = &rt.ctl;
    st.note.clearRetainingCapacity();
    st.note.appendSlice(st.gpa, note) catch {};
    finish(rt);
}

/// Begin executing the acts just queued (also takes the first step now).
fn begin(rt: anytype) void {
    const st = &rt.ctl;
    st.act_i = 0;
    if (st.acts.items.len == 0) return finish(rt);
    st.busy = true;
    stepAct(rt);
}

fn addAct(st: *State, a: Act) void {
    st.acts.append(st.gpa, a) catch {};
}

fn addPool(st: *State, bytes: []const u8) struct { off: u32, len: u32 } {
    const off: u32 = @intCast(st.pool.items.len);
    st.pool.appendSlice(st.gpa, bytes) catch {};
    return .{ .off = off, .len = @intCast(bytes.len) };
}

// ── Latest frame access ────────────────────────────────────────────

/// The latest frame's cmds WITHOUT the dev inspector's overlay, so the agent
/// reads and operates the app, not the tool.
fn frameCmds(rt: anytype) @TypeOf(rt.bufs[0].cmds.items) {
    const all = rt.bufs[rt.current].cmds.items;
    return all[0..@min(rt.ctl.app_len[rt.current], all.len)];
}

fn frameRects(rt: anytype) []const @import("layout/engine.zig").Rect {
    const all = rt.rects[rt.current].items;
    return all[0..@min(rt.ctl.app_len[rt.current], all.len)];
}

fn frameHeader(rt: anytype) snapshot.Header {
    return .{
        .window_w = @floatFromInt(rt.ctl.width),
        .window_h = @floatFromInt(rt.ctl.height),
        .frame = rt.ts.frame_counter,
        .last_msg = rt.last_msg,
    };
}

fn snapshotText(rt: anytype) ![]u8 {
    return snapshot.snapshotAlloc(rt.ctl.gpa, frameCmds(rt), frameRects(rt), .{
        .header = frameHeader(rt),
        .transient = &rt.ts,
    });
}

fn frameContains(rt: anytype, needle: []const u8) bool {
    const text = snapshotText(rt) catch return false;
    defer rt.ctl.gpa.free(text);
    return std.mem.indexOf(u8, text, needle) != null;
}

fn takeScreenshot(rt: anytype, path: []const u8) !void {
    const Gpu = @TypeOf(rt.gpu.*);
    if (comptime !@hasDecl(Gpu, "readFrame")) return error.NoOffscreenGpu;
    try headless_run.writeFramePng(rt.gpu, rt.ctl.gpa, path);
}

// ── Instant commands ───────────────────────────────────────────────

fn cmdInfo(rt: anytype) void {
    const st = &rt.ctl;
    var buf: [128]u8 = undefined;
    const ver = if (@hasDecl(teak, "version")) teak.version else "";
    const note = std.fmt.bufPrint(&buf, "\"teak\":\"{s}\",\"width\":{d},\"height\":{d},", .{ ver, st.width, st.height }) catch "";
    replyOk(rt, note);
}

fn cmdSnapshot(rt: anytype) void {
    const st = &rt.ctl;
    const text = snapshotText(rt) catch return fail(rt, "out of memory", .{});
    defer st.gpa.free(text);
    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    aw.writer.writeAll("\"snapshot\":") catch return;
    std.json.Stringify.encodeJsonString(text, .{}, &aw.writer) catch return;
    aw.writer.writeAll(",") catch return;
    replyOk(rt, aw.written());
}

fn cmdMsglog(rt: anytype, n: usize) void {
    const st = &rt.ctl;
    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const have = @min(n, st.msgCount());
    w.print("\"total\":{d},\"msgs\":[", .{st.ring_total}) catch return;
    var i: usize = have;
    while (i > 0) {
        i -= 1; // oldest of the requested window first
        if (have - 1 - i > 0) w.writeByte(',') catch return;
        std.json.Stringify.encodeJsonString(st.msgAt(i).?, .{}, w) catch return;
    }
    w.writeAll("],") catch return;
    replyOk(rt, aw.written());
}

fn cmdState(rt: anytype) void {
    const st = &rt.ctl;
    const App = @TypeOf(rt.*).AppDecl;
    if (comptime !@hasDecl(App, "debugState")) {
        return fail(rt, "the app has no debugState hook (pub fn debugState(*const Model, *std.Io.Writer) void)", .{});
    }
    var body: std.Io.Writer.Allocating = .init(st.gpa);
    defer body.deinit();
    App.debugState(&rt.model, &body.writer);
    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    aw.writer.writeAll("\"state\":") catch return;
    std.json.Stringify.encodeJsonString(body.written(), .{}, &aw.writer) catch return;
    aw.writer.writeAll(",") catch return;
    replyOk(rt, aw.written());
}

/// Write the a11y tree of the latest frame as JSON members: `"nodes":[...],`.
fn cmdTree(rt: anytype) void {
    const st = &rt.ctl;
    var arena_state = std.heap.ArenaAllocator.init(st.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = a11y.buildTree(arena, frameCmds(rt), frameRects(rt), rt.ts.focus_index) catch
        return fail(rt, "out of memory", .{});

    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("\"nodes\":[") catch return;
    for (nodes, 0..) |n, i| {
        if (i > 0) w.writeByte(',') catch return;
        writeNode(w, n, i) catch return;
    }
    w.writeAll("],") catch return;
    replyOk(rt, aw.written());
}

fn isClickable(n: a11y.A11yNode) bool {
    return switch (n.role) {
        .button, .text_input, .checkbox, .radio, .slider => !n.disabled,
        else => false,
    };
}

fn isFocusable(n: a11y.A11yNode) bool {
    return n.role == .text_input and !n.disabled;
}

fn writeNode(w: *std.Io.Writer, n: a11y.A11yNode, i: usize) !void {
    try w.print("{{\"i\":{d},\"index\":{d},\"role\":\"{s}\",\"label\":", .{ i, n.cmd_index, @tagName(n.role) });
    try std.json.Stringify.encodeJsonString(n.label, .{}, w);
    try w.print(",\"rect\":[{d},{d},{d},{d}],\"focusable\":{},\"clickable\":{},\"focused\":{},\"disabled\":{}", .{
        n.bounds.x,     n.bounds.y,     n.bounds.w, n.bounds.h,
        isFocusable(n), isClickable(n), n.focused,  n.disabled,
    });
    switch (n.role) {
        .text_input => {
            try w.writeAll(",\"value\":");
            try std.json.Stringify.encodeJsonString(n.label, .{}, w);
        },
        .checkbox, .radio => try w.print(",\"checked\":{}", .{n.state != 0}),
        .slider => try w.print(",\"value\":{d}", .{n.state}),
        else => {},
    }
    try w.writeByte('}');
}

// ── Selectors ──────────────────────────────────────────────────────

const Target = struct {
    x: f32,
    y: f32,
    /// JSON member describing what was hit, for the reply note.
    desc: [256]u8 = undefined,
    desc_len: usize = 0,
};

/// Resolve `{role, label, index, nth}` or `{x, y}` (read from `sel`, which is
/// the "selector" member if present, else the command object itself) to a
/// point in the latest frame.
fn resolve(rt: anytype, obj: std.json.ObjectMap) !Target {
    const sel: std.json.ObjectMap = if (obj.get("selector")) |s| switch (s) {
        .object => |o| o,
        else => obj,
    } else obj;

    var t: Target = .{ .x = 0, .y = 0 };
    if (getNum(sel, "x")) |x| if (getNum(sel, "y")) |y| {
        t.x = @floatCast(x);
        t.y = @floatCast(y);
        return t;
    };

    const rects = frameRects(rt);
    if (getNum(sel, "index")) |idx| {
        const i: usize = @intFromFloat(@max(idx, 0));
        if (i >= rects.len) return error.IndexOutOfRange;
        t.x = rects[i].x + rects[i].w / 2;
        t.y = rects[i].y + rects[i].h / 2;
        return describe(t, "cmd", i, rects[i]);
    }

    const role = getStr(sel, "role");
    const label = getStr(sel, "label");
    if (role == null and label == null) return error.EmptySelector;
    const nth: usize = if (getNum(sel, "nth")) |n| @intFromFloat(@max(n, 0)) else 0;

    var arena_state = std.heap.ArenaAllocator.init(rt.ctl.gpa);
    defer arena_state.deinit();
    const nodes = try a11y.buildTree(arena_state.allocator(), frameCmds(rt), rects, rt.ts.focus_index);
    var seen: usize = 0;
    for (nodes) |n| {
        if (role) |r| if (!std.mem.eql(u8, r, @tagName(n.role))) continue;
        if (label) |l| if (std.ascii.findIgnoreCase(n.label, l) == null) continue;
        if (seen < nth) {
            seen += 1;
            continue;
        }
        t.x = n.bounds.x + n.bounds.w / 2;
        t.y = n.bounds.y + n.bounds.h / 2;
        const lab = n.label[0..@min(n.label.len, 60)];
        const d = std.fmt.bufPrint(&t.desc, "{{\"role\":\"{s}\",\"index\":{d},\"label\":{f},\"rect\":[{d},{d},{d},{d}]}}", .{
            @tagName(n.role), n.cmd_index, std.json.fmt(lab, .{}), n.bounds.x, n.bounds.y,
            n.bounds.w,       n.bounds.h,
        }) catch t.desc[0..0];
        t.desc_len = d.len;
        return t;
    }
    return error.NoMatch;
}

fn describe(t0: Target, role: []const u8, index: usize, r: anytype) Target {
    var t = t0;
    const d = std.fmt.bufPrint(&t.desc, "{{\"role\":\"{s}\",\"index\":{d},\"rect\":[{d},{d},{d},{d}]}}", .{ role, index, r.x, r.y, r.w, r.h }) catch t.desc[0..0];
    t.desc_len = d.len;
    return t;
}

fn selectorError(rt: anytype, e: anyerror) void {
    switch (e) {
        error.NoMatch => fail(rt, "no visible node matches the selector (see the `tree` command)", .{}),
        error.EmptySelector => fail(rt, "selector needs role and/or label, an index, or x and y", .{}),
        error.IndexOutOfRange => fail(rt, "cmd index out of range", .{}),
        else => fail(rt, "selector failed: {s}", .{@errorName(e)}),
    }
}

fn setTargetNote(rt: anytype, t: Target) void {
    const st = &rt.ctl;
    st.note.appendSlice(st.gpa, "\"target\":") catch {};
    st.note.appendSlice(st.gpa, t.desc[0..t.desc_len]) catch {};
    st.note.appendSlice(st.gpa, ",") catch {};
}

// ── Input commands ─────────────────────────────────────────────────

fn cmdClick(rt: anytype, obj: std.json.ObjectMap) void {
    const st = &rt.ctl;
    const t = resolve(rt, obj) catch |e| return selectorError(rt, e);
    const button: pointer.Button = if (getStr(obj, "button")) |b|
        std.meta.stringToEnum(pointer.Button, b) orelse .left
    else
        .left;
    // The runtime routes against the PREVIOUS frame's layout, so a click needs
    // a frame between its parts, exactly as a real mouse produces them.
    addAct(st, .{ .move = .{ t.x, t.y } });
    addAct(st, .{ .down = button });
    addAct(st, .{ .up = button });
    addAct(st, .nop);
    setTargetNote(rt, t);
    begin(rt);
}

fn cmdHover(rt: anytype, obj: std.json.ObjectMap) void {
    const st = &rt.ctl;
    const t = resolve(rt, obj) catch |e| return selectorError(rt, e);
    addAct(st, .{ .move = .{ t.x, t.y } });
    addAct(st, .nop);
    setTargetNote(rt, t);
    begin(rt);
}

fn cmdScroll(rt: anytype, obj: std.json.ObjectMap) void {
    const st = &rt.ctl;
    const dx: f32 = @floatCast(getNum(obj, "dx") orelse 0);
    const dy: f32 = @floatCast(getNum(obj, "dy") orelse 0);
    const has_target = obj.get("selector") != null or obj.get("role") != null or obj.get("label") != null or
        obj.get("index") != null or (obj.get("x") != null and obj.get("y") != null);
    if (has_target) {
        const t = resolve(rt, obj) catch |e| return selectorError(rt, e);
        addAct(st, .{ .move = .{ t.x, t.y } });
        setTargetNote(rt, t);
    }
    addAct(st, .{ .wheel = .{ dx, dy } });
    addAct(st, .nop);
    begin(rt);
}

fn cmdType(rt: anytype, obj: std.json.ObjectMap) void {
    const st = &rt.ctl;
    const text = getStr(obj, "text") orelse return fail(rt, "type needs \"text\"", .{});
    if (!std.unicode.utf8ValidateSlice(text)) return fail(rt, "text is not valid UTF-8", .{});
    // One frame's input queue holds 64 bytes; send 32 per frame.
    var rest = text;
    while (rest.len > 0) {
        var n = @min(rest.len, 32);
        while (n < rest.len and n > 0 and (rest[n] & 0xC0) == 0x80) n -= 1;
        const p = addPool(st, rest[0..n]);
        addAct(st, .{ .chars = .{ .off = p.off, .len = p.len } });
        rest = rest[n..];
    }
    addAct(st, .nop);
    begin(rt);
}

fn cmdKey(rt: anytype, obj: std.json.ObjectMap) void {
    const st = &rt.ctl;
    const name = getStr(obj, "name") orelse return fail(rt, "key needs \"name\" (a SpecialKey: enter, tab, backspace, ctrl_a, ...)", .{});
    const k = std.meta.stringToEnum(keys.SpecialKey, name) orelse
        return fail(rt, "unknown key \"{s}\"; valid names are the teak.SpecialKey tags", .{name});
    const count: usize = if (getNum(obj, "count")) |c| @intFromFloat(std.math.clamp(c, 1, 64)) else 1;
    for (0..count) |_| addAct(st, .{ .key = k });
    addAct(st, .nop);
    begin(rt);
}

fn cmdWait(rt: anytype, obj: std.json.ObjectMap) void {
    const st = &rt.ctl;
    if (getStr(obj, "until_text")) |needle| {
        const p = addPool(st, needle);
        const timeout: u32 = if (getNum(obj, "timeout_frames")) |t| @intFromFloat(@max(t, 0)) else 600;
        if (frameContains(rt, needle)) return replyOk(rt, "");
        addAct(st, .{ .wait_text = .{ .off = p.off, .len = p.len, .left = timeout } });
        return begin(rt);
    }
    const frames: u32 = if (getNum(obj, "frames")) |f| @intFromFloat(@max(f, 0)) else 1;
    if (frames == 0) return replyOk(rt, "");
    addAct(st, .{ .wait = frames });
    begin(rt);
}

fn cmdScreenshot(rt: anytype, obj: std.json.ObjectMap) void {
    const st = &rt.ctl;
    const path = getStr(obj, "path") orelse return fail(rt, "screenshot needs \"path\"", .{});
    const p = addPool(st, path);
    st.note.appendSlice(st.gpa, "\"path\":") catch {};
    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    std.json.Stringify.encodeJsonString(path, .{}, &aw.writer) catch {};
    st.note.appendSlice(st.gpa, aw.written()) catch {};
    st.note.appendSlice(st.gpa, ",") catch {};
    addAct(st, .{ .screenshot = .{ .off = p.off, .len = p.len } });
    begin(rt);
}

// ── Tests ──────────────────────────────────────────────────────────

test "State ring keeps the newest Msgs, oldest first by age" {
    const Msg = union(enum) { a: u32 };
    var st = State.init(std.testing.allocator);
    defer st.deinit();
    for (0..40) |i| st.logMsg(Msg, .{ .a = @intCast(i) });
    try std.testing.expectEqual(@as(usize, ring_n), st.msgCount());
    try std.testing.expectEqualStrings(".a(39)", st.msgAt(0).?);
    try std.testing.expectEqualStrings(".a(8)", st.msgAt(ring_n - 1).?);
    try std.testing.expect(st.msgAt(ring_n) == null);
}
