//! Headless agent-driver entry for the todo example: the real native wgpu
//! renderer on an offscreen target, no window, controlled over the Unix
//! socket named by `TEAK_CONTROL`. Launched by `teak-drive` (CLI or MCP):
//!
//!     TEAK_CONTROL=/tmp/todo.sock ./zig-out/bin/todo-drive
//!     teak-drive --socket /tmp/todo.sock snapshot
//!
//! See docs/features/agent-driver.md.

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    try teak.headless.serve(App, Host, Gpu, gpa_impl.allocator(), .{ .width = 720, .height = 600 });
}
