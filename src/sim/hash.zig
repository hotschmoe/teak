//! See SRC.md, src/sim/hash.zig.
const std = @import("std");
const assert = @import("../assert.zig").assert;

pub const jobs_max = 1024;
pub const visits_max = 16 * 1024 * 1024;
pub const Error = error{HashLimit};

const Job = struct {
    data: [*]const u8,
    count: u32,
    stride: u32,
    visit: *const fn (*Hasher, *const anyopaque) Error!void,
};

pub const Hasher = struct {
    state: std.hash.Wyhash = .init(0),
    jobs: [jobs_max]Job = undefined,
    count: u16 = 0,

    pub fn word(self: *Hasher, value: u64) void {
        assert(self.count <= jobs_max);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.state.update(&bytes);
        assert(std.mem.readInt(u64, &bytes, .little) == value);
    }

    pub fn add(self: *Hasher, value: anytype) Error!void {
        assert(self.count == 0);
        try self.push(@TypeOf(value), &value);
        for (0..visits_max) |_| {
            if (self.count == 0) break;
            const index = self.count - 1;
            const job = self.jobs[index];
            if (job.count == 1) {
                self.count -= 1;
            } else {
                self.jobs[index].data += job.stride;
                self.jobs[index].count -= 1;
            }
            try job.visit(self, @ptrCast(job.data));
        }
        if (self.count != 0) return error.HashLimit;
        assert(self.count == 0);
    }

    fn integer(self: *Hasher, value: anytype) void {
        assert(self.count <= jobs_max);
        const T = @TypeOf(value);
        const U = @Int(.unsigned, @bitSizeOf(T));
        const byte_count = @max(1, (@bitSizeOf(T) + 7) / 8);
        const Storage = @Int(.unsigned, byte_count * 8);
        var bytes: [byte_count]u8 = undefined;
        std.mem.writeInt(Storage, &bytes, @as(U, @bitCast(value)), .little);
        assert(bytes.len > 0);
        self.state.update(&bytes);
    }

    fn push(self: *Hasher, comptime T: type, value: *const T) Error!void {
        assert(self.count <= jobs_max);
        try self.span(T, @as([*]const T, @ptrCast(value))[0..1]);
        assert(@intFromPtr(value) % @alignOf(T) == 0);
    }

    fn span(self: *Hasher, comptime T: type, values: []const T) Error!void {
        assert(self.count <= jobs_max);
        if (values.len == 0 or @sizeOf(T) == 0) return;
        if (values.len > std.math.maxInt(u32) or self.count == jobs_max)
            return error.HashLimit;
        if (T == u8) {
            self.state.update(values);
            return;
        }
        switch (@typeInfo(T)) {
            .int, .float => if (comptime @bitSizeOf(T) == @sizeOf(T) * 8 and
                @import("builtin").cpu.arch.endian() == .little)
            {
                self.state.update(std.mem.sliceAsBytes(values));
                return;
            },
            else => {},
        }
        self.jobs[self.count] = .{
            .data = @ptrCast(values.ptr),
            .count = @intCast(values.len),
            .stride = @intCast(@sizeOf(T)),
            .visit = Visitor(T).visit,
        };
        self.count += 1;
        assert(self.count <= jobs_max);
    }

    pub fn finish(self: *Hasher) u64 {
        assert(self.count == 0);
        const result = self.state.final();
        assert(self.count == 0);
        return result;
    }
};

