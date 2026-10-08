//! Page 5: structure - tabs, a draggable split pane, progress bars.

const std = @import("std");
const teak = @import("teak");
const model = @import("model.zig");
const ui = @import("ui.zig");

const Model = model.Model;
const Msg = model.Msg;
const W = teak.widgets;

pub const tab_labels = [_][]const u8{ "General", "Network", "About" };

pub const split_opts: W.split.Opts = .{
    .orientation = .horizontal,
    .width = 520,
    .height = 190,
    .divider = 8,
    .min_a = 120,
    .min_b = 120,
    .id = 0xD1,
};

fn tabSelect(i: usize) Msg {
    return .{ .tabs = .{ .select = i } };
}

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 14, .align_cross = .start });

    // Column 1: tabs + progress.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 400, .align_cross = .stretch });
    ui.card(cb, "Tabs", 0, 0);
    model.Tabs.viewWith(&m.tabs, cb, &tab_labels, .{ .selectMsg = tabSelect }, .{ .min_width = 96, .height = 28 });
    switch (@min(m.tabs.selected, tab_labels.len - 1)) {
        0 => {
            cb.checkbox(.check_a, m.check_a, "Enable notifications");
            cb.checkbox(.check_b, m.check_b, "Remember me");
        },
        1 => {
            W.toggle.view(cb, Msg{ .toggle_wifi = {} }, m.wifi, "Wi-Fi");
            W.toggle.view(cb, Msg{ .toggle_sound = {} }, m.sound, "Sound");
        },
        else => {
            cb.text("Tabs keep only `selected` and `focused`");
            cb.textMuted("in the Model. Click a tab, then use");
            cb.textMuted("Left / Right / Home / End.");
        },
    }
    ui.endCard(cb);

    ui.card(cb, "Progress", 0, 0);
    cb.textMuted("Determinate (volume slider value):");
    W.progress.bar(cb, m.volume, .{ .width = 360 });
    cb.textMuted(if (m.job_running) "Indeterminate (a job is running):" else "Indeterminate:");
    W.progress.indeterminate(cb, m.progress.phase, .{ .width = 360 });
    cb.textMuted("A job (determinate):");
    W.progress.bar(cb, m.job, .{ .width = 360 });
    ui.row(cb);
    if (m.job_running) {
        cb.button(.job_cancel, "Cancel job");
    } else {
        cb.button(.job_start, "Start job");
    }
    cb.textMuted(ui.fmt(cb, "{d:.0}%", .{m.job * 100}));
    ui.endRow(cb);
    ui.endCard(cb);
    cb.popGroup();

    // Column 2: split pane.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 14, .width = 560, .align_cross = .stretch });
    ui.card(cb, "Split pane (drag the divider)", 0, 0);
    W.split.begin(&m.split, cb, split_opts);
    cb.heading("Left pane");
    cb.text("A fixed-size group.");
    cb.textMuted(ui.fmt(cb, "{d:.0} px", .{W.split.paneA(&m.split, split_opts)}));
    W.split.dividerFocusable(&m.split, cb, split_opts, Msg{ .split = .focus });
    cb.heading("Right pane");
    cb.text("Minimum size 120 px each.");
    cb.textMuted(ui.fmt(cb, "{d:.0} px", .{W.split.paneB(&m.split, split_opts)}));
    W.split.end(cb);
    cb.textMuted(ui.fmt(cb, "ratio {d:.2} - kept in the Model", .{m.split.ratio}));
    ui.endCard(cb);
    cb.popGroup();

    cb.popGroup();
}
