//! Declarative-effects service for native hosts (Linux/X11 today): what
//! `Host.submit` / `Host.pollEffectResults` stand on. See
//! docs/features/effects.md for the contract; this file is the native half.
//!
//!   http             `std.http.Client` (TLS) on a short-lived worker thread
//!                    per request, at most `max_jobs` at once; the frame loop
//!                    never blocks. The timeout is enforced at poll time: at
//!                    the deadline the app gets status 0 / "timeout after N
//!                    ms" and the worker's late answer is discarded (std's
//!                    client has no socket timeout, so a stuck connect lingers
//!                    on its own thread until the OS gives up).
//!   storage_*        one file per key under `$XDG_CONFIG_HOME/teak/<app>/`
//!                    (default `~/.config`). An empty value deletes the key.
//!   download         written to `$TEAK_OUT` (default: the cwd).
//!   open_file        there is no dialog: `file_cancelled`, unless the env var
//!                    `TEAK_OPEN=path` names a file, which every request then
//!                    reads (lets agents and tests drive the app).
//!   clock            the OS wall clock and UTC offset.
//!   query_param      argv `--name=value`, else env `TEAK_<NAME_UPPER>`.
//!   write_clipboard  logged once and ignored (X11 selections are async).
//!
//! Results are queued under a mutex and handed out by `poll`; every result
//! owns a small arena that is freed at the next `poll`, which is why result
//! slices stay valid until then.

const std = @import("std");
const teak = @import("teak");

const Effect = teak.Effect;
const EffectResult = teak.EffectResult;
const Io = std.Io;

pub const max_jobs = 8;
/// Largest response body / file taken.
pub const max_body_bytes: usize = 32 * 1024 * 1024;

const gpa = std.heap.page_allocator;

/// `std.log.warn`, silent in tests (the build runner reports any stderr
/// output of a test binary as a failure).
fn warn(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) return;
    std.log.warn(fmt, args);
}

/// A finished result and the arena that owns its slices.
const Pending = struct {
    arena: *std.heap.ArenaAllocator,
    result: EffectResult,
};

const Job = struct {
    /// 0 = free slot.
    id: u32 = 0,
    deadline_ms: u64 = 0,
    timeout_ms: u32 = 0,
    /// The deadline passed and the app was told; the worker frees its own
    /// result when it finishes.
    abandoned: bool = false,
};

