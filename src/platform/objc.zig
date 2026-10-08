//! A minimal Objective-C runtime binding for the macOS host, loaded with
//! `std.DynLib` instead of linked: libobjc and the frameworks are opened by
//! path at runtime, so cross-compiling from any OS needs no macOS SDK, no
//! `-framework` flags and no Objective-C sources (the same approach as the
//! X11 / Wayland hosts). Everything here is plain C-ABI calls through
//! `objc_msgSend`; the only Objective-C "code" is the handful of classes the
//! host registers at run time (`cocoa.zig`), whose methods are Zig functions.
//!
//! `msg` is the typed message-send: `msg(R, receiver, sel, .{args})` casts
//! `objc_msgSend` to the exact `fn (id, SEL, args...) R` the call needs
//! (that cast IS the ObjC calling convention), using `objc_msgSend_stret`
//! for large struct returns on x86_64.

const std = @import("std");
const builtin = @import("builtin");

pub const Id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const Sel = *opaque {};
pub const Imp = *const anyopaque;

pub const CGFloat = f64;
pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { w: CGFloat = 0, h: CGFloat = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };
pub const NSRange = extern struct { location: u64 = 0, length: u64 = 0 };
pub const NSNotFound: u64 = std.math.maxInt(i64);

const Api = struct {
    objc_getClass: *const fn ([*:0]const u8) callconv(.c) Class,
    objc_getProtocol: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    sel_registerName: *const fn ([*:0]const u8) callconv(.c) Sel,
    objc_msgSend: *const anyopaque,
    objc_allocateClassPair: *const fn (Class, [*:0]const u8, usize) callconv(.c) Class,
    objc_registerClassPair: *const fn (Class) callconv(.c) void,
    class_addMethod: *const fn (Class, Sel, Imp, [*:0]const u8) callconv(.c) bool,
    class_addIvar: *const fn (Class, [*:0]const u8, usize, u8, [*:0]const u8) callconv(.c) bool,
    class_addProtocol: *const fn (Class, ?*anyopaque) callconv(.c) bool,
    class_getInstanceVariable: *const fn (Class, [*:0]const u8) callconv(.c) ?*anyopaque,
    object_getIvar: *const fn (Id, ?*anyopaque) callconv(.c) Id,
    object_setIvar: *const fn (Id, ?*anyopaque, Id) callconv(.c) void,
    objc_autoreleasePoolPush: *const fn () callconv(.c) ?*anyopaque,
    objc_autoreleasePoolPop: *const fn (?*anyopaque) callconv(.c) void,
};

var api: Api = undefined;
var stret: ?*const anyopaque = null;
var libs: [4]?std.DynLib = @splat(null);
var loaded = false;

