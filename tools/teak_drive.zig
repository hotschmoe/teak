//! teak-drive: drive a running teak app from a shell or from an LLM agent.
//!
//!     teak-drive [--socket PATH] <command> [args]      one-shot commands
//!     teak-drive launch [--x11|--headless] BINARY ...  start an app with a control socket
//!     teak-drive mcp                                   MCP server on stdio (JSON-RPC)
//!
//! The app side is `TEAK_CONTROL=<socket>` (src/control.zig); this tool is a
//! thin client of that line-delimited JSON protocol. See
//! docs/features/agent-driver.md.

const std = @import("std");
const control_socket = @import("control_socket");

const Client = control_socket.Client;
const Io = std.Io;

pub const version = "0.1.0";

const usage =
    \\teak-drive — drive a running teak app (docs/features/agent-driver.md)
    \\
    \\usage: teak-drive [--socket PATH] <command> [args]
    \\  (the socket defaults to $TEAK_CONTROL)
    \\
    \\read:     snapshot | tree | info | state | msglog [N]
    \\act:      drag '<from-selector-json>' '<to-selector-json>' | shortcut CHORD (e.g. ctrl+shift+p) | click|hover [--role R] [--label L | LABEL...] [--index N] [--nth N] [--x X --y Y]
    \\          type TEXT | key NAME [COUNT] | scroll --dy N [--dx N] [selector]
    \\          wait --frames N | wait --text STR [--timeout FRAMES]
    \\          screenshot PATH | inspect [on|off] | quit
    \\other:    raw '<json>'          send one protocol object, print the reply
    \\          launch [--x11|--headless] [--socket PATH] BINARY [ARGS...]
    \\          mcp                   MCP server on stdio (tools: launch_app, snapshot, ...)
    \\
    \\Replies are JSON; `snapshot` prints the snapshot text and `tree` one line per node.
    \\Exit status 1 when the app answers {"ok":false}.
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [8192]u8 = undefined;
    var out_w = Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};
    var err_buf: [1024]u8 = undefined;
    var err_w = Io.File.stderr().writer(io, &err_buf);
    const errw = &err_w.interface;
    defer errw.flush() catch {};

    var i: usize = 1;
    var socket: ?[]const u8 = init.environ_map.get("TEAK_CONTROL");
    while (i < args.len and std.mem.startsWith(u8, args[i], "--socket")) {
        if (std.mem.eql(u8, args[i], "--socket") and i + 1 < args.len) {
            socket = args[i + 1];
            i += 2;
        } else if (std.mem.startsWith(u8, args[i], "--socket=")) {
            socket = args[i]["--socket=".len..];
            i += 1;
        } else break;
    }
    if (i >= args.len or std.mem.eql(u8, args[i], "help") or std.mem.eql(u8, args[i], "--help")) {
        try errw.writeAll(usage);
        return;
    }
    const cmd = args[i];
    const rest = args[i + 1 ..];

    if (std.mem.eql(u8, cmd, "mcp")) return mcpMain(init, out);
    if (std.mem.eql(u8, cmd, "launch")) return launchCmd(init, out, errw, socket, rest);

    const sock = socket orelse {
        try errw.writeAll("teak-drive: no socket; pass --socket PATH or set TEAK_CONTROL\n");
        std.process.exit(2);
    };
    const line = (try buildCommand(gpa, cmd, rest)) orelse {
        try errw.print("teak-drive: unknown or malformed command \"{s}\" (try `teak-drive help`)\n", .{cmd});
        std.process.exit(2);
    };
    defer gpa.free(line);

    var cl = Client.connect(sock) catch {
        try errw.print("teak-drive: cannot connect to {s} (is the app running with TEAK_CONTROL set?)\n", .{sock});
        std.process.exit(2);
    };
    defer cl.close();
    try cl.sendLine(line);
    const reply = try cl.readLine(gpa);
    defer gpa.free(reply);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch {
        try out.print("{s}\n", .{reply});
        return;
    };
    defer parsed.deinit();
    const ok = replyOk(parsed.value);
    if (!ok) {
        try errw.print("{s}\n", .{reply});
        try errw.flush();
        std.process.exit(1);
    }
    if (std.mem.eql(u8, cmd, "snapshot")) {
        if (parsed.value.object.get("snapshot")) |s| return out.writeAll(s.string);
    } else if (std.mem.eql(u8, cmd, "tree")) {
        return writeTreeText(out, parsed.value);
    }
    try out.print("{s}\n", .{reply});
}

