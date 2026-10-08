//! Unix-domain-socket transport for the agent control channel
//! (`docs/features/agent-driver.md`): a non-blocking, single-client,
//! line-delimited server that Hosts embed to implement the optional
//! `controlListen` / `controlRecv` / `controlSend` surface, plus a tiny
//! blocking `Client` used by `tools/teak-drive` and the tests.
//!
//! Pure transport. It knows nothing about the protocol (`src/control.zig`
//! owns that) or the App. Linux only (raw syscalls, no libc); on every
//! other OS `Server.listen` returns false and the Host simply reports "no
//! control channel", so the runtime never changes behavior there.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;

/// The OS can host the transport.
pub const supported = builtin.os.tag == .linux;

/// Longest accepted protocol line, bytes. A longer line is dropped whole.
pub const max_line = 16 * 1024;

fn sockaddrUn(path: []const u8) ?linux.sockaddr.un {
    if (path.len == 0 or path.len >= 108) return null;
    var a: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(a.path[0..path.len], path);
    return a;
}

/// Non-blocking line server. At most one client at a time; a new client
/// replaces the previous one once that one disconnects.
pub const Server = struct {
    listen_fd: i32 = -1,
    client_fd: i32 = -1,
    path: [108]u8 = @splat(0),
    path_len: usize = 0,
    inbuf: [max_line]u8 = undefined,
    in_len: usize = 0,
    /// Dropping bytes of an over-long line until its newline.
    discarding: bool = false,

    pub fn isListening(self: *const Server) bool {
        return self.listen_fd >= 0;
    }

    /// Bind + listen at `path` (an existing socket file there is replaced).
    pub fn listen(self: *Server, path: []const u8) bool {
        if (comptime !supported) return false;
        if (self.listen_fd >= 0) return true;
        const addr = sockaddrUn(path) orelse return false;
        var z: [109]u8 = @splat(0);
        @memcpy(z[0..path.len], path);
        _ = linux.unlink(@ptrCast(&z));

        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return false;
        const fd: i32 = @intCast(rc);
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS or
            linux.errno(linux.listen(fd, 1)) != .SUCCESS)
        {
            _ = linux.close(fd);
            return false;
        }
        self.listen_fd = fd;
        @memcpy(self.path[0..path.len], path);
        self.path_len = path.len;
        return true;
    }

    pub fn deinit(self: *Server) void {
        if (comptime !supported) return;
        self.dropClient();
        if (self.listen_fd >= 0) {
            _ = linux.close(self.listen_fd);
            self.listen_fd = -1;
            var z: [109]u8 = @splat(0);
            @memcpy(z[0..self.path_len], self.path[0..self.path_len]);
            _ = linux.unlink(@ptrCast(&z));
        }
    }

    fn dropClient(self: *Server) void {
        if (self.client_fd >= 0) _ = linux.close(self.client_fd);
        self.client_fd = -1;
        self.in_len = 0;
        self.discarding = false;
    }

    /// Copy the next complete line (without its newline) into `out` and
    /// return it, or null when none is ready. Never blocks.
    pub fn recvLine(self: *Server, out: []u8) ?[]u8 {
        if (comptime !supported) return null;
        if (self.listen_fd < 0) return null;
        if (self.client_fd < 0) {
            const rc = linux.accept4(self.listen_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return null;
            self.client_fd = @intCast(rc);
            self.in_len = 0;
            self.discarding = false;
        }
        while (true) {
            if (std.mem.indexOfScalar(u8, self.inbuf[0..self.in_len], '\n')) |nl| {
                const line = self.inbuf[0..nl];
                defer {
                    const rest = self.in_len - (nl + 1);
                    std.mem.copyForwards(u8, self.inbuf[0..rest], self.inbuf[nl + 1 .. self.in_len]);
                    self.in_len = rest;
                }
                if (self.discarding) {
                    self.discarding = false;
                    continue;
                }
                const n = @min(line.len, out.len);
                @memcpy(out[0..n], line[0..n]);
                return out[0..n];
            }
            if (self.in_len == self.inbuf.len) {
                // Over-long line with no newline yet: drop it and keep
                // discarding until its end.
                self.in_len = 0;
                self.discarding = true;
            }
            const rc = linux.read(self.client_fd, self.inbuf[self.in_len..].ptr, self.inbuf.len - self.in_len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) { // peer closed
                        self.dropClient();
                        return null;
                    }
                    if (self.discarding) {
                        if (std.mem.indexOfScalar(u8, self.inbuf[self.in_len..][0..rc], '\n')) |nl| {
                            const rest = rc - (nl + 1);
                            std.mem.copyForwards(u8, self.inbuf[0..rest], self.inbuf[self.in_len + nl + 1 ..][0..rest]);
                            self.in_len = rest;
                            self.discarding = false;
                        }
                        continue;
                    }
                    self.in_len += rc;
                },
                .AGAIN => return null,
                .INTR => continue,
                else => {
                    self.dropClient();
                    return null;
                },
            }
        }
    }

    /// Write `bytes` to the client (all of it, spinning briefly if the
    /// socket buffer is full). Silently dropped without a client.
    pub fn send(self: *Server, bytes: []const u8) void {
        if (comptime !supported) return;
        if (self.client_fd < 0) return;
        var off: usize = 0;
        var spins: u32 = 0;
        while (off < bytes.len) {
            const rc = linux.write(self.client_fd, bytes[off..].ptr, bytes.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .AGAIN, .INTR => {
                    spins += 1;
                    if (spins > 2_000_000) return self.dropClient();
                    std.atomic.spinLoopHint();
                },
                else => return self.dropClient(),
            }
        }
    }
};

