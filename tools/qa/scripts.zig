//! QA states per example: what to render, at what size, and the input script.
//! Positions are logical px at scale 1 (the headless Host scales them for 2x).
const std = @import("std");
const teak = @import("teak");

const Step = teak.headless.Step;
pub const State = struct { name: []const u8, steps: []const Step, msaa: bool = true, clear: ?[4]f32 = null };
pub const Spec = struct {
    width: u32 = 1280,
    height: u32 = 800,
    /// Name of an `App` decl holding the clear colour, or a fixed colour.
    clear_decl: ?[]const u8 = null,
    clear: ?[4]f32 = null,
    states: []const State,
};

/// The colour the window clears to: the App's own (`paper`, `bg`) if named.
pub fn clearColor(comptime App: type, comptime spec: Spec) ?[4]f32 {
    if (spec.clear) |c| return c;
    if (spec.clear_decl) |d| if (@hasDecl(App, d)) return @field(App, d);
    return null;
}

const initial: State = .{ .name = "initial", .steps = &.{.{ .frames = 40 }} };

pub fn specFor(comptime name: []const u8) Spec {
    if (std.mem.eql(u8, name, "chrome")) return chrome;
    if (std.mem.eql(u8, name, "counter_greeter")) return counter_greeter;
    if (std.mem.eql(u8, name, "todo")) return todo;
    if (std.mem.eql(u8, name, "tree")) return tree;
    if (std.mem.eql(u8, name, "viewport")) return viewport;
    if (std.mem.eql(u8, name, "effects")) return effects;
    if (std.mem.eql(u8, name, "fonts")) return fonts;
    if (std.mem.eql(u8, name, "scene3d")) return scene3d;
    if (std.mem.eql(u8, name, "scene_layers")) return scene_layers;
    if (std.mem.eql(u8, name, "kerf_viewer")) return kerf_viewer;
    if (std.mem.eql(u8, name, "gallery")) return gallery;
    if (std.mem.eql(u8, name, "notes")) return notes;
    if (std.mem.eql(u8, name, "tables")) return tables;
    @compileError("no QA script for example " ++ name);
}

const chrome: Spec = .{ .clear_decl = "paper", .states = &.{
    initial,
    .{ .name = "modern", .clear = .{ 0.95, 0.96, 0.98, 1 }, .steps = &.{ .{ .frames = 2 }, .{ .chars = "m" }, .{ .frames = 40 } } },
    .{ .name = "edited", .steps = &.{
        .{ .frames = 2 },
        .{ .click = .{ 47, 253 } },
        .{ .click = .{ 180, 314 } },
        .{ .chars = "-X1" },
        .{ .click = .{ 180, 376 } },
        .{ .chars = "al" },
        .{ .move = .{ 600, 500 } },
        .{ .frames = 40 },
    } },
    .{ .name = "modern_combo", .clear = .{ 0.95, 0.96, 0.98, 1 }, .steps = &.{
        .{ .frames = 2 },
        .{ .chars = "m" },
        .{ .frames = 5 },
        .{ .click = .{ 180, 427 } },
        .{ .chars = "a" },
        .{ .move = .{ 600, 500 } },
        .{ .frames = 40 },
    } },
} };

const counter_greeter: Spec = .{ .width = 900, .height = 500, .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
    .{ .name = "counted_named", .steps = &.{
        .{ .frames = 2 },
        .{ .click = .{ 70, 134 } },
        .{ .click = .{ 70, 134 } },
        .{ .click = .{ 70, 134 } },
        .{ .click = .{ 284, 98 } },
        .{ .chars = "Teak" },
        .{ .move = .{ 600, 400 } },
        .{ .frames = 2 },
    } },
    .{ .name = "help_modal", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 38, 25 } }, .{ .frames = 2 } } },
    .{ .name = "light_mode", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 126, 25 } }, .{ .move = .{ 600, 400 } }, .{ .frames = 2 } } },
    .{ .name = "hover_button", .steps = &.{ .{ .frames = 2 }, .{ .move = .{ 70, 134 } }, .{ .frames = 2 } } },
} };

