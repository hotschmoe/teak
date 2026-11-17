const std = @import("std");
const teak = @import("teak");
const component = teak.component;
const counter = @import("counter.zig");
const greeter = @import("greeter.zig");
const rich_zig_adapter = @import("rich_zig_adapter.zig");

// ── Composed Application ───────────────────────────────────────────
//
// Compose counter + greeter into one app via teak.component.Components, plus AppLevel
// state for focus tracking. Keyboard events aren't in AppLevel.Msg — the
// main loop reads Model.focused and translates keys directly into
// component Msgs (e.g. Msg{ .greeter = .{ .name_char = c } }). This keeps
// AppLevel tiny and avoids duplicate enum plumbing.

pub const FocusField = enum { greeter };

const AppLevel = struct {
    focused: ?FocusField = null,
    /// Demo: help modal open/closed state. Driven by AppLevel Msgs so
    /// nothing platform-specific leaks into the component world.
    show_help_modal: bool = false,
    /// Theme toggle — drives `cb.theme = Theme.dark_default vs
    /// Theme.light_default` at the host boundary (see ui_main.zig).
    dark_mode: bool = true,
    /// Set when the user has asked the host to open the secondary
    /// stats window; cleared when the user asks to close it. The host
    /// (ui_main.zig) reads this flag and creates / tears down the
    /// actual platform + GPU resources — neither belongs in Model.
    show_stats_window: bool = false,

    pub const Msg = union(enum) {
        focus_set: FocusField,
        focus_clear,
        help_open,
        help_close,
        toggle_theme,
        open_stats_window,
        close_stats_window,
    };

    // `@This().Msg` disambiguates against the file-scope `pub const Msg`
    // alias below — both are in scope from inside this struct.
    pub fn update(model: anytype, msg: @This().Msg) void {
        switch (msg) {
            .focus_set => |f| model.focused = f,
            .focus_clear => model.focused = null,
            .help_open => model.show_help_modal = true,
            .help_close => model.show_help_modal = false,
            .toggle_theme => model.dark_mode = !model.dark_mode,
            .open_stats_window => model.show_stats_window = true,
            .close_stats_window => model.show_stats_window = false,
        }
    }
};

const Composed = component.Components(.{
    .counter = counter,
    .greeter = greeter,
}, AppLevel);