fn replyOk(v: std.json.Value) bool {
    if (v != .object) return false;
    const ok = v.object.get("ok") orelse return false;
    return ok == .bool and ok.bool;
}

/// One line per a11y node: `[i] role "label" rect=(x,y,w,h) flags`.
fn writeTreeText(w: *Io.Writer, v: std.json.Value) !void {
    const nodes = (v.object.get("nodes") orelse return).array.items;
    for (nodes) |n| {
        const o = n.object;
        const r = o.get("rect").?.array.items;
        try w.print("[{d}] {s} \"{s}\" rect=({d},{d},{d},{d})", .{
            jsonInt(o.get("i").?), o.get("role").?.string, o.get("label").?.string,
            jsonInt(r[0]),         jsonInt(r[1]),          jsonInt(r[2]),
            jsonInt(r[3]),
        });
        if (o.get("clickable").?.bool) try w.writeAll(" clickable");
        if (o.get("focusable").?.bool) try w.writeAll(" focusable");
        if (o.get("focused").?.bool) try w.writeAll(" focused");
        if (o.get("disabled").?.bool) try w.writeAll(" disabled");
        if (o.get("checked")) |c| try w.writeAll(if (c.bool) " checked" else " unchecked");
        try w.writeByte('\n');
    }
}

fn jsonInt(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(@round(f)),
        else => 0,
    };
}

// ── Command-line -> protocol object ────────────────────────────────

fn jsonStr(w: *Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// Build the one-line protocol object for CLI command `cmd`, or null when
/// the arguments do not fit.
fn buildCommand(gpa: std.mem.Allocator, cmd: []const u8, args: []const []const u8) !?[]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    if (std.mem.eql(u8, cmd, "raw")) {
        if (args.len != 1) return null;
        try w.writeAll(args[0]);
        return try aw.toOwnedSlice();
    }
    const simple = [_][]const u8{ "snapshot", "tree", "info", "ping", "state", "quit" };
    for (simple) |s| if (std.mem.eql(u8, cmd, s)) {
        try w.print("{{\"cmd\":\"{s}\"}}", .{cmd});
        return try aw.toOwnedSlice();
    };
    if (std.mem.eql(u8, cmd, "msglog")) {
        try w.writeAll("{\"cmd\":\"msglog\"");
        if (args.len > 0) try w.print(",\"n\":{s}", .{args[0]});
        try w.writeByte('}');
    } else if (std.mem.eql(u8, cmd, "type")) {
        if (args.len == 0) return null;
        try w.writeAll("{\"cmd\":\"type\",\"text\":");
        // Several words join with a single space: `type hello world`.
        var joined: Io.Writer.Allocating = .init(gpa);
        defer joined.deinit();
        for (args, 0..) |a, k| {
            if (k > 0) try joined.writer.writeByte(' ');
            try joined.writer.writeAll(a);
        }
        try jsonStr(w, joined.written());
        try w.writeByte('}');
    } else if (std.mem.eql(u8, cmd, "drag")) {
        if (args.len != 2) return null; // two selector objects as JSON
        try w.print("{{\"cmd\":\"drag\",\"from\":{s},\"to\":{s}}}", .{ args[0], args[1] });
    } else if (std.mem.eql(u8, cmd, "shortcut")) {
        if (args.len != 1) return null;
        try w.writeAll("{\"cmd\":\"shortcut\",\"chord\":");
        try jsonStr(w, args[0]);
        try w.writeByte('}');
    } else if (std.mem.eql(u8, cmd, "key")) {
        if (args.len == 0) return null;
        try w.writeAll("{\"cmd\":\"key\",\"name\":");
        try jsonStr(w, args[0]);
        if (args.len > 1) try w.print(",\"count\":{s}", .{args[1]});
        try w.writeByte('}');
    } else if (std.mem.eql(u8, cmd, "screenshot")) {
        if (args.len != 1) return null;
        try w.writeAll("{\"cmd\":\"screenshot\",\"path\":");
        const abs = try absolutePath(gpa, args[0]);
        defer gpa.free(abs);
        try jsonStr(w, abs);
        try w.writeByte('}');
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        try w.writeAll("{\"cmd\":\"inspect\"");
        if (args.len > 0) try w.print(",\"on\":{}", .{std.mem.eql(u8, args[0], "on")});
        try w.writeByte('}');
    } else if (std.mem.eql(u8, cmd, "click") or std.mem.eql(u8, cmd, "hover") or std.mem.eql(u8, cmd, "scroll") or std.mem.eql(u8, cmd, "wait")) {
        try w.print("{{\"cmd\":\"{s}\"", .{cmd});
        var label: Io.Writer.Allocating = .init(gpa);
        defer label.deinit();
        var k: usize = 0;
        while (k < args.len) : (k += 1) {
            const a = args[k];
            if (std.mem.startsWith(u8, a, "--") and k + 1 < args.len) {
                const name = a[2..];
                const val = args[k + 1];
                k += 1;
                const numeric = [_][]const u8{ "index", "nth", "x", "y", "dx", "dy", "frames", "timeout" };
                var is_num = false;
                for (numeric) |nm| if (std.mem.eql(u8, name, nm)) {
                    is_num = true;
                };
                if (std.mem.eql(u8, name, "text")) {
                    try w.writeAll(",\"until_text\":");
                    try jsonStr(w, val);
                } else if (std.mem.eql(u8, name, "timeout")) {
                    try w.print(",\"timeout_frames\":{s}", .{val});
                } else if (is_num) {
                    try w.print(",\"{s}\":{s}", .{ name, val });
                } else {
                    try w.print(",\"{s}\":", .{name});
                    try jsonStr(w, val);
                }
            } else {
                if (label.written().len > 0) try label.writer.writeByte(' ');
                try label.writer.writeAll(a);
            }
        }
        if (label.written().len > 0) {
            try w.writeAll(",\"label\":");
            try jsonStr(w, label.written());
        }
        try w.writeByte('}');
    } else return null;
    return try aw.toOwnedSlice();
}

