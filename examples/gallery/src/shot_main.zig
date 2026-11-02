//! Headless screenshots of the gallery (no display needed):
//! `zig build shot -- out.png [--state <name>]`. One state per page and per
//! look, plus the overlays (menus, dialog, toast, tooltip, context menu).

const std = @import("std");
const teak = @import("teak");
const Host = @import("teak-platform-headless").Host;
const Gpu = @import("teak-gpu-headless").Gpu;
const App = @import("app.zig");

const Step = teak.headless.Step;

const to_overlays: []const Step = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .frames = 2 } };

const dark: Step = .{ .click = .{ 88, 720 } };
const light: Step = .{ .click = .{ 88, 752 } };

const states = [_]teak.headless.ShotState{
    .{ .name = "controls_dark", .steps = &.{ .{ .frames = 2 }, dark, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "data_light", .steps = &.{ .{ .frames = 2 }, light, .{ .click = .{ 88, 142 } }, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "overlays_dark_menu", .steps = &.{ .{ .frames = 2 }, dark, .{ .click = .{ 88, 174 } }, .{ .click = .{ 108, 14 } }, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "scene", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 238 } }, .{ .frames = 4 } } },
    .{ .name = "layout", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 206 } }, .{ .frames = 2 } } },
    .{ .name = "layout_split", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 206 } }, .{ .click = .{ 160, 126 } }, .{ .frames = 2 }, .{ .drag = .{ .{ 835, 200 }, .{ 930, 200 } } }, .{ .frames = 2 } } },
    .{ .name = "overlays", .steps = to_overlays },
    .{ .name = "menu_file", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 36, 14 } }, .{ .move = .{ 700, 600 } }, .{ .frames = 2 } } },
    .{ .name = "menu_submenu", .steps = &.{ .{ .frames = 2 }, .{ .key = .f10 }, .{ .frames = 1 }, .{ .key = .right }, .{ .frames = 1 }, .{ .key = .down }, .{ .frames = 1 }, .{ .key = .down }, .{ .frames = 1 }, .{ .key = .enter }, .{ .frames = 2 } } },
    .{ .name = "context", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .move = .{ 700, 520 } }, .{ .down = .right }, .{ .frames = 2 }, .{ .up = .right }, .{ .frames = 2 } } },
    .{ .name = "tooltip", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .frames = 2 }, .{ .move = .{ 230, 146 } }, .{ .frames = 45 } } },
    .{ .name = "toasts", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .click = .{ 644, 124 } }, .{ .click = .{ 722, 124 } }, .{ .click = .{ 738, 156 } }, .{ .move = .{ 600, 600 } }, .{ .frames = 30 } } },
    .{ .name = "toast_sliding", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .click = .{ 644, 124 } }, .{ .move = .{ 600, 600 } }, .{ .frames = 5 } } },
    .{ .name = "dialog", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .click = .{ 790, 263 } }, .{ .frames = 2 } } },
    .{ .name = "focus_ring", .steps = &.{ .{ .frames = 2 }, .{ .key = .tab }, .{ .frames = 1 }, .{ .key = .tab }, .{ .frames = 1 }, .{ .key = .tab }, .{ .frames = 1 }, .{ .key = .tab }, .{ .frames = 2 } } },
    .{ .name = "focus_ring_light", .steps = &.{ .{ .frames = 2 }, light, .{ .move = .{ 900, 700 } }, .{ .key = .tab }, .{ .frames = 1 }, .{ .key = .tab }, .{ .frames = 1 }, .{ .key = .tab }, .{ .frames = 2 } } },
    .{ .name = "controls", .steps = &.{.{ .frames = 3 }} },
    .{ .name = "data", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 142 } }, .{ .frames = 2 } } },
    .{ .name = "data_scrolled", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 142 } }, .{ .frames = 2 }, .{ .move = .{ 600, 240 } }, .{ .wheel = .{ 0, 4400 } }, .{ .frames = 3 } } },
    .{ .name = "inputs", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .frames = 2 } } },
    .{ .name = "inputs_dropdown", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .click = .{ 300, 125 } }, .{ .frames = 2 } } },
    .{ .name = "inputs_combo", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .click = .{ 720, 125 } }, .{ .chars = "a" }, .{ .frames = 2 } } },
};

pub fn main(init: std.process.Init) !void {
    // `shotCli` parses `--state`, `--list`, `--all`, `--idle-check`, `--gates-json`.
    // The first state (`controls_dark`) stays the default PNG.
    try teak.headless.shotCli(App, Host, Gpu, init, "gallery.png", .{
        .width = 1280,
        .height = 800,
    }, &states);
}
