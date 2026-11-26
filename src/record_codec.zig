//! See SRC.md, src/record_codec.zig.
const std = @import("std");
const assert = @import("assert.zig").assert;

pub const Error = error{ RecordLimit, BadRecording };
const jobs_max = 1024;
const visits_max = 1024 * 1024;
const Job = struct {
    data: [*]u8,
    count: u32,
    stride: u32,
    visit: *const fn (*Codec, *anyopaque) Error!void,
    name: []const u8,
};

pub const Codec = struct {
    bytes: []u8,
    position: u32 = 0,
    reading: bool = false,
    storage: []align(16) u8 = &.{},
    used: u32 = 0,
    jobs: [jobs_max]Job = undefined,
    count: u16 = 0,
    last_type: []const u8 = "",

    pub fn transfer(self: *Codec, value: anytype) Error!void {
        assert(self.count == 0);
        assert(self.position <= self.bytes.len);
        try self.push(@TypeOf(value.*), value);
        for (0..visits_max) |_| {
            if (self.count == 0) return;
            const index = self.count - 1;
            const job = self.jobs[index];
            if (job.count == 1) self.count -= 1 else {
                self.jobs[index].data += job.stride;
                self.jobs[index].count -= 1;
            }
            self.last_type = job.name;
            try job.visit(self, @ptrCast(job.data));
        }
        return error.RecordLimit;
    }

    fn integer(self: *Codec, value: anytype) Error!void {
        const T = @TypeOf(value.*);
        const U = @Int(.unsigned, @bitSizeOf(T));
        const size = @max(1, (@bitSizeOf(T) + 7) / 8);
        const Storage = @Int(.unsigned, size * 8);
        assert(self.position <= self.bytes.len);
        assert(@bitSizeOf(T) <= 64);
        if (size > self.bytes.len - self.position) return error.RecordLimit;
        const bytes: *[size]u8 = @ptrCast(self.bytes[self.position..][0..size]);
        if (self.reading) {
            const bits = std.mem.readInt(Storage, bytes, .little);
            if (bits > std.math.maxInt(U)) return error.BadRecording;
            value.* = @bitCast(@as(U, @intCast(bits)));
        } else std.mem.writeInt(Storage, bytes, @as(U, @bitCast(value.*)), .little);
        self.position += size;
    }

    fn push(self: *Codec, comptime T: type, value: *T) Error!void {
        assert(self.count <= jobs_max);
        assert(@intFromPtr(value) % @alignOf(T) == 0);
        try self.span(T, @as([*]T, @ptrCast(value))[0..1]);
    }

    fn span(self: *Codec, comptime T: type, values: []T) Error!void {
        assert(self.count <= jobs_max);
        assert(self.position <= self.bytes.len);
        if (values.len == 0 or @sizeOf(T) == 0) return;
        if (T == u8) {
            if (values.len > self.bytes.len - self.position) return error.RecordLimit;
            const bytes = self.bytes[self.position..][0..values.len];
            if (self.reading) @memcpy(values, bytes) else @memcpy(bytes, values);
            self.position += @intCast(values.len);
            return;
        }
        if (self.count == jobs_max or values.len > std.math.maxInt(u32))
            return error.RecordLimit;
        self.jobs[self.count] = .{
            .data = @ptrCast(values.ptr),
            .count = @intCast(values.len),
            .stride = @intCast(@sizeOf(T)),
            .visit = Visitor(T).visit,
            .name = @typeName(T),
        };
        self.count += 1;
    }

    fn reserve(self: *Codec, comptime T: type, length: u32) Error![]T {
        assert(self.used <= self.storage.len);
        assert(@alignOf(T) <= 16);
        const start = std.mem.alignForward(u32, self.used, @alignOf(T));
        const size = @as(u64, length) * @sizeOf(T);
        if (start > self.storage.len or size > self.storage.len - start)
            return error.RecordLimit;
        self.used = start + @as(u32, @intCast(size));
        return @as([*]T, @ptrCast(@alignCast(self.storage[start..].ptr)))[0..length];
    }
};