/// `path` made absolute against the current directory. Caller frees.
fn absolutePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(std.Options.debug_io, &buf);
    return std.fs.path.join(gpa, &.{ buf[0..n], path });
}

// ── launch (shell use) ─────────────────────────────────────────────

const Launched = struct {
    child: std.process.Child,
    sock: []u8,
};

/// Spawn `argv` with `TEAK_CONTROL=sock` (and DISPLAY, if given) and wait
/// until the socket accepts a connection.
fn spawnApp(init: std.process.Init, argv: []const []const u8, sock: []const u8, cwd: ?[]const u8, display: ?[]const u8, inherit_stdout: bool) !Launched {
    const gpa = init.gpa;
    const io = init.io;
    var env = try init.environ_map.clone(gpa);
    defer env.deinit();
    try env.put("TEAK_CONTROL", sock);
    if (display) |d| try env.put("DISPLAY", d);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .stdin = .ignore,
        .stdout = if (inherit_stdout) .inherit else .ignore,
        .stderr = .inherit,
    });
    errdefer child.kill(io);

    // Wait for the app to create its socket (GPU init can take a moment).
    var tries: u32 = 0;
    while (tries < 400) : (tries += 1) {
        if (Client.connect(sock)) |c| {
            var cc = c;
            cc.close();
            return .{ .child = child, .sock = try gpa.dupe(u8, sock) };
        } else |_| {}
        Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    return error.AppDidNotStart;
}

