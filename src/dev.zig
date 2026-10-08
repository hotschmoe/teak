//! Hot reload for dev builds (native, Linux): the App compiled as a shared
//! library behind a stable loader executable. See docs/features/hot-reload.md.
//!
//! ```
//!   libapp.so  = App + Runtime(App) + Host + Gpu, exported through `Plugin`
//!   loader exe = `runLoader(lib_path)`: no teak types, only a C ABI
//! ```
//!
//! The loader watches the library's mtime. On change it copies the file to a
//! fresh name (a same-path `dlopen` would return the old mapping), loads it,
//! builds a NEW `Runtime` over the SAME Host / Gpu objects (window, GPU
//! device, glyph caches, the control socket all live in an `Env` the first
//! library created and every later one only borrows), and carries state
//! across:
//!
//!   * the Model, byte for byte, when `typeFingerprint(App.Model)` matches
//!     (@typeName + field names / types / sizes, recursively) -- otherwise the
//!     new Model starts from its defaults and the loader says so;
//!   * the hover / press / focus `TransientState`.
//!
//! Old libraries are never unloaded: a Model may hold slices of string
//! literals that live in the old image, and a leaked mapping per reload is
//! the right price for a dev tool. A Host / Gpu layout change (teak itself
//! rebuilt) is refused, not guessed: restart the loader.
//!
//! HARDLINE: this is the Host layer (hatch 4). `Runtime`, `view`, `update`
//! and the Model are untouched and unaware; the swap happens between two
//! frames, outside every pass, and the only thing crossing the boundary is a
//! byte copy of a Model whose type has been proven identical.

const std = @import("std");
const run_mod = @import("run.zig");

/// Bump when the exported C ABI below changes.
pub const abi_version: u32 = 1;

// ── Fingerprints ───────────────────────────────────────────────────

/// A 64-bit hash of a type's SHAPE: its name, size, and (recursively) the
/// names, types and offsets of its fields. Pointers hash their own type name
/// only (no recursion through them), so self-referential types terminate.
pub fn typeFingerprint(comptime T: type) u64 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var h = std.hash.Wyhash.init(0x7ea4);
        feed(&h, T, 0);
        return h.final();
    }
}

fn feed(h: *std.hash.Wyhash, comptime T: type, comptime depth: u32) void {
    // Anonymous aggregates carry a compiler-numbered name (`...__struct_1234`)
    // that shifts with unrelated edits; their fields are hashed below anyway.
    if (std.mem.find(u8, @typeName(T), "__") == null) h.update(@typeName(T));
    h.update(std.mem.asBytes(&@as(u64, @sizeOf(T))));
    if (depth > 12) return;
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names, s.field_types, 0..) |name, FT, i| {
            h.update(name);
            if (s.layout != .@"packed") h.update(std.mem.asBytes(&@as(u64, @offsetOf(T, name))));
            _ = i;
            feed(h, FT, depth + 1);
        },
        .@"union" => |u| inline for (u.field_names, u.field_types) |name, FT| {
            h.update(name);
            feed(h, FT, depth + 1);
        },
        .@"enum" => |e| inline for (e.field_names, e.field_values) |name, v| {
            h.update(name);
            h.update(std.mem.asBytes(&@as(i128, @intCast(v))));
        },
        .array => |a| {
            h.update(std.mem.asBytes(&@as(u64, a.len)));
            feed(h, a.child, depth + 1);
        },
        .optional => |o| feed(h, o.child, depth + 1),
        .vector => |v| feed(h, v.child, depth + 1),
        else => {}, // scalars, pointers: the type name + size above identify them
    }
}

// ── The library side ───────────────────────────────────────────────

/// Everything the window system and GPU need, created once by the FIRST
/// library and handed to every later one.
pub fn Env(comptime Host: type, comptime Gpu: type) type {
    return struct {
        host: Host,
        gpu: Gpu,
    };
}