pub const Service = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    app_name: []u8,
    pending: std.ArrayList(Pending) = .empty,
    delivered: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    jobs: [max_jobs]Job = @splat(.{}),
    clipboard_warned: bool = false,

    /// `app_name` (usually the window title) names the storage directory; it
    /// is reduced to a lowercase slug.
    pub fn create(app_name: []const u8) !*Service {
        const self = try gpa.create(Service);
        errdefer gpa.destroy(self);
        self.* = .{ .io = std.Options.debug_io, .app_name = try slug(app_name) };
        return self;
    }

    /// Rename the storage directory (`RunOptions.app_name`).
    pub fn setAppName(self: *Service, app_name: []const u8) !void {
        const name = try slug(app_name);
        self.lock();
        defer self.unlock();
        gpa.free(self.app_name);
        self.app_name = name;
    }

    /// Free everything. Workers still running (a connect that has not given
    /// up) keep the Service alive: it is leaked rather than freed under them.
    pub fn destroy(self: *Service) void {
        self.lock();
        var running = false;
        for (self.jobs) |j| running = running or j.id != 0;
        self.unlock();
        if (running) return;
        self.releaseDelivered();
        for (self.pending.items) |p| freeArena(p.arena);
        self.pending.deinit(gpa);
        self.delivered.deinit(gpa);
        gpa.free(self.app_name);
        gpa.destroy(self);
    }

    fn lock(self: *Service) void {
        self.mutex.lockUncancelable(self.io);
    }
    fn unlock(self: *Service) void {
        self.mutex.unlock(self.io);
    }

    // ── Submit ──────────────────────────────────────────────────────

    /// Start `e`. Slices inside `e` are copied; nothing is kept by reference.
    pub fn submit(self: *Service, e: Effect) teak.EffectSubmit {
        switch (e) {
            .http => |r| return self.startHttp(r),
            .download => |d| {
                const ok = writeDownload(self.io, d.name, d.bytes);
                self.finish(.{ .downloaded = .{ .id = d.id, .ok = ok } });
            },
            .open_file => |o| self.openFile(o.id),
            // The X11 host intercepts this before it reaches the service
            // (it owns the selection); any other embedder gets a one-time note.
            .write_clipboard => {
                if (!self.clipboard_warned) {
                    self.clipboard_warned = true;
                    warn("teak: write_clipboard is not handled by this host; ignored", .{});
                }
            },
            .storage_set => |s| self.storageSet(s.key, s.value),
            .storage_get => |g| self.storageGet(g.id, g.key),
            .clock => |c| self.clock(c.id),
            .query_param => |q| self.queryParam(q.id, q.name),
        }
        return .accepted;
    }

    /// A fresh arena for a result's slices (null on OOM).
    pub fn newArena() ?*std.heap.ArenaAllocator {
        const a = gpa.create(std.heap.ArenaAllocator) catch return null;
        a.* = .init(gpa);
        return a;
    }

    pub fn freeArena(a: *std.heap.ArenaAllocator) void {
        a.deinit();
        gpa.destroy(a);
    }

    /// Queue a result whose slices live in `arena` (null: the result has none).
    pub fn push(self: *Service, arena: ?*std.heap.ArenaAllocator, r: EffectResult) void {
        const a = arena orelse newArena() orelse return;
        self.lock();
        defer self.unlock();
        self.pending.append(gpa, .{ .arena = a, .result = r }) catch freeArena(a);
    }

    /// Queue a result that borrows nothing.
    fn finish(self: *Service, r: EffectResult) void {
        self.push(null, r);
    }

    // ── Poll ────────────────────────────────────────────────────────

    /// Fill `buf` with the results that are ready; returns the count. The
    /// slices stay valid until the next `poll`.
    pub fn poll(self: *Service, buf: []EffectResult, now_ms: u64) usize {
        self.lock();
        defer self.unlock();
        self.releaseDelivered();
        self.expireJobs(now_ms);

        const n = @min(buf.len, self.pending.items.len);
        for (self.pending.items[0..n], 0..) |p, i| {
            buf[i] = p.result;
            self.delivered.append(gpa, p.arena) catch freeArena(p.arena);
        }
        std.mem.copyForwards(Pending, self.pending.items[0 .. self.pending.items.len - n], self.pending.items[n..]);
        self.pending.shrinkRetainingCapacity(self.pending.items.len - n);
        return n;
    }

    fn releaseDelivered(self: *Service) void {
        for (self.delivered.items) |a| freeArena(a);
        self.delivered.clearRetainingCapacity();
    }

    /// Answer requests whose deadline passed. Called with the lock held.
    fn expireJobs(self: *Service, now_ms: u64) void {
        for (&self.jobs) |*j| {
            if (j.id == 0 or j.abandoned or now_ms < j.deadline_ms) continue;
            j.abandoned = true;
            const a = newArena() orelse continue;
            const err = std.fmt.allocPrint(a.allocator(), "timeout after {d} ms", .{j.timeout_ms}) catch "timeout";
            self.pending.append(gpa, .{ .arena = a, .result = .{ .http = .{ .id = j.id, .status = 0, .err = err } } }) catch freeArena(a);
        }
    }

    // ── HTTP ────────────────────────────────────────────────────────

    const HttpJob = struct {
        service: *Service,
        slot: usize,
        arena: *std.heap.ArenaAllocator,
        id: u32,
        method: std.http.Method,
        url: []const u8,
        headers: []std.http.Header,
        body: []const u8,
    };

    fn startHttp(self: *Service, r: teak.HttpRequest) teak.EffectSubmit {
        const arena = newArena() orelse return .busy;
        const a = arena.allocator();
        const job = a.create(HttpJob) catch {
            freeArena(arena);
            return .busy;
        };
        const copied = copyRequest(a, r) catch {
            freeArena(arena);
            return .busy;
        };
        job.* = .{ .service = self, .slot = 0, .arena = arena, .id = r.id, .method = copied.method, .url = copied.url, .headers = copied.headers, .body = copied.body };

        self.lock();
        const slot = for (&self.jobs, 0..) |*j, i| {
            if (j.id == 0) break i;
        } else null;
        if (slot) |i| self.jobs[i] = .{
            .id = r.id,
            .deadline_ms = nowMs(self.io) + r.timeout_ms,
            .timeout_ms = r.timeout_ms,
        };
        self.unlock();
        const i = slot orelse {
            freeArena(arena);
            return .busy;
        };
        job.slot = i;

        const thread = std.Thread.spawn(.{}, httpWorker, .{job}) catch {
            self.lock();
            self.jobs[i] = .{};
            self.unlock();
            freeArena(arena);
            return .busy;
        };
        thread.detach();
        return .accepted;
    }

    const Copied = struct { method: std.http.Method, url: []const u8, headers: []std.http.Header, body: []const u8 };

    fn copyRequest(a: std.mem.Allocator, r: teak.HttpRequest) !Copied {
        const headers = try a.alloc(std.http.Header, r.headers.len);
        for (r.headers, headers) |h, *out| out.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        return .{
            .method = switch (r.method) {
                .get => .GET,
                .post => .POST,
                .put => .PUT,
                .delete => .DELETE,
            },
            .url = try a.dupe(u8, r.url),
            .headers = headers,
            .body = try a.dupe(u8, r.body),
        };
    }

    fn httpWorker(job: *HttpJob) void {
        const self = job.service;
        const a = job.arena.allocator();

        var failure: []const u8 = "";
        var status: u16 = 0;
        var body: []const u8 = "";
        if (fetch(self.io, a, job)) |res| {
            status = res.status;
            body = res.body;
        } else |e| {
            failure = std.fmt.allocPrint(a, "{s}", .{describeError(e)}) catch "network error";
        }

        self.lock();
        const abandoned = self.jobs[job.slot].abandoned;
        self.jobs[job.slot] = .{};
        if (!abandoned) {
            self.pending.append(gpa, .{
                .arena = job.arena,
                .result = .{ .http = .{ .id = job.id, .status = status, .body = body, .err = failure } },
            }) catch {};
        }
        const dropped = abandoned;
        self.unlock();
        if (dropped) freeArena(job.arena);
    }

    const Fetched = struct { status: u16, body: []const u8 };

    fn fetch(io: Io, a: std.mem.Allocator, job: *const HttpJob) !Fetched {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        var out: Io.Writer.Allocating = .init(a);
        const res = try client.fetch(.{
            .location = .{ .url = job.url },
            .method = job.method,
            .payload = if (job.body.len > 0 or job.method == .POST or job.method == .PUT) job.body else null,
            .extra_headers = job.headers,
            .response_writer = &out.writer,
            .keep_alive = false,
        });
        if (out.written().len > max_body_bytes) return error.ResponseTooLarge;
        return .{ .status = @backingInt(res.status), .body = out.written() };
    }

    // ── Storage, download, open, clock, query ───────────────────────

    fn storageSet(self: *Service, key: []const u8, value: []const u8) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = storagePath(&path_buf, self.app_name, key) orelse return;
        const dir = std.fs.path.dirname(path) orelse return;
        if (value.len == 0) {
            Io.Dir.cwd().deleteFile(self.io, path) catch {};
            return;
        }
        Io.Dir.cwd().createDirPath(self.io, dir) catch |e| return warn("teak: storage dir {s}: {s}", .{ dir, @errorName(e) });
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = value }) catch |e|
            warn("teak: storage write {s}: {s}", .{ path, @errorName(e) });
    }

    fn storageGet(self: *Service, id: u32, key: []const u8) void {
        const arena = newArena() orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const value: ?[]const u8 = if (storagePath(&path_buf, self.app_name, key)) |path|
            Io.Dir.cwd().readFileAlloc(self.io, path, arena.allocator(), .limited(max_body_bytes)) catch null
        else
            null;
        self.push(arena, .{ .storage_value = .{ .id = id, .value = value } });
    }

    fn openFile(self: *Service, id: u32) void {
        const path = envValue("TEAK_OPEN") orelse return self.finish(.{ .file_cancelled = .{ .id = id } });
        const arena = newArena() orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, arena.allocator(), .limited(max_body_bytes)) catch |e| {
            warn("teak: TEAK_OPEN={s}: {s}", .{ path, @errorName(e) });
            freeArena(arena);
            return self.finish(.{ .file_cancelled = .{ .id = id } });
        };
        const name = std.fs.path.basename(path);
        self.push(arena, .{ .file_opened = .{ .id = id, .name = name, .mime = mimeFromName(name), .bytes = bytes } });
    }

    fn clock(self: *Service, id: u32) void {
        const now = Io.Clock.real.now(self.io);
        const secs: i64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
        self.finish(.{ .clock = .{
            .id = id,
            .unix_ms = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms)),
            .utc_offset_min = utcOffsetMinutes(secs),
        } });
    }

    fn queryParam(self: *Service, id: u32, name: []const u8) void {
        const arena = newArena() orelse return;
        const a = arena.allocator();
        const cmdline = Io.Dir.cwd().readFileAlloc(self.io, "/proc/self/cmdline", a, .limited(1 << 20)) catch "";
        const value: ?[]const u8 = argValue(cmdline, name) orelse blk: {
            var env_buf: [128]u8 = undefined;
            const env_name = envVarName(&env_buf, name) orelse break :blk null;
            break :blk envValue(env_name);
        };
        self.push(arena, .{ .query_value = .{ .id = id, .value = value } });
    }
};

