//! See SRC.md, src/sim/trace.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;
const input = @import("input.zig");

pub const App = enum { todo, counter_greeter, tree, gallery, tables, notes, probe };
pub const Header = struct {
    version: u32 = 1,
    app: App,
    seed: u64,
    commit: []const u8,
    workload_frames: u32,
};
const DiskFrame = struct { advance_ms: u32, events: []const input.Event };
pub const Loaded = struct { header: Header, count: u32 };

pub fn write(writer: *std.Io.Writer, header: Header, frames: []const input.Frame) !void {
    assert(header.version == 1);
    assert(header.workload_frames > 0);
    try std.json.Stringify.value(header, .{}, writer);
    try writer.writeByte('\n');
    for (frames) |frame| {
        try std.json.Stringify.value(DiskFrame{
            .advance_ms = frame.advance_ms,
            .events = frame.events[0..frame.count],
        }, .{}, writer);
        try writer.writeByte('\n');
    }
}

pub fn read(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    frames: []input.Frame,
) !Loaded {
    assert(frames.len > 0);
    assert(bytes.len <= 128 * 1024 * 1024);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next() orelse return error.TraceHeader;
    const parsed = try std.json.parseFromSlice(Header, allocator, first, .{});
    const header = parsed.value;
    if (header.version != 1 or header.workload_frames == 0) return error.TraceVersion;
    var count: u32 = 0;
    for (0..frames.len + 1) |_| {
        const line = lines.next() orelse break;
        if (line.len == 0) continue;
        if (count == frames.len) return error.TraceLimit;
        const value = try std.json.parseFromSlice(DiskFrame, allocator, line, .{});
        const frame = value.value;
        if (frame.events.len > input.events_max or frame.advance_ms > 300000)
            return error.TraceInput;
        frames[count] = .{ .advance_ms = frame.advance_ms };
        for (frame.events) |event| {
            try validate_event(event);
            try frames[count].push(event);
        }
        count += 1;
    }
    if (count == 0) return error.TraceEmpty;
    return .{ .header = header, .count = count };
}

fn validate_event(event: input.Event) !void {
    assert(@sizeOf(input.Event) > 0);
    assert(input.events_max > 0);
    switch (event) {
        .move, .wheel => |point| {
            for (point) |coordinate| {
                if (!std.math.isFinite(coordinate) or @abs(coordinate) > 1.0e7)
                    return error.TraceInput;
            }
        },
        .text => |index| if (index >= input.text_samples.len) return error.TraceInput,
        .scale => |scale| {
            if (!std.math.isFinite(scale) or scale < 0.5 or scale > 4) return error.TraceInput;
        },
        .resize => |size| {
            if (size[0] > 16384 or size[1] > 16384) return error.TraceInput;
        },
        else => {},
    }
}
