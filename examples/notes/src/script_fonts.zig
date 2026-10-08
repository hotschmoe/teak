//! Optional complex-script faces for the "Show scripts" line, loaded at run time
//! from the directory in `$NOTES_SCRIPT_FONTS` (nothing is shipped: Noto Naskh
//! Arabic / Sans Hebrew / Sans Devanagari are SIL OFL downloads). Without the
//! variable the app runs unchanged. Registered in the serif family, one weight
//! per script, matching `app.scriptsLine`.

const std = @import("std");
const teak = @import("teak");

pub const Face = struct { family: teak.FontFamily, weight: teak.FontWeight, bytes: []u8 };

const wanted = [_]struct { file: []const u8, family: teak.FontFamily, weight: teak.FontWeight }{
    .{ .file = "NotoNaskhArabic-Regular.ttf", .family = .serif, .weight = .regular },
    .{ .file = "NotoSansHebrew-Regular.ttf", .family = .serif, .weight = .bold },
    .{ .file = "NotoSansDevanagari-Regular.ttf", .family = .serif, .weight = .medium },
};

/// Faces found in `$NOTES_SCRIPT_FONTS` (empty when unset or missing). Free with `free`.
pub fn load(gpa: std.mem.Allocator, io: std.Io) []Face {
    const dir_z = std.c.getenv("NOTES_SCRIPT_FONTS") orelse return &.{};
    const dir = std.mem.span(dir_z);
    var list: std.ArrayList(Face) = .empty;
    for (wanted) |w| {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, w.file }) catch continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20)) catch continue;
        list.append(gpa, .{ .family = w.family, .weight = w.weight, .bytes = bytes }) catch {
            gpa.free(bytes);
            continue;
        };
    }
    return list.toOwnedSlice(gpa) catch &.{};
}

pub fn free(gpa: std.mem.Allocator, faces: []Face) void {
    for (faces) |f| gpa.free(f.bytes);
    gpa.free(faces);
}
