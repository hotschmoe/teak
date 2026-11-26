//! Backend for an OS the monitor cannot read: every Sample stays empty.

const sys = @import("sys.zig");

pub const State = struct {
    pub fn init(_: *State) void {}
    pub fn deinit(_: *State) void {}
    pub fn read(_: *State, _: *sys.Sample, _: *sys.Counters) void {}
};