fn launchCmd(init: std.process.Init, out: *Io.Writer, errw: *Io.Writer, socket: ?[]const u8, args: []const []const u8) !void {
    const gpa = init.gpa;
    var x11 = false;
    var display: ?[]const u8 = null;
    var sock_arg = socket;
    var i: usize = 0;
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--x11")) {
            x11 = true;
        } else if (std.mem.eql(u8, args[i], "--headless")) {
            x11 = false;
        } else if (std.mem.eql(u8, args[i], "--socket") and i + 1 < args.len) {
            i += 1;
            sock_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--display") and i + 1 < args.len) {
            i += 1;
            display = args[i];
        } else break;
    }
    if (i >= args.len) {
        try errw.writeAll("usage: teak-drive launch [--x11|--headless] [--socket PATH] [--display :N] BINARY [ARGS...]\n");
        std.process.exit(2);
    }
    const path = sock_arg orelse try std.fmt.allocPrint(gpa, "/tmp/teak-drive-{d}.sock", .{std.os.linux.getpid()});
    var l = spawnApp(init, args[i..], path, null, display, false) catch |e| {
        try errw.print("teak-drive: could not start {s}: {s}\n", .{ args[i], @errorName(e) });
        std.process.exit(1);
    };
    // Leave the app running: the caller owns it from here (`teak-drive quit`).
    try out.print("socket={s}\npid={d}\n", .{ l.sock, l.child.id orelse 0 });
    _ = &l;
}

// ── MCP server ─────────────────────────────────────────────────────

const protocol_version = "2024-11-05";

const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON text of the `inputSchema` object.
    schema: []const u8,
};

const selector_props =
    \\"role":{"type":"string","description":"a11y role: button, text_input, checkbox, radio, slider, text, group, ..."},
    \\"label":{"type":"string","description":"case-insensitive substring of the widget label / text"},
    \\"index":{"type":"integer","description":"cmd index from snapshot/tree (alternative to role+label)"},
    \\"nth":{"type":"integer","description":"pick the Nth match (default 0)"},
    \\"x":{"type":"number"},"y":{"type":"number"}
;

const tools = [_]Tool{
    .{ .name = "launch_app", .description = "Start a teak app under control and connect to it. `example` runs examples/<name> (built with `zig build drive` on first use); `binary` runs any teak app built with the control channel. mode headless renders offscreen with the real GPU renderer (screenshots work); x11 opens a window on $DISPLAY (no screenshots). Replaces any app already launched.", .schema =
    \\{"type":"object","properties":{"example":{"type":"string","description":"example name, e.g. todo"},"binary":{"type":"string","description":"path to an app binary (instead of example)"},"mode":{"type":"string","enum":["headless","x11"]},"args":{"type":"array","items":{"type":"string"}},"cwd":{"type":"string"},"display":{"type":"string","description":"X display for x11 mode, e.g. :99"}}}
    },
    .{ .name = "snapshot", .description = "The current frame as text: one line per widget with its rect, in the teak snapshot format. Cheapest way to read the UI.", .schema = "{\"type\":\"object\",\"properties\":{}}" },
    .{ .name = "tree", .description = "Accessibility tree of the current frame: role, label, rect, clickable/focusable/focused/disabled, checked, value. Use it to choose selectors.", .schema = "{\"type\":\"object\",\"properties\":{}}" },
    .{ .name = "click", .description = "Click a widget chosen by role and/or label substring (or cmd index, or x/y). Goes through the real input path. Fails with an error if nothing matches.", .schema = "{\"type\":\"object\",\"properties\":{" ++ selector_props ++ ",\"button\":{\"type\":\"string\",\"enum\":[\"left\",\"middle\",\"right\"]}}}" },
    .{ .name = "hover", .description = "Move the pointer over a widget (same selectors as click).", .schema = "{\"type\":\"object\",\"properties\":{" ++ selector_props ++ "}}" },
    .{ .name = "type", .description = "Type text into the focused widget (click a text input first).", .schema =
    \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
    },
    .{ .name = "key", .description = "Press a special key by teak.SpecialKey name: enter, tab, shift_tab, escape, backspace, delete, left, right, up, down, home, end, page_up, page_down, ctrl_a, ctrl_c, ctrl_v, ...", .schema =
    \\{"type":"object","properties":{"name":{"type":"string"},"count":{"type":"integer"}},"required":["name"]}
    },
    .{ .name = "drag", .description = "Drag from one widget to another with the real pointer path (in-app drag and drop, e.g. reordering list rows). `from` and `to` are selector objects ({role,label,index,nth,x,y}); add offset_x / offset_y (from the node center) to press the non-interactive part of a row, since pressing an interactive widget clicks it instead.", .schema =
    \\{"type":"object","properties":{"from":{"type":"object"},"to":{"type":"object"}},"required":["from","to"]}
    },
    .{ .name = "shortcut", .description = "Press a keyboard shortcut such as ctrl+s, ctrl+shift+p, alt+enter or f5; the app's command table matches it like a real key press (use this to run commands and open the command palette).", .schema =
    \\{"type":"object","properties":{"chord":{"type":"string"}},"required":["chord"]}
    },
    .{ .name = "scroll", .description = "Scroll the wheel (dy>0 scrolls content down), optionally over a selected widget.", .schema = "{\"type\":\"object\",\"properties\":{\"dx\":{\"type\":\"number\"},\"dy\":{\"type\":\"number\"}," ++ selector_props ++ "}}" },
    .{ .name = "screenshot", .description = "Write the current frame to a PNG (headless mode only) and return its path; set include_image to also receive the pixels inline.", .schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"output file (default: a temp file)"},"include_image":{"type":"boolean"}}}
    },
    .{ .name = "msglog", .description = "The most recent Msgs the app dispatched (update transitions), oldest first.", .schema =
    \\{"type":"object","properties":{"n":{"type":"integer"}}}
    },
    .{ .name = "state", .description = "The app's own debug dump of its Model (requires the app to implement debugState).", .schema = "{\"type\":\"object\",\"properties\":{}}" },
    .{ .name = "wait", .description = "Wait for N frames, or until the snapshot contains `until_text` (fails after timeout_frames).", .schema =
    \\{"type":"object","properties":{"frames":{"type":"integer"},"until_text":{"type":"string"},"timeout_frames":{"type":"integer"}}}
    },
    .{ .name = "quit", .description = "Close the launched app.", .schema = "{\"type\":\"object\",\"properties\":{}}" },
};

