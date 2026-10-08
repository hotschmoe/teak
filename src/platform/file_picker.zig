//! Native file dialogs for Linux hosts (X11 today, Wayland through the same
//! `native_effects.Service`): the `open_file` effect and `download` with
//! `pick = true` (a save dialog). See docs/features/effects.md.
//!
//! A dialog is run by an external picker program that speaks the `zenity` /
//! `kdialog` command line, blocking on a worker thread (never the frame
//! loop): `$TEAK_PICKER` (any program with zenity's CLI, which is also how
//! tests and agents script a pick), else `zenity`, else `kdialog`. Both are
//! GTK / Qt front-ends that talk to the desktop themselves, so the dialog is
//! the native one on GNOME, KDE and (via the portal-aware toolkits) Flatpak.
//! No D-Bus client is linked: speaking `org.freedesktop.portal.FileChooser`
//! directly needs a session-bus socket, SASL and the Request/Response signal
//! dance, which is not verifiable without a live portal; the subprocess keeps
//! the same user-visible result with a few dozen lines and no new protocol
//! code to get wrong. A host without either program answers `file_cancelled`.
//!
//! Pure helpers (`acceptToGlobs`, `buildArgv`) are unit-tested; `pick` is the
//! only part that spawns.

const std = @import("std");
const Io = std.Io;

pub const Kind = enum { open, save };

pub const Tool = enum {
    zenity,
    kdialog,
};

pub const PickError = error{ NoPicker, PickerFailed, OutOfMemory };

/// `".json,.kerf.json"` -> `"*.json *.kerf.json"`; `"image/*"` -> common
/// image globs; `"application/json"` -> `"*.json"`; empty -> empty (all files).
/// Caller frees.
pub fn acceptToGlobs(a: std.mem.Allocator, accept: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.tokenizeAny(u8, accept, ", ");
    while (it.next()) |tok| {
        const globs: []const u8 = if (std.mem.eql(u8, tok, "image/*"))
            "*.png *.jpg *.jpeg *.gif *.webp *.bmp"
        else if (std.mem.eql(u8, tok, "text/*"))
            "*.txt *.md *.csv"
        else if (std.mem.eql(u8, tok, "application/json"))
            "*.json"
        else if (std.mem.eql(u8, tok, "image/png"))
            "*.png"
        else if (std.mem.eql(u8, tok, "image/jpeg"))
            "*.jpg *.jpeg"
        else if (std.mem.eql(u8, tok, "application/pdf"))
            "*.pdf"
        else if (tok[0] == '.')
            "" // handled below: ".ext" -> "*.ext"
        else
            continue; // an unknown MIME type: no filter for it
        if (out.items.len > 0) try out.append(a, ' ');
        if (globs.len == 0) {
            try out.appendSlice(a, "*");
            try out.appendSlice(a, tok);
        } else try out.appendSlice(a, globs);
    }
    return out.toOwnedSlice(a);
}

/// The command line for a dialog. `program` is the executable to run (the
/// resolved tool, or `$TEAK_PICKER` with zenity's syntax). All slices live in `a`.
pub fn buildArgv(
    a: std.mem.Allocator,
    tool: Tool,
    program: []const u8,
    kind: Kind,
    accept: []const u8,
    title: []const u8,
    name: []const u8,
) PickError![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(a);
    const globs = try acceptToGlobs(a, accept);
    try argv.append(a, program);
    switch (tool) {
        .zenity => {
            try argv.append(a, "--file-selection");
            if (kind == .save) {
                try argv.append(a, "--save");
                try argv.append(a, "--confirm-overwrite");
                if (name.len > 0) try argv.append(a, try std.fmt.allocPrint(a, "--filename={s}", .{name}));
            }
            if (title.len > 0) try argv.append(a, try std.fmt.allocPrint(a, "--title={s}", .{title}));
            if (globs.len > 0) try argv.append(a, try std.fmt.allocPrint(a, "--file-filter=Files | {s}", .{globs}));
        },
        .kdialog => {
            if (kind == .open) {
                try argv.append(a, "--getopenfilename");
                try argv.append(a, ".");
            } else {
                try argv.append(a, "--getsavefilename");
                try argv.append(a, if (name.len > 0) try std.fmt.allocPrint(a, "./{s}", .{name}) else ".");
            }
            if (globs.len > 0) try argv.append(a, try std.fmt.allocPrint(a, "{s}|Files", .{globs}));
            if (title.len > 0) {
                try argv.append(a, "--title");
                try argv.append(a, title);
            }
        },
    }
    return argv.toOwnedSlice(a);
}