fn Visitor(comptime T: type) type {
    return struct {
        fn visit(codec: *Codec, raw: *anyopaque) Error!void {
            assert(codec.count <= jobs_max);
            assert(codec.position <= codec.bytes.len);
            const value: *T = @ptrCast(@alignCast(raw));
            switch (@typeInfo(T)) {
                .void => {},
                .bool => {
                    var bits: u8 = if (codec.reading) 0 else @intFromBool(value.*);
                    try codec.integer(&bits);
                    if (bits > 1) return error.BadRecording;
                    if (codec.reading) value.* = bits == 1;
                },
                .int => try codec.integer(value),
                .float => |info| {
                    var bits: @Int(.unsigned, info.bits) = if (codec.reading)
                        0
                    else
                        @bitCast(value.*);
                    try codec.integer(&bits);
                    if (codec.reading) value.* = @bitCast(bits);
                },
                .@"enum" => try enum_value(codec, value),
                .@"struct" => |info| if (info.layout == .@"packed") {
                    var bits: @Int(.unsigned, @bitSizeOf(T)) = if (codec.reading)
                        0
                    else
                        @bitCast(value.*);
                    try codec.integer(&bits);
                    if (codec.reading) value.* = @bitCast(bits);
                } else try fields(codec, value),
                .@"union" => try union_value(codec, value),
                .optional => try optional_value(codec, value),
                .array => |info| try codec.span(info.child, value),
                .pointer => |info| {
                    if (info.size != .slice) @compileError("recording requires plain data");
                    try slice_value(codec, value);
                },
                else => @compileError("cannot record " ++ @typeName(T)),
            }
        }
    };
}

fn fields(codec: *Codec, value: anytype) Error!void {
    const info = @typeInfo(@TypeOf(value.*)).@"struct";
    assert(codec.count <= jobs_max);
    assert(codec.position <= codec.bytes.len);
    inline for (0..info.field_names.len) |offset| {
        const index = info.field_names.len - offset - 1;
        if (!info.field_attrs[index].@"comptime")
            try codec.push(info.field_types[index], &@field(value.*, info.field_names[index]));
    }
}

fn union_value(codec: *Codec, value: anytype) Error!void {
    const T = @TypeOf(value.*);
    const Tag = std.meta.Tag(T);
    var tag: Tag = if (codec.reading) std.meta.tags(Tag)[0] else std.meta.activeTag(value.*);
    assert(codec.count <= jobs_max);
    try enum_value(codec, &tag);
    if (codec.reading) switch (tag) {
        inline else => |active| value.* = @unionInit(T, @tagName(active), undefined),
    };
    switch (value.*) {
        inline else => |*payload| try codec.push(@TypeOf(payload.*), payload),
    }
    assert(codec.count <= jobs_max);
}

fn enum_value(codec: *Codec, value: anytype) Error!void {
    const T = @TypeOf(value.*);
    assert(codec.position <= codec.bytes.len);
    assert(codec.count <= jobs_max);
    var tag: u32 = if (codec.reading) 0 else @backingInt(value.*);
    try codec.integer(&tag);
    if (codec.reading) value.* = std.enums.fromInt(T, tag) orelse return error.BadRecording;
}

fn optional_value(codec: *Codec, value: anytype) Error!void {
    var present: u8 = if (codec.reading) 0 else @intFromBool(value.* != null);
    assert(codec.count <= jobs_max);
    try codec.integer(&present);
    if (present > 1) return error.BadRecording;
    if (codec.reading) value.* = if (present == 1)
        std.mem.zeroes(@typeInfo(@TypeOf(value.*)).optional.child)
    else
        null;
    if (value.*) |*payload| try codec.push(@TypeOf(payload.*), payload);
    assert(codec.count <= jobs_max);
}

fn slice_value(codec: *Codec, value: anytype) Error!void {
    const Child = @typeInfo(@TypeOf(value.*)).pointer.child;
    assert(codec.count <= jobs_max);
    if (!codec.reading and value.len > std.math.maxInt(u32)) return error.RecordLimit;
    var length: u32 = if (codec.reading) 0 else @intCast(value.len);
    try codec.integer(&length);
    const reserved = try codec.reserve(Child, length);
    if (codec.reading) value.* = reserved;
    try codec.span(Child, @constCast(value.*));
    assert(codec.count <= jobs_max);
}
