const std = @import("std");
const FileIo = @import("teak").FileIo;
const assert = @import("teak").assert;

pub fn files(self: anytype) FileIo {
    assert(@typeInfo(@TypeOf(self)) == .pointer);
    assert(@typeInfo(@TypeOf(self.*)) == .@"struct");
    return .{ .ctx = self, .read = read_file, .write = write_file };
}

pub fn now_ns(_: anytype) u64 {
    const now = std.Io.Clock.awake.now(std.Options.debug_io);
    return @intCast(@max(now.nanoseconds, 0));
}

pub fn read_file(_: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, limit: u32) ![]u8 {
    assert(limit > 0);
    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        gpa,
        .limited(limit),
    );
    assert(data.len <= limit);
    return data;
}

fn write_file(_: ?*anyopaque, path: []const u8, bytes: []const u8, mode: FileIo.WriteMode) !void {
    const io = std.Options.debug_io;
    const dir = std.Io.Dir.cwd();
    switch (mode) {
        .replace => try dir.writeFile(io, .{ .sub_path = path, .data = bytes }),
        .atomic => {
            var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const temporary = try std.fmt.bufPrint(&buffer, "{s}.tmp", .{path});
            assert(temporary.len == path.len + 4);
            assert(std.mem.endsWith(u8, temporary, ".tmp"));
            try dir.writeFile(io, .{ .sub_path = temporary, .data = bytes });
            try dir.rename(temporary, dir, path, io);
        },
        .append => {
            const file = try dir.openFile(io, path, .{ .mode = .write_only });
            defer file.close(io);
            const end = try file.length(io);
            try file.writePositionalAll(io, bytes, end);
        },
    }
}