/// Build the exported surface for one App. `Init` supplies construction:
///
/// ```zig
/// const Init = struct {
///     pub fn host(gpa: std.mem.Allocator) !Host { return Host.init(gpa, 720, 600); }
///     pub fn gpu(host: *Host) !Gpu { return Gpu.initOffscreen(720, 600, .{}); }
/// };
/// comptime { teak.dev.Plugin(App, Host, Gpu, Init).exportAll(); }
/// ```
pub fn Plugin(comptime App: type, comptime Host: type, comptime Gpu: type, comptime Init: type) type {
    return struct {
        const E = Env(Host, Gpu);
        const Rt = run_mod.Runtime(App, Host, Gpu);
        const gpa = std.heap.c_allocator;

        pub const app_fingerprint: u64 = typeFingerprint(App.Model);
        pub const env_fingerprint: u64 = typeFingerprint(Host) ^ (typeFingerprint(Gpu) *% 31) ^ typeFingerprint(run_mod.RunOptions);

        fn abi() callconv(.c) u32 {
            return abi_version;
        }
        fn appFp() callconv(.c) u64 {
            return app_fingerprint;
        }
        fn envFp() callconv(.c) u64 {
            return env_fingerprint;
        }

        /// Each image has its own copy of std's globals, so the process
        /// environment (TEAK_CONTROL, TEAK_INSPECT ...) must be handed over.
        fn setEnviron(block: [*:null]const ?[*:0]const u8) callconv(.c) void {
            const t = std.Options.debug_threaded_io orelse return;
            t.environ = .{ .process_environ = .{ .block = .{ .slice = std.mem.span(block) } } };
            t.environ_initialized = false;
        }

        fn envOpen() callconv(.c) ?*anyopaque {
            const e = gpa.create(E) catch return null;
            e.host = Init.host(gpa) catch {
                gpa.destroy(e);
                return null;
            };
            e.gpu = Init.gpu(&e.host) catch {
                e.host.deinit();
                gpa.destroy(e);
                return null;
            };
            return e;
        }
        fn envClose(env: *anyopaque) callconv(.c) void {
            const e: *E = @ptrCast(@alignCast(env));
            e.gpu.deinit();
            e.host.deinit();
            gpa.destroy(e);
        }
        fn envClosed(env: *anyopaque) callconv(.c) bool {
            const e: *E = @ptrCast(@alignCast(env));
            return e.host.shouldClose();
        }

        fn start(env: *anyopaque) callconv(.c) ?*anyopaque {
            const e: *E = @ptrCast(@alignCast(env));
            const rt = gpa.create(Rt) catch return null;
            rt.* = Rt.init(gpa, &e.host, &e.gpu, .{}) catch {
                gpa.destroy(rt);
                return null;
            };
            return rt;
        }
        fn stop(p: *anyopaque) callconv(.c) void {
            const rt: *Rt = @ptrCast(@alignCast(p));
            rt.deinit();
            gpa.destroy(rt);
        }
        /// Carry the Model + TransientState of `old` (built by ANOTHER image
        /// with the same app fingerprint) into `new`.
        fn adopt(new: *anyopaque, old: *anyopaque) callconv(.c) void {
            const n: *Rt = @ptrCast(@alignCast(new));
            const o: *Rt = @ptrCast(@alignCast(old));
            const dst = std.mem.asBytes(&n.model);
            const src = std.mem.asBytes(&o.model);
            @memcpy(dst, src);
            n.ts = o.ts;
            n.prev_ts = o.prev_ts;
        }
        /// 0 ok, 1 host closed, -1 error.
        fn frame(p: *anyopaque) callconv(.c) i32 {
            const rt: *Rt = @ptrCast(@alignCast(p));
            rt.frame() catch return -1;
            return if (rt.host.shouldClose()) 1 else 0;
        }
        fn isQuiet(p: *anyopaque) callconv(.c) bool {
            const rt: *Rt = @ptrCast(@alignCast(p));
            return rt.quiet;
        }
        /// Block (at most `cap_ms`) until input or the next sub is due.
        fn wait(p: *anyopaque, cap_ms: u32) callconv(.c) void {
            const rt: *Rt = @ptrCast(@alignCast(p));
            if (comptime @hasDecl(Host, "waitEvents")) {
                rt.host.waitEvents(@min(rt.idleTimeoutMs(), cap_ms));
            }
        }

        pub fn exportAll() void {
            @export(&abi, .{ .name = "teak_dev_abi" });
            @export(&setEnviron, .{ .name = "teak_dev_set_environ" });
            @export(&appFp, .{ .name = "teak_dev_app_fingerprint" });
            @export(&envFp, .{ .name = "teak_dev_env_fingerprint" });
            @export(&envOpen, .{ .name = "teak_dev_env_open" });
            @export(&envClose, .{ .name = "teak_dev_env_close" });
            @export(&envClosed, .{ .name = "teak_dev_env_closed" });
            @export(&start, .{ .name = "teak_dev_start" });
            @export(&stop, .{ .name = "teak_dev_stop" });
            @export(&adopt, .{ .name = "teak_dev_adopt" });
            @export(&frame, .{ .name = "teak_dev_frame" });
            @export(&isQuiet, .{ .name = "teak_dev_quiet" });
            @export(&wait, .{ .name = "teak_dev_wait" });
        }
    };
}

