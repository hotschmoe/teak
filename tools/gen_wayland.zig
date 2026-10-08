//! Generator for `src/platform/wayland/protocols.zig`.
//!
//! Not part of the normal build (the output is committed). Re-run by hand
//! when adding a protocol:
//!
//!   zig run tools/gen_wayland.zig -- src/platform/wayland/protocols.zig \
//!       /usr/share/wayland/wayland.xml \
//!       /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml ...
//!
//! For each `<interface>` it emits the `wl_interface` table libwayland-client
//! needs to marshal (requests) and dispatch (events), an opaque proxy type,
//! one Zig function per request, an `extern struct` listener per interface
//! with events (every field defaults to a no-op, so a Host only fills in the
//! events it cares about), and enum constants. libwayland-client itself is
//! dlopened (`client.zig`); no wayland-scanner or dev package is involved.

const std = @import("std");

const Arg = struct {
    name: []const u8,
    kind: []const u8,
    iface: ?[]const u8 = null,
    nullable: bool = false,
};

const Msg = struct {
    name: []const u8,
    since: u32 = 1,
    destructor: bool = false,
    args: std.ArrayList(Arg) = .empty,
};

const Entry = struct { name: []const u8, value: []const u8 };
const Enum = struct { name: []const u8, entries: std.ArrayList(Entry) = .empty };

const Iface = struct {
    name: []const u8,
    version: u32,
    requests: std.ArrayList(Msg) = .empty,
    events: std.ArrayList(Msg) = .empty,
    enums: std.ArrayList(Enum) = .empty,
};

fn attr(tag: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, key)) |p| {
        i = p + key.len;
        if (p == 0 or !std.ascii.isWhitespace(tag[p - 1])) continue;
        if (!std.mem.startsWith(u8, tag[i..], "=\"")) continue;
        const start = i + 2;
        const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
        return tag[start..end];
    }
    return null;
}

fn parse(gpa: std.mem.Allocator, xml: []const u8, out: *std.ArrayList(Iface)) !void {
    var i: usize = 0;
    var cur_iface: ?*Iface = null;
    var cur_msg: ?*Msg = null;
    var cur_enum: ?*Enum = null;
    var in_event = false;
    while (std.mem.indexOfScalarPos(u8, xml, i, '<')) |lt| {
        if (std.mem.startsWith(u8, xml[lt..], "<!--")) {
            i = (std.mem.indexOfPos(u8, xml, lt, "-->") orelse xml.len) + 3;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, xml, lt, '>') orelse break;
        const tag = xml[lt + 1 .. gt];
        i = gt + 1;
        if (tag.len == 0 or tag[0] == '?' or tag[0] == '!') continue;
        if (tag[0] == '/') {
            const nm = tag[1..];
            if (std.mem.eql(u8, nm, "interface")) cur_iface = null;
            if (std.mem.eql(u8, nm, "request") or std.mem.eql(u8, nm, "event")) cur_msg = null;
            if (std.mem.eql(u8, nm, "enum")) cur_enum = null;
            continue;
        }
        const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n/") orelse tag.len;
        const el = tag[0..name_end];
        if (std.mem.eql(u8, el, "interface")) {
            try out.append(gpa, .{ .name = attr(tag, "name").?, .version = try std.fmt.parseInt(u32, attr(tag, "version").?, 10) });
            cur_iface = &out.items[out.items.len - 1];
        } else if (std.mem.eql(u8, el, "request") or std.mem.eql(u8, el, "event")) {
            const ifc = cur_iface.?;
            in_event = std.mem.eql(u8, el, "event");
            const list = if (in_event) &ifc.events else &ifc.requests;
            try list.append(gpa, .{
                .name = attr(tag, "name").?,
                .since = if (attr(tag, "since")) |s| try std.fmt.parseInt(u32, s, 10) else 1,
                .destructor = if (attr(tag, "type")) |t| std.mem.eql(u8, t, "destructor") else false,
            });
            cur_msg = &list.items[list.items.len - 1];
            if (std.mem.endsWith(u8, tag, "/")) cur_msg = null;
        } else if (std.mem.eql(u8, el, "arg")) {
            if (cur_msg) |m| try m.args.append(gpa, .{
                .name = attr(tag, "name").?,
                .kind = attr(tag, "type").?,
                .iface = attr(tag, "interface"),
                .nullable = if (attr(tag, "allow-null")) |v| std.mem.eql(u8, v, "true") else false,
            });
        } else if (std.mem.eql(u8, el, "enum")) {
            const ifc = cur_iface.?;
            try ifc.enums.append(gpa, .{ .name = attr(tag, "name").? });
            cur_enum = &ifc.enums.items[ifc.enums.items.len - 1];
        } else if (std.mem.eql(u8, el, "entry")) {
            if (cur_enum) |e| try e.entries.append(gpa, .{ .name = attr(tag, "name").?, .value = attr(tag, "value").? });
        }
    }
}

