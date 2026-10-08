//! The gallery's state and transitions. Everything the demos remember lives
//! here (HARDLINE §1); widgets bring their own `Model` / `Msg` / `update` and
//! this file wires them together.

const std = @import("std");
const teak = @import("teak");
const theme = @import("theme.zig");

const W = teak.widgets;

// ── Widget instances ───────────────────────────────────────────────

pub const Action = enum {
    reset,
    toast_demo,
    quit,
    look_retro,
    look_dark,
    look_light,
    about,
    shortcuts,
    page_controls,
    page_inputs,
    page_data,
    page_overlays,
    page_layout,
    page_scene,
    copy,
    paste,
    select_all,
    properties,
    refresh,
};

pub const MB = W.menu.MenuBar(Action);
pub const CM = W.menu.ContextMenu(Action);
pub const Toasts = W.toast.Toast(4, 72);
pub const Tooltip = W.tooltip;
pub const Tabs = W.tabs;
pub const Split = W.split;
pub const Progress = W.progress;
pub const NameField = teak.TextField(32);
pub const QtyField = teak.NumericField(.{ .capacity = 8, .min = 0, .max = 999, .precision = 0, .invalid_message = "enter 0 - 999" });
pub const Drop = teak.Dropdown(8);
pub const Combo = teak.Combobox(24);
pub const Area = teak.TextArea(512);
pub const area_id: u32 = 31;

pub const Page = enum {
    controls,
    inputs,
    data,
    overlays,
    layout,
    scene,

    pub fn title(self: Page) []const u8 {
        return switch (self) {
            .controls => "Controls",
            .inputs => "Inputs",
            .data => "Data",
            .overlays => "Overlays",
            .layout => "Layout",
            .scene => "3D & images",
        };
    }
};

pub const Field = enum { name, search, qty, combo, area };
pub const SliderId = enum { volume, mix };
pub const Dialog = enum { none, about, shortcuts, confirm_reset };

pub const tree_len = 14;
pub const series_len = 48;
pub const list_rows: u32 = 10_000;
pub const list_row_h: f32 = 22;
pub const list_h: f32 = 200;

pub const Msg = union(enum) {
    // shell
    go: Page,
    look: Look,
    window: [2]f32,
    menubar: MB.Msg,
    run: Action,
    ctx: CM.Msg,
    toast: Toasts.Msg,
    tip: Tooltip.Msg,
    dialog: Dialog,
    dialog_confirm,
    dialog_cancel,
    demo: u8,
    toast_push: struct { kind: W.toast.Kind, sticky: bool = false },
    // controls
    clicked,
    check_a,
    check_b,
    radio: u8,
    toggle_wifi,
    toggle_sound,
    toggle_dark_hint,
    slider_grab: SliderId,
    slider_set: struct { id: SliderId, v: f32 },
    // inputs
    focus_set: Field,
    /// Tab left the text fields for another widget: nothing has text focus.
    blur,
    /// A leaf with nothing to do (tree files).
    noop,
    focus_clear,
    name: NameField.Msg,
    search: NameField.Msg,
    qty: QtyField.Msg,
    drop: Drop.Msg,
    combo: Combo.Msg,
    area: Area.Msg,
    // data
    tree_toggle: u8,
    row_pick: u8,
    list_scroll_by: f32,
    list_extent: [2]f32,
    note_scroll_by: f32,
    note_extent: [2]f32,
    chart_run,
    chart_tick,
    // layout
    tabs: Tabs.Msg,
    split: Split.Msg,
    progress: Progress.Msg,
    job_start,
    job_tick,
    job_cancel,
    // scene
    scene_orbit,
    scene_tick,
    scene_zoom: f32,
};

pub const Look = theme.Look;

pub const Model = struct {
    win_w: f32 = 1280,
    win_h: f32 = 800,
    page: Page = .controls,
    look: Look = .retro,
    dialog: Dialog = .none,
    last_action: ?Action = null,
    clicks: u32 = 0,

    menubar: MB.Model = .{},
    ctx: CM.Model = .{},
    toasts: Toasts.Model = .{},
    tip: Tooltip.Model = .{},

    // controls
    check_a: bool = true,
    check_b: bool = false,
    radio: u8 = 1,
    wifi: bool = true,
    sound: bool = false,
    dark_hint: bool = true,
    volume: f32 = 0.35,
    mix: f32 = 0.7,

    // inputs
    focus: ?Field = null,
    name: NameField.Model = .{},
    search: NameField.Model = .{},
    qty: QtyField.Model = .{},
    drop: Drop.Model = .{ .selected = 1 },
    combo: Combo.Model = .{},
    area: Area.Model = .{},

    // data
    tree_open: [tree_len]bool = .{ true, true, false, false, true, false, false, false, true, false, false, false, false, false },
    row_sel: u8 = 1,
    list_scroll: f32 = 0,
    list_viewport: f32 = list_h,
    list_content: f32 = @as(f32, @floatFromInt(list_rows)) * list_row_h,
    note_scroll: f32 = 0,
    note_viewport: f32 = 150,
    note_content: f32 = 0,
    chart_on: bool = false,
    chart_t: u32 = 0,
    series: [series_len]f32 = initialSeries(),

    // layout
    tabs: Tabs.Model = .{},
    split: Split.Model = .{ .ratio = 0.42 },
    progress: Progress.Model = .{ .phase = 18 },
    job: f32 = 0,
    job_running: bool = false,

    // scene
    azimuth: f32 = 0.6,
    distance: f32 = 8.5,
    orbiting: bool = false,

    /// Subscriptions listed this frame; rebuilt by `refreshSubs` after every
    /// `update` so `subscribe` can stay a pure read of the Model.
    subs: [6]teak.Sub(Msg) = undefined,
    subs_len: usize = 0,
};