fn Visitor(comptime T: type) type {
    assert(@sizeOf(T) <= std.math.maxInt(u32));
    assert(@alignOf(T) > 0);
    return struct {
        fn visit(h: *Hasher, raw: *const anyopaque) Error!void {
            assert(h.count <= jobs_max);
            const value: *const T = @ptrCast(@alignCast(raw));
            switch (@typeInfo(T)) {
                .void => {},
                .bool => h.word(@intFromBool(value.*)),
                .int => h.integer(value.*),
                .float => |info| h.integer(@as(@Int(.unsigned, info.bits), @bitCast(value.*))),
                .@"enum" => h.integer(@backingInt(value.*)),
                .@"struct" => |info| if (info.layout == .@"packed") {
                    h.integer(@as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(value.*)));
                } else {
                    try fields(h, value);
                },
                .@"union" => {
                    h.integer(@backingInt(std.meta.activeTag(value.*)));
                    switch (value.*) {
                        inline else => |*payload| try h.push(@TypeOf(payload.*), payload),
                    }
                },
                .optional => {
                    h.word(@intFromBool(value.* != null));
                    if (value.*) |*payload| try h.push(@TypeOf(payload.*), payload);
                },
                .array => |info| {
                    h.word(info.len);
                    try h.span(info.child, value);
                },
                .pointer => |info| switch (info.size) {
                    .slice => {
                        h.word(value.len);
                        try h.span(info.child, value.*);
                    },
                    .one => try h.push(info.child, value.*),
                    else => @compileError("simulation hash requires a bounded plain-data pointer"),
                },
                else => @compileError("simulation hash cannot inspect " ++ @typeName(T)),
            }
            assert(h.count <= jobs_max);
        }
    };
}

fn fields(h: *Hasher, value: anytype) Error!void {
    const T = @TypeOf(value.*);
    const info = @typeInfo(T).@"struct";
    assert(h.count <= jobs_max);
    inline for (0..info.field_names.len) |offset| {
        const i = info.field_names.len - offset - 1;
        const name = info.field_names[i];
        if (info.field_attrs[i].@"comptime") continue;
        if (comptime @typeInfo(info.field_types[i]) == .array) {
            try array_field(h, value, name);
        } else try h.push(info.field_types[i], &@field(value.*, name));
    }
    assert(h.count <= jobs_max);
}

fn array_field(h: *Hasher, value: anytype, comptime name: []const u8) Error!void {
    const T = @TypeOf(value.*);
    const array = &@field(value.*, name);
    const Child = @typeInfo(@TypeOf(array.*)).array.child;
    assert(h.count <= jobs_max);
    if (comptime std.mem.eql(u8, name, "log") and @hasField(T, "log_n")) {
        assert(value.log_n <= array.len);
        h.word(value.log_n);
        for (0..value.log_n) |offset| {
            const i = value.log_n - offset - 1;
            assert(value.log_len[i] <= array[i].len);
            h.word(value.log_len[i]);
            try h.span(u8, array[i][0..value.log_len[i]]);
        }
        return;
    }
    const length = active_length(value, name, @intCast(array.len));
    assert(length <= array.len);
    h.word(length);
    try h.span(Child, array[0..length]);
}

fn active_length(value: anytype, comptime name: []const u8, capacity: u32) u32 {
    const T = @TypeOf(value.*);
    const sibling = name ++ "_len";
    if (comptime @hasField(T, sibling) and
        @typeInfo(@FieldType(T, sibling)) == .int) return @intCast(@field(value.*, sibling));
    inline for (.{
        .{ "buf", "len" },      .{ "items", "len" },     .{ "text", "len" },
        .{ "recs", "n" },       .{ "events", "count" },  .{ "heights", "count" },
        .{ "order", "n_rows" }, .{ "rank", "n_rows" },   .{ "visible", "n_visible" },
        .{ "h", "n" },          .{ "log_len", "log_n" },
    }) |pair| {
        if (comptime std.mem.eql(u8, name, pair[0]) and @hasField(T, pair[1]))
            return @intCast(@field(value.*, pair[1]));
    }
    if (comptime std.mem.eql(u8, name, "prefix") and @hasField(T, "n")) return value.n + 1;
    return capacity;
}

pub fn hash(value: anytype) Error!u64 {
    var hasher: Hasher = .{};
    assert(hasher.count == 0);
    try hasher.add(value);
    assert(hasher.count == 0);
    return hasher.finish();
}