pub const Model = Composed.Model;
pub const Msg = Composed.Msg;
pub const update = Composed.update;

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });

    // Top toolbar: Help button + theme toggle + stats-window toggle.
    // AppLevel Msgs only; the host (ui_main.zig) consumes
    // `show_stats_window` to manage the secondary platform window.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 8, .gap = 8 });
    cb.button(Msg{ .help_open = {} }, "Help");
    cb.button(Msg{ .toggle_theme = {} }, if (m.dark_mode) "Light mode" else "Dark mode");
    cb.button(
        if (m.show_stats_window) Msg{ .close_stats_window = {} } else Msg{ .open_stats_window = {} },
        if (m.show_stats_window) "Close stats" else "Open stats",
    );
    cb.popGroup();

    // Main row: counter on the left, greeter on the right.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 16, .gap = 16 });

    // Counter: payloadless variants wrap straight into AppMsg.
    counter.view(&m.counter, cb, component.buildMsgs(counter, "counter", Msg));

    // Greeter: wrapped in flex=1 so it claims remaining horizontal space.
    // Its `focus` click routes to AppLevel (focus_set), not Greeter.update —
    // so we hand-build this msgs struct instead of using buildMsgs.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .flex = 1 });
    greeter.view(&m.greeter, cb, .{ .focus = Msg{ .focus_set = .greeter } });
    cb.popGroup();

    cb.popGroup();

    cb.popGroup();

    // Modal overlay rendered last so it's at the top of the buffer;
    // hit-test gives it precedence regardless. The host should set the
    // overlay's width/height to the window size for a true modal
    // backdrop — for now we use a generous 900x500.
    if (m.show_help_modal) {
        cb.pushOverlay(.{
            .x = 0,
            .y = 0,
            .width = 900,
            .height = 500,
            .padding = 0,
            // Dim scrim behind the panel — opaque enough to push the
            // underlying UI back so the modal panel reads as the focused
            // surface. The panel itself supplies its own opaque fill via
            // GroupStyle.bg (theme.panel_bg) below.
            .backdrop = .{ 0, 0, 0, 0.78 },
            // Modal: clicking the dim scrim must NOT activate widgets
            // underneath. Click-outside-to-close dismisses via help_close
            // — matches HARDLINE §2 hatch 5's "modal + backdrop_msg"
            // pattern.
            .modal = true,
            .backdrop_msg = Msg{ .help_close = {} },
        });
        // Inner panel: centered card with text + close button. The
        // `bg = panel_bg` is what makes the help text readable — without
        // it the labels float directly on the dim scrim.
        cb.pushGroup(.{
            .direction = .vertical,
            .padding = 16,
            .gap = 12,
            .bg = cb.theme.panel_bg,
        });
        cb.heading("Teak — Functional Gaps + Ergonomic Helpers demo");

        // Rich text via rich_zig markup. Parsed once per frame into the
        // CmdBuffer's arena — fine for a panel that doesn't change.
        const rich = rich_zig_adapter.buildRichText(
            cb.arena.allocator(),
            "[bold]Overlay[/], [bold]virtual list[/], [bold]image[/], and [bold red]rich text[/] now live.",
            .{ 0.92, 0.92, 0.94, 1.0 },
            .{ .size_px = 14, .family = .sans },
        ) catch teak.RichTextCmd{ .content = "(rich text parse failed)" };
        cb.richTextStyled(rich);

        // Mixed-font demo: a results line where the value is mono and
        // the units are muted. Identical shape any engineering UI
        // would use for readouts.
        cb.mixedText(&.{
            .{ .text = "Count: ", .color = cb.theme.muted_color },
            .{ .text = std.fmt.allocPrint(
                cb.arena.allocator(),
                "{d}",
                .{m.counter.count},
            ) catch "?", .font = cb.theme.typography.mono },
            .{ .text = "  ·  Name: ", .color = cb.theme.muted_color },
            .{ .text = if (m.greeter.name_len > 0)
                m.greeter.name[0..m.greeter.name_len]
            else
                "(unset)", .font = cb.theme.typography.mono },
        });

        // Form row demo: label + content + units + validation. The
        // form-row helper brackets the layout; the textInput inside is
        // a non-functional placeholder for this illustrative demo.
        cb.pushFormRow(.{
            .label = "Throughput",
            .units = "ops/s",
            .validation = if (m.counter.count < 0) "negative — check sign" else "",
        });
        cb.textMono(std.fmt.allocPrint(
            cb.arena.allocator(),
            "{d}.0",
            .{m.counter.count},
        ) catch "0");
        cb.popFormRow();

        cb.button(Msg{ .help_close = {} }, "Close");
        cb.popGroup();
        cb.popOverlay();
    }
}

/// Build the secondary "Stats" window's UI. Same Cmd type as the
/// primary view so layout / render passes are window-agnostic — the
/// host just hands a different CmdBuffer to a different surface. No
/// interactive widgets here: the secondary window's only job is to
/// mirror the counter value in a separate top-level window.
pub fn statsView(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8, .bg = cb.theme.panel_bg });
    cb.heading("Stats");
    const text_buf = std.fmt.allocPrint(
        cb.arena.allocator(),
        "Counter: {d}",
        .{m.counter.count},
    ) catch "Counter: ?";
    cb.text(text_buf);
    const name_buf = std.fmt.allocPrint(
        cb.arena.allocator(),
        "Name: {s}",
        .{if (m.greeter.name_len > 0) m.greeter.name[0..m.greeter.name_len] else "(unset)"},
    ) catch "Name: ?";
    cb.text(name_buf);

    // Count-history line chart. The chart helper turns the counter's
    // rolling history window (plain Model state, updated in counter.update)
    // into gridlines + a polyline; the canvas cmd renders them through the
    // solid-quad pipeline. ~3 lines of view code for a full line chart.
    const series = counter.history(&m.counter);
    if (series.len >= 1) {
        var lo: f32 = series[0];
        var hi: f32 = series[0];
        for (series) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        // Pad the range a touch so a flat series isn't pinned to an edge.
        if (hi == lo) {
            hi += 1;
            lo -= 1;
        }
        const prims = teak.chart.lineChartPrimitives(
            cb.arena.allocator(),
            series,
            .{ .width = 320, .height = 100, .min = lo, .max = hi, .grid_lines = 4 },
        );
        cb.canvasLabeled(.{ .width = 320, .height = 100, .bg = cb.theme.panel_bg }, prims, "count history");
    }

    cb.popGroup();
}

