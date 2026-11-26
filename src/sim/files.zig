//! See SRC.md, src/sim/files.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const FileIo = @import("../platform/host.zig").FileIo;

pub const files_max = 4;
pub const name_bytes_max = 128;
pub const file_bytes_max = 256 * 1024;
const Entry = struct {
    name: [name_bytes_max]u8 = undefined,
    name_len: u16 = 0,
    bytes: [file_bytes_max]u8 = undefined,
    len: u32 = 0,
};

pub const Table = struct {
    entries: [files_max]Entry = @splat(.{}),
    count: u8 = 0,
    limits: u64 = 0,
    reads: u64 = 0,
    writes: [3]u64 = @splat(0),

    pub fn capability(self: *Table) FileIo {
        return .{ .ctx = self, .read = read, .write = write };
    }

    pub fn get(self: *const Table, name: []const u8) ?[]const u8 {
        assert(self.count <= files_max);
        if (name.len == 0) return null;
        for (self.entries[0..self.count]) |*entry| {
            assert(entry.name_len <= name_bytes_max);
            assert(entry.len <= file_bytes_max);
            if (std.mem.eql(u8, name, entry.name[0..entry.name_len]))
                return entry.bytes[0..entry.len];
        }
        return null;
    }

    fn read(context: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, max: u32) ![]u8 {
        const self: *Table = @ptrCast(@alignCast(context.?));
        assert(self.count <= files_max);
        self.reads += 1;
        const bytes = self.get(name) orelse return error.FileNotFound;
        assert(bytes.len <= file_bytes_max);
        if (bytes.len > max) {
            self.limits += 1;
            return error.FileLimit;
        }
        return allocator.dupe(u8, bytes);
    }

    fn write(
        context: ?*anyopaque,
        name: []const u8,
        bytes: []const u8,
        mode: FileIo.WriteMode,
    ) !void {
        const self: *Table = @ptrCast(@alignCast(context.?));
        assert(self.count <= files_max);
        var index: u32 = self.count;
        for (self.entries[0..self.count], 0..) |*entry, offset| {
            if (std.mem.eql(u8, name, entry.name[0..entry.name_len])) {
                index = @intCast(offset);
                break;
            }
        }
        const start = if (mode == .append and index < self.count) self.entries[index].len else 0;
        assert(start <= file_bytes_max);
        if (name.len == 0 or name.len > name_bytes_max or index == files_max or
            bytes.len > file_bytes_max - start)
        {
            self.limits += 1;
            return error.FileLimit;
        }
        const entry = &self.entries[index];
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = @intCast(name.len);
        @memmove(entry.bytes[start..][0..bytes.len], bytes);
        entry.len = start + @as(u32, @intCast(bytes.len));
        if (index == self.count) self.count += 1;
        self.writes[@backingInt(mode)] += 1;
        assert(entry.len <= file_bytes_max);
    }
};
