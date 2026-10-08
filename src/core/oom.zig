//! The framework's single out-of-memory policy.
//!
//! The per-frame command buffer, its arena, and the render pass's vertex
//! lists grow through allocators the framework does not own (the host's
//! backing allocator). Failure there is unrecoverable mid-frame — and the
//! emitters (`cb.text(...)`, `cb.button(...)`, ...) are deliberately
//! non-error-returning so `view` stays a plain function. The previous
//! `catch unreachable` was undefined behaviour in ReleaseFast/ReleaseSmall;
//! `oom()` is a defined, loud, identical-in-every-mode panic.

/// Abort with a message naming the failure. Use as `alloc(...) catch oom()`.
pub fn oom() noreturn {
    @panic("teak: out of memory (per-frame command buffer / arena / vertex list)");
}

test "oom is noreturn" {
    try @import("std").testing.expect(@typeInfo(@TypeOf(oom)).@"fn".return_type.? == noreturn);
}