const Mcp = struct {
    init: std.process.Init,
    gpa: std.mem.Allocator,
    io: Io,
    app: ?Launched = null,
    cl: ?Client = null,
    shots: u32 = 0,
    launches: u32 = 0,

    fn stopApp(self: *Mcp) void {
        if (self.cl) |*c| {
            c.sendLine("{\"cmd\":\"quit\"}") catch {};
            // Give the app a moment to exit by itself, then make sure.
            if (c.readLine(self.gpa)) |r| self.gpa.free(r) else |_| {}
            c.close();
            self.cl = null;
        }
        if (self.app) |*a| {
            a.child.kill(self.io);
            self.gpa.free(a.sock);
            self.app = null;
        }
    }

    /// Send one protocol line to the app, return the parsed reply.
    fn ask(self: *Mcp, line: []const u8) !std.json.Parsed(std.json.Value) {
        const c = &(self.cl orelse return error.NoApp);
        try c.sendLine(line);
        const reply = try c.readLine(self.gpa);
        defer self.gpa.free(reply);
        return std.json.parseFromSlice(std.json.Value, self.gpa, reply, .{});
    }
};

fn mcpMain(init: std.process.Init, out: *Io.Writer) !void {
    const gpa = init.gpa;
    const io = init.io;
    var mcp: Mcp = .{ .init = init, .gpa = gpa, .io = io };
    defer mcp.stopApp();

    const in_buf = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(in_buf);
    var fr = Io.File.stdin().readerStreaming(io, in_buf);
    const r = &fr.interface;

    while (true) {
        const line = (r.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                try rpcError(out, null, -32700, "message too long");
                continue;
            },
            error.ReadFailed => return,
        }) orelse return;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        handleRpc(&mcp, out, trimmed) catch |e| {
            std.log.err("teak-drive mcp: {s}", .{@errorName(e)});
        };
        try out.flush();
    }
}

fn writeId(w: *Io.Writer, id: ?std.json.Value) !void {
    if (id) |v| try std.json.Stringify.value(v, .{}, w) else try w.writeAll("null");
}

fn rpcError(out: *Io.Writer, id: ?std.json.Value, code: i32, msg: []const u8) !void {
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(out, id);
    try out.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try jsonStr(out, msg);
    try out.writeAll("}}\n");
}

