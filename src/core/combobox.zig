//! Searchable select ("combobox"): a text input that filters an app-owned
//! option list shown in the same modal-overlay list `Dropdown` uses.
//!
//! Built ENTIRELY from existing primitives (zero new Cmd variants): a
//! `text_input` for the query, then `push_overlay` (modal, `backdrop_msg` =
//! close) holding one `button` per matching option -- inside a `push_scroll`
//! when the matches exceed `max_visible`. Like Dropdown, the option labels are
//! owned by the app and passed to `viewWith`; the component stores only the
//! query, the open flag, the selected index, the highlighted *match ordinal*
//! and the list scroll offset (HARDLINE §1: all state in the Model).
//!
//! Matching is case-insensitive over code points (ASCII, Latin-1/Extended-A,
//! Greek and Cyrillic fold) and grapheme-safe: a match must start and end on
//! option grapheme boundaries, so "e" does not match half of "e" + U+0301.
//! `Match.substring` (default) or `Match.prefix`.
//!
//! Interaction: click the input (or type) to open; typing filters and puts the
//! highlight on the first match; Up/Down/PageUp/PageDown move the highlight
//! (scrolled into view), Enter commits it, Escape or a click outside closes,
//! clicking a row selects it. With no matches a disabled "No matches" row shows.
//!
//! Wiring (see docs/cookbook.md recipe 14): the app routes chars with
//! `charMsg`, keys with `keyMsg`, and wheel with `scrollByMsg`, wrapping the
//! results in its AppMsg exactly as for Dropdown.

const std = @import("std");
const cmd = @import("cmd.zig");
const component = @import("component.zig");
const text_field = @import("text_field.zig");
const unicode = @import("unicode.zig");
const keys = @import("../input/keys.zig");
const dropdown = @import("dropdown.zig");

/// Height of one list row (matches `Dropdown`'s `ITEM_HEIGHT`).
pub const ITEM_HEIGHT: f32 = dropdown.ITEM_HEIGHT;

/// Label of the disabled row shown when the query matches nothing.
pub const NO_MATCHES = "No matches";

pub const Match = enum {
    /// The query may appear anywhere in the option.
    substring,
    /// The option must start with the query.
    prefix,
};

pub const ViewOpts = struct {
    /// Window-absolute top-left of the open list (typically the bottom-left of
    /// the input's previous-frame rect).
    list_x: f32 = 0,
    list_y: f32 = 0,
    list_width: f32 = 200,
    /// Rows visible before the list scrolls. `0` = never scroll.
    max_visible: usize = 8,
    match: Match = .substring,
    /// Input styling; null uses the theme's `text_input`.
    input_style: ?cmd.TextInputStyle = null,
};

// ── Matching (pure) ────────────────────────────────────────────────

/// Simple case fold: ASCII, Latin-1 Supplement, Latin Extended-A (paired
/// forms), Greek and Cyrillic capitals map to their lowercase.
pub fn foldCase(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 32,
        0x100...0x137, 0x14A...0x177 => if (cp % 2 == 0) cp + 1 else cp,
        0x139...0x148, 0x179...0x17E => if (cp % 2 == 1) cp + 1 else cp,
        0x391...0x3A1, 0x3A3...0x3A9 => cp + 32,
        0x410...0x42F => cp + 32,
        0x400...0x40F => cp + 80,
        else => cp,
    };
}

/// True when `option` matches `query` (empty queries match everything).
pub fn matches(query: []const u8, option: []const u8, mode: Match) bool {
    if (query.len == 0) return true;
    var start: usize = 0;
    while (start < option.len) {
        if (matchAt(query, option, start)) return true;
        if (mode == .prefix) return false;
        start = unicode.nextGrapheme(option, start);
    }
    return false;
}

fn matchAt(query: []const u8, option: []const u8, start: usize) bool {
    var qi: usize = 0;
    var oi = start;
    while (qi < query.len) {
        if (oi >= option.len) return false;
        const q = unicode.utf8DecodeLossy(query, qi);
        const o = unicode.utf8DecodeLossy(option, oi);
        if (foldCase(q.cp) != foldCase(o.cp)) return false;
        qi += q.len;
        oi += o.len;
    }
    return unicode.isGraphemeBoundary(option, oi);
}