// ── Pure helpers ────────────────────────────────────────────────────

/// "Kerf CAD (beta)" -> "kerf-cad-beta": lowercase letters and digits, runs
/// of anything else become one '-', no leading / trailing '-'; "app" if
/// nothing is left. Caller frees.
fn slug(name: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(gpa, std.ascii.toLower(c));
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
            try out.append(gpa, '-');
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(gpa, "app");
    return out.toOwnedSlice(gpa);
}

fn nowMs(io: Io) u64 {
    const now = Io.Clock.awake.now(io);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}

/// A user-facing reason for a failed request.
fn describeError(e: anyerror) []const u8 {
    return switch (e) {
        error.ResponseTooLarge => "response too large",
        error.UnknownHostName, error.TemporaryNameServerFailure, error.NameServerFailure => "network error: unknown host",
        error.ConnectionRefused => "network error: connection refused",
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => "network error: TLS failure",
        error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidFormat, error.InvalidPort => "invalid URL",
        else => "network error",
    };
}

/// Where the value of `key` lives: `<config>/teak/<app>/<escaped key>`.
/// Null for an empty key or when no config dir can be found.
fn storagePath(buf: []u8, app_name: []const u8, key: []const u8) ?[]const u8 {
    if (key.len == 0) return null;
    const base = configDir(buf[0 .. std.fs.max_path_bytes / 2]) orelse return null;
    var w: Io.Writer = .fixed(buf[base.len..]);
    w.print("/teak/{f}/{f}", .{ EscapedName{ .name = app_name }, EscapedName{ .name = key } }) catch return null;
    return buf[0 .. base.len + w.buffered().len];
}