// ── The loader side ────────────────────────────────────────────────

/// One loaded image: its symbols.
const Image = struct {
    lib: std.DynLib,
    app_fp: u64,
    env_fp: u64,
    env_open: *const fn () callconv(.c) ?*anyopaque,
    env_close: *const fn (*anyopaque) callconv(.c) void,
    env_closed: *const fn (*anyopaque) callconv(.c) bool,
    start: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    stop: *const fn (*anyopaque) callconv(.c) void,
    adopt: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
    frame: *const fn (*anyopaque) callconv(.c) i32,
    quiet: *const fn (*anyopaque) callconv(.c) bool,
    wait: *const fn (*anyopaque, u32) callconv(.c) void,

    fn open(path: [:0]const u8, environ: ?[*:null]const ?[*:0]const u8) !Image {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        const abi_fn = lib.lookup(*const fn () callconv(.c) u32, "teak_dev_abi") orelse return error.NotATeakPlugin;
        if (abi_fn() != abi_version) return error.AbiMismatch;
        if (environ) |env| if (lib.lookup(*const fn ([*:null]const ?[*:0]const u8) callconv(.c) void, "teak_dev_set_environ")) |f| f(env);
        const fp = lib.lookup(*const fn () callconv(.c) u64, "teak_dev_app_fingerprint") orelse return error.NotATeakPlugin;
        const efp = lib.lookup(*const fn () callconv(.c) u64, "teak_dev_env_fingerprint") orelse return error.NotATeakPlugin;
        return .{
            .lib = lib,
            .app_fp = fp(),
            .env_fp = efp(),
            .env_open = lib.lookup(@FieldType(Image, "env_open"), "teak_dev_env_open") orelse return error.NotATeakPlugin,
            .env_close = lib.lookup(@FieldType(Image, "env_close"), "teak_dev_env_close") orelse return error.NotATeakPlugin,
            .env_closed = lib.lookup(@FieldType(Image, "env_closed"), "teak_dev_env_closed") orelse return error.NotATeakPlugin,
            .start = lib.lookup(@FieldType(Image, "start"), "teak_dev_start") orelse return error.NotATeakPlugin,
            .stop = lib.lookup(@FieldType(Image, "stop"), "teak_dev_stop") orelse return error.NotATeakPlugin,
            .adopt = lib.lookup(@FieldType(Image, "adopt"), "teak_dev_adopt") orelse return error.NotATeakPlugin,
            .frame = lib.lookup(@FieldType(Image, "frame"), "teak_dev_frame") orelse return error.NotATeakPlugin,
            .quiet = lib.lookup(@FieldType(Image, "quiet"), "teak_dev_quiet") orelse return error.NotATeakPlugin,
            .wait = lib.lookup(@FieldType(Image, "wait"), "teak_dev_wait") orelse return error.NotATeakPlugin,
        };
    }
};