fn initialSeries() [series_len]f32 {
    var s: [series_len]f32 = undefined;
    for (&s, 0..) |*v, i| v.* = sample(@intCast(i));
    return s;
}

/// A smooth-ish deterministic signal for the chart.
pub fn sample(t: u32) f32 {
    const x: f32 = @floatFromInt(t);
    return 0.5 + 0.32 * @sin(x * 0.21) + 0.12 * @sin(x * 0.67 + 1.3);
}

// ── Update ─────────────────────────────────────────────────────────

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .go => |p| {
            m.page = p;
            m.focus = null;
            Tooltip.update(&m.tip, .hide);
        },
        .look => |l| m.look = l,
        .window => |w| {
            m.win_w = w[0];
            m.win_h = w[1];
        },
        .menubar => |s| MB.update(&m.menubar, s),
        .ctx => |s| CM.update(&m.ctx, s),
        .toast => |s| Toasts.update(&m.toasts, s),
        .tip => |s| Tooltip.update(&m.tip, s),
        .dialog => |d| {
            m.dialog = d;
            Tooltip.update(&m.tip, .hide);
        },
        .dialog_confirm => {
            if (m.dialog == .confirm_reset) {
                reset(m);
                Toasts.push(&m.toasts, .success, "Demo state reset", Toasts.default_ttl);
            }
            m.dialog = .none;
        },
        .dialog_cancel => m.dialog = .none,
        .demo => |i| {
            const text = switch (i) {
                0 => "Saved",
                1 => "Opened a file",
                else => "Exported",
            };
            Toasts.push(&m.toasts, .success, text, Toasts.default_ttl);
            Tooltip.update(&m.tip, .hide);
        },
        .toast_push => |p| {
            const text = switch (p.kind) {
                .info => "Heads up: just so you know",
                .success => "Done: that worked",
                .warning => "Careful: disk almost full",
                .danger => "Failed: could not connect",
            };
            Toasts.push(&m.toasts, p.kind, if (p.sticky) "Sticky: dismiss me with x" else text, if (p.sticky) 0 else Toasts.default_ttl);
        },
        .run => |a| {
            MB.update(&m.menubar, .close);
            CM.update(&m.ctx, .close);
            perform(m, a);
        },

        .clicked => m.clicks += 1,
        .check_a => m.check_a = !m.check_a,
        .check_b => m.check_b = !m.check_b,
        .radio => |i| m.radio = i,
        .toggle_wifi => m.wifi = !m.wifi,
        .toggle_sound => m.sound = !m.sound,
        .toggle_dark_hint => m.dark_hint = !m.dark_hint,
        .slider_grab => {},
        .slider_set => |s| switch (s.id) {
            .volume => m.volume = s.v,
            .mix => m.mix = s.v,
        },

        .focus_set => |f| m.focus = f,
        .blur => m.focus = null,
        .noop => {},
        .focus_clear => m.focus = null,
        .name => |s| NameField.update(&m.name, s),
        .search => |s| NameField.update(&m.search, s),
        .qty => |s| QtyField.update(&m.qty, s),
        .drop => |s| Drop.update(&m.drop, s),
        .combo => |s| {
            Combo.update(&m.combo, s);
            if (s == .focus) m.focus = .combo;
        },
        .area => |s| {
            Area.update(&m.area, s);
            if (s == .focus) m.focus = .area;
        },

        .tree_toggle => |i| {
            if (i < tree_len) m.tree_open[i] = !m.tree_open[i];
        },
        .row_pick => |i| m.row_sel = i,
        .list_scroll_by => |dy| m.list_scroll = clampList(m, m.list_scroll + dy),
        .list_extent => |e| {
            m.list_viewport = e[0];
            m.list_content = e[1];
            m.list_scroll = clampList(m, m.list_scroll);
        },
        .note_scroll_by => |dy| m.note_scroll = std.math.clamp(m.note_scroll + dy, 0, @max(0, m.note_content - m.note_viewport)),
        .note_extent => |e| {
            m.note_viewport = e[0];
            m.note_content = e[1];
            m.note_scroll = std.math.clamp(m.note_scroll, 0, @max(0, m.note_content - m.note_viewport));
        },
        .chart_run => m.chart_on = !m.chart_on,
        .chart_tick => {
            m.chart_t += 1;
            std.mem.copyForwards(f32, m.series[0 .. series_len - 1], m.series[1..series_len]);
            m.series[series_len - 1] = sample(m.chart_t + series_len);
        },

        .tabs => |s| Tabs.update(&m.tabs, s),
        .split => |s| Split.update(&m.split, s),
        .progress => |s| Progress.update(&m.progress, s),
        .job_start => {
            m.job = 0;
            m.job_running = true;
        },
        .job_tick => {
            m.job += 0.025;
            if (m.job >= 1) {
                m.job = 1;
                m.job_running = false;
                Toasts.push(&m.toasts, .success, "Job finished", Toasts.default_ttl);
            }
        },
        .job_cancel => {
            m.job_running = false;
            Toasts.push(&m.toasts, .warning, "Job cancelled", Toasts.default_ttl);
        },

        .scene_orbit => m.orbiting = !m.orbiting,
        .scene_tick => m.azimuth += 0.012,
        .scene_zoom => |d| m.distance = std.math.clamp(m.distance + d, 3, 20),
    }
    refreshSubs(m);
}