fn handleRpc(mcp: *Mcp, out: *Io.Writer, line: []const u8) !void {
    const gpa = mcp.gpa;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch
        return rpcError(out, null, -32700, "parse error");
    defer parsed.deinit();
    if (parsed.value != .object) return rpcError(out, null, -32600, "invalid request");
    const obj = parsed.value.object;
    const id: ?std.json.Value = obj.get("id");
    const method = if (obj.get("method")) |m| (if (m == .string) m.string else "") else "";
    const params: ?std.json.ObjectMap = if (obj.get("params")) |p| (if (p == .object) p.object else null) else null;

    if (id == null) return; // notifications (initialized, cancelled, ...) get no reply

    if (std.mem.eql(u8, method, "initialize")) {
        // Echo the client's protocol version when it sent one we can speak.
        var ver: []const u8 = protocol_version;
        if (params) |p| if (p.get("protocolVersion")) |v| if (v == .string) {
            ver = v.string;
        };
        try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(out, id);
        try out.writeAll(",\"result\":{\"protocolVersion\":");
        try jsonStr(out, ver);
        try out.print(",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"teak-drive\",\"version\":\"{s}\"}},", .{version});
        try out.writeAll("\"instructions\":\"Drive a teak GUI app. Start with launch_app, read the UI with snapshot or tree, act with click/type/key, verify with snapshot or screenshot.\"}}\n");
    } else if (std.mem.eql(u8, method, "ping")) {
        try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(out, id);
        try out.writeAll(",\"result\":{}}\n");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(out, id);
        try out.writeAll(",\"result\":{\"tools\":[");
        for (tools, 0..) |t, k| {
            if (k > 0) try out.writeByte(',');
            try out.writeAll("{\"name\":");
            try jsonStr(out, t.name);
            try out.writeAll(",\"description\":");
            try jsonStr(out, t.description);
            // Schemas are multi-line literals; the wire format is one line.
            try out.writeAll(",\"inputSchema\":");
            for (t.schema) |c| if (c != '\n') try out.writeByte(c);
            try out.writeByte('}');
        }
        try out.writeAll("]}}\n");
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const p = params orelse return rpcError(out, id, -32602, "missing params");
        const name = getStr(p, "name") orelse return rpcError(out, id, -32602, "missing tool name");
        const args: std.json.ObjectMap = if (p.get("arguments")) |a| (if (a == .object) a.object else .empty) else .empty;
        var res: ToolResult = .{};
        defer res.deinit(gpa);
        callTool(mcp, name, args, &res) catch |e| {
            res.is_error = true;
            res.text.clearRetainingCapacity();
            try res.text.print(gpa, "{s}", .{errorText(e)});
        };
        try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(out, id);
        try out.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
        try jsonStr(out, res.text.items);
        try out.writeByte('}');
        if (res.image_b64) |b64| {
            try out.writeAll(",{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"");
            try out.writeAll(b64);
            try out.writeAll("\"}");
        }
        try out.print("],\"isError\":{}}}}}\n", .{res.is_error});
    } else {
        try rpcError(out, id, -32601, "method not found");
    }
}

fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.NoApp => "no app launched: call launch_app first",
        error.AppDidNotStart => "the app did not open its control socket within 20s (is the binary built with the control channel? see launch_app)",
        error.ConnectionClosed => "the app closed the connection (it quit or crashed)",
        error.UnknownTool => "unknown tool",
        error.BadArguments => "bad arguments",
        error.BinaryNotFound => "binary not found; pass `binary`, or build the example with `zig build drive` in examples/<name>",
        else => @errorName(e),
    };
}