/// `$XDG_CONFIG_HOME`, else `$HOME/.config`, written into `buf`.
fn configDir(buf: []u8) ?[]const u8 {
    if (envValue("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0 and x.len <= buf.len) {
            @memcpy(buf[0..x.len], x);
            return buf[0..x.len];
        }
    }
    const home = envValue("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config", .{home}) catch null;
}

/// A name made safe for one path component: letters, digits and `._-` stay,
/// everything else becomes `%XX`; a leading dot is escaped too.
const EscapedName = struct {
    name: []const u8,

    pub fn format(self: EscapedName, w: *Io.Writer) Io.Writer.Error!void {
        for (self.name, 0..) |c, i| {
            const plain = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or (c == '.' and i > 0);
            if (plain) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
        }
    }
};

fn envValue(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// `TEAK_<NAME_UPPER>`: letters and digits upper-cased, everything else `_`.
fn envVarName(buf: []u8, name: []const u8) ?[:0]const u8 {
    const prefix = "TEAK_";
    if (prefix.len + name.len + 1 > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    for (name, 0..) |c, i| buf[prefix.len + i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_';
    buf[prefix.len + name.len] = 0;
    return buf[0 .. prefix.len + name.len :0];
}

/// The value of `--name=value` in a NUL-separated `/proc/self/cmdline`.
fn argValue(cmdline: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cmdline, 0);
    while (it.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        const rest = arg[2..];
        if (rest.len > name.len and std.mem.startsWith(u8, rest, name) and rest[name.len] == '=') return rest[name.len + 1 ..];
    }
    return null;
}

/// Write a download into `$TEAK_OUT` (default the cwd) under the base name of
/// `name`. False when the name is unusable or the write fails.
fn writeDownload(io: Io, name: []const u8, bytes: []const u8) bool {
    const base = std.fs.path.basename(name);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (envValue("TEAK_OUT")) |dir| blk: {
        Io.Dir.cwd().createDirPath(io, dir) catch return false;
        break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, base }) catch return false;
    } else base;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |e| {
        warn("teak: download {s}: {s}", .{ path, @errorName(e) });
        return false;
    };
    return true;
}