/// Translate a character typed while a text input is focused into the
/// correct component Msg. Returns null if nothing is focused, which means
/// the main loop should drop the key event.
pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    const f = m.focused orelse return null;
    return switch (f) {
        .greeter => Msg{ .greeter = .{ .name_char = c } },
    };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    const f = m.focused orelse return null;
    return switch (f) {
        .greeter => switch (key) {
            .backspace => Msg{ .greeter = .name_backspace },
            .left => Msg{ .greeter = .name_cursor_left },
            .right => Msg{ .greeter = .name_cursor_right },
            .shift_left => Msg{ .greeter = .name_select_left },
            .shift_right => Msg{ .greeter = .name_select_right },
            .ctrl_a => Msg{ .greeter = .name_select_all },
            .escape => Msg{ .greeter = .name_select_none },
            // ctrl_c / ctrl_x / ctrl_v are routed by the host loop
            // through clipboard() — they don't translate to a single
            // component Msg here. The host calls the appropriate one
            // directly using the clipboard surface.
            else => null,
        },
    };
}

/// Currently selected greeter text, or "" if none. Used by
/// `clipboardText` / `clipboardMsg` for ctrl_c / ctrl_x.
pub fn greeterSelection(m: *const Model) []const u8 {
    return greeter.selectionText(&m.greeter);
}

// ── teak.run hooks ─────────────────────────────────────────────────
//
// The optional decls `teak.run` detects with `@hasDecl`. They move the
// per-app variance (theme, focus, clipboard policy, the secondary Stats
// window) out of a hand-rolled loop and into data/Msg-shaped functions.

/// Per-frame theme. `dark_mode` flips between the two presets — the same
/// choice the old `ui_main.zig` made when assigning `cb.theme`.
pub fn themeFor(m: *const Model) teak.Theme {
    return if (m.dark_mode) teak.Theme.dark_default else teak.Theme.light_default;
}

/// The greeter input's focus Msg when focused, so `teak.run` draws its
/// focus ring + blinks the cursor. The input's `focus_msg` is
/// `focus_set = .greeter`, which `run` maps back to a cmd index by value.
pub fn focusedMsg(m: *const Model) ?Msg {
    if (m.focused == null) return null;
    return Msg{ .focus_set = .greeter };
}

/// What Ctrl+C / Ctrl+X put on the OS clipboard: the greeter's selection (a
/// pure query; `teak.run` does the write).
pub fn clipboardText(m: *const Model, key: teak.SpecialKey) ?[]const u8 {
    if (key != .ctrl_c and key != .ctrl_x) return null;
    const sel = greeterSelection(m);
    return if (sel.len > 0) sel else null;
}

/// The Msg for a clipboard chord: Ctrl+V pastes over the selection, Ctrl+X
/// deletes it (after `clipboardText` copied it), Ctrl+C changes nothing.
pub fn clipboardMsg(m: *const Model, key: teak.SpecialKey, paste: []const u8) ?Msg {
    return switch (key) {
        .ctrl_x => if (greeterSelection(m).len > 0) Msg{ .greeter = .name_backspace } else null,
        .ctrl_v => Msg{ .greeter = .{ .name_replace_selection = paste } },
        else => null,
    };
}

/// Declares the secondary "Stats" window when the user has toggled it on.
/// `teak.run` owns the platform + GPU window lifecycle keyed off this
/// data-shaped spec (HARDLINE §4(c) — the app never touches
/// `Host.openSecondaryWindow`).
pub fn secondaryWindow(m: *const Model) ?teak.SecondaryWindowSpec {
    return if (m.show_stats_window)
        .{ .title = "Teak — Stats", .width = 360, .height = 200 }
    else
        null;
}

/// The secondary window's view. Same Cmd type as the primary; `run` hands
/// it a different CmdBuffer bound to a different surface.
pub const secondaryView = statsView;

/// Dispatched when the user closes the Stats window from the OS, so the
/// `show_stats_window` flag flips back and the toolbar button re-labels.
pub fn secondaryClosedMsg(_: *const Model) ?Msg {
    return .close_stats_window;
}

// ── Tests ──────────────────────────────────────────────────────────











