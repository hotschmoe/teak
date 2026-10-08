//! Tiny helpers over `std.json.Value` shared by the IR / mesh / style
//! parsers. All accessors are tolerant: wrong type or missing key => null.

const std = @import("std");
pub const Value = std.json.Value;

pub fn asObject(v: Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

pub fn asArray(v: Value) ?[]const Value {
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

pub fn num(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn str(v: Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn get(obj: std.json.ObjectMap, key: []const u8) ?Value {
    return obj.get(key);
}

pub fn getNum(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return num(v);
}

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return str(v);
}

pub fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getArr(obj: std.json.ObjectMap, key: []const u8) ?[]const Value {
    const v = obj.get(key) orelse return null;
    return asArray(v);
}

pub fn getObj(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return asObject(v);
}