pub fn mimeFromName(name: []const u8) []const u8 {
    const table = [_]struct { ext: []const u8, mime: []const u8 }{
        .{ .ext = ".json", .mime = "application/json" },
        .{ .ext = ".txt", .mime = "text/plain" },
        .{ .ext = ".md", .mime = "text/markdown" },
        .{ .ext = ".csv", .mime = "text/csv" },
        .{ .ext = ".dxf", .mime = "image/vnd.dxf" },
        .{ .ext = ".png", .mime = "image/png" },
        .{ .ext = ".jpg", .mime = "image/jpeg" },
        .{ .ext = ".jpeg", .mime = "image/jpeg" },
        .{ .ext = ".svg", .mime = "image/svg+xml" },
        .{ .ext = ".pdf", .mime = "application/pdf" },
    };
    const ext = std.fs.path.extension(name);
    for (table) |t| if (std.ascii.eqlIgnoreCase(ext, t.ext)) return t.mime;
    return "application/octet-stream";
}

/// glibc / musl `struct tm` (the part `localtime_r` fills).
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

fn utcOffsetMinutes(unix_secs: i64) i32 {
    var tm: Tm = undefined;
    if (localtime_r(&unix_secs, &tm) == null) return 0;
    return @intCast(@divTrunc(tm.gmtoff, 60));
}

// ── Tests ───────────────────────────────────────────────────────────

test "slug makes a directory name from a window title" {
    for ([_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "Kerf CAD (beta)", .out = "kerf-cad-beta" },
        .{ .in = "  --  ", .out = "app" },
        .{ .in = "", .out = "app" },
        .{ .in = "chrome", .out = "chrome" },
    }) |c| {
        const got = try slug(c.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "EscapedName keeps plain names and escapes the rest" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}|{f}|{f}", .{ EscapedName{ .name = "kerf.note-1_a" }, EscapedName{ .name = "../etc/x y" }, EscapedName{ .name = ".hidden" } });
    try std.testing.expectEqualStrings("kerf.note-1_a|%2E.%2Fetc%2Fx%20y|%2Ehidden", w.buffered());
}

