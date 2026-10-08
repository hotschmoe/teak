//! The Linux host: one binary, two backends. `init` picks Wayland when
//! `WAYLAND_DISPLAY` is set and its libraries load and connect, otherwise
//! X11 (which also covers XWayland). `TEAK_BACKEND=x11` or `=wayland` forces
//! one. Every `validateHost` method forwards to the live backend through an
//! `inline else` switch, so no platform code leaks into core and the choice
//! is a runtime value held in one tagged union.
//!
//! `NativeHandle` is the matching tagged union; `gpu/surface_linux.zig`
//! turns it into the Xlib or Wayland wgpu surface source.

const std = @import("std");
const teak = @import("teak");
const x11 = @import("x11.zig");
const wayland = @import("wayland.zig");

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const TextMeasurer = teak.TextMeasurer;
pub const Clipboard = teak.Clipboard;
pub const ImeState = teak.ImeState;
pub const A11yNode = teak.A11yNode;
pub const FileDialogResult = teak.FileDialogResult;
pub const FileDialogFilter = teak.FileDialogFilter;
pub const FileDialogPoll = teak.FileDialogPoll;

pub const Backend = enum { x11, wayland };

pub const NativeHandle = union(Backend) {
    x11: x11.NativeHandle,
    wayland: wayland.Host.NativeHandle,
};

/// Which backend to try first, from the environment (pure, for tests).
pub fn preferredBackend(wayland_display: ?[]const u8, forced: ?[]const u8) Backend {
    if (forced) |f| {
        if (std.ascii.eqlIgnoreCase(f, "x11")) return .x11;
        if (std.ascii.eqlIgnoreCase(f, "wayland")) return .wayland;
    }
    if (wayland_display) |d| if (d.len > 0) return .wayland;
    return .x11;
}

