//! libc stand-ins for stb_truetype on wasm32-freestanding (no libc there).
//! `stb_wasm_impl.c` points STBTT_malloc/free and the few libm calls it cannot
//! express as compiler builtins at these exports. Pulled in by `text.zig` only
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

export fn teak_stb_pow(x: f64, y: f64) f64 {
    return std.math.pow(f64, x, y);
}

export fn teak_stb_fmod(x: f64, y: f64) f64 {
    return @mod(x, y);
}

export fn teak_stb_cos(x: f64) f64 {
    return @cos(x);
}

export fn teak_stb_acos(x: f64) f64 {
    return std.math.acos(x);
}