pub const ReloadResult = enum {
    /// Nothing changed on disk.
    unchanged,
    /// Swapped; the Model carried over.
    kept_model,
    /// Swapped; the Model type changed, so the new one starts fresh.
    reset_model,
    /// The new library could not be used; the old one keeps running.
    rejected,
};

pub const Loader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// The watched path (the build output).
    path: []const u8,
    /// Copies of the library are written here under unique names.
    tmp_dir: []const u8,
    generation: u32 = 0,
    /// The loader's own process environment, forwarded into each image.
    environ: ?[*:null]const ?[*:0]const u8 = null,
    image: Image = undefined,
    env: *anyopaque = undefined,
    rt: *anyopaque = undefined,
    last_mtime: i96 = 0,
    /// Number of images loaded so far (all stay mapped).
    loaded: u32 = 0,
    /// Human-readable note about the last reload (reason for a reset / reject).
    note: [160]u8 = undefined,
    note_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8, tmp_dir: []const u8, environ: ?[*:null]const ?[*:0]const u8) !Loader {
        var self: Loader = .{ .io = io, .gpa = gpa, .path = path, .tmp_dir = tmp_dir, .environ = environ };
        self.image = try self.openCopy();
        self.last_mtime = self.mtime() orelse 0;
        self.env = self.image.env_open() orelse return error.EnvOpenFailed;
        self.rt = self.image.start(self.env) orelse return error.StartFailed;
        return self;
    }

    pub fn deinit(self: *Loader) void {
        self.image.stop(self.rt);
        self.image.env_close(self.env);
        // The images stay mapped (see the module doc).
    }

    pub fn lastNote(self: *const Loader) []const u8 {
        return self.note[0..self.note_len];
    }

    fn setNote(self: *Loader, comptime fmt: []const u8, args: anytype) void {
        const out: []const u8 = std.fmt.bufPrint(&self.note, fmt, args) catch self.note[0..];
        self.note_len = out.len;
    }

    fn mtime(self: *Loader) ?i96 {
        const st = std.Io.Dir.cwd().statFile(self.io, self.path, .{}) catch return null;
        return st.mtime.nanoseconds;
    }

    fn openCopy(self: *Loader) !Image {
        self.generation += 1;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dst = try std.fmt.bufPrintSentinel(&buf, "{s}/teak-dev-{d}-{d}.so", .{ self.tmp_dir, self.generation, std.os.linux.getpid() }, 0);
        try std.Io.Dir.copyFile(std.Io.Dir.cwd(), self.path, std.Io.Dir.cwd(), dst, self.io, .{});
        const img = try Image.open(dst, self.environ);
        self.loaded += 1;
        return img;
    }

    /// Check the file and swap when it changed. Call between frames.
    pub fn pollReload(self: *Loader) ReloadResult {
        const mt = self.mtime() orelse return .unchanged;
        if (mt == self.last_mtime) return .unchanged;
        // The build may still be writing: wait until the mtime has been
        // stable for one more poll.
        std.Io.sleep(self.io, .fromMilliseconds(30), .awake) catch {};
        if ((self.mtime() orelse 0) != mt) return .unchanged;
        self.last_mtime = mt;
        return self.reload();
    }

    /// Load the file at `path` now and swap.
    pub fn reload(self: *Loader) ReloadResult {
        var img = self.openCopy() catch |e| {
            self.setNote("reload rejected: {s} (still running the previous build)", .{@errorName(e)});
            return .rejected;
        };
        if (img.env_fp != self.image.env_fp) {
            self.setNote("reload rejected: the Host / Gpu layout changed (teak itself was rebuilt); restart the loader", .{});
            return .rejected;
        }
        const new_rt = img.start(self.env) orelse {
            self.setNote("reload rejected: the new build could not start", .{});
            return .rejected;
        };
        const keep = img.app_fp == self.image.app_fp;
        if (keep) {
            img.adopt(new_rt, self.rt);
            self.setNote("reloaded: Model kept", .{});
        } else {
            self.setNote("reloaded: the Model type changed, state reset to defaults", .{});
        }
        self.image.stop(self.rt);
        self.image = img;
        self.rt = new_rt;
        return if (keep) .kept_model else .reset_model;
    }

    /// One frame of the current build. False: the Host closed or the frame failed.
    pub fn frame(self: *Loader) bool {
        return self.image.frame(self.rt) == 0;
    }

    /// After a quiet frame: block in the Host for at most `cap_ms`.
    pub fn idle(self: *Loader, cap_ms: u32) void {
        if (self.image.quiet(self.rt)) self.image.wait(self.rt, cap_ms);
    }

    pub fn closed(self: *Loader) bool {
        return self.image.env_closed(self.env);
    }
};