/// Number of options matching `query`.
pub fn countMatches(query: []const u8, options: []const []const u8, mode: Match) usize {
    var n: usize = 0;
    for (options) |o| n += @intFromBool(matches(query, o, mode));
    return n;
}

/// Original index of the `n`th (0-based) matching option.
pub fn nthMatch(query: []const u8, options: []const []const u8, mode: Match, n: usize) ?usize {
    var k: usize = 0;
    for (options, 0..) |o, i| {
        if (!matches(query, o, mode)) continue;
        if (k == n) return i;
        k += 1;
    }
    return null;
}

/// Ordinal of original option `index` among the matches, or null if filtered out.
pub fn ordinalOf(query: []const u8, options: []const []const u8, mode: Match, index: usize) ?usize {
    if (index >= options.len or !matches(query, options[index], mode)) return null;
    var k: usize = 0;
    for (options[0..index]) |o| k += @intFromBool(matches(query, o, mode));
    return k;
}

fn hashContent(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

// ── Component ──────────────────────────────────────────────────────

/// A combobox whose query field holds up to `cap` bytes.
pub fn Combobox(comptime cap: usize) type {
    return struct {
        const TF = text_field.TextField(cap);
        pub const capacity = cap;

        pub const Move = enum { prev, next, first, last, page_prev, page_next };

        pub const Highlight = struct {
            move: Move,
            /// Number of matches (upper clamp).
            count: usize,
            /// Viewport rows (page size and scroll-to-reveal; 0 = no scrolling).
            max_visible: usize,
        };

        pub const ScrollBy = struct { delta: f32, max: f32 };

        pub const Msg = union(enum) {
            /// Click on the input: open the list with an empty query.
            focus,
            /// Close without changing the selection (Escape, click outside).
            close,
            /// Choose original option index `i`.
            select: usize,
            /// Query editing; changing the text opens the list and resets the highlight.
            edit: TF.Msg,
            highlight: Highlight,
            scroll_by: ScrollBy,
        };

        pub const Model = struct {
            query: TF.Model = .{},
            open: bool = false,
            /// Index into the app's options, null = nothing chosen yet.
            selected: ?usize = null,
            /// Keyboard highlight as an ordinal among the *matches*.
            highlighted: usize = 0,
            scroll_offset: f32 = 0,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .focus => if (!model.open) {
                    model.open = true;
                    model.query.clear();
                    // Empty query: ordinals equal original indices.
                    model.highlighted = model.selected orelse 0;
                    model.scroll_offset = 0;
                },
                .close => {
                    model.open = false;
                    model.query.clear();
                },
                .select => |i| {
                    model.selected = i;
                    model.open = false;
                    model.query.clear();
                },
                .edit => |m| {
                    const before = hashContent(model.query.content());
                    TF.update(&model.query, m);
                    if (hashContent(model.query.content()) != before) {
                        model.open = true;
                        model.highlighted = 0;
                        model.scroll_offset = 0;
                    }
                },
                .highlight => |h| {
                    if (h.count == 0) {
                        model.highlighted = 0;
                        return;
                    }
                    const last = h.count - 1;
                    const c = @min(model.highlighted, last);
                    const page = @max(h.max_visible, 1);
                    model.highlighted = switch (h.move) {
                        .prev => c -| 1,
                        .next => @min(c + 1, last),
                        .first => 0,
                        .last => last,
                        .page_prev => c -| page,
                        .page_next => @min(c + page, last),
                    };
                    model.scroll_offset = reveal(model.scroll_offset, model.highlighted, h.max_visible);
                },
                .scroll_by => |s| {
                    model.scroll_offset = std.math.clamp(model.scroll_offset + s.delta, 0, @max(0, s.max));
                },
            }
        }

        fn reveal(scroll: f32, i: usize, max_visible: usize) f32 {
            if (max_visible == 0) return scroll;
            const viewport = @as(f32, @floatFromInt(max_visible)) * ITEM_HEIGHT;
            const top = @as(f32, @floatFromInt(i)) * ITEM_HEIGHT;
            var new = scroll;
            if (top < new) new = top;
            if (top + ITEM_HEIGHT > new + viewport) new = top + ITEM_HEIGHT - viewport;
            return @max(0, new);
        }

        // ── Msg builders for the app's host hooks ─────────────────

        /// Msg for one typed byte (route from `keyCharMsg` while the combobox has focus).
        pub fn charMsg(c: u8) Msg {
            return .{ .edit = .{ .char = c } };
        }

        /// Msg for a pasted/replacement string.
        pub fn pasteMsg(bytes: []const u8) Msg {
            return .{ .edit = .{ .replace_selection = bytes } };
        }

        pub fn highlightMsg(model: *const Model, move: Move, options: []const []const u8, opts: ViewOpts) Msg {
            return .{ .highlight = .{
                .move = move,
                .count = countMatches(model.query.content(), options, opts.match),
                .max_visible = opts.max_visible,
            } };
        }

        pub fn scrollByMsg(model: *const Model, delta: f32, options: []const []const u8, opts: ViewOpts) Msg {
            return .{ .scroll_by = .{ .delta = delta, .max = maxScroll(countMatches(model.query.content(), options, opts.match), opts.max_visible) } };
        }

        /// The Msg for Enter: select the highlighted match. Null when closed or nothing matches.
        pub fn enterMsg(model: *const Model, options: []const []const u8, opts: ViewOpts) ?Msg {
            if (!model.open) return null;
            const i = nthMatch(model.query.content(), options, opts.match, model.highlighted) orelse return null;
            return .{ .select = i };
        }

        /// Map a special key to a Msg: Up/Down/PageUp/PageDown move the
        /// highlight (Down on a closed combobox opens it), Enter commits,
        /// Escape closes, editing keys (Backspace, Delete, arrows, Home/End, word
        /// chords, Ctrl+A/Z/Y) edit the query. Null for anything else.
        pub fn keyMsg(model: *const Model, key: keys.SpecialKey, options: []const []const u8, opts: ViewOpts) ?Msg {
            switch (key) {
                .up, .down, .page_up, .page_down => {
                    if (!model.open) return if (key == .down) .focus else null;
                    const mv: Move = switch (key) {
                        .up => .prev,
                        .down => .next,
                        .page_up => .page_prev,
                        else => .page_next,
                    };
                    return highlightMsg(model, mv, options, opts);
                },
                .enter => return enterMsg(model, options, opts),
                .escape => return if (model.open) .close else null,
                else => return text_field.textFieldSpecial(Msg, "edit", key),
            }
        }

        /// The text the input shows: the query while open, else the selected label.
        pub fn shownText(model: *const Model, options: []const []const u8) []const u8 {
            if (model.open) return model.query.content();
            const s = model.selected orelse return "";
            return if (s < options.len) options[s] else "";
        }

        pub fn maxScroll(count: usize, max_visible: usize) f32 {
            if (max_visible == 0 or count <= max_visible) return 0;
            return @as(f32, @floatFromInt(count - max_visible)) * ITEM_HEIGHT;
        }

        // ── View ──────────────────────────────────────────────────

        /// Canonical 3-arg view (composes through `Components`): just the input.
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            cb.textInputSelected(msgs.focus, model.query.content(), model.query.cursor, model.query.selection_anchor, cb.theme.text_input);
        }

        /// Full view, called explicitly by the app. `msgs` carries `.focus`
        /// (input click), `.close` (backdrop / disabled row) and a comptime
        /// `selectMsg: fn (usize) AppMsg` taking the *original* option index.
        pub fn viewWith(model: *const Model, cb: anytype, options: []const []const u8, msgs: anytype, opts: ViewOpts) void {
            const style = opts.input_style orelse cb.theme.text_input;
            if (model.open) {
                cb.textInputSelected(msgs.focus, model.query.content(), model.query.cursor, model.query.selection_anchor, style);
            } else {
                cb.textInputSelected(msgs.focus, shownText(model, options), 0, null, style);
                return;
            }

            const q = model.query.content();
            const n = countMatches(q, options, opts.match);
            const rows: usize = @max(n, 1);
            const scrolls = opts.max_visible > 0 and rows > opts.max_visible;
            const shown_rows = if (scrolls) opts.max_visible else rows;
            const viewport_h = @as(f32, @floatFromInt(shown_rows)) * ITEM_HEIGHT;

            cb.pushOverlay(.{
                .x = opts.list_x,
                .y = opts.list_y,
                .width = opts.list_width,
                .height = viewport_h,
                .modal = true,
                .backdrop_msg = msgs.close,
                .backdrop = cb.theme.panel_bg,
                .padding = 0,
                .gap = 0,
            });
            if (scrolls) {
                cb.pushScroll(.{
                    .direction = .vertical,
                    .width = opts.list_width,
                    .height = viewport_h,
                    .padding = 0,
                    .gap = 0,
                    .scroll_y = std.math.clamp(model.scroll_offset, 0, maxScroll(n, opts.max_visible)),
                });
            } else {
                cb.pushGroup(.{ .direction = .vertical, .bg = cb.theme.panel_bg, .padding = 0, .gap = 0 });
            }
            if (n == 0) {
                cb.buttonDisabled(msgs.close, NO_MATCHES);
            } else {
                var ordinal: usize = 0;
                for (options, 0..) |opt, i| {
                    if (!matches(q, opt, opts.match)) continue;
                    var row = cb.theme.button;
                    row.min_width = opts.list_width;
                    if (ordinal == model.highlighted) {
                        row.bg = cb.theme.button.hover_bg;
                        row.fg = cb.theme.button.hover_fg orelse cb.theme.button.fg;
                    }
                    cb.buttonStyled(msgs.selectMsg(i), opt, row);
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

test "foldCase and matches: case, accents, Greek, Cyrillic" {
    try testing.expect(matches("beam", "Wood BEAM 2x10", .substring));
    try testing.expect(!matches("beam", "Wood BEAM 2x10", .prefix));
    try testing.expect(matches("wood", "Wood BEAM 2x10", .prefix));
    try testing.expect(matches("", "anything", .prefix));
    try testing.expect(matches("\u{00E9}cole", "\u{00C9}COLE", .prefix)); // é / É
    try testing.expect(matches("\u{03C3}", "\u{03A3}IGMA", .prefix)); // σ / Σ
    try testing.expect(matches("\u{0434}\u{043E}\u{043C}", "\u{0414}\u{041E}\u{041C}", .prefix));
    try testing.expect(!matches("x", "", .substring));
}

test "matches is grapheme-safe" {
    // "e" must not match the base of "e" + COMBINING ACUTE (that would split the cluster).
    try testing.expect(!matches("e", "e\u{0301}", .substring));
    try testing.expect(matches("e\u{0301}", "caf\u{0065}\u{0301}", .substring));
    // Matching the start of a flag is also a split.
    try testing.expect(!matches("\u{1F1FA}", "\u{1F1FA}\u{1F1F8}", .substring));
    try testing.expect(matches("\u{1F1FA}\u{1F1F8}", "x\u{1F1FA}\u{1F1F8}", .substring));
    // Invalid bytes never crash.
    try testing.expect(!matches("a", "\xFF\xFE", .substring));
}

const opts_list = [_][]const u8{ "Pine", "Oak", "Maple", "Spruce", "Cedar", "Birch", "Ash", "Beech" };

test "countMatches / nthMatch / ordinalOf" {
    try testing.expectEqual(@as(usize, 8), countMatches("", &opts_list, .substring));
    try testing.expectEqual(@as(usize, 5), countMatches("e", &opts_list, .substring)); // Pine Maple Spruce Cedar Beech
    try testing.expectEqual(@as(?usize, 0), nthMatch("pi", &opts_list, .prefix, 0));
    try testing.expectEqual(@as(?usize, null), nthMatch("pi", &opts_list, .prefix, 1));
    try testing.expectEqual(@as(?usize, 7), nthMatch("b", &opts_list, .prefix, 1));
    try testing.expectEqual(@as(?usize, 1), ordinalOf("b", &opts_list, .prefix, 7));
    try testing.expectEqual(@as(?usize, null), ordinalOf("b", &opts_list, .prefix, 0));
}

const CB = Combobox(16);

fn typeStr(m: *CB.Model, s: []const u8) void {
    for (s) |c| CB.update(m, CB.charMsg(c));
}

test "validateComponent: Combobox satisfies the component contract" {
    component.validateComponent(CB);
}

test "update: focus opens, typing filters + resets highlight, select closes" {
    var m: CB.Model = .{};
    CB.update(&m, .focus);
    try testing.expect(m.open);
    typeStr(&m, "ar");
    try testing.expectEqualStrings("ar", m.query.content());
    try testing.expectEqual(@as(usize, 0), m.highlighted);
    CB.update(&m, .{ .select = 4 });
    try testing.expect(!m.open);
    try testing.expectEqual(@as(?usize, 4), m.selected);
    try testing.expectEqualStrings("", m.query.content());
    // Focusing again parks the highlight on the selection.
    CB.update(&m, .focus);
    try testing.expectEqual(@as(usize, 4), m.highlighted);
    // Cursor-only edits don't reset the highlight.
    CB.update(&m, .{ .highlight = .{ .move = .last, .count = 8, .max_visible = 0 } });
    CB.update(&m, .{ .edit = .cursor_left });
    try testing.expectEqual(@as(usize, 7), m.highlighted);
    CB.update(&m, .close);
    try testing.expect(!m.open);
}

test "keyMsg: arrows move the highlight, Enter commits the Nth match, Escape closes" {
    var m: CB.Model = .{};
    const o: ViewOpts = .{ .max_visible = 3 };
    // Closed: Down opens, Up/Enter/Escape do nothing.
    try testing.expectEqual(CB.Msg.focus, CB.keyMsg(&m, .down, &opts_list, o).?);
    try testing.expect(CB.keyMsg(&m, .up, &opts_list, o) == null);
    try testing.expect(CB.keyMsg(&m, .enter, &opts_list, o) == null);
    try testing.expect(CB.keyMsg(&m, .escape, &opts_list, o) == null);

    CB.update(&m, .focus);
    typeStr(&m, "e"); // Pine, Maple, Spruce, Cedar, Beech -> 5 matches
    CB.update(&m, CB.keyMsg(&m, .down, &opts_list, o).?);
    CB.update(&m, CB.keyMsg(&m, .down, &opts_list, o).?);
    try testing.expectEqual(@as(usize, 2), m.highlighted);
    // Enter selects the 3rd match = Spruce (original index 3).
    try testing.expectEqual(CB.Msg{ .select = 3 }, CB.keyMsg(&m, .enter, &opts_list, o).?);
    // Scroll-to-reveal after moving past the 3-row viewport.
    CB.update(&m, CB.keyMsg(&m, .down, &opts_list, o).?);
    try testing.expectEqual(@as(f32, ITEM_HEIGHT), m.scroll_offset);
    CB.update(&m, CB.keyMsg(&m, .page_up, &opts_list, o).?);
    try testing.expectEqual(@as(usize, 0), m.highlighted);
    try testing.expectEqual(@as(f32, 0), m.scroll_offset);
    // Editing keys map to query edits.
    try testing.expectEqual(CB.Msg{ .edit = .backspace }, CB.keyMsg(&m, .backspace, &opts_list, o).?);
    try testing.expectEqual(CB.Msg.close, CB.keyMsg(&m, .escape, &opts_list, o).?);
    // No matches: Enter does nothing.
    typeStr(&m, "zzz");
    try testing.expect(CB.keyMsg(&m, .enter, &opts_list, o) == null);
}

const ViewOpts_ = ViewOpts;

const App = struct {
    pub const Msg = union(enum) { focus, close, select: usize };
    fn pick(i: usize) Msg {
        return .{ .select = i };
    }
    const msgs = .{ .focus = Msg.focus, .close = Msg.close, .selectMsg = pick };
};

fn renderSnapshot(m: *const CB.Model, opts: ViewOpts_, expected: []const u8) !void {
    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    CB.viewWith(m, &cb, &opts_list, App.msgs, opts);
    cb.popGroup();
    try testing.expect(cmd.validateBalance(cb.cmds.items) == null);
    var rects: [64]engine.Rect = undefined;
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 400, 400, text.monoMeasurer());
    try snapshot.expectSnapshot(cb.cmds.items, rects[0..n], .{}, expected);
}

test "viewWith (closed): one input showing the selected label, no overlay" {
    const m: CB.Model = .{ .selected = 1 };
    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    CB.viewWith(&m, &cb, &opts_list, App.msgs, .{});
    try testing.expectEqual(@as(usize, 1), cb.cmds.items.len);
    try testing.expectEqualStrings("Oak", cb.cmds.items[0].text_input.content);
    try testing.expectEqual(App.Msg.focus, cb.cmds.items[0].text_input.focus_msg);
}

test "viewWith (open, filtered): input + overlay with only the matches" {
    var m: CB.Model = .{};
    CB.update(&m, .focus);
    typeStr(&m, "ch");
    // Matches: Birch (5), Beech (7).
    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    CB.viewWith(&m, &cb, &opts_list, App.msgs, .{ .list_width = 160 });
    const items = cb.cmds.items;
    try testing.expectEqual(@as(usize, 7), items.len); // input, overlay, group, 2 rows, pop, pop
    try testing.expectEqualStrings("ch", items[0].text_input.content);
    try testing.expect(items[1].push_overlay.modal);
    try testing.expectEqual(App.Msg.close, items[1].push_overlay.backdrop_msg.?);
    try testing.expectEqual(App.pick(5), items[3].button.msg);
    try testing.expectEqualStrings("Birch", items[3].button.label);
    try testing.expectEqual(App.pick(7), items[4].button.msg);
}

test "viewWith (open, no matches): disabled 'No matches' row" {
    var m: CB.Model = .{};
    CB.update(&m, .focus);
    typeStr(&m, "xyz");
    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    CB.viewWith(&m, &cb, &opts_list, App.msgs, .{});
    try testing.expectEqual(@as(usize, 6), cb.cmds.items.len);
    const row = cb.cmds.items[3].button;
    try testing.expectEqualStrings(NO_MATCHES, row.label);
    try testing.expect(row.disabled);
}

test "viewWith (open, many matches): scrolls inside the overlay" {
    var m: CB.Model = .{};
    CB.update(&m, .focus);
    CB.update(&m, .{ .highlight = .{ .move = .last, .count = 8, .max_visible = 3 } });
    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();
    CB.viewWith(&m, &cb, &opts_list, App.msgs, .{ .max_visible = 3 });
    const items = cb.cmds.items;
    try testing.expect(items[2] == .push_scroll);
    try testing.expectEqual(@as(f32, 5 * ITEM_HEIGHT), items[2].push_scroll.scroll_y);
    try testing.expectEqual(@as(f32, 3 * ITEM_HEIGHT), items[1].push_overlay.height);
}

test "snapshot golden: open list filtered by 'a'" {
    var m: CB.Model = .{};
    CB.update(&m, .focus);
    typeStr(&m, "a");
    try renderSnapshot(&m, .{ .list_x = 20, .list_y = 40, .list_width = 120, .max_visible = 4 },
        \\group (0,0,400,400) vertical
        \\  text_input (0,0,400,28) "a" cursor=1
        \\  overlay (20,40,120,144) layer=1 [modal]
        \\    group (20,40,120,144) vertical bg
        \\      button (20,40,120,36) "Oak"
        \\      button (20,76,120,36) "Maple"
        \\      button (20,112,120,36) "Cedar"
        \\      button (20,148,120,36) "Ash"
        \\
    );
}

test "compose: Combobox routes through Components" {
    const Comp = component.Components(.{ .material = CB }, null);
    var model: Comp.Model = .{};
    Comp.update(&model, .{ .material = .focus });
    Comp.update(&model, .{ .material = CB.charMsg('o') });
    try testing.expect(model.material.open);
    try testing.expectEqualStrings("o", model.material.query.content());
}