/// Open libobjc (+ Foundation / AppKit / QuartzCore so their classes
/// resolve). Idempotent. Fails off macOS or if a library is missing.
pub fn load() error{ObjcUnavailable}!void {
    if (loaded) return;
    var objc = std.DynLib.open("/usr/lib/libobjc.A.dylib") catch return error.ObjcUnavailable;
    var a: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |name, ty| {
        @field(a, name) = objc.lookup(ty, name) orelse {
            objc.close();
            return error.ObjcUnavailable;
        };
    }
    api = a;
    stret = objc.lookup(*const anyopaque, "objc_msgSend_stret");
    libs[0] = objc;
    const frameworks = [_][:0]const u8{
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/AppKit.framework/AppKit",
        "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    };
    for (frameworks, 1..) |path, i| {
        libs[i] = std.DynLib.open(path) catch return error.ObjcUnavailable;
    }
    loaded = true;
}

pub fn cls(name: [*:0]const u8) Id {
    return api.objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) Sel {
    return api.sel_registerName(name);
}

/// Open a pool, returning its token for `poolPop`.
pub fn poolPush() ?*anyopaque {
    return api.objc_autoreleasePoolPush();
}

pub fn poolPop(token: ?*anyopaque) void {
    api.objc_autoreleasePoolPop(token);
}

fn needsStret(comptime R: type) bool {
    return builtin.cpu.arch == .x86_64 and @typeInfo(R) == .@"struct" and @sizeOf(R) > 16;
}

/// Typed `objc_msgSend`. `args` is a tuple of at most 5 values; their Zig
/// types ARE the C parameter types, so pass exactly typed values (`f64`,
/// `u64`, `bool`, `Id`, `Sel`, structs). Zero-sized results use `void`.
pub fn msg(comptime R: type, target: Id, s: Sel, args: anytype) R {
    const n = @typeInfo(@TypeOf(args)).@"struct".field_names.len;
    if (comptime needsStret(R)) {
        var out: R = undefined;
        const raw = stret orelse unreachable;
        switch (n) {
            0 => @as(*const fn (*R, Id, Sel) callconv(.c) void, @ptrCast(raw))(&out, target, s),
            1 => @as(*const fn (*R, Id, Sel, @TypeOf(args[0])) callconv(.c) void, @ptrCast(raw))(&out, target, s, args[0]),
            2 => @as(*const fn (*R, Id, Sel, @TypeOf(args[0]), @TypeOf(args[1])) callconv(.c) void, @ptrCast(raw))(&out, target, s, args[0], args[1]),
            else => @compileError("msg: stret arity"),
        }
        return out;
    }
    const raw = api.objc_msgSend;
    return switch (n) {
        0 => @as(*const fn (Id, Sel) callconv(.c) R, @ptrCast(raw))(target, s),
        1 => @as(*const fn (Id, Sel, @TypeOf(args[0])) callconv(.c) R, @ptrCast(raw))(target, s, args[0]),
        2 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1])) callconv(.c) R, @ptrCast(raw))(target, s, args[0], args[1]),
        3 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) R, @ptrCast(raw))(target, s, args[0], args[1], args[2]),
        4 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3])) callconv(.c) R, @ptrCast(raw))(target, s, args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4])) callconv(.c) R, @ptrCast(raw))(target, s, args[0], args[1], args[2], args[3], args[4]),
        else => @compileError("msg: too many arguments"),
    };
}

/// `[Class new-style alloc/init]` convenience: `[[cls alloc] init]`.
pub fn allocInit(class: Id) Id {
    return msg(Id, msg(Id, class, sel("alloc"), .{}), sel("init"), .{});
}

// ── NSString / NSArray helpers ─────────────────────────────────────

/// A new autoreleased NSString from UTF-8 (`s` must be NUL-terminated).
pub fn nsString(s: [*:0]const u8) Id {
    return msg(Id, cls("NSString"), sel("stringWithUTF8String:"), .{s});
}

/// Borrow the UTF-8 bytes of an NSString (valid until it is released /
/// the autorelease pool drains); empty for nil.
pub fn utf8Of(str: Id) []const u8 {
    if (str == null) return "";
    const p = msg(?[*:0]const u8, str, sel("UTF8String"), .{}) orelse return "";
    return std.mem.span(p);
}

// ── Class construction ─────────────────────────────────────────────

pub const Method = struct { name: [*:0]const u8, imp: Imp, types: [*:0]const u8 };

/// Register `name` as a subclass of `super` with one pointer-sized ivar
/// (`state`, read back with `getState` / `setState`), the given methods and
/// optional protocols. Returns the class.
pub fn defineClass(name: [*:0]const u8, super: [*:0]const u8, methods: []const Method, protocols: []const [*:0]const u8) Class {
    const c = api.objc_allocateClassPair(cls(super), name, 0);
    _ = api.class_addIvar(c, "teak_state", @sizeOf(usize), @intCast(std.math.log2_int(usize, @alignOf(usize))), "^v");
    for (methods) |m| _ = api.class_addMethod(c, sel(m.name), m.imp, m.types);
    for (protocols) |p| if (api.objc_getProtocol(p)) |proto| {
        _ = api.class_addProtocol(c, proto);
    };
    api.objc_registerClassPair(c);
    return c;
}

pub fn setState(obj: Id, state: ?*anyopaque) void {
    const iv = api.class_getInstanceVariable(msg(Class, obj, sel("class"), .{}), "teak_state");
    api.object_setIvar(obj, iv, state);
}

pub fn getState(obj: Id) ?*anyopaque {
    const iv = api.class_getInstanceVariable(msg(Class, obj, sel("class"), .{}), "teak_state");
    return api.object_getIvar(obj, iv);
}

test "CGRect / NSRange have the C layout the ABI expects" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CGRect));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(NSRange));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CGPoint));
}
