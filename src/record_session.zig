//! See SRC.md, src/record_session.zig.
const std = @import("std");
const assert = @import("assert.zig").assert;
const record = @import("input_record.zig");

pub const Session = struct {
    backing: []align(16) u8 = &.{},
    buffer: []u8 = &.{},
    scratch: []align(16) u8 = &.{},
    stream: []u8 = &.{},
    stream_len: u32 = 0,
    position: u32 = 0,
    used: u32 = 0,
    replay: ?[]u8 = null,
    replay_position: u32 = 0,
    failure: ?anyerror = null,
    limits: u64 = 0,
    recording: bool = false,
    in_frame: bool = false,
    storage_used: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, recording: bool, replay: ?[]u8) !Session {
        var self: Session = .{ .recording = recording, .replay = replay };
        if (replay) |bytes| self.replay_position = try record.validate_version(bytes);
        if (!recording and replay == null) return self;
        const stream_size: u32 = if (recording) record.recording_bytes_max else 0;
        const length = 2 * record.frame_bytes_max + stream_size;
        self.backing = try allocator.alignedAlloc(u8, .@"16", length);
        self.buffer = self.backing[0..record.frame_bytes_max];
        const scratch_area = self.backing[record.frame_bytes_max..];
        self.scratch = @alignCast(scratch_area[0..record.frame_bytes_max]);
        if (recording) {
            self.stream = self.backing[2 * record.frame_bytes_max ..];
            @memcpy(self.stream[0..record.version.len], record.version);
            self.stream_len = record.version.len;
        }
        assert(self.buffer.len == record.frame_bytes_max);
        assert(self.scratch.len == self.buffer.len);
        return self;
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        assert(self.buffer.len == self.scratch.len);
        assert(self.stream_len <= self.stream.len);
        allocator.free(self.backing);
    }

    pub fn begin(self: *Session, index: u32) !void {
        assert(!self.in_frame);
        assert(self.position <= record.frame_bytes_max);
        self.position = 0;
        self.used = 0;
        self.storage_used = 0;
        if (self.replay) |bytes| {
            if (index >= record.frames_max) return error.RecordLimit;
            const frame = try record.next_frame(bytes, &self.replay_position, index);
            @memcpy(self.buffer[0..frame.bytes.len], frame.bytes);
            self.used = @intCast(frame.bytes.len);
        }
        if (self.recording and index >= record.frames_max) self.stop(error.RecordLimit);
        self.in_frame = true;
    }

    pub fn finish(self: *Session, index: u32) !bool {
        assert(self.in_frame);
        assert(self.stream_len <= self.stream.len);
        self.in_frame = false;
        if (self.failure) |err| return err;
        if (self.replay != null and self.position != self.used) return error.RecordingOrder;
        if (!self.recording) return false;
        const length = record.write_frame(self.stream[self.stream_len..], .{
            .index = index,
            .bytes = self.buffer[0..self.position],
        }) catch |err| {
            self.stop(err);
            return false;
        };
        self.stream_len += length;
        return true;
    }

    pub fn stop(self: *Session, err: anyerror) void {
        assert(self.recording);
        assert(self.limits == 0);
        self.recording = false;
        self.limits += 1;
        std.log.warn("teak: recording stopped: {s}", .{@errorName(err)});
    }

    pub fn value(self: *Session, comptime call: record.Call, result: anytype) @TypeOf(result) {
        assert(self.position <= self.buffer.len);
        assert(self.used <= self.buffer.len);
        if (!self.in_frame or (!self.recording and self.replay == null)) return result;
        if (self.failure != null) return std.mem.zeroes(@TypeOf(result));
        var copy = result;
        self.transfer(call, &copy) catch |err| {
            if (self.replay != null) self.failure = err else self.stop(err);
            return if (self.replay != null) std.mem.zeroes(@TypeOf(result)) else result;
        };
        return copy;
    }

    fn transfer(self: *Session, comptime call: record.Call, result: anytype) !void {
        assert(self.position <= self.buffer.len);
        const reading = self.replay != null;
        const limit = if (reading) self.used else self.buffer.len;
        if (self.position == limit) return if (reading) error.BadRecording else error.RecordLimit;
        if (reading) {
            if (self.buffer[self.position] != @backingInt(call)) return error.RecordingOrder;
        } else self.buffer[self.position] = @backingInt(call);
        self.position += 1;
        var codec: record.codec.Codec = .{
            .bytes = self.buffer[0..limit],
            .position = self.position,
            .reading = reading,
            .storage = self.scratch,
            .used = self.storage_used,
        };
        codec.transfer(result) catch |err| {
            if (reading) std.log.err("teak: replay call {s} byte {d} type {s}: {s}", .{
                @tagName(call), codec.position, codec.last_type, @errorName(err),
            });
            return err;
        };
        self.position = codec.position;
        self.storage_used = codec.used;
        assert(self.position <= limit);
    }
};