test "storagePath is under the config dir and refuses an empty key" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(storagePath(&buf, "kerf", "") == null);
    const p = storagePath(&buf, "my app", "doc/1") orelse return; // no HOME in this environment
    try std.testing.expect(std.mem.endsWith(u8, p, "/teak/my%20app/doc%2F1"));
}

test "argValue finds --name=value only as a whole name" {
    const cmd = "prog\x00--who=ada\x00--whoever=x\x00--api=http://h:1/\x00positional\x00";
    try std.testing.expectEqualStrings("ada", argValue(cmd, "who").?);
    try std.testing.expectEqualStrings("http://h:1/", argValue(cmd, "api").?);
    try std.testing.expect(argValue(cmd, "who2") == null);
    try std.testing.expect(argValue(cmd, "missing") == null);
    try std.testing.expect(argValue("--flag\x00", "flag") == null);
}

test "envVarName upper-cases and replaces punctuation" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("TEAK_API_BASE", envVarName(&buf, "api-base").?);
    try std.testing.expectEqualStrings("TEAK_WHO", envVarName(&buf, "who").?);
}

test "mimeFromName" {
    try std.testing.expectEqualStrings("application/json", mimeFromName("a.JSON"));
    try std.testing.expectEqualStrings("image/png", mimeFromName("shot.png"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFromName("noext"));
}

test "describeError gives a reason a person can act on" {
    try std.testing.expectEqualStrings("network error: connection refused", describeError(error.ConnectionRefused));
    try std.testing.expectEqualStrings("invalid URL", describeError(error.UnsupportedUriScheme));
}

// ── Local server for the round-trip tests (libc sockets) ────────────

const TestServer = struct {
    fd: c_int,
    port: u16,
    /// What to do with the one connection it accepts.
    mode: enum { echo, silent },
    thread: ?std.Thread = null,

    fn start(mode: @TypeOf(@as(TestServer, undefined).mode)) !*TestServer {
        const self = try gpa.create(TestServer);
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
        if (std.c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.NameFailed;
        self.* = .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port), .mode = mode };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *TestServer) void {
        // Unblock a server still waiting in accept, then join.
        if (self.thread) |t| {
            var addr: std.c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, self.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
            const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
            _ = std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
            _ = std.c.close(fd);
            t.join();
        }
        _ = std.c.close(self.fd);
        gpa.destroy(self);
    }

    fn serve(self: *TestServer) void {
        const conn = std.c.accept(self.fd, null, null);
        if (conn < 0) return;
        defer _ = std.c.close(conn);
        var req: [4096]u8 = undefined;
        var n: usize = 0;
        // Read the head, then the body announced by Content-Length.
        while (n < req.len) {
            const got = std.c.read(conn, req[n..].ptr, req.len - n);
            if (got <= 0) return;
            n += @intCast(got);
            const head_end = std.mem.find(u8, req[0..n], "\r\n\r\n") orelse continue;
            const want = contentLength(req[0..head_end]);
            if (n >= head_end + 4 + want) break;
        }
        if (self.mode == .silent) {
            // Say nothing for longer than the test's timeout, then hang up.
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 700 * std.time.ns_per_ms }, null);
            return;
        }
        const head_end = std.mem.find(u8, req[0..n], "\r\n\r\n").? + 4;
        var out: [1024]u8 = undefined;
        const first_line = req[0..std.mem.findScalar(u8, req[0..n], '\r').?];
        const body = std.fmt.bufPrint(out[200..], "{s}|{s}|{d}", .{ first_line, headerValue(req[0..head_end], "x-test") orelse "-", n - head_end }) catch return;
        const head = std.fmt.bufPrint(out[0..200], "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
        _ = std.c.write(conn, head.ptr, head.len);
        _ = std.c.write(conn, body.ptr, body.len);
    }

    fn contentLength(head: []const u8) usize {
        const v = headerValue(head, "content-length") orelse return 0;
        return std.fmt.parseInt(usize, v, 10) catch 0;
    }

    fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, head, "\r\n");
        _ = it.next();
        while (it.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }
};

