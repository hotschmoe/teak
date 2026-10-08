//! The stable hot-reload loader: `zig-out/bin/todo-dev [path/to/libapp.so]`.
//! It owns nothing of the app; rebuild `libapp.so` (`zig build dev --watch`)
//! and it swaps the new build in, keeping the Model. See docs/features/hot-reload.md.

const std = @import("std");
const teak = @import("teak");

pub fn main(init: std.process.Init) !void {
    try teak.dev.runLoader(init, "zig-out/lib/libapp.so");
}