const keywords = [_][]const u8{ "type", "error", "test", "align", "export", "async", "defer", "var", "const", "fn", "pub", "if", "else", "for", "while", "switch", "return", "try", "catch", "usingnamespace", "opaque", "union", "enum", "struct", "break", "continue", "unreachable", "undefined", "null", "true", "false", "and", "or", "inline", "comptime", "extern", "packed", "volatile", "anytype", "resume", "suspend", "nosuspend", "orelse", "noalias", "threadlocal", "linksection", "callconv", "allowzero", "anyframe", "addrspace", "errdefer", "noinline" };

fn ident(w: *std.Io.Writer, name: []const u8) !void {
    var quote = name.len > 0 and std.ascii.isDigit(name[0]);
    for (keywords) |k| if (std.mem.eql(u8, k, name)) {
        quote = true;
    };
    if (quote) try w.print("@\"{s}\"", .{name}) else try w.writeAll(name);
}

fn zigType(w: *std.Io.Writer, a: Arg, comptime listener: bool) !void {
    _ = listener;
    if (std.mem.eql(u8, a.kind, "int") or std.mem.eql(u8, a.kind, "fixed") or std.mem.eql(u8, a.kind, "fd")) {
        try w.writeAll("i32");
    } else if (std.mem.eql(u8, a.kind, "uint")) {
        try w.writeAll("u32");
    } else if (std.mem.eql(u8, a.kind, "string")) {
        try w.writeAll(if (a.nullable) "?[*:0]const u8" else "[*:0]const u8");
    } else if (std.mem.eql(u8, a.kind, "array")) {
        try w.writeAll("*client.Array");
    } else if (std.mem.eql(u8, a.kind, "object") or std.mem.eql(u8, a.kind, "new_id")) {
        if (a.nullable) try w.writeAll("?");
        if (a.iface) |n| {
            try w.print("*{s}", .{n});
        } else try w.writeAll("*anyopaque");
    } else return error.UnknownArgType;
}

fn sigChar(a: Arg) u8 {
    const k = a.kind;
    if (std.mem.eql(u8, k, "int")) return 'i';
    if (std.mem.eql(u8, k, "uint")) return 'u';
    if (std.mem.eql(u8, k, "fixed")) return 'f';
    if (std.mem.eql(u8, k, "string")) return 's';
    if (std.mem.eql(u8, k, "object")) return 'o';
    if (std.mem.eql(u8, k, "new_id")) return 'n';
    if (std.mem.eql(u8, k, "array")) return 'a';
    return 'h';
}

/// libwayland signature: since-version digits, then one char per arg ('?'
/// before nullable ones). A new_id without an interface (registry.bind)
/// expands to "sun" on the wire.
fn writeSig(w: *std.Io.Writer, m: Msg) !void {
    if (m.since > 1) try w.print("{d}", .{m.since});
    for (m.args.items) |a| {
        if (std.mem.eql(u8, a.kind, "new_id") and a.iface == null) {
            try w.writeAll("sun");
            continue;
        }
        if (a.nullable) try w.writeAll("?");
        try w.writeByte(sigChar(a));
    }
}