/// Poll until one result arrives (or ~5 s pass).
fn waitOne(svc: *Service, out: *EffectResult) !void {
    var buf: [4]EffectResult = undefined;
    for (0..1000) |_| {
        if (svc.poll(&buf, nowMs(svc.io)) > 0) {
            out.* = buf[0];
            return;
        }
        std.Io.sleep(svc.io, .fromMilliseconds(5), .awake) catch {};
    }
    return error.NoResult;
}

test "http: a POST round-trips with its body and headers, off the calling thread" {
    const server = try TestServer.start(.echo);
    defer server.stop();
    const svc = try Service.create("test");
    defer svc.destroy();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/echo", .{server.port});
    const headers = [_]teak.Header{.{ .name = "x-test", .value = "yes" }};
    try std.testing.expectEqual(teak.EffectSubmit.accepted, svc.submit(.{ .http = .{ .id = 7, .method = .post, .url = url, .headers = &headers, .body = "hello" } }));

    var r: EffectResult = undefined;
    try waitOne(svc, &r);
    try std.testing.expectEqual(@as(u32, 7), r.http.id);
    try std.testing.expectEqual(@as(u16, 200), r.http.status);
    try std.testing.expectEqualStrings("POST /echo HTTP/1.1|yes|5", r.http.body);
    try std.testing.expectEqualStrings("", r.http.err);
}

test "http: a refused connection is status 0 with a reason" {
    const server = try TestServer.start(.echo);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.port});
    server.stop(); // nothing listens on that port any more
    const svc = try Service.create("test");
    defer svc.destroy();

    _ = svc.submit(.{ .http = .{ .id = 1, .url = url } });
    var r: EffectResult = undefined;
    try waitOne(svc, &r);
    try std.testing.expectEqual(@as(u16, 0), r.http.status);
    try std.testing.expect(r.http.err.len > 0);
}

test "http: the timeout answers at the deadline and the late reply is dropped" {
    const server = try TestServer.start(.silent);
    defer server.stop();
    const svc = try Service.create("test");
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.port});
    _ = svc.submit(.{ .http = .{ .id = 3, .url = url, .timeout_ms = 150 } });
    defer {
        // The abandoned worker finishes once the server hangs up; only then
        // may the Service go (destroy leaves it alone while a worker runs).
        for (0..400) |_| {
            svc.lock();
            const idle = for (svc.jobs) |j| {
                if (j.id != 0) break false;
            } else true;
            svc.unlock();
            if (idle) break;
            std.Io.sleep(svc.io, .fromMilliseconds(5), .awake) catch {};
        }
        svc.destroy();
    }

    var r: EffectResult = undefined;
    try waitOne(svc, &r);
    try std.testing.expectEqual(@as(u16, 0), r.http.status);
    try std.testing.expectEqualStrings("timeout after 150 ms", r.http.err);
}

test "storage: set, get, overwrite, delete" {
    const svc = try Service.create("teak-test-storage");
    defer svc.destroy();
    const cfg = envValue("XDG_CONFIG_HOME") orelse envValue("HOME") orelse return;
    _ = cfg;

    svc.storageSet("note", "one");
    var r: EffectResult = undefined;
    svc.storageGet(1, "note");
    try waitOne(svc, &r);
    try std.testing.expectEqualStrings("one", r.storage_value.value.?);

    svc.storageSet("note", "two");
    svc.storageGet(2, "note");
    try waitOne(svc, &r);
    try std.testing.expectEqualStrings("two", r.storage_value.value.?);

    svc.storageSet("note", ""); // deletes
    svc.storageGet(3, "note");
    try waitOne(svc, &r);
    try std.testing.expect(r.storage_value.value == null);
}

