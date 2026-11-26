pub fn assert(condition: bool) void {
    if (!condition) @panic("assertion failed");
}