const ToolResult = struct {
    text: std.ArrayList(u8) = .empty,
    image_b64: ?[]u8 = null,
    is_error: bool = false,

    fn deinit(self: *ToolResult, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        if (self.image_b64) |b| gpa.free(b);
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn callTool(mcp: *Mcp, name: []const u8, args: std.json.ObjectMap, res: *ToolResult) !void {
    const gpa = mcp.gpa;
    if (std.mem.eql(u8, name, "launch_app")) return toolLaunch(mcp, args, res);

    // Everything else is a protocol command forwarded to the app.
    var known = false;
    for (tools) |t| if (std.mem.eql(u8, t.name, name)) {
        known = true;
    };
    if (!known) return error.UnknownTool;

    var cmd_aw: Io.Writer.Allocating = .init(gpa);
    defer cmd_aw.deinit();
    const w = &cmd_aw.writer;
    try w.writeAll("{\"cmd\":");
    try jsonStr(w, name);
    var shot_path: ?[]const u8 = null;
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |p| gpa.free(p);
    var it = args.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "include_image")) continue;
        if (std.mem.eql(u8, name, "screenshot") and std.mem.eql(u8, e.key_ptr.*, "path")) continue;
        try w.writeByte(',');
        try jsonStr(w, e.key_ptr.*);
        try w.writeByte(':');
        try std.json.Stringify.value(e.value_ptr.*, .{}, w);
    }
    if (std.mem.eql(u8, name, "screenshot")) {
        if (getStr(args, "path")) |p| {
            owned_path = try absolutePath(gpa, p);
            shot_path = owned_path;
        } else {
            mcp.shots += 1;
            owned_path = try std.fmt.allocPrint(gpa, "/tmp/teak-drive-{d}-shot-{d}.png", .{ std.os.linux.getpid(), mcp.shots });
            shot_path = owned_path;
        }
        try w.writeAll(",\"path\":");
        try jsonStr(w, shot_path.?);
    }
    try w.writeByte('}');

    var reply = try mcp.ask(cmd_aw.written());
    defer reply.deinit();
    if (!replyOk(reply.value)) {
        res.is_error = true;
        const msg = getStr(reply.value.object, "error") orelse "command failed";
        try res.text.appendSlice(gpa, msg);
        return;
    }
    const o = reply.value.object;
    if (std.mem.eql(u8, name, "snapshot")) {
        try res.text.appendSlice(gpa, getStr(o, "snapshot") orelse "");
    } else if (std.mem.eql(u8, name, "tree")) {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeTreeText(&aw.writer, reply.value);
        try res.text.appendSlice(gpa, aw.written());
    } else if (std.mem.eql(u8, name, "state")) {
        try res.text.appendSlice(gpa, getStr(o, "state") orelse "");
    } else if (std.mem.eql(u8, name, "msglog")) {
        const msgs = o.get("msgs").?.array.items;
        for (msgs) |m| try res.text.print(gpa, "{s}\n", .{m.string});
        if (msgs.len == 0) try res.text.appendSlice(gpa, "(no Msgs yet)");
    } else {
        // Acts: summarize what happened.
        try res.text.print(gpa, "ok (frame {d}, last Msg: {s})", .{ jsonInt(o.get("frame").?), getStr(o, "last_msg") orelse "" });
        if (o.get("target")) |t| {
            var tw: Io.Writer.Allocating = .init(gpa);
            defer tw.deinit();
            try std.json.Stringify.value(t, .{}, &tw.writer);
            try res.text.print(gpa, "; target {s}", .{tw.written()});
        }
    }
    if (std.mem.eql(u8, name, "screenshot")) {
        res.text.clearRetainingCapacity();
        try res.text.print(gpa, "Saved screenshot: {s}", .{shot_path.?});
        if (args.get("include_image")) |v| if (v == .bool and v.bool) {
            const bytes = try Io.Dir.cwd().readFileAlloc(mcp.io, shot_path.?, gpa, .limited(64 * 1024 * 1024));
            defer gpa.free(bytes);
            const enc = std.base64.standard.Encoder;
            const b64 = try gpa.alloc(u8, enc.calcSize(bytes.len));
            _ = enc.encode(b64, bytes);
            res.image_b64 = b64;
        };
    }
    if (std.mem.eql(u8, name, "quit")) {
        if (mcp.cl) |*c| c.close();
        mcp.cl = null;
        if (mcp.app) |*a| {
            _ = a.child.wait(mcp.io) catch {};
            gpa.free(a.sock);
            mcp.app = null;
        }
    }
}

