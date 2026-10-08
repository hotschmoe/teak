//! Headless screenshots of the kerf_viewer example (no display needed):
//! `zig build shot -- out.png [--state <name>]` (`-- --list` prints the states).
//! Each state plays an input script against the real App on the native wgpu
//! backend and writes the last frame (same CLI as `teak.headless.shotCli`).

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

const Step = teak.headless.Step;

// Window positions at 1280x800 (see the checked-in shots for the layout).
const tab_section: [2]f32 = .{ 415, 66 };
const tab_iso: [2]f32 = .{ 491, 66 };
const tab_3d: [2]f32 = .{ 547, 66 };
const chat_input: [2]f32 = .{ 180, 690 };

/// SECTION A of palmer: click the stem wall (selects it in every view), then
/// hover the footing (blue outline).
const section_steps = [_]Step{
    .{ .frames = 3 },
    .{ .click = .{ 542, 350 } },
    .{ .move = .{ 470, 505 } },
    .{ .frames = 2 },
};

/// flush-psl-2x6's ISO B with a part selected from the table.
const iso_steps = [_]Step{
    .{ .frames = 2 },
    .{ .click = .{ 1111, 20 } }, // FLUSH-PSL-2X6
    .{ .frames = 2 },
    .{ .click = tab_iso },
    .{ .frames = 2 },
    .{ .click = .{ 1100, 134 } }, // table row 02
    .{ .move = .{ 640, 400 } },
    .{ .frames = 2 },
};

/// The 3D tab with a selection made in the table and a section cut.
const three_d_steps = [_]Step{
    .{ .frames = 2 },
    .{ .click = tab_3d },
    .{ .frames = 2 },
    .{ .click = .{ 1100, 134 } }, // table row 02
    .{ .frames = 3 },
};

/// Type to the scripted Claude: it selects a part and answers.
const chat_steps = [_]Step{
    .{ .frames = 2 },
    .{ .click = chat_input },
    .{ .chars = "where is the stem wall" },
    .{ .frames = 1 },
    .{ .key = .shift_enter },
    .{ .frames = 1 },
    .{ .chars = "and highlight it everywhere" },
    .{ .frames = 1 },
    .{ .key = .enter },
    .{ .frames = 100 },
    .{ .chars = "cut it" },
    .{ .frames = 1 },
    .{ .key = .enter },
    .{ .frames = 100 },
};

/// NOTES text area with text typed in.
const notes_steps = [_]Step{
    .{ .frames = 2 },
    .{ .click = .{ 1100, 710 } },
    .{ .chars = "Verify the dowel lap with the engineer of record." },
    .{ .frames = 1 },
    .{ .key = .shift_enter },
    .{ .frames = 1 },
    .{ .chars = "Hold the weep screed 2 in. above grade." },
    .{ .frames = 3 },
};

const State = struct { name: []const u8, steps: []const Step };
const states = [_]State{
    .{ .name = "section_selected", .steps = &section_steps },
    .{ .name = "iso_selected", .steps = &iso_steps },
    .{ .name = "three_d", .steps = &three_d_steps },
    .{ .name = "chat_demo", .steps = &chat_steps },
    .{ .name = "notes", .steps = &notes_steps },
};

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    var path: []const u8 = "kerf_viewer.png";
    var state: []const u8 = states[0].name;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--list")) {
            for (states) |st| std.debug.print("{s}\n", .{st.name});
            return;
        } else if (std.mem.eql(u8, a, "--state")) {
            state = it.next() orelse state;
        } else path = a;
    }
    for (states) |st| {
        if (!std.mem.eql(u8, st.name, state)) continue;
        try teak.headless.shot(App, Host, Gpu, init.gpa, path, .{
            .width = 1280,
            .height = 800,
            .run = .{ .clear_color = App.paper },
            .steps = st.steps,
        });
        std.debug.print("wrote {s} ({s})\n", .{ path, st.name });
        return;
    }
    std.debug.print("unknown state '{s}' (try --list)\n", .{state});
    return error.UnknownState;
}
