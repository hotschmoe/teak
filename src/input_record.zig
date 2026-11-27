//! See SRC.md, src/input_record.zig.
const std = @import("std");
const assert = @import("assert.zig").assert;
pub const codec = @import("record_codec.zig");
pub const Error = codec.Error || error{ RecordingVersion, RecordingOrder };
pub const version = "teak-recording 2\n";
pub const frame_bytes_max = 1024 * 1024;
pub const recording_bytes_max = 64 * 1024 * 1024;
pub const frames_max = 100032;
pub const text_max = 256;
pub const keys_max = 64;
pub const chords_max = 16;

pub const Call = enum(u8) {
    control_state,
    pollInputs,
    shouldClose,
    nowMs,
    now_ns,
    scaleFactor,
    imeState,
    pollEffectResults,
    submit,
    pollA11yActions,
    clipboard_read,
    pollSecondaryInputs,
    secondary_opened,
    secondary_handle,
    secondary_surface,
    measure,
    file_write,
};

pub const Frame = struct {
    index: u32,
    bytes: []u8,
};

pub fn validate_version(bytes: []const u8) Error!u32 {
    if (!std.mem.startsWith(u8, bytes, version)) return error.RecordingVersion;
    assert(bytes.len >= version.len);
    assert(bytes[version.len - 1] == '\n');
    return version.len;
}

pub fn next_frame(bytes: []u8, position: *u32, index: u32) Error!Frame {
    assert(position.* <= bytes.len);
    assert(index <= frames_max);
    if (bytes.len - position.* < 8) return error.BadRecording;
    const header = bytes[position.*..][0..8];
    const number = std.mem.readInt(u32, header[0..4], .little);
    const length = std.mem.readInt(u32, header[4..8], .little);
    if (number != index) return error.RecordingOrder;
    if (length > frame_bytes_max or length > bytes.len - position.* - 8)
        return error.BadRecording;
    position.* += 8;
    const payload = bytes[position.*..][0..length];
    position.* += length;
    return .{ .index = number, .bytes = payload };
}

pub fn write_frame(target: []u8, frame: Frame) Error!u32 {
    assert(frame.bytes.len <= frame_bytes_max);
    assert(frame.index < frames_max);
    if (target.len < 8 or frame.bytes.len > target.len - 8) return error.RecordLimit;
    std.mem.writeInt(u32, target[0..4], frame.index, .little);
    std.mem.writeInt(u32, target[4..8], @intCast(frame.bytes.len), .little);
    @memcpy(target[8..][0..frame.bytes.len], frame.bytes);
    return @intCast(8 + frame.bytes.len);
}

pub fn check_input(input: anytype) Error!void {
    if (input.chars.len > text_max or input.keys.len > keys_max or
        input.chords.len > chords_max) return error.RecordLimit;
    assert(input.chars.len <= text_max);
    assert(input.keys.len <= keys_max);
}
