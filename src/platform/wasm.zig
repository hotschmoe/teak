//! Wasm host stub. Real implementation is blocked on zunk integration
//! (see `tasks-wasm.md` and `docs/path_to_wasm_test.md`). Declares the
//! interface-satisfying shape so `validateHost` accepts it; every entry
//! point panics until the zunk `init` / `frame(dt)` / `resize(w,h)` /
//! `cleanup` lifecycle is wired through.
//!
//! When this file is filled in, ownership of the main loop inverts — zunk
//! owns rAF and calls into app-exported frame(dt); the Host's `pollInputs`
//! becomes a snapshot over `zunk.web.input`'s shared-memory struct rather
//! than a message pump.

const std = @import("std");
const teak = @import("teak");

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;

pub const NativeHandle = struct {};

pub const Host = struct {
    pub fn init() !Host {
        @panic("platform/wasm.zig: not implemented — see tasks-wasm.md §3 and docs/path_to_wasm_test.md");
    }

    pub fn deinit(_: *Host) void {}

    pub fn pollInputs(_: *Host) InputState {
        @panic("platform/wasm.zig: pollInputs not implemented");
    }

    pub fn shouldClose(_: *const Host) bool {
        return false;
    }

    pub fn nativeHandle(_: *const Host) NativeHandle {
        return .{};
    }
};

comptime {
    teak.validateHost(Host);
}
