//! libc stand-ins for stb_truetype on wasm32-freestanding (no libc there):
//! `stb_wasm_impl.c` points STBTT_malloc/free at these exports. Pulled in by `text.zig` only
//! on freestanding targets.

const std = @import("std");

const header_len = 16; // keeps the payload 16-byte aligned and stores the size

export fn teak_stb_malloc(n: usize) ?*anyopaque {
    const mem = std.heap.wasm_allocator.alignedAlloc(u8, .@"16", n + header_len) catch return null;
    std.mem.writeInt(usize, mem[0..@sizeOf(usize)], n + header_len, .little);
    return mem.ptr + header_len;
}

export fn teak_stb_free(p: ?*anyopaque) void {
    const ptr = p orelse return;
    const base: [*]align(16) u8 = @ptrFromInt(@intFromPtr(ptr) - header_len);
    const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
    std.heap.wasm_allocator.free(base[0..total]);
}
