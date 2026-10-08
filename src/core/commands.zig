//! Command registry, keyboard shortcuts and the command palette.
//!
//! An App declares what it can do as DATA: a pure function of the Model that
//! fills a `CommandList(Msg)` with `{ id, label, shortcut, enabled, msg }`
//! rows. The runtime matches the frame's key chords against the enabled rows
//! BEFORE widget key handling and dispatches the matching row's `msg` through
//! `update` (HARDLINE: a command is a Msg, never a callback). The same table
//! feeds menu items (a label with its shortcut) and the `CommandPalette`.
//!
//! ```zig
//! pub fn commands(m: *const Model, list: *teak.CommandList(Msg)) void {
//!     list.add(.{ .id = "file.save", .label = "Save", .shortcut = .ctrl(.s),
//!                 .enabled = m.dirty, .msg = .save });
//!     list.add(.{ .id = "palette", .label = "Command Palette",
//!                 .shortcut = .ctrlShift(.p), .alt_shortcut = .ctrl(.k),
//!                 .msg = .{ .palette = .focus }, .hidden = true });
//! }
//! ```
//!
//! `Chord.mod` is the platform's primary modifier (Ctrl on Windows/Linux, Cmd
//! on macOS), so one table works everywhere; `Chord.format(w, platform)`
//! prints it the platform's way for menus and the palette.
//!
//! Pure data and pure functions: no platform imports, no clock, no state. See
//! docs/features/commands.md.

const std = @import("std");
const cmd = @import("cmd.zig");
const combobox = @import("combobox.zig");
const text_field = @import("text_field.zig");
const keys = @import("../input/keys.zig");

pub const Chord = keys.Chord;
pub const Platform = keys.Platform;

/// Commands one `CommandList` holds.
pub const max_commands = 96;

pub fn Command(comptime Msg: type) type {
    return struct {
        pub const MsgT = Msg;
        /// Stable identifier ("file.save"): what an agent or a config refers to.
        id: []const u8,
        /// Human label shown in menus and the palette ("Save").
        label: []const u8,
        /// The chord shown in menus and the palette, and one optional second
        /// binding. Stored by value (a slice of a temporary would dangle once
        /// the `commands` hook returns).
        shortcut: ?Chord = null,
        alt_shortcut: ?Chord = null,
        /// Disabled commands neither fire from shortcuts nor appear in the palette.
        enabled: bool = true,
        /// Not listed in the palette (the palette's own opener, internal commands),
        /// but its shortcuts still work.
        hidden: bool = false,
        /// What running the command does: dispatched through `update`.
        msg: Msg,

        /// The shortcut a menu shows next to the label, if any.
        pub fn primaryShortcut(self: @This()) ?Chord {
            return self.shortcut;
        }

        /// `label` + a column gap + the formatted primary shortcut ("Save    Ctrl+S"),
        /// allocated in `arena` (pass `cb.arena.allocator()`); the plain label
        /// when there is no shortcut. `column` pads the label to that many
        /// bytes so shortcuts line up in a monospace menu.
        pub fn menuLabel(self: @This(), arena: std.mem.Allocator, platform: Platform, column: usize) []const u8 {
            const sc = self.primaryShortcut() orelse return self.label;
            var aw: std.Io.Writer.Allocating = .init(arena);
            aw.writer.writeAll(self.label) catch return self.label;
            var pad: usize = if (column > self.label.len) column - self.label.len else 0;
            pad = @max(pad, 2);
            aw.writer.splatByteAll(' ', pad) catch return self.label;
            sc.format(&aw.writer, platform) catch return self.label;
            return aw.written();
        }
    };
}

