//! See SRC.md, src/platform/native_fonts.zig.
const std = @import("std");
const builtin = @import("builtin");
const teak = @import("teak");
const assert = teak.assert;

const font_bytes_max: u32 = 32 * 1024 * 1024;
const explicit_count: u16 = 4;
const primary_candidates = [_][]const u8{
    "C:\\Windows\\Fonts\\consola.ttf",
    "C:\\Windows\\Fonts\\cour.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Monaco.ttf",
    "/System/Library/Fonts/Courier.ttc",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/Library/Fonts/Courier New.ttf",
};
const windows_candidates = [_][]const u8{
    "consola.ttf", "cour.ttf", "lucon.ttf", "segoeui.ttf", "arial.ttf",
};
const extra_candidates = [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/wenquanyi/wqy-zenhei/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/noto/NotoEmoji-Regular.ttf",
    "/usr/share/fonts/noto/NotoEmoji-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
    "/usr/share/fonts/gnu-free/FreeSans.ttf",
    "/usr/share/fonts/truetype/unifont/unifont.ttf",
    "/usr/share/fonts/opentype/unifont/unifont.otf",
};

pub fn open(
    comptime Text: type,
    allocator: std.mem.Allocator,
    options: teak.Options,
) !*Text.TextState {
    assert(Text.fallback.system_count == extra_candidates.len);
    assert(Text.fallback.first_id == Text.face.fallback_face_id + 1);
    const state = try Text.TextState.open(allocator, .{});
    const source: Text.face.Source = .{
        .options = options,
        .primary = read_primary,
        .extra = read_extra,
    };
    Text.face.configure(state, source);
    assert(state.faces.source != null);
    return state;
}

fn read_primary(allocator: std.mem.Allocator, options: teak.Options) ![]u8 {
    if (options.font_path) |path| {
        if (path.len > 0) {
            if (read_font(allocator, path)) |bytes| return bytes else |err| {
                if (err == error.OutOfMemory) return err;
            }
        }
    }
    if (builtin.os.tag == .windows) {
        const directory = options.windows_directory orelse "C:\\Windows";
        var buffer: [1024]u8 = undefined;
        for (windows_candidates) |name| {
            assert(name.len > 0);
            const path = std.fmt.bufPrint(&buffer, "{s}\\Fonts\\{s}", .{
                std.mem.trimEnd(u8, directory, "\\/"), name,
            }) catch return error.PathTooLong;
            assert(path.len <= buffer.len);
            if (read_font(allocator, path)) |bytes| return bytes else |err| {
                if (err == error.OutOfMemory) return err;
            }
        }
    } else {
        for (primary_candidates) |path| {
            assert(path.len > 0);
            if (read_font(allocator, path)) |bytes| return bytes else |err| {
                if (err == error.OutOfMemory) return err;
            }
        }
    }
    return error.FontNotFound;
}

fn read_extra(allocator: std.mem.Allocator, options: teak.Options, index: u16) !?[]u8 {
    assert(index < explicit_count + extra_candidates.len);
    if (index >= explicit_count) {
        return try read_font(allocator, extra_candidates[index - explicit_count]);
    }
    assert(index < explicit_count);
    const paths = options.fallback_fonts orelse return null;
    var iterator = std.mem.splitScalar(u8, paths, ':');
    var count: u16 = 0;
    for (0..paths.len + 1) |_| {
        const path = iterator.next() orelse return null;
        if (path.len == 0) continue;
        assert(count <= index);
        if (count == index) return try read_font(allocator, path);
        count += 1;
    }
    return null;
}

fn read_font(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try @import("native_io.zig").read_file(null, allocator, path, font_bytes_max);
    errdefer allocator.free(data);
    assert(data.len <= font_bytes_max);
    if (data.len == 0) return error.EmptyFont;
    assert(data.len > 0);
    return data;
}