const todo: Spec = .{ .width = 720, .height = 600, .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
    .{ .name = "three_items", .steps = &.{
        .{ .frames = 2 },
        .{ .click = .{ 80, 66 } },
        .{ .chars = "Buy milk" },
        .{ .frames = 1 },
        .{ .key = .enter },
        .{ .frames = 1 },
        .{ .chars = "Write the golden tests" },
        .{ .frames = 1 },
        .{ .key = .enter },
        .{ .frames = 1 },
        .{ .chars = "Ship it" },
        .{ .frames = 1 },
        .{ .key = .enter },
        .{ .frames = 1 },
        .{ .click = .{ 33, 171 } },
        .{ .move = .{ 400, 400 } },
    } },
} };

const tree: Spec = .{ .width = 720, .height = 600, .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
    .{ .name = "toggled", .steps = &.{
        .{ .frames = 2 },
        .{ .click = .{ 75, 117 } },
        .{ .click = .{ 75, 231 } },
        .{ .move = .{ 600, 500 } },
        .{ .frames = 2 },
    } },
} };

const viewport: Spec = .{ .width = 900, .height = 520, .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
    .{ .name = "zoomed_panned", .steps = &.{
        .{ .frames = 2 },
        .{ .move = .{ 290, 240 } },
        .{ .wheel = .{ 0, -240 } },
        .{ .frames = 2 },
        .{ .drag = .{ .{ 300, 250 }, .{ 380, 300 } } },
        .{ .frames = 2 },
    } },
    .{ .name = "list_scrolled", .steps = &.{ .{ .frames = 2 }, .{ .move = .{ 660, 300 } }, .{ .wheel = .{ 0, 200 } }, .{ .frames = 3 } } },
} };

const effects: Spec = .{ .width = 1000, .height = 640, .clear = .{ 0.08, 0.08, 0.1, 1.0 }, .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
    .{ .name = "hover", .steps = &.{ .{ .frames = 2 }, .{ .move = .{ 60, 101 } }, .{ .frames = 2 } } },
} };

const fonts: Spec = .{ .width = 1000, .height = 520, .clear = .{ 0.08, 0.08, 0.1, 1.0 }, .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 2 }} },
} };

const scene3d: Spec = .{ .clear = .{ 0.07, 0.08, 0.1, 1 }, .states = &.{
    .{ .name = "orbit", .steps = &.{ .{ .frames = 40 }, .{ .click = .{ 580, 391 } }, .{ .frames = 5 } } },
    .{ .name = "edges_hidden", .steps = &.{ .{ .frames = 40 }, .{ .click = .{ 590, 347 } }, .{ .move = .{ 900, 600 } }, .{ .frames = 3 } } },
} };

const scene_layers: Spec = .{ .clear_decl = "paper", .states = &.{
    .{ .name = "initial", .steps = &.{ .{ .frames = 4 }, .{ .click = .{ 1100, 108 } }, .{ .frames = 2 } } },
} };

const kerf_viewer: Spec = .{ .clear_decl = "paper", .states = &.{
    .{ .name = "section", .steps = &.{.{ .frames = 10 }} },
    .{ .name = "section_hover", .steps = &.{ .{ .frames = 3 }, .{ .click = .{ 542, 350 } }, .{ .move = .{ 470, 505 } }, .{ .frames = 2 } } },
    .{ .name = "three_d", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 547, 66 } }, .{ .frames = 2 }, .{ .click = .{ 1100, 134 } }, .{ .frames = 3 } } },
    .{ .name = "iso", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 1111, 20 } }, .{ .frames = 2 }, .{ .click = .{ 491, 66 } }, .{ .frames = 2 }, .{ .click = .{ 1100, 134 } }, .{ .move = .{ 640, 400 } }, .{ .frames = 2 } } },
    .{ .name = "cut", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 547, 66 } }, .{ .frames = 2 }, .{ .click = .{ 1100, 134 } }, .{ .click = .{ 416, 133 } }, .{ .frames = 4 } } },
    .{ .name = "chat", .steps = &.{
        .{ .frames = 2 },
        .{ .click = .{ 180, 690 } },
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
    } },
} };