/// The loader executable's whole job: `pub fn main(init)` calls this with the
/// library path (default `zig-out/lib/libapp.so`).
pub fn runLoader(init: std.process.Init, default_path: []const u8) !void {
    const gpa = std.heap.c_allocator;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse default_path;
    const io = std.Options.debug_io;

    var tmp_buf: [64]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "/tmp", .{}) catch unreachable;
    var loader = try Loader.init(gpa, io, path, tmp, init.minimal.environ.block.slice.ptr);
    defer loader.deinit();
    std.debug.print("[teak dev] running {s}; rebuild it (zig build dev --watch) to reload\n", .{path});

    var n: u32 = 0;
    while (!loader.closed()) {
        n +%= 1;
        // Poll the file ~every 8th iteration (cheap stat; keeps idle wakeups low).
        if (n % 8 == 0) switch (loader.pollReload()) {
            .unchanged => {},
            else => std.debug.print("[teak dev] {s}\n", .{loader.lastNote()}),
        };
        if (!loader.frame()) break;
        loader.idle(100);
        std.Io.sleep(io, .fromMilliseconds(4), .awake) catch {};
    }
}

// ── Tests ──────────────────────────────────────────────────────────

fn fpOf(comptime T: type) u64 {
    return comptime typeFingerprint(T);
}

test "typeFingerprint: stable for equal shapes, sensitive to fields, types and order" {
    const A = struct { a: i32, b: [4]u8, c: ?u16 };
    const A2 = struct { a: i32, b: [4]u8, c: ?u16 };
    const B = struct { a: i32, b: [4]u8, c: ?u32 };
    const C = struct { b: [4]u8, a: i32, c: ?u16 };
    const D = struct { a: i32, b: [5]u8, c: ?u16 };
    const E = struct { a: i32, b: [4]u8, c: ?u16, d: bool };
    try std.testing.expect(fpOf(A) != fpOf(A2)); // @typeName differs per declaration
    // The same type always hashes the same.
    try std.testing.expectEqual(fpOf(A), fpOf(A));
    try std.testing.expect(fpOf(A) != fpOf(B));
    try std.testing.expect(fpOf(A) != fpOf(C));
    try std.testing.expect(fpOf(A) != fpOf(D));
    try std.testing.expect(fpOf(A) != fpOf(E));
}

test "typeFingerprint terminates on self-referential types and covers unions / enums" {
    const Node = struct { next: ?*@This(), v: u8, k: union(enum) { a: u8, b: [2]u16 }, e: enum { x, y } };
    _ = fpOf(Node);
    const E1 = enum { a, b };
    const E2 = enum { a, c };
    try std.testing.expect(fpOf(E1) != fpOf(E2));
}