fn clampList(m: *const Model, y: f32) f32 {
    return std.math.clamp(y, 0, @max(0, m.list_content - m.list_viewport));
}

pub fn perform(m: *Model, a: Action) void {
    m.last_action = a;
    switch (a) {
        .reset => m.dialog = .confirm_reset,
        .toast_demo => Toasts.push(&m.toasts, .info, "Hello from the menu", Toasts.default_ttl),
        .quit => Toasts.push(&m.toasts, .warning, "Close the window to quit", Toasts.default_ttl),
        .look_retro => m.look = .retro,
        .look_dark => m.look = .dark,
        .look_light => m.look = .light,
        .about => m.dialog = .about,
        .shortcuts => m.dialog = .shortcuts,
        .page_controls => m.page = .controls,
        .page_inputs => m.page = .inputs,
        .page_data => m.page = .data,
        .page_overlays => m.page = .overlays,
        .page_layout => m.page = .layout,
        .page_scene => m.page = .scene,
        .copy => Toasts.push(&m.toasts, .info, "Copied", Toasts.default_ttl),
        .paste => Toasts.push(&m.toasts, .info, "Pasted", Toasts.default_ttl),
        .select_all => Toasts.push(&m.toasts, .info, "Selected everything", Toasts.default_ttl),
        .properties => Toasts.push(&m.toasts, .info, "Properties...", Toasts.default_ttl),
        .refresh => Toasts.push(&m.toasts, .success, "Refreshed", Toasts.default_ttl),
    }
}

pub fn reset(m: *Model) void {
    const keep_win = .{ m.win_w, m.win_h };
    const keep_look = m.look;
    m.* = .{};
    m.win_w = keep_win[0];
    m.win_h = keep_win[1];
    m.look = keep_look;
    refreshSubs(m);
}

// ── Subscriptions ──────────────────────────────────────────────────

fn refreshSubs(m: *Model) void {
    var n: usize = 0;
    if (Toasts.active(&m.toasts)) {
        m.subs[n] = .{ .every = .{ .interval_ms = W.toast.TICK_MS, .msg = .{ .toast = .tick } } };
        n += 1;
    }
    if (Toasts.animating(&m.toasts)) {
        m.subs[n] = .animation_frame;
        n += 1;
    }
    if (Tooltip.deadline(&m.tip)) |d| {
        m.subs[n] = .{ .at = .{ .deadline_ms = d, .msg = .{ .tip = .show } } };
        n += 1;
    }
    if (m.job_running) {
        m.subs[n] = .{ .every = .{ .interval_ms = 60, .msg = .job_tick } };
        n += 1;
        m.subs[n] = .{ .every = .{ .interval_ms = W.progress.TICK_MS, .msg = .{ .progress = .tick } } };
        n += 1;
    }
    if (m.chart_on and m.page == .data) {
        m.subs[n] = .{ .every = .{ .interval_ms = 200, .msg = .chart_tick } };
        n += 1;
    }
    if (m.orbiting and m.page == .scene) {
        m.subs[n] = .{ .every = .{ .interval_ms = 16, .msg = .scene_tick } };
        n += 1;
    }
    m.subs_len = n;
}

pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    return m.subs[0..m.subs_len];
}
