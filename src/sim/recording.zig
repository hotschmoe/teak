//! See SRC.md, src/sim/recording.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const record = @import("../input_record.zig");

pub const recording_path = "input.record";
pub const snapshot_path = "frame.snapshot";

pub const Replay = struct {
    bytes: []const u8,
    position: u32 = 0,

    pub fn next(self: *Replay, frame: u32) !?record.FrameRec {
        assert(self.position <= self.bytes.len);
        assert(self.bytes.len <= @import("files.zig").file_bytes_max);
        for (0..self.bytes.len + 1) |_| {
            if (self.position == self.bytes.len) return null;
            const end = std.mem.indexOfScalarPos(u8, self.bytes, self.position, '\n') orelse
                self.bytes.len;
            const parsed = try record.parseLine(self.bytes[self.position..end]);
            if (parsed) |value| {
                if (value.frame > frame) return null;
                if (value.frame < frame) return error.RecordFrameOrder;
            }
            self.position = @intCast(@min(end + 1, self.bytes.len));
            if (parsed) |value| return value;
        }
        return error.RecordLimit;
    }
};