const g_dark: Step = .{ .click = .{ 88, 720 } };
const g_light: Step = .{ .click = .{ 88, 752 } };
// page buttons: retro layout, then the dark / light layout (the sidebar shifts a few px)
const gr = [_]f32{ 78, 110, 142, 174, 206, 238 };
const gd = [_]f32{ 85, 119, 153, 187, 221, 255 };
fn gpage(comptime y: f32) Step {
    return .{ .click = .{ 88, y } };
}
const to_data: Step = .{ .click = .{ 88, 142 } };
const gallery: Spec = .{ .states = &.{
    .{ .name = "retro_controls", .steps = &.{ .{ .frames = 2 }, gpage(gr[0]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "retro_inputs", .steps = &.{ .{ .frames = 2 }, gpage(gr[1]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "retro_data", .steps = &.{ .{ .frames = 2 }, gpage(gr[2]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "retro_overlays", .steps = &.{ .{ .frames = 2 }, gpage(gr[3]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "retro_layout", .steps = &.{ .{ .frames = 2 }, gpage(gr[4]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "retro_scene", .steps = &.{ .{ .frames = 2 }, gpage(gr[5]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "dark_controls", .clear = null, .steps = &.{ .{ .frames = 2 }, g_dark, gpage(gd[0]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "dark_data", .clear = null, .steps = &.{ .{ .frames = 2 }, g_dark, gpage(gd[2]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "dark_overlays", .clear = null, .steps = &.{ .{ .frames = 2 }, g_dark, gpage(gd[3]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "dark_layout", .clear = null, .steps = &.{ .{ .frames = 2 }, g_dark, gpage(gd[4]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "light_controls", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, g_light, gpage(gd[0]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "light_inputs", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, g_light, gpage(gd[1]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "light_data", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, g_light, gpage(gd[2]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "light_overlays", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, g_light, gpage(gd[3]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "light_layout", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, g_light, gpage(gd[4]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "light_scene", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, g_light, gpage(gd[5]), .{ .move = .{ 900, 700 } }, .{ .frames = 4 } } },
    .{ .name = "controls_dark", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 720 } }, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "controls_light", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 752 } }, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "data_light", .clear = .{ 0.96, 0.96, 0.97, 1 }, .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 752 } }, to_data, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "data_dark", .steps = &.{ .{ .frames = 2 }, to_data, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "inputs", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .frames = 2 } } },
    .{ .name = "inputs_dropdown", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 110 } }, .{ .click = .{ 300, 125 } }, .{ .frames = 2 } } },
    .{ .name = "layout", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 206 } }, .{ .frames = 2 } } },
    .{ .name = "overlays", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .frames = 2 } } },
    .{ .name = "overlays_menu", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .click = .{ 108, 14 } }, .{ .move = .{ 900, 700 } }, .{ .frames = 2 } } },
    .{ .name = "overlays_dialog", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .click = .{ 790, 263 } }, .{ .frames = 2 } } },
    .{ .name = "overlays_tooltip", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .frames = 2 }, .{ .move = .{ 230, 146 } }, .{ .frames = 45 } } },
    .{ .name = "overlays_toasts", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 174 } }, .{ .click = .{ 644, 124 } }, .{ .click = .{ 722, 124 } }, .{ .move = .{ 600, 600 } }, .{ .frames = 30 } } },
    .{ .name = "scene", .steps = &.{ .{ .frames = 2 }, .{ .click = .{ 88, 238 } }, .{ .frames = 4 } } },
} };

const notes: Spec = .{ .clear_decl = "bg", .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 3 }} },
    .{ .name = "chat", .steps = &.{
        .{ .frames = 3 },
        .{ .click = .{ 1000, 700 } },
        .{ .chars = "Ship it Friday, then we write the release notes together." },
        .{ .frames = 1 },
        .{ .key = .enter },
        .{ .frames = 1 },
        .{ .chars = "Sounds good! One more thing: can someone check the wrapped" },
        .{ .frames = 2 },
        .{ .drag = .{ .{ 140, 126 }, .{ 560, 300 } } },
        .{ .move = .{ 640, 700 } },
        .{ .frames = 2 },
    } },
} };

const tables: Spec = .{ .width = 1100, .height = 700, .clear = .{ 0.08, 0.09, 0.11, 1 }, .states = &.{
    .{ .name = "initial", .steps = &.{.{ .frames = 4 }} },
    .{ .name = "scrolled", .steps = &.{ .{ .frames = 4 }, .{ .move = .{ 500, 300 } }, .{ .wheel = .{ 0, 3000 } }, .{ .frames = 3 } } },
} };
