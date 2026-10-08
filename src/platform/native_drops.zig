//! Turning pasted / dropped bytes into the `EffectResult`s the web host
//! produces, for native hosts that receive them from the OS (Wayland data
//! offers today; the X11 host has its own copy of these four routines).
//! Every function queues onto a `native_effects.Service`.

const std = @import("std");
const native_effects = @import("native_effects.zig");
const x11_data = @import("x11_data.zig");
const teak = @import("teak");

const Service = native_effects.Service;

pub const MAX_DROP_FILE_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_DROP_FILES = 64;

/// Queue `.pasted_text`.
pub fn pastedText(svc: *Service, txt: []const u8) void {
    if (txt.len == 0) return;
    const arena = Service.newArena() orelse return;
    const copy = arena.allocator().dupe(u8, txt) catch return Service.freeArena(arena);
    svc.push(arena, .{ .pasted_text = .{ .text = copy } });
}

/// Queue a dropped text selection.
pub fn droppedText(svc: *Service, txt: []const u8) void {
    if (txt.len == 0) return;
    const arena = Service.newArena() orelse return;
    const copy = arena.allocator().dupe(u8, txt) catch return Service.freeArena(arena);
    svc.push(arena, .{ .dropped = .{ .kind = .text, .mime = "text/plain", .bytes = copy } });
}

/// A pasted PNG as `Drop{kind = .image}`: the owner's bytes verbatim, size
/// from the header, no thumbnail (native has no image decoder).
pub fn pastedImage(svc: *Service, png: []const u8) void {
    const size = x11_data.pngSize(png) orelse return;
    const arena = Service.newArena() orelse return;
    const copy = arena.allocator().dupe(u8, png) catch return Service.freeArena(arena);
    svc.push(arena, .{ .dropped = .{
        .kind = .image,
        .mime = "image/png",
        .bytes = copy,
        .width = size.w,
        .height = size.h,
    } });
}

/// One `Drop` per readable regular file in a `text/uri-list` (read here, up
/// to 32 MiB each; unreadable files, directories and remote URIs skipped).
pub fn droppedFiles(svc: *Service, uri_list: []const u8) void {
    var it = x11_data.UriIter{ .rest = uri_list };
    var count: usize = 0;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |uri| {
        if (count >= MAX_DROP_FILES) break;
        const path = x11_data.uriToPath(uri, &path_buf) orelse continue;
        const arena = Service.newArena() orelse return;
        const a = arena.allocator();
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, a, .limited(MAX_DROP_FILE_BYTES)) catch {
            Service.freeArena(arena);
            continue;
        };
        const name = a.dupe(u8, std.fs.path.basename(path)) catch {
            Service.freeArena(arena);
            continue;
        };
        const mime = native_effects.mimeFromName(name);
        const is_image = std.mem.eql(u8, mime, "image/png") or std.mem.eql(u8, mime, "image/jpeg");
        const size = if (is_image) x11_data.pngSize(bytes) else null;
        svc.push(arena, .{ .dropped = .{
            .kind = if (is_image) .image else .file,
            .name = name,
            .mime = mime,
            .bytes = bytes,
            .width = if (size) |s| s.w else 0,
            .height = if (size) |s| s.h else 0,
        } });
        count += 1;
    }
}

test "droppedFiles reads a file:// URI into a Drop; remote and missing URIs are skipped" {
    const svc = try Service.create("drops-test");
    defer svc.destroy();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_n = try std.process.currentPath(std.Options.debug_io, &cwd_buf);
    var list_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    const list = try std.fmt.bufPrint(&list_buf, "# c\r\nfile://remote/etc/passwd\r\nfile://{s}/no-such-file\r\nfile://{s}/build.zig.zon\r\n", .{ cwd_buf[0..cwd_n], cwd_buf[0..cwd_n] });
    droppedFiles(svc, list);
    var out: [4]teak.EffectResult = undefined;
    const n = svc.poll(&out, 0);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(teak.DropKind.file, out[0].dropped.kind);
    try std.testing.expectEqualStrings("build.zig.zon", out[0].dropped.name);
    try std.testing.expect(out[0].dropped.bytes.len > 0);
}
