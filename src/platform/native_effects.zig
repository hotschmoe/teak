//! Declarative-effects service for native hosts (Linux/X11 and Windows): what
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
//!                    (default `~/.config`; Windows `%APPDATA%\teak\<app>\`).
//!                    An empty value deletes the key.
//!   open_file        a native dialog (`file_picker.zig`: `$TEAK_PICKER`,
//!                    zenity or kdialog) on a worker thread; `file_cancelled`
//!                    when cancelled or no picker is installed. The env var
//!                    `TEAK_OPEN=path` bypasses the dialog: every request
//!                    reads that file (lets agents and tests drive the app).
//!                    A Host with its own picker (Win32) answers through
//!                    `openPath`.
//!   download         with `pick = true` a Save As dialog, else written to
//!                    `$TEAK_OUT` (default: the cwd).
//!   clock            the OS wall clock and UTC offset.
//!   query_param      argv `--name=value` (Windows: the command line), else
//!                    env `TEAK_<NAME_UPPER>`.
//!   write_clipboard  logged once and ignored (X11 selections are async);
//!   write_clipboard_image   likewise: the X11 host serves both itself.
//!
//! Results are queued under a mutex and handed out by `poll`; every result
//! owns a small arena that is freed at the next `poll`, which is why result
//! slices stay valid until then.

const std = @import("std");
const builtin = @import("builtin");
const teak = @import("teak");
const file_picker = @import("file_picker.zig");
const x11_data = @import("x11_data.zig");