/// A fixed-capacity command table, filled by the App's `commands` hook.
pub fn CommandList(comptime Msg: type) type {
    return struct {
        const Self = @This();
        pub const Cmd = Command(Msg);

        items: [max_commands]Cmd = undefined,
        len: usize = 0,

        /// Append a command (silently dropped past `max_commands`).
        pub fn add(self: *Self, c: Cmd) void {
            if (self.len == max_commands) return;
            self.items[self.len] = c;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const Cmd {
            return self.items[0..self.len];
        }

        /// The first ENABLED command bound to `chord`, if any.
        pub fn match(self: *const Self, chord: Chord) ?*const Cmd {
            for (self.items[0..self.len]) |*c| {
                if (!c.enabled) continue;
                if (c.shortcut) |sc| if (sc.eql(chord)) return c;
                if (c.alt_shortcut) |sc| if (sc.eql(chord)) return c;
            }
            return null;
        }

        /// The command with this `id`.
        pub fn byId(self: *const Self, id: []const u8) ?*const Cmd {
            for (self.items[0..self.len]) |*c| if (std.mem.eql(u8, c.id, id)) return c;
            return null;
        }

        /// The palette's option list: labels of the enabled, non-hidden
        /// commands, in table order. `map[i]` is the table index of option `i`.
        /// Returns the option count.
        pub fn paletteOptions(self: *const Self, labels: *[max_commands][]const u8, map: *[max_commands]u16) usize {
            var n: usize = 0;
            for (self.items[0..self.len], 0..) |c, i| {
                if (!c.enabled or c.hidden) continue;
                labels[n] = c.label;
                map[n] = @intCast(i);
                n += 1;
            }
            return n;
        }

        /// The command behind palette option `option` (the index a
        /// `CommandPalette` `.select` Msg carries).
        pub fn paletteCommand(self: *const Self, option: usize) ?*const Cmd {
            var labels: [max_commands][]const u8 = undefined;
            var map: [max_commands]u16 = undefined;
            const n = self.paletteOptions(&labels, &map);
            if (option >= n) return null;
            return &self.items[map[option]];
        }
    };
}

// ── Command palette ────────────────────────────────────────────────

pub const PaletteViewOpts = struct {
    /// Window size in logical pixels (centers the panel; pass what `windowMsg` gave you).
    window_w: f32 = 800,
    window_h: f32 = 600,
    /// Panel width.
    width: f32 = 480,
    /// Rows visible before the list scrolls.
    max_visible: usize = 9,
    platform: Platform = .pc,
    /// Pad labels to this many bytes so shortcuts align.
    column: usize = 34,
};

/// The command palette: a modal overlay with a query field and the command
/// table fuzzy-filtered below it; Up/Down move the highlight, Enter runs the
/// highlighted command, Escape or a click outside closes. Built on `Combobox`
/// (same Model / Msg / update; `.focus` opens it, `.select(i)` carries the
/// palette option index), composed from existing primitives (zero new Cmd
/// variants). All state is the `Model`.
///
/// Wiring (docs/cookbook.md recipe 16): the App keeps a `palette: Palette.Model`,
/// routes chars with `charMsg` and keys with `keyMsg` while `palette.open`,
/// renders with `viewPalette`, and on `.select(i)` closes the palette and runs
/// `list.paletteCommand(i).msg`.
pub fn CommandPalette(comptime cap: usize) type {
    return struct {
        const CB = combobox.Combobox(cap);
        pub const Model = CB.Model;
        pub const Msg = CB.Msg;
        pub const update = CB.update;
        pub const charMsg = CB.charMsg;
        pub const pasteMsg = CB.pasteMsg;

        /// Component-contract view (a component hosting the palette has no
        /// command table to show): nothing is drawn.
        pub fn view(_: *const Model, _: anytype, _: anytype) void {}

        fn comboOpts(opts: PaletteViewOpts) combobox.ViewOpts {
            return .{ .max_visible = opts.max_visible, .match = .fuzzy, .list_width = opts.width };
        }

        /// Open the palette with an empty query.
        pub fn openMsg() Msg {
            return .focus;
        }

        /// Map a special key while the palette is open: Up/Down/PageUp/PageDown
        /// move the highlight, Enter runs it (`.select`), Escape closes,
        /// editing keys edit the query. Null for anything else.
        pub fn keyMsg(model: *const Model, key: keys.SpecialKey, list: anytype, opts: PaletteViewOpts) ?Msg {
            if (!model.open) return null;
            var labels: [max_commands][]const u8 = undefined;
            var map: [max_commands]u16 = undefined;
            const n = list.paletteOptions(&labels, &map);
            return CB.keyMsg(model, key, labels[0..n], comboOpts(opts));
        }

        /// Wheel over the palette list.
        pub fn scrollByMsg(model: *const Model, delta: f32, list: anytype, opts: PaletteViewOpts) Msg {
            var labels: [max_commands][]const u8 = undefined;
            var map: [max_commands]u16 = undefined;
            const n = list.paletteOptions(&labels, &map);
            return CB.scrollByMsg(model, delta, labels[0..n], comboOpts(opts));
        }

        /// Draw the palette when open (nothing when closed). `msgs` carries
        /// `.focus` (query click), `.close` and `selectMsg: fn (usize) AppMsg`
        /// taking the palette option index.
        pub fn viewPalette(model: *const Model, cb: anytype, list: anytype, msgs: anytype, opts: PaletteViewOpts) void {
            if (!model.open) return;
            const arena = cb.arena.allocator();
            var labels: [max_commands][]const u8 = undefined;
            var map: [max_commands]u16 = undefined;
            const n_opts = list.paletteOptions(&labels, &map);
            // Rows show "label    shortcut".
            for (labels[0..n_opts], map[0..n_opts]) |*l, mi| l.* = list.items[mi].menuLabel(arena, opts.platform, opts.column);

            const q = model.query.content();
            const n = combobox.countMatches(q, labels[0..n_opts], .fuzzy);
            const rows: usize = @max(n, 1);
            const scrolls = opts.max_visible > 0 and rows > opts.max_visible;
            const shown = if (scrolls) opts.max_visible else rows;
            const row_h = combobox.ITEM_HEIGHT;
            const list_h = @as(f32, @floatFromInt(shown)) * row_h;
            const input_h: f32 = 36;
            const w = @min(opts.width, opts.window_w - 16);
            const x = @max((opts.window_w - w) / 2, 0);
            const y = opts.window_h * 0.14;

            // Dim, click-to-close layer over the whole window.
            cb.pushOverlay(.{
                .x = 0,
                .y = 0,
                .width = opts.window_w,
                .height = opts.window_h,
                .modal = true,
                .backdrop_msg = msgs.close,
                .backdrop = .{ 0, 0, 0, 0.45 },
                .padding = 0,
            });
            cb.popOverlay();
            // The panel.
            cb.pushOverlay(.{
                .x = x,
                .y = y,
                .width = w,
                .height = input_h + list_h + 2,
                .modal = true,
                .backdrop_msg = msgs.focus,
                .backdrop = cb.theme.panel_bg,
                .border = cb.theme.divider.color,
                .padding = 1,
                .gap = 0,
            });
            var input_style = cb.theme.text_input;
            input_style.min_width = w - 2;
            cb.textInputSelected(msgs.focus, q, model.query.cursor, model.query.selection_anchor, input_style);
            if (scrolls) {
                cb.pushScroll(.{
                    .direction = .vertical,
                    .width = w - 2,
                    .height = list_h,
                    .padding = 0,
                    .gap = 0,
                    .scroll_y = std.math.clamp(model.scroll_offset, 0, CB.maxScroll(n, opts.max_visible)),
                });
            } else {
                cb.pushGroup(.{ .direction = .vertical, .bg = cb.theme.panel_bg, .padding = 0, .gap = 0 });
            }
            if (n == 0) {
                cb.buttonDisabled(msgs.close, "No matching commands");
            } else {
                var ordinal: usize = 0;
                for (labels[0..n_opts], 0..) |label, i| {
                    if (!combobox.matches(q, list.items[map[i]].label, .fuzzy)) continue;
                    var row = cb.theme.button;
                    row.min_width = w - 2;
                    if (ordinal == model.highlighted) {
                        row.bg = cb.theme.button.hover_bg;
                        row.fg = cb.theme.button.hover_fg orelse cb.theme.button.fg;
                    }
                    cb.buttonStyled(msgs.selectMsg(i), label, row);
                    ordinal += 1;
                }
            }
            if (scrolls) cb.popScroll() else cb.popGroup();
            cb.popOverlay();
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const snapshot = @import("snapshot.zig");
const engine = @import("../layout/engine.zig");
const text = @import("text.zig");

const TMsg = union(enum) { save, open, find, palette_open, quit };
const List = CommandList(TMsg);

fn sampleList(dirty: bool) List {
    var l: List = .{};
    l.add(.{ .id = "file.save", .label = "Save", .shortcut = Chord.ctrl(.s), .enabled = dirty, .msg = .save });
    l.add(.{ .id = "file.open", .label = "Open File...", .shortcut = Chord.ctrl(.o), .alt_shortcut = Chord.plain(.f3), .msg = .open });
    l.add(.{ .id = "edit.find", .label = "Find in Document", .shortcut = Chord.ctrl(.f), .msg = .find });
    l.add(.{ .id = "palette", .label = "Command Palette", .shortcut = Chord.ctrlShift(.p), .alt_shortcut = Chord.ctrl(.k), .hidden = true, .msg = .palette_open });
    l.add(.{ .id = "app.quit", .label = "Quit", .shortcut = Chord.ctrl(.q), .msg = .quit });
    return l;
}

test "match: enabled commands only, any of the chords" {
    var l = sampleList(true);
    try testing.expectEqual(TMsg.save, l.match(Chord.ctrl(.s)).?.msg);
    try testing.expectEqual(TMsg.open, l.match(Chord.plain(.f3)).?.msg);
    try testing.expectEqual(TMsg.palette_open, l.match(Chord.ctrl(.k)).?.msg);
    try testing.expectEqual(TMsg.palette_open, l.match(Chord.ctrlShift(.p)).?.msg);
    try testing.expect(l.match(Chord.ctrl(.z)) == null);
    try testing.expect(l.match(Chord.ctrlShift(.s)) == null); // Shift matters

    l = sampleList(false); // Save disabled: the chord no longer fires
    try testing.expect(l.match(Chord.ctrl(.s)) == null);
    try testing.expectEqualStrings("app.quit", l.byId("app.quit").?.id);
}

test "paletteOptions skips disabled and hidden commands; paletteCommand maps back" {
    const l = sampleList(false);
    var labels: [max_commands][]const u8 = undefined;
    var map: [max_commands]u16 = undefined;
    const n = l.paletteOptions(&labels, &map);
    try testing.expectEqual(@as(usize, 3), n); // Open, Find, Quit
    try testing.expectEqualStrings("Find in Document", labels[1]);
    try testing.expectEqual(TMsg.find, l.paletteCommand(1).?.msg);
    try testing.expectEqual(TMsg.quit, l.paletteCommand(2).?.msg);
    try testing.expect(l.paletteCommand(3) == null);
}

test "menuLabel puts the platform's shortcut next to the label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const l = sampleList(true);
    try testing.expectEqualStrings("Save    Ctrl+S", l.items[0].menuLabel(arena.allocator(), .pc, 8));
    try testing.expectEqualStrings("Save  Cmd+S", l.items[0].menuLabel(arena.allocator(), .mac, 0));
    var none = Command(TMsg){ .id = "x", .label = "Plain", .msg = .quit };
    try testing.expectEqualStrings("Plain", none.menuLabel(arena.allocator(), .pc, 8));
    _ = &none;
}

const P = CommandPalette(24);

fn pick(i: usize) TMsg {
    _ = i;
    return .quit;
}

test "palette: fuzzy filter, highlight, Enter selects the Nth match's option index" {
    const l = sampleList(true);
    var m: P.Model = .{};
    try testing.expect(P.keyMsg(&m, .enter, &l, .{}) == null); // closed: nothing
    P.update(&m, P.openMsg());
    try testing.expect(m.open);
    for ("fnd") |c| P.update(&m, P.charMsg(c)); // "Find in Document"
    const enter = P.keyMsg(&m, .enter, &l, .{}).?;
    // Option indices skip the hidden palette row: Save 0, Open 1, Find 2, Quit 3.
    try testing.expectEqual(P.Msg{ .select = 2 }, enter);
    try testing.expectEqual(TMsg.find, l.paletteCommand(enter.select).?.msg);
    // A query that matches nothing: Enter does nothing.
    for ("zzz") |c| P.update(&m, P.charMsg(c));
    try testing.expect(P.keyMsg(&m, .enter, &l, .{}) == null);
    try testing.expectEqual(P.Msg.close, P.keyMsg(&m, .escape, &l, .{}).?);
}

test "viewPalette: closed draws nothing; open draws dim layer, panel, query and rows with shortcuts" {
    const App = struct {
        pub const Msg = TMsg;
        const msgs = .{ .focus = TMsg.palette_open, .close = TMsg.quit, .selectMsg = pick };
    };
    const l = sampleList(true);
    var m: P.Model = .{};
    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    P.viewPalette(&m, &cb, &l, App.msgs, .{});
    try testing.expectEqual(@as(usize, 0), cb.cmds.items.len);

    P.update(&m, .focus);
    P.viewPalette(&m, &cb, &l, App.msgs, .{ .window_w = 800, .window_h = 600 });
    try testing.expect(cmd.validateBalance(cb.cmds.items) == null);
    var rects: [64]engine.Rect = undefined;
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 800, 600, text.monoMeasurer());
    const snap = try snapshot.snapshotAlloc(testing.allocator, cb.cmds.items, rects[0..n], .{});
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\"Save") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "Ctrl+S") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "Command Palette") == null); // hidden
    try testing.expect(std.mem.indexOf(u8, snap, "Ctrl+Q") != null);
}
