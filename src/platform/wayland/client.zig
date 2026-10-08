//! libwayland-client, loaded with `std.DynLib` (no wayland dev package and no
//! `-lwayland-client` at build time; the same approach as `x11.zig`).
//!
//! The wire protocol is marshalled by libwayland itself through
//! `wl_proxy_marshal_array_flags`, driven by the `Interface` tables that
//! `tools/gen_wayland.zig` writes into `protocols.zig`. Using the real
//! library (rather than speaking the wire ourselves) keeps `wl_display*` /
//! `wl_surface*` valid for Vulkan's `VK_KHR_wayland_surface`, which the GPU
//! backend needs.
//!
//! `api` is a process-wide table of function pointers, written once by
//! `load` and read-only afterwards (the library is global state anyway).

const std = @import("std");

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const Interface,
};

/// `wl_argument`: 8 bytes, the member chosen by the message signature.
pub const Argument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: ?[*:0]const u8,
    o: ?*anyopaque,
    n: u32,
    a: ?*Array,
    h: i32,
};

pub const Array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

pub const Display = opaque {};

pub const Api = struct {
    display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    display_disconnect: *const fn (*Display) callconv(.c) void,
    display_get_fd: *const fn (*Display) callconv(.c) c_int,
    display_dispatch_pending: *const fn (*Display) callconv(.c) c_int,
    display_flush: *const fn (*Display) callconv(.c) c_int,
    display_roundtrip: *const fn (*Display) callconv(.c) c_int,
    display_prepare_read: *const fn (*Display) callconv(.c) c_int,
    display_read_events: *const fn (*Display) callconv(.c) c_int,
    display_cancel_read: *const fn (*Display) callconv(.c) void,
    display_get_error: *const fn (*Display) callconv(.c) c_int,
    proxy_add_listener: *const fn (*anyopaque, [*]const ?*const anyopaque, ?*anyopaque) callconv(.c) c_int,
    proxy_destroy: *const fn (*anyopaque) callconv(.c) void,
    proxy_get_version: *const fn (*anyopaque) callconv(.c) u32,
    proxy_marshal_array_flags: *const fn (*anyopaque, u32, ?*const Interface, u32, u32, [*]Argument) callconv(.c) ?*anyopaque,
};

pub var api: Api = undefined;
var lib: ?std.DynLib = null;

/// Names of the libwayland symbols, in `Api` field order, prefixed `wl_`.
fn symbolName(comptime field: []const u8) [:0]const u8 {
    return "wl_" ++ field;
}

/// dlopen libwayland-client and resolve `api`. Idempotent.
pub fn load() error{WaylandLibMissing}!void {
    if (lib != null) return;
    var l = std.DynLib.open("libwayland-client.so.0") catch return error.WaylandLibMissing;
    var a: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |name, ty| {
        @field(a, name) = l.lookup(ty, symbolName(name)) orelse {
            l.close();
            return error.WaylandLibMissing;
        };
    }
    api = a;
    lib = l;
}

/// `wl_proxy_marshal_array_flags` with the proxy's own version unless
/// `version` is non-zero (a `bind` of an explicit version). `flags` 1 =
/// destructor.
pub fn marshal(proxy: *anyopaque, opcode: u32, iface: ?*const Interface, version: u32, flags: u32, args: [*]Argument) ?*anyopaque {
    const v = if (version != 0) version else api.proxy_get_version(proxy);
    return api.proxy_marshal_array_flags(proxy, opcode, iface, v, flags, args);
}

/// 24.8 signed fixed point (`wl_fixed_t`) to float.
pub fn fixedToF32(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 256.0;
}

pub fn f32ToFixed(v: f32) i32 {
    return @intFromFloat(@round(v * 256.0));
}

test "fixed point round trips" {
    try std.testing.expectEqual(@as(f32, 1.5), fixedToF32(f32ToFixed(1.5)));
    try std.testing.expectEqual(@as(f32, -10.25), fixedToF32(f32ToFixed(-10.25)));
}

test "Argument is pointer-sized" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Argument));
}