/// First line of the picker's stdout, trimmed; null when empty (cancelled).
pub fn parseChoice(stdout: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, std.mem.sliceTo(stdout, '\n'), " \t\r");
    return if (line.len == 0) null else line;
}

/// Show the dialog and block until it closes. Returns the chosen path
/// (allocated in `a`), or null when the user cancelled. `error.NoPicker`:
/// no picker program is installed.
pub fn pick(
    a: std.mem.Allocator,
    env_picker: ?[]const u8,
    kind: Kind,
    accept: []const u8,
    title: []const u8,
    name: []const u8,
) PickError!?[]u8 {
    const candidates = [_]struct { tool: Tool, program: []const u8 }{
        .{ .tool = .zenity, .program = env_picker orelse "zenity" },
        .{ .tool = .kdialog, .program = "kdialog" },
    };
    const n: usize = if (env_picker != null) 1 else candidates.len;
    // Spawning needs an `Io` that can allocate (the process-wide debug `Io`
    // cannot), and the child must inherit our environment (DISPLAY,
    // WAYLAND_DISPLAY, DBUS_*, XDG_*: how the toolkit finds the desktop).
    var threaded: Io.Threaded = .init(a, .{
        .environ = if (std.Options.debug_threaded_io) |t| t.environ.process_environ else .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    for (candidates[0..n]) |c| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const argv = try buildArgv(arena.allocator(), c.tool, c.program, kind, accept, title, name);
        const res = std.process.run(a, io, .{
            .argv = argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch |e| switch (e) {
            error.FileNotFound, error.AccessDenied => continue, // not installed: try the next tool
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.PickerFailed,
        };
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        // zenity / kdialog exit 1 on cancel, 0 with the path on stdout.
        const ok = switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) return null;
        const choice = parseChoice(res.stdout) orelse return null;
        return try a.dupe(u8, choice);
    }
    return error.NoPicker;
}

// ── Tests ──────────────────────────────────────────────────────────

test "acceptToGlobs: extensions, MIME wildcards, unknown types" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = ".json,.kerf.json", .out = "*.json *.kerf.json" },
        .{ .in = "image/*", .out = "*.png *.jpg *.jpeg *.gif *.webp *.bmp" },
        .{ .in = ".dxf, image/png", .out = "*.dxf *.png" },
        .{ .in = "application/x-unknown", .out = "" },
        .{ .in = "", .out = "" },
    };
    for (cases) |c| {
        const got = try acceptToGlobs(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "buildArgv: zenity and kdialog open / save command lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zo = try buildArgv(a, .zenity, "zenity", .open, ".json", "Open mesh", "");
    try std.testing.expectEqual(@as(usize, 4), zo.len);
    try std.testing.expectEqualStrings("--file-selection", zo[1]);
    try std.testing.expectEqualStrings("--title=Open mesh", zo[2]);
    try std.testing.expectEqualStrings("--file-filter=Files | *.json", zo[3]);

    const zs = try buildArgv(a, .zenity, "zenity", .save, "", "", "out.dxf");
    try std.testing.expectEqualStrings("--save", zs[2]);
    try std.testing.expectEqualStrings("--confirm-overwrite", zs[3]);
    try std.testing.expectEqualStrings("--filename=out.dxf", zs[4]);

    const ko = try buildArgv(a, .kdialog, "kdialog", .open, "image/png", "Pick", "");
    try std.testing.expectEqualStrings("--getopenfilename", ko[1]);
    try std.testing.expectEqualStrings("*.png|Files", ko[3]);
    const ks = try buildArgv(a, .kdialog, "kdialog", .save, "", "", "a.txt");
    try std.testing.expectEqualStrings("--getsavefilename", ks[1]);
    try std.testing.expectEqualStrings("./a.txt", ks[2]);
}

test "parseChoice takes the first line, trimmed; empty means cancelled" {
    try std.testing.expectEqualStrings("/tmp/a b.json", parseChoice("/tmp/a b.json\n").?);
    try std.testing.expectEqualStrings("/x", parseChoice("  /x  \r\nsecond\n").?);
    try std.testing.expect(parseChoice("") == null);
    try std.testing.expect(parseChoice("\n") == null);
}