test "clock is plausible" {
    const svc = try Service.create("test");
    defer svc.destroy();
    _ = svc.submit(.{ .clock = .{ .id = 5 } });
    var r: EffectResult = undefined;
    try waitOne(svc, &r);
    try std.testing.expect(r.clock.unix_ms > 1_700_000_000_000);
    try std.testing.expect(@abs(r.clock.utc_offset_min) <= 14 * 60);
}

test "open_file without TEAK_OPEN is cancelled; clipboard and storage_set make no result" {
    if (envValue("TEAK_OPEN") != null) return;
    const svc = try Service.create("test");
    defer svc.destroy();
    _ = svc.submit(.{ .write_clipboard = .{ .id = 1, .text = "x" } });
    _ = svc.submit(.{ .open_file = .{ .id = 2 } });
    var r: EffectResult = undefined;
    try waitOne(svc, &r);
    try std.testing.expectEqual(@as(u32, 2), r.file_cancelled.id);
    var buf: [2]EffectResult = undefined;
    try std.testing.expectEqual(@as(usize, 0), svc.poll(&buf, 0));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setEnv(name: [:0]const u8, value: [:0]const u8) void {
    _ = setenv(name, value, 1);
}
fn unsetEnv(name: [:0]const u8) void {
    _ = unsetenv(name);
}

test "download goes to TEAK_OUT and open_file reads TEAK_OPEN, once per request" {
    const svc = try Service.create("test");
    defer svc.destroy();
    const dir = "/tmp/teak-native-fx-test";
    setEnv("TEAK_OUT", dir);
    defer unsetEnv("TEAK_OUT");

    _ = svc.submit(.{ .download = .{ .id = 1, .name = "../evil/out.json", .mime = "application/json", .bytes = "{\"ok\":1}" } });
    var r: EffectResult = undefined;
    try waitOne(svc, &r);
    try std.testing.expect(r.downloaded.ok);
    // The name is reduced to its base: nothing escapes the output directory.
    setEnv("TEAK_OPEN", dir ++ "/out.json");
    defer unsetEnv("TEAK_OPEN");
    for ([_]u32{ 2, 3 }) |id| {
        _ = svc.submit(.{ .open_file = .{ .id = id } });
        try waitOne(svc, &r);
        try std.testing.expectEqual(id, r.file_opened.id);
        try std.testing.expectEqualStrings("out.json", r.file_opened.name);
        try std.testing.expectEqualStrings("application/json", r.file_opened.mime);
        try std.testing.expectEqualStrings("{\"ok\":1}", r.file_opened.bytes);
    }

    setEnv("TEAK_OPEN", dir ++ "/missing.json");
    _ = svc.submit(.{ .open_file = .{ .id = 4 } });
    try waitOne(svc, &r);
    try std.testing.expectEqual(@as(u32, 4), r.file_cancelled.id);

    try std.testing.expect(!writeDownload(svc.io, "..", "x"));
    try std.testing.expect(!writeDownload(svc.io, "", "x"));
}

test "query_param falls back to TEAK_<NAME> and reports absent ones" {
    const svc = try Service.create("test");
    defer svc.destroy();
    setEnv("TEAK_QP_TEST", "from-env");
    defer unsetEnv("TEAK_QP_TEST");
    var r: EffectResult = undefined;
    _ = svc.submit(.{ .query_param = .{ .id = 1, .name = "qp-test" } });
    try waitOne(svc, &r);
    try std.testing.expectEqualStrings("from-env", r.query_value.value.?);
    _ = svc.submit(.{ .query_param = .{ .id = 2, .name = "qp-not-set" } });
    try waitOne(svc, &r);
    try std.testing.expect(r.query_value.value == null);
}