fn findTeakRoot(mcp: *Mcp) ![]u8 {
    const gpa = mcp.gpa;
    if (mcp.init.environ_map.get("TEAK_ROOT")) |r| return gpa.dupe(u8, r);
    // zig-out/bin/teak-drive -> repo root.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(mcp.io, &buf) catch return error.BinaryNotFound;
    const exe = buf[0..n];
    const bin = std.fs.path.dirname(exe) orelse return error.BinaryNotFound;
    const out = std.fs.path.dirname(bin) orelse return error.BinaryNotFound;
    const root = std.fs.path.dirname(out) orelse return error.BinaryNotFound;
    return gpa.dupe(u8, root);
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn toolLaunch(mcp: *Mcp, args: std.json.ObjectMap, res: *ToolResult) !void {
    const gpa = mcp.gpa;
    const io = mcp.io;
    mcp.stopApp();

    const x11 = if (getStr(args, "mode")) |m| std.mem.eql(u8, m, "x11") else false;
    var bin_owned: ?[]u8 = null;
    defer if (bin_owned) |b| gpa.free(b);
    var cwd: ?[]const u8 = getStr(args, "cwd");
    var cwd_owned: ?[]u8 = null;
    defer if (cwd_owned) |c| gpa.free(c);

    var binary: []const u8 = undefined;
    if (getStr(args, "binary")) |b| {
        binary = b;
    } else if (getStr(args, "example")) |ex| {
        if (std.mem.indexOfAny(u8, ex, "/\\.") != null) return error.BadArguments;
        const root = try findTeakRoot(mcp);
        defer gpa.free(root);
        const dir = try std.fmt.allocPrint(gpa, "{s}/examples/{s}", .{ root, ex });
        defer gpa.free(dir);
        const suffix: []const u8 = if (x11) "ui" else "drive";
        bin_owned = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/{s}-{s}", .{ dir, ex, suffix });
        if (!fileExists(io, bin_owned.?)) {
            // First use: build it.
            var child = std.process.spawn(io, .{
                .argv = &.{ "zig", "build", "drive" },
                .cwd = .{ .path = dir },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .inherit,
            }) catch return error.BinaryNotFound;
            const term = child.wait(io) catch return error.BinaryNotFound;
            if (term != .exited or term.exited != 0) return error.BinaryNotFound;
            if (!fileExists(io, bin_owned.?)) return error.BinaryNotFound;
        }
        binary = bin_owned.?;
        // wgpu-native's shared library sits next to the binary.
        if (cwd == null) {
            cwd_owned = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin", .{dir});
            cwd = cwd_owned;
        }
    } else return error.BadArguments;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, binary);
    if (args.get("args")) |a| if (a == .array) for (a.array.items) |s| if (s == .string) try argv.append(gpa, s.string);

    mcp.launches += 1;
    const sock = try std.fmt.allocPrint(gpa, "/tmp/teak-drive-{d}-{d}.sock", .{ std.os.linux.getpid(), mcp.launches });
    defer gpa.free(sock);
    const display = getStr(args, "display");
    mcp.app = try spawnApp(mcp.init, argv.items, sock, cwd, display, false);
    mcp.cl = try Client.connect(sock);

    var reply = try mcp.ask("{\"cmd\":\"info\"}");
    defer reply.deinit();
    const o = reply.value.object;
    try res.text.print(gpa, "launched {s} ({s}); window {d}x{d}. Call snapshot or tree to see the UI.", .{
        std.fs.path.basename(binary),
        if (x11) "x11" else "headless",
        jsonInt(o.get("width") orelse .{ .integer = 0 }),
        jsonInt(o.get("height") orelse .{ .integer = 0 }),
    });
}

test "buildCommand maps CLI words to protocol objects" {
    const gpa = std.testing.allocator;
    {
        const s = (try buildCommand(gpa, "click", &.{ "--role", "button", "Add", "item" })).?;
        defer gpa.free(s);
        try std.testing.expectEqualStrings("{\"cmd\":\"click\",\"role\":\"button\",\"label\":\"Add item\"}", s);
    }
    {
        const s = (try buildCommand(gpa, "wait", &.{ "--text", "done", "--timeout", "30" })).?;
        defer gpa.free(s);
        try std.testing.expectEqualStrings("{\"cmd\":\"wait\",\"until_text\":\"done\",\"timeout_frames\":30}", s);
    }
    {
        const s = (try buildCommand(gpa, "type", &.{ "hi", "\"there\"" })).?;
        defer gpa.free(s);
        try std.testing.expectEqualStrings("{\"cmd\":\"type\",\"text\":\"hi \\\"there\\\"\"}", s);
    }
    try std.testing.expect((try buildCommand(gpa, "bogus", &.{})) == null);
    try std.testing.expect((try buildCommand(gpa, "key", &.{})) == null);
}