/// Blocking client (tools + tests).
pub const Client = struct {
    fd: i32,

    pub fn connect(path: []const u8) !Client {
        if (comptime !supported) return error.Unsupported;
        const addr = sockaddrUn(path) orelse return error.PathTooLong;
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        const fd: i32 = @intCast(rc);
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
            _ = linux.close(fd);
            return error.ConnectFailed;
        }
        return .{ .fd = fd };
    }

    pub fn close(self: *Client) void {
        if (comptime !supported) return;
        _ = linux.close(self.fd);
    }

    /// Send `line` plus a newline.
    pub fn sendLine(self: *Client, line: []const u8) !void {
        var off: usize = 0;
        while (off < line.len) {
            const rc = linux.write(self.fd, line[off..].ptr, line.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
        const nl = "\n";
        while (true) {
            const rc = linux.write(self.fd, nl, 1);
            switch (linux.errno(rc)) {
                .SUCCESS => return,
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
    }

    /// Read one line (blocking) into a fresh allocation, without its newline.
    pub fn readLine(self: *Client, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const rc = linux.read(self.fd, &chunk, chunk.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.ConnectionClosed;
                    // Replies are one line each and the server sends nothing
                    // unsolicited, so a chunk holds at most that one line.
                    try out.appendSlice(gpa, chunk[0..rc]);
                    if (std.mem.indexOfScalar(u8, out.items, '\n')) |nl| {
                        out.shrinkRetainingCapacity(nl);
                        return out.toOwnedSlice(gpa);
                    }
                },
                .INTR => {},
                else => return error.ReadFailed,
            }
        }
    }
};

test "server and client exchange lines" {
    if (comptime !supported) return error.SkipZigTest;
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/teak-ctl-test-{d}.sock", .{linux.getpid()});

    var srv: Server = .{};
    try std.testing.expect(srv.listen(path));
    defer srv.deinit();

    var out: [128]u8 = undefined;
    try std.testing.expect(srv.recvLine(&out) == null); // no client yet

    var cl = try Client.connect(path);
    defer cl.close();
    try cl.sendLine("{\"cmd\":\"hi\"}");
    try cl.sendLine("second");

    // Non-blocking: the data is already in the kernel buffer.
    const l1 = srv.recvLine(&out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("{\"cmd\":\"hi\"}", l1);
    const l2 = srv.recvLine(&out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("second", l2);
    try std.testing.expect(srv.recvLine(&out) == null);

    srv.send("{\"ok\":true}\n");
    const reply = try cl.readLine(std.testing.allocator);
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"ok\":true}", reply);
}