const is_windows = builtin.os.tag == .windows;

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
    /// A file dialog is open on its worker thread (one at a time).
    dialog_busy: bool = false,
    picker_warned: bool = false,

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
        running = running or self.dialog_busy;
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

    /// Start `e`. Slices inside `e` are copied; nothing is kept by reference.
    pub fn submit(self: *Service, e: Effect) teak.EffectSubmit {
        switch (e) {
            .http => |r| return self.startHttp(r),
            .download => |d| {
                if (d.pick) return self.startDialog(.save, d.id, "", d.title, d.name, d.bytes);
                const ok = writeDownload(self.io, d.name, d.bytes);
                self.finish(.{ .downloaded = .{ .id = d.id, .ok = ok } });
            },
            .open_file => |o| {
                if (envValue("TEAK_OPEN") != null) {
                    self.openPath(o.id, envValue("TEAK_OPEN"));
                } else return self.startDialog(.open, o.id, o.accept, o.title, "", "");
            },
            .write_clipboard, .write_clipboard_image => {
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

    const DialogJob = struct {
        service: *Service,
        arena: *std.heap.ArenaAllocator,
        kind: file_picker.Kind,
        id: u32,
        accept: []const u8,
        title: []const u8,
        name: []const u8,
        bytes: []const u8,
    };

    fn startDialog(self: *Service, kind: file_picker.Kind, id: u32, accept: []const u8, title: []const u8, name: []const u8, bytes: []const u8) teak.EffectSubmit {
        self.lock();
        if (self.dialog_busy) {
            self.unlock();
            return .busy; // one dialog at a time; the runtime retries next frame
        }
        self.dialog_busy = true;
        self.unlock();

        const arena = newArena() orelse return self.dialogFailed(null);
        const a = arena.allocator();
        const job = a.create(DialogJob) catch return self.dialogFailed(arena);
        job.* = .{
            .service = self,
            .arena = arena,
            .kind = kind,
            .id = id,
            .accept = a.dupe(u8, accept) catch return self.dialogFailed(arena),
            .title = a.dupe(u8, title) catch return self.dialogFailed(arena),
            .name = a.dupe(u8, name) catch return self.dialogFailed(arena),
            .bytes = a.dupe(u8, bytes) catch return self.dialogFailed(arena),
        };
        const thread = std.Thread.spawn(.{}, dialogWorker, .{job}) catch return self.dialogFailed(arena);
        thread.detach();
        return .accepted;
    }

    fn dialogFailed(self: *Service, arena: ?*std.heap.ArenaAllocator) teak.EffectSubmit {
        if (arena) |a| freeArena(a);
        self.lock();
        self.dialog_busy = false;
        self.unlock();
        return .busy;
    }

    fn dialogWorker(job: *DialogJob) void {
        const self = job.service;
        defer {
            self.lock();
            self.dialog_busy = false;
            self.unlock();
            freeArena(job.arena);
        }
        const chosen: ?[]u8 = file_picker.pick(gpa, envValue("TEAK_PICKER"), job.kind, job.accept, job.title, job.name) catch |e| blk: {
            if (e == error.NoPicker and !self.picker_warned) {
                self.picker_warned = true;
                warn("teak: no file dialog available (install zenity or kdialog, or set TEAK_OPEN)", .{});
            }
            break :blk null;
        };
        defer if (chosen) |c| gpa.free(c);

        switch (job.kind) {
            .save => {
                const path = chosen orelse return self.finish(.{ .downloaded = .{ .id = job.id, .ok = false } });
                const ok = if (Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = job.bytes })) |_| true else |e| blk: {
                    warn("teak: save {s}: {s}", .{ path, @errorName(e) });
                    break :blk false;
                };
                self.finish(.{ .downloaded = .{ .id = job.id, .ok = ok } });
            },
            .open => {
                const path = chosen orelse return self.finish(.{ .file_cancelled = .{ .id = job.id } });
                const arena = newArena() orelse return self.finish(.{ .file_cancelled = .{ .id = job.id } });
                const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, arena.allocator(), .limited(max_body_bytes)) catch |e| {
                    warn("teak: open {s}: {s}", .{ path, @errorName(e) });
                    freeArena(arena);
                    return self.finish(.{ .file_cancelled = .{ .id = job.id } });
                };
                const name = std.fs.path.basename(path);
                const name_copy = arena.allocator().dupe(u8, name) catch name;
                self.push(arena, .{ .file_opened = .{ .id = job.id, .name = name_copy, .mime = mimeFromName(name_copy), .bytes = bytes } });
            },
        }
    }

    /// Answer open request `id` with the file at `path` (null: the user
    /// cancelled, or there is no picker).
    pub fn openPath(self: *Service, id: u32, path_or_null: ?[]const u8) void {
        const path = path_or_null orelse return self.finish(.{ .file_cancelled = .{ .id = id } });
        const arena = newArena() orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, arena.allocator(), .limited(max_body_bytes)) catch |e| {
            warn("teak: open {s}: {s}", .{ path, @errorName(e) });
            freeArena(arena);
            return self.finish(.{ .file_cancelled = .{ .id = id } });
        };
        const name = std.fs.path.basename(path);
        self.push(arena, .{ .file_opened = .{ .id = id, .name = name, .mime = mimeFromName(name), .bytes = bytes } });
    }

    /// Write `bytes` to the exact `path` the user picked and answer
    /// download request `id`.
    pub fn downloadTo(self: *Service, id: u32, path: []const u8, bytes: []const u8) void {
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch |e| {
            warn("teak: download {s}: {s}", .{ path, @errorName(e) });
            return self.finish(.{ .downloaded = .{ .id = id, .ok = false } });
        };
        self.finish(.{ .downloaded = .{ .id = id, .ok = true } });
    }

    /// Answer download request `id` as failed (the user cancelled the picker).
    pub fn downloadCancelled(self: *Service, id: u32) void {
        self.finish(.{ .downloaded = .{ .id = id, .ok = false } });
    }

    /// Report a file dropped on the window: read it and queue an unsolicited
    /// `dropped` result. Unreadable or oversized files are ignored.
    pub fn dropFile(self: *Service, path: []const u8) void {
        const arena = newArena() orelse return;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, arena.allocator(), .limited(max_body_bytes)) catch |e| {
            warn("teak: drop {s}: {s}", .{ path, @errorName(e) });
            return freeArena(arena);
        };
        const name = std.fs.path.basename(path);
        const mime = mimeFromName(name);
        const is_image = std.mem.eql(u8, mime, "image/png") or std.mem.eql(u8, mime, "image/jpeg");
        const size = if (is_image) x11_data.pngSize(bytes) else null;
        self.push(arena, .{ .dropped = .{
            .kind = if (is_image) .image else .file,
            .name = name,
            .mime = mime,
            .bytes = bytes,
            .width = if (size) |sz| sz.w else 0,
            .height = if (size) |sz| sz.h else 0,
        } });
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
        const cmdline = if (is_windows)
            windowsCmdline(a) catch ""
        else
            selfCmdline(self.io, a);
        const value: ?[]const u8 = argValue(cmdline, name) orelse blk: {
            var env_buf: [128]u8 = undefined;
            const env_name = envVarName(&env_buf, name) orelse break :blk null;
            break :blk envValue(env_name);
        };
        self.push(arena, .{ .query_value = .{ .id = id, .value = value } });
    }
};