fn envSlice(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

pub const Host = struct {
    impl: Impl,

    const Impl = union(Backend) { x11: x11.Host, wayland: wayland.Host };

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        const first = preferredBackend(envSlice("WAYLAND_DISPLAY"), envSlice("TEAK_BACKEND"));
        const forced = envSlice("TEAK_BACKEND") != null;
        switch (first) {
            .wayland => {
                if (wayland.Host.init(title, width, height)) |w| {
                    return .{ .impl = .{ .wayland = w } };
                } else |err| {
                    if (forced) return err;
                    std.log.info("teak: Wayland unavailable ({s}); falling back to X11", .{@errorName(err)});
                }
                return .{ .impl = .{ .x11 = try x11.Host.init(title, width, height) } };
            },
            .x11 => return .{ .impl = .{ .x11 = try x11.Host.init(title, width, height) } },
        }
    }

    /// Which backend this host is running on.
    pub fn backend(self: *const Host) Backend {
        return self.impl;
    }

    pub fn deinit(self: *Host) void {
        switch (self.impl) {
            inline else => |*h| h.deinit(),
        }
    }

    pub fn pollInputs(self: *Host) InputState {
        return switch (self.impl) {
            inline else => |*h| h.pollInputs(),
        };
    }

    pub fn shouldClose(self: *const Host) bool {
        return switch (self.impl) {
            inline else => |*h| h.shouldClose(),
        };
    }

    pub fn nativeHandle(self: *const Host) NativeHandle {
        return switch (self.impl) {
            .x11 => |*h| .{ .x11 = h.nativeHandle() },
            .wayland => |*h| .{ .wayland = h.nativeHandle() },
        };
    }

    pub fn textMeasurer(self: *Host) TextMeasurer {
        return switch (self.impl) {
            inline else => |*h| h.textMeasurer(),
        };
    }

    pub fn clipboard(self: *Host) Clipboard {
        return switch (self.impl) {
            inline else => |*h| h.clipboard(),
        };
    }

    pub fn imeState(self: *const Host) ImeState {
        return switch (self.impl) {
            inline else => |*h| h.imeState(),
        };
    }

    pub fn publishA11yTree(self: *Host, nodes: []const A11yNode) void {
        switch (self.impl) {
            inline else => |*h| h.publishA11yTree(nodes),
        }
    }

    pub fn openFileDialog(self: *Host, f: FileDialogFilter) FileDialogResult {
        return switch (self.impl) {
            inline else => |*h| h.openFileDialog(f),
        };
    }

    pub fn saveFileDialog(self: *Host, f: FileDialogFilter) FileDialogResult {
        return switch (self.impl) {
            inline else => |*h| h.saveFileDialog(f),
        };
    }

    pub fn requestFileDialog(self: *Host, f: FileDialogFilter) u32 {
        return switch (self.impl) {
            inline else => |*h| h.requestFileDialog(f),
        };
    }

    pub fn requestSaveFileDialog(self: *Host, f: FileDialogFilter) u32 {
        return switch (self.impl) {
            inline else => |*h| h.requestSaveFileDialog(f),
        };
    }

    pub fn pollFileDialogResult(self: *Host, id: u32) FileDialogPoll {
        return switch (self.impl) {
            inline else => |*h| h.pollFileDialogResult(id),
        };
    }

    pub fn openSecondaryWindow(self: *Host, title: []const u8, w: u32, h: u32) ?u32 {
        return switch (self.impl) {
            inline else => |*x| x.openSecondaryWindow(title, w, h),
        };
    }

    pub fn pollSecondaryInputs(self: *Host, id: u32) ?InputState {
        return switch (self.impl) {
            inline else => |*h| h.pollSecondaryInputs(id),
        };
    }

    pub fn closeSecondaryWindow(self: *Host, id: u32) void {
        switch (self.impl) {
            inline else => |*h| h.closeSecondaryWindow(id),
        }
    }

    pub fn secondaryWindowHandle(_: *const Host, _: u32) ?NativeHandle {
        return null;
    }

    pub fn setTitle(self: *Host, title: []const u8) void {
        switch (self.impl) {
            inline else => |*h| h.setTitle(title),
        }
    }

    pub fn nowMs(self: *const Host) u64 {
        return switch (self.impl) {
            inline else => |*h| h.nowMs(),
        };
    }

    pub fn scaleFactor(self: *const Host) f32 {
        return switch (self.impl) {
            inline else => |*h| h.scaleFactor(),
        };
    }

    pub fn setCursor(self: *Host, shape: teak.CursorShape) void {
        switch (self.impl) {
            inline else => |*h| h.setCursor(shape),
        }
    }

    pub fn setImeSpot(self: *Host, x: i32, y: i32) void {
        switch (self.impl) {
            inline else => |*h| h.setImeSpot(x, y),
        }
    }

    pub fn submit(self: *Host, e: teak.Effect) teak.EffectSubmit {
        return switch (self.impl) {
            inline else => |*h| h.submit(e),
        };
    }

    pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize {
        return switch (self.impl) {
            inline else => |*h| h.pollEffectResults(buf),
        };
    }

    pub fn setAppName(self: *Host, name: []const u8) void {
        switch (self.impl) {
            inline else => |*h| h.setAppName(name),
        }
    }

    pub fn registerFont(self: *Host, family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) !void {
        switch (self.impl) {
            inline else => |*h| try h.registerFont(family, weight, ttf),
        }
    }
};

comptime {
    teak.validateHost(Host);
}

test "preferredBackend: Wayland only when advertised, TEAK_BACKEND forces" {
    try std.testing.expectEqual(Backend.x11, preferredBackend(null, null));
    try std.testing.expectEqual(Backend.x11, preferredBackend("", null));
    try std.testing.expectEqual(Backend.wayland, preferredBackend("wayland-0", null));
    try std.testing.expectEqual(Backend.x11, preferredBackend("wayland-0", "x11"));
    try std.testing.expectEqual(Backend.wayland, preferredBackend(null, "Wayland"));
    try std.testing.expectEqual(Backend.wayland, preferredBackend("wayland-0", "bogus"));
}