fn writeTypes(w: *std.Io.Writer, ifc: Iface, m: Msg, dir: []const u8) !void {
    try w.print("const {s}_{s}_{s}_types = [_]?*const client.Interface{{", .{ ifc.name, dir, m.name });
    for (m.args.items) |a| {
        if (std.mem.eql(u8, a.kind, "new_id") and a.iface == null) {
            try w.writeAll("null, null, null, ");
        } else if ((std.mem.eql(u8, a.kind, "object") or std.mem.eql(u8, a.kind, "new_id")) and a.iface != null) {
            try w.print("&{s}_interface, ", .{a.iface.?});
        } else try w.writeAll("null, ");
    }
    try w.writeAll("};\n");
}

fn emit(w: *std.Io.Writer, ifaces: []const Iface) !void {
    try w.writeAll(
        \\//! GENERATED by tools/gen_wayland.zig from the Wayland protocol XML — do
        \\//! not edit. See that file for how to regenerate.
        \\
        \\const client = @import("client.zig");
        \\
        \\fn noop() callconv(.c) void {}
        \\
        \\
    );
    for (ifaces) |ifc| try w.print("pub const {s} = opaque {{}};\n", .{ifc.name});
    try w.writeAll("\n");

    for (ifaces) |ifc| {
        for (ifc.requests.items) |m| try writeTypes(w, ifc, m, "request");
        for (ifc.events.items) |m| try writeTypes(w, ifc, m, "event");
        for ([_]struct { []const u8, []const Msg }{ .{ "request", ifc.requests.items }, .{ "event", ifc.events.items } }) |set| {
            if (set.@"1".len == 0) continue;
            try w.print("const {s}_{s}s = [_]client.Message{{\n", .{ ifc.name, set.@"0" });
            for (set.@"1") |m| {
                try w.print("    .{{ .name = \"{s}\", .signature = \"", .{m.name});
                try writeSig(w, m);
                try w.print("\", .types = &{s}_{s}_{s}_types }},\n", .{ ifc.name, set.@"0", m.name });
            }
            try w.writeAll("};\n");
        }
        try w.print("pub const {s}_interface: client.Interface = .{{\n    .name = \"{s}\",\n    .version = {d},\n", .{ ifc.name, ifc.name, ifc.version });
        try w.print("    .method_count = {d},\n    .methods = {s},\n", .{ ifc.requests.items.len, if (ifc.requests.items.len > 0) try std.fmt.allocPrint(std.heap.page_allocator, "&{s}_requests", .{ifc.name}) else "null" });
        try w.print("    .event_count = {d},\n    .events = {s},\n}};\n\n", .{ ifc.events.items.len, if (ifc.events.items.len > 0) try std.fmt.allocPrint(std.heap.page_allocator, "&{s}_events", .{ifc.name}) else "null" });

        for (ifc.enums.items) |e| {
            try w.print("pub const {s}__{s} = struct {{\n", .{ ifc.name, e.name });
            for (e.entries.items) |en| {
                try w.writeAll("    pub const ");
                try ident(w, en.name);
                try w.print(": u32 = {s};\n", .{en.value});
            }
            try w.writeAll("};\n");
        }

        // Requests.
        for (ifc.requests.items, 0..) |m, opcode| {
            var ret: ?Arg = null;
            var generic_new = false;
            for (m.args.items) |a| if (std.mem.eql(u8, a.kind, "new_id")) {
                ret = a;
                generic_new = a.iface == null;
            };
            try w.print("pub fn {s}_{s}(self: *{s}", .{ ifc.name, m.name, ifc.name });
            for (m.args.items) |a| {
                if (std.mem.eql(u8, a.kind, "new_id")) {
                    if (generic_new) try w.writeAll(", iface: *const client.Interface, version: u32");
                    continue;
                }
                try w.writeAll(", ");
                try ident(w, a.name);
                try w.writeAll(": ");
                try zigType(w, a, false);
            }
            try w.writeAll(") ");
            if (ret) |r| {
                if (generic_new) try w.writeAll("*anyopaque") else try w.print("*{s}", .{r.iface.?});
            } else try w.writeAll("void");
            try w.writeAll(" {\n");
            try w.print("    var args = [_]client.Argument{{", .{});
            for (m.args.items) |a| {
                if (std.mem.eql(u8, a.kind, "new_id")) {
                    if (generic_new) try w.writeAll(" .{ .s = iface.name }, .{ .u = version }, .{ .n = 0 },") else try w.writeAll(" .{ .n = 0 },");
                } else if (std.mem.eql(u8, a.kind, "int")) {
                    try w.writeAll(" .{ .i = ");
                    try ident(w, a.name);
                    try w.writeAll(" },");
                } else if (std.mem.eql(u8, a.kind, "uint")) {
                    try w.writeAll(" .{ .u = ");
                    try ident(w, a.name);
                    try w.writeAll(" },");
                } else if (std.mem.eql(u8, a.kind, "fixed")) {
                    try w.writeAll(" .{ .f = ");
                    try ident(w, a.name);
                    try w.writeAll(" },");
                } else if (std.mem.eql(u8, a.kind, "string")) {
                    try w.writeAll(" .{ .s = ");
                    try ident(w, a.name);
                    try w.writeAll(" },");
                } else if (std.mem.eql(u8, a.kind, "array")) {
                    try w.writeAll(" .{ .a = ");
                    try ident(w, a.name);
                    try w.writeAll(" },");
                } else if (std.mem.eql(u8, a.kind, "fd")) {
                    try w.writeAll(" .{ .h = ");
                    try ident(w, a.name);
                    try w.writeAll(" },");
                } else {
                    try w.writeAll(" .{ .o = @ptrCast(");
                    try ident(w, a.name);
                    try w.writeAll(") },");
                }
            }
            try w.writeAll(" };\n");
            const iface_expr: []const u8 = if (ret) |r| (if (generic_new) "iface" else try std.fmt.allocPrint(std.heap.page_allocator, "&{s}_interface", .{r.iface.?})) else "null";
            const ver_expr: []const u8 = if (generic_new) "version" else "0";
            try w.print("    const r = client.marshal(@ptrCast(self), {d}, {s}, {s}, {d}, &args);\n", .{ opcode, iface_expr, ver_expr, @as(u32, if (m.destructor) 1 else 0) });
            if (ret != null) {
                if (generic_new) try w.writeAll("    return r.?;\n") else try w.print("    return @ptrCast(r.?);\n", .{});
            } else try w.writeAll("    _ = r;\n");
            try w.writeAll("}\n\n");
        }

        // Listener.
        if (ifc.events.items.len > 0) {
            try w.print("pub const {s}_listener = extern struct {{\n", .{ifc.name});
            for (ifc.events.items) |m| {
                try w.writeAll("    ");
                try ident(w, m.name);
                try w.print(": *const fn (?*anyopaque, *{s}", .{ifc.name});
                for (m.args.items) |a| {
                    try w.writeAll(", ");
                    try zigType(w, a, true);
                }
                try w.writeAll(") callconv(.c) void = @ptrCast(&noop),\n");
            }
            try w.writeAll("};\n");
            try w.print("pub fn {s}_add_listener(self: *{s}, l: *const {s}_listener, data: ?*anyopaque) void {{\n    _ = client.api.proxy_add_listener(@ptrCast(self), @ptrCast(l), data);\n}}\n\n", .{ ifc.name, ifc.name, ifc.name });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) {
        std.debug.print("usage: gen_wayland <out.zig> <protocol.xml>...\n", .{});
        std.process.exit(2);
    }
    var ifaces: std.ArrayList(Iface) = .empty;
    for (args[2..]) |path| {
        const xml = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .unlimited);
        try parse(gpa, xml, &ifaces);
    }
    var buf: std.Io.Writer.Allocating = .init(gpa);
    try emit(&buf.writer, ifaces.items);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = buf.written() });
    std.debug.print("wrote {s}: {d} interfaces\n", .{ args[1], ifaces.items.len });
}