/// This process's argv as a NUL-separated buffer (`/proc/self/cmdline` on
/// Linux; rebuilt from `_NSGetArgv` on macOS, which has no procfs).
fn selfCmdline(io: Io, a: std.mem.Allocator) []const u8 {
    if (builtin.os.tag == .macos) {
        const argc = _NSGetArgc().*;
        const argv = _NSGetArgv().*;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < argc) : (i += 1) {
            out.appendSlice(a, std.mem.span(argv[i])) catch return "";
            out.append(a, 0) catch return "";
        }
        return out.items;
    }
    return Io.Dir.cwd().readFileAlloc(io, "/proc/self/cmdline", a, .limited(1 << 20)) catch "";
}
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

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
    const sep = std.fs.path.sep;
    w.print("{c}teak{c}{f}{c}{f}", .{ sep, sep, EscapedName{ .name = app_name }, sep, EscapedName{ .name = key } }) catch return null;
    return buf[0 .. base.len + w.buffered().len];
}

/// `$XDG_CONFIG_HOME`, else `$HOME/.config`, written into `buf`. Windows:
/// `%APPDATA%` (Roaming app data).
fn configDir(buf: []u8) ?[]const u8 {
    if (is_windows) {
        const appdata = envValue("APPDATA") orelse return null;
        if (appdata.len > buf.len) return null;
        @memcpy(buf[0..appdata.len], appdata);
        return buf[0..appdata.len];
    }
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

/// True when the environment variable `name` is set and non-empty.
pub fn envSet(name: [:0]const u8) bool {
    return envValue(name) != null;
}

/// Windows reads the process environment as UTF-16 (the CRT's `getenv` is
/// ANSI and misses non-ASCII profile paths); results live in a small
/// per-thread ring so a few lookups can be held at once.
threadlocal var env_ring: [4][2048]u8 = undefined;
threadlocal var env_next: usize = 0;

fn envValue(name: [:0]const u8) ?[]const u8 {
    if (is_windows) {
        var wname: [128]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wname, name) catch return null;
        if (n >= wname.len) return null;
        wname[n] = 0;
        var wval: [2048]u16 = undefined;
        const len = win.GetEnvironmentVariableW(@ptrCast(&wname), &wval, wval.len);
        if (len == 0 or len >= wval.len) return null;
        const slot = &env_ring[env_next % env_ring.len];
        env_next +%= 1;
        const m = std.unicode.utf16LeToUtf8(slot, wval[0..len]) catch return null;
        return if (m == 0) null else slot[0..m];
    }
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// The few kernel32 calls the Windows build needs.
const win = struct {
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
    extern "kernel32" fn GetTimeZoneInformation(info: *TimeZoneInformation) callconv(.winapi) u32;

    const SystemTime = extern struct {
        year: u16,
        month: u16,
        day_of_week: u16,
        day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        millis: u16,
    };
    const TimeZoneInformation = extern struct {
        bias: i32,
        standard_name: [32]u16,
        standard_date: SystemTime,
        standard_bias: i32,
        daylight_name: [32]u16,
        daylight_date: SystemTime,
        daylight_bias: i32,
    };
};

/// The process command line as NUL-separated UTF-8 arguments (the shape
/// `argValue` reads), split with the usual Windows quoting: a double-quoted
/// run is one argument, whitespace separates the rest.
fn windowsCmdline(a: std.mem.Allocator) ![]const u8 {
    const wide = std.mem.span(win.GetCommandLineW());
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(a, wide);
    return splitCommandLine(a, utf8);
}

fn splitCommandLine(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_quotes = false;
    var in_arg = false;
    for (line) |ch| {
        if (ch == '"') {
            in_quotes = !in_quotes;
            in_arg = true;
        } else if ((ch == ' ' or ch == '\t') and !in_quotes) {
            if (in_arg) try out.append(a, 0);
            in_arg = false;
        } else {
            try out.append(a, ch);
            in_arg = true;
        }
    }
    if (in_arg) try out.append(a, 0);
    return out.toOwnedSlice(a);
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
const Tm = if (is_windows) void else extern struct {
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
const localtime_r = if (is_windows) {} else struct {
    extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
}.localtime_r;

fn utcOffsetMinutes(unix_secs: i64) i32 {
    if (is_windows) {
        // Windows bias is the number of minutes added to local time for UTC.
        var info: win.TimeZoneInformation = undefined;
        const id = win.GetTimeZoneInformation(&info);
        const extra: i32 = switch (id) {
            1 => info.standard_bias,
            2 => info.daylight_bias,
            else => 0,
        };
        return -(info.bias + extra);
    }
    var tm: Tm = undefined;
    if (localtime_r(&unix_secs, &tm) == null) return 0;
    return @intCast(@divTrunc(tm.gmtoff, 60));
}

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
        while (n < req.len) {
            const got = std.c.read(conn, req[n..].ptr, req.len - n);
            if (got <= 0) return;
            n += @intCast(got);
            const head_end = std.mem.find(u8, req[0..n], "\r\n\r\n") orelse continue;
            const want = contentLength(req[0..head_end]);
            if (n >= head_end + 4 + want) break;
        }
        if (self.mode == .silent) {
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

const posix_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setEnv(name: [:0]const u8, value: [:0]const u8) void {
    if (is_windows) {
        var wname: [64]u16 = undefined;
        var wvalue: [512]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wname, name) catch unreachable;
        wname[n] = 0;
        const v = std.unicode.utf8ToUtf16Le(&wvalue, value) catch unreachable;
        wvalue[v] = 0;
        _ = win.SetEnvironmentVariableW(@ptrCast(&wname), @ptrCast(&wvalue));
    } else _ = posix_env.setenv(name, value, 1);
}
fn unsetEnv(name: [:0]const u8) void {
    if (is_windows) {
        var wname: [64]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wname, name) catch unreachable;
        wname[n] = 0;
        _ = win.SetEnvironmentVariableW(@ptrCast(&wname), null);
    } else _ = posix_env.unsetenv(name);
}

/// Write an executable picker script that records its argv in `<dir>/argv`
/// and prints `choice` (nothing when empty), exiting `code`.
fn writePickerScript(dir: []const u8, choice: []const u8, code: u8) !void {
    const io = std.Options.debug_io;
    try Io.Dir.cwd().createDirPath(io, dir);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/picker.sh", .{dir});
    var body: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&body, "#!/bin/sh\nprintf '%s\\n' \"$@\" > {s}/argv\n[ -n '{s}' ] && echo '{s}'\nexit {d}\n", .{ dir, choice, choice, code });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text, .flags = .{ .permissions = .executable_file } });
}
