//! Menus: a menu bar with drop-down menus and nested submenus, and a context
//! (right-click) menu. Zero new Cmd variants: a row of `button`s for the bar,
//! modal-overlay panels of `button` rows for the menus (the Dropdown /
//! Combobox pattern), and a transparent full-window modal "scrim" overlay so
//! a click anywhere else dismisses the menu.
//!
//! ## Shape
//!
//! The menu *tree* is app data: `MenuItem(Action)` values (label, optional
//! action, shortcut text, enabled / checked flags, children). `Action` is
//! the app's own type for "what a menu entry does" (usually an enum). The
//! component keeps only *navigation state* (`State`: is the bar active,
//! which top menu is hot / open, how deep the submenu chain is, and the
//! highlighted row at each level), all in the Model (HARDLINE §1).
//!
//! Choosing a leaf dispatches `msgs.run(action)` (an ordinary app Msg); the
//! app's `update` closes the menu in the same step:
//!
//! ```zig
//! const MB = teak.widgets.menu.MenuBar(Action);
//! const file_menu = [_]MB.Item{
//!     .{ .label = "&New", .action = .new, .shortcut = "Ctrl+N" },
//!     .{ .label = "&Open...", .action = .open, .shortcut = "Ctrl+O" },
//!     MB.Item.sep,
//!     .{ .label = "Open &Recent", .children = &recent },
//!     .{ .label = "E&xit", .action = .quit },
//! };
//! const menus = [_]MB.Item{ .{ .label = "&File", .children = &file_menu }, ... };
//!
//! // Msg:  menubar: MB.Msg,  run: Action
//! fn wrapMenu(m: MB.Msg) Msg { return .{ .menubar = m }; }
//! fn wrapRun(a: Action) Msg { return .{ .run = a }; }
//! const menu_msgs = .{ .menu = wrapMenu, .run = wrapRun };
//! // update:  .menubar => |m| MB.update(&model.menubar, m),
//! //          .run => |a| { MB.update(&model.menubar, .close); perform(a); },
//! // view:    MB.viewWith(&m.menubar, cb, &menus, menu_msgs, .{ .window_w = ..., .window_h = ... });
//! // keys:    if (MB.keyMsg(&m.menubar, key, &menus, menu_msgs)) |msg| return msg;
//! // chars:   if (MB.isActive(&m.menubar)) return MB.charMsg(&m.menubar, c, &menus, menu_msgs);
//! ```
//!
//! ## Keyboard
//!
//! F10 or a bare Alt tap (`SpecialKey.f10` / `.alt_tap`) activates the bar;
//! Left/Right move between menus, Down/Up/Enter open one; inside a menu
//! Up/Down move (skipping separators and disabled rows, wrapping), Right
//! opens a submenu (or moves to the next menu), Left leaves it, Enter runs
//! the row, Escape backs out one level and finally deactivates. While the
//! bar is active a plain letter is a mnemonic: the character after `&` in a
//! label (`"&File"` -> F). `&&` is a literal ampersand.
//!
//! ## Geometry
//!
//! `view` cannot read layout, so every position is computed from fixed
//! sizes: top entries are `top_width` wide, rows `row_h` tall, separators
//! `SEP_H`, panels `panel_w` wide. Row text is padded with spaces to
//! `cols` columns so shortcuts line up in a monospaced font; set `cols`
//! and `panel_w` together if you change the font.

const std = @import("std");
const oom = @import("../oom.zig").oom;
const cmd = @import("../cmd.zig");
const component = @import("../component.zig");
const keys = @import("../../input/keys.zig");
const util = @import("util.zig");

/// Deepest submenu chain (levels of overlay panels).
pub const max_depth = 4;
/// Height of a separator row (padding + the 1 px rule).
pub const SEP_H: f32 = 9;

/// Navigation state shared by the menu bar and the context menu.
pub const State = struct {
    /// Menu bar only: keyboard focus is on the bar (after F10 / Alt / a click).
    active: bool = false,
    /// Menu bar only: the highlighted top-level menu.
    hot: u8 = 0,
    /// A drop-down (or, for a context menu, the panel) is open.
    open: bool = false,
    /// Index of the deepest open level (0 = the first panel).
    depth: u8 = 0,
    /// Highlighted row at each level.
    sel: [max_depth]u8 = @splat(0),
};

/// One menu entry. `children.len > 0` makes it a submenu; `separator` a rule.
pub fn MenuItem(comptime Action: type) type {
    return struct {
        const Self = @This();
        /// Text; `&` marks the mnemonic letter (`&&` = a literal `&`).
        label: []const u8 = "",
        /// What choosing the entry does; null for submenus and inert rows.
        action: ?Action = null,
        /// Shown right-aligned (display only; the app routes the chord).
        shortcut: []const u8 = "",
        enabled: bool = true,
        /// Prefix the row with a check mark.
        checked: bool = false,
        separator: bool = false,
        children: []const Self = &.{},

        pub const sep: Self = .{ .separator = true };

        pub fn isSub(self: Self) bool {
            return self.children.len > 0;
        }
        pub fn selectable(self: Self) bool {
            return !self.separator and self.enabled;
        }
        /// Lower-cased mnemonic letter, if the label has one.
        pub fn mnemonic(self: Self) ?u8 {
            var i: usize = 0;
            while (i < self.label.len) : (i += 1) {
                if (self.label[i] != '&') continue;
                if (i + 1 >= self.label.len) return null;
                if (self.label[i + 1] == '&') {
                    i += 1;
                    continue;
                }
                return std.ascii.toLower(self.label[i + 1]);
            }
            return null;
        }
    };
}

/// Index of the mnemonic character within `displayLabel(label)`, or null.
pub fn mnemonicIndex(label: []const u8) ?usize {
    var shown: usize = 0;
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        if (label[i] == '&' and i + 1 < label.len) {
            if (label[i + 1] == '&') {
                i += 1; // a literal '&'
            } else return shown;
        }
        shown += 1;
    }
    return null;
}

/// `label` without its mnemonic markers (`&x` -> `x`, `&&` -> `&`), in the frame arena.
pub fn displayLabel(cb: anytype, label: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        if (label[i] == '&' and i + 1 < label.len) {
            i += 1;
            out.append(cb.arena.allocator(), label[i]) catch oom();
        } else {
            out.append(cb.arena.allocator(), label[i]) catch oom(); // plain char, or a trailing '&'
        }
    }
    return out.items;
}

pub const ViewOpts = struct {
    /// Top-left of the menu bar in window coordinates (panels are placed from it).
    x: f32 = 0,
    y: f32 = 0,
    window_w: f32,
    window_h: f32,
    /// Width of each top-level entry.
    top_width: f32 = 72,
    bar_height: f32 = 28,
    panel_w: f32 = 244,
    row_h: f32 = 28,
    /// Text columns per row (labels are padded to this so shortcuts align in a mono font).
    cols: usize = 27,
    /// Fill the bar's row: a background strip the full window width.
    bar_bg: bool = true,
};

fn firstSelectable(items: anytype) ?u8 {
    for (items, 0..) |it, i| if (it.selectable()) return @intCast(i);
    return null;
}

fn lastSelectable(items: anytype) ?u8 {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i].selectable()) return @intCast(i);
    }
    return null;
}

/// The next selectable index after `cur` in `dir` (+1 / -1), wrapping.
fn stepSelectable(items: anytype, cur: u8, dir: i8) ?u8 {
    const n = items.len;
    if (n == 0) return null;
    var i: usize = @min(cur, n - 1);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        i = if (dir > 0) (i + 1) % n else (i + n - 1) % n;
        if (items[i].selectable()) return @intCast(i);
    }
    return null;
}

/// What a key or mnemonic does.
fn Outcome(comptime Action: type) type {
    return union(enum) {
        none,
        /// Replace the navigation state.
        state: State,
        /// Dismiss the whole menu (context menu: close; bar: deactivate).
        close,
        run: Action,
    };
}

pub fn Nav(comptime Action: type) type {
    const I = MenuItem(Action);
    const Out = Outcome(Action);
    return struct {
        /// The rows shown at `level` of the open chain.
        fn levelItems(root: []const I, st: State, bar: bool, level: usize) []const I {
            var cur: []const I = root;
            if (bar) {
                if (st.hot >= root.len) return &.{};
                cur = root[st.hot].children;
            }
            var k: usize = 0;
            while (k < level) : (k += 1) {
                if (st.sel[k] >= cur.len) return &.{};
                cur = cur[st.sel[k]].children;
            }
            return cur;
        }

        fn withSel(st: State, level: usize, idx: ?u8) State {
            var s = st;
            if (idx) |i| s.sel[level] = i;
            return s;
        }

        /// Open the panel of top menu `hot`.
        fn openTop(root: []const I, st: State, hot: u8) State {
            var s = st;
            s.active = true;
            s.hot = hot;
            s.open = true;
            s.depth = 0;
            s.sel = @splat(0);
            if (firstSelectable(root[hot].children)) |f| s.sel[0] = f;
            return s;
        }

        /// Descend into the submenu under the highlighted row.
        fn descend(root: []const I, st: State, bar: bool) ?State {
            if (st.depth + 1 >= max_depth) return null;
            const items = levelItems(root, st, bar, st.depth);
            if (st.sel[st.depth] >= items.len) return null;
            const it = items[st.sel[st.depth]];
            if (!it.isSub() or !it.enabled) return null;
            var s = st;
            s.depth += 1;
            s.sel[s.depth] = firstSelectable(it.children) orelse 0;
            return s;
        }

        fn moveTop(root: []const I, st: State, dir: i8) ?u8 {
            return stepSelectable(root, st.hot, dir);
        }

        pub fn key(root: []const I, st: State, k: keys.SpecialKey, bar: bool) Out {
            if (bar) return barKey(root, st, k);
            return ctxKey(root, st, k);
        }

        fn barKey(root: []const I, st: State, k: keys.SpecialKey) Out {
            if (!st.active) {
                return switch (k) {
                    .f10, .alt_tap => if (firstSelectable(root)) |h| .{ .state = .{ .active = true, .hot = h } } else .none,
                    else => .none,
                };
            }
            if (k == .f10 or k == .alt_tap) return .close;
            if (!st.open) {
                return switch (k) {
                    .left => if (moveTop(root, st, -1)) |h| .{ .state = .{ .active = true, .hot = h } } else .none,
                    .right => if (moveTop(root, st, 1)) |h| .{ .state = .{ .active = true, .hot = h } } else .none,
                    .down, .up, .enter => if (st.hot < root.len and root[st.hot].children.len > 0) .{ .state = openTop(root, st, st.hot) } else .none,
                    .escape => .close,
                    else => .none,
                };
            }
            return panelKey(root, st, k, true);
        }

        fn ctxKey(root: []const I, st: State, k: keys.SpecialKey) Out {
            if (!st.open) return .none;
            if (k == .escape and st.depth == 0) return .close;
            return panelKey(root, st, k, false);
        }

        /// Keys inside an open panel chain (shared by bar and context menu).
        fn panelKey(root: []const I, st: State, k: keys.SpecialKey, bar: bool) Out {
            const items = levelItems(root, st, bar, st.depth);
            const cur = st.sel[st.depth];
            switch (k) {
                .down => return if (stepSelectable(items, cur, 1)) |i| .{ .state = withSel(st, st.depth, i) } else .none,
                .up => return if (stepSelectable(items, cur, -1)) |i| .{ .state = withSel(st, st.depth, i) } else .none,
                .home => return if (firstSelectable(items)) |i| .{ .state = withSel(st, st.depth, i) } else .none,
                .end => return if (lastSelectable(items)) |i| .{ .state = withSel(st, st.depth, i) } else .none,
                .right => {
                    if (descend(root, st, bar)) |s| return .{ .state = s };
                    if (bar and st.depth == 0) {
                        if (moveTop(root, st, 1)) |h| if (root[h].children.len > 0) return .{ .state = openTop(root, st, h) };
                    }
                    return .none;
                },
                .left => {
                    if (st.depth > 0) {
                        var s = st;
                        s.depth -= 1;
                        return .{ .state = s };
                    }
                    if (bar) {
                        if (moveTop(root, st, -1)) |h| if (root[h].children.len > 0) return .{ .state = openTop(root, st, h) };
                    }
                    return .none;
                },
                .enter => {
                    if (cur >= items.len) return .none;
                    const it = items[cur];
                    if (!it.selectable()) return .none;
                    if (it.isSub()) return if (descend(root, st, bar)) |s| .{ .state = s } else .none;
                    if (it.action) |a| return .{ .run = a };
                    return .close;
                },
                .escape => {
                    if (st.depth > 0) {
                        var s = st;
                        s.depth -= 1;
                        return .{ .state = s };
                    }
                    var s = st;
                    s.open = false;
                    return .{ .state = s };
                },
                else => return .none,
            }
        }

        /// A typed letter while the menu is active: a mnemonic.
        pub fn mnemonic(root: []const I, st: State, c: u8, bar: bool) Out {
            const lc = std.ascii.toLower(c);
            if (bar and !st.active) return .none;
            if (bar and !st.open) {
                for (root, 0..) |it, i| {
                    if (it.selectable() and it.mnemonic() == lc and it.children.len > 0)
                        return .{ .state = openTop(root, st, @intCast(i)) };
                }
                return .none;
            }
            if (!st.open) return .none;
            const items = levelItems(root, st, bar, st.depth);
            for (items, 0..) |it, i| {
                if (!it.selectable() or it.mnemonic() != lc) continue;
                const s = withSel(st, st.depth, @intCast(i));
                if (it.isSub()) return if (descend(root, s, bar)) |d| .{ .state = d } else .none;
                if (it.action) |a| return .{ .run = a };
                return .close;
            }
            return .none;
        }

        fn rowsHeight(items: []const I, o: ViewOpts) f32 {
            var h: f32 = 0;
            for (items) |it| h += if (it.separator) SEP_H else o.row_h;
            return h;
        }

        fn rowOffset(items: []const I, index: usize, o: ViewOpts) f32 {
            var y: f32 = 0;
            for (items[0..@min(index, items.len)]) |it| y += if (it.separator) SEP_H else o.row_h;
            return y;
        }

        /// One row's text: check mark, label, padding, shortcut or submenu arrow.
        fn rowText(cb: anytype, it: I, o: ViewOpts) []const u8 {
            const shown = displayLabel(cb, it.label);
            const tail: []const u8 = if (it.isSub()) ">" else it.shortcut;
            const lead: []const u8 = if (it.checked) "* " else "  ";
            var out: std.ArrayList(u8) = .empty;
            const a = cb.arena.allocator();
            out.appendSlice(a, lead) catch oom();
            out.appendSlice(a, shown) catch oom();
            const used = lead.len + shown.len + tail.len;
            out.appendNTimes(a, ' ', if (used < o.cols) o.cols - used else 1) catch oom();
            out.appendSlice(a, tail) catch oom();
            return out.items;
        }

        /// Emit the open panel chain (levels `0..=st.depth`) starting at (x0, y0).
        /// `goto(State)` builds the app Msg that sets the navigation state.
        pub fn emitPanels(
            cb: anytype,
            root: []const I,
            st: State,
            bar: bool,
            x0: f32,
            y0: f32,
            msgs: anytype,
            o: ViewOpts,
        ) void {
            const pal = cb.theme.palette;
            var x = x0;
            var y = y0;
            var level: usize = 0;
            while (level <= st.depth and level < max_depth) : (level += 1) {
                const items = levelItems(root, st, bar, level);
                if (items.len == 0) break;
                const h = rowsHeight(items, o) + 2; // rows + the 1 px panel border
                if (x + o.panel_w > o.window_w) x = @max(0, o.window_w - o.panel_w);
                if (y + h > o.window_h) y = @max(0, o.window_h - h);

                cb.pushOverlay(.{
                    .x = x,
                    .y = y,
                    .width = o.panel_w,
                    .height = h,
                    .padding = 0,
                    .gap = 0,
                    .shadow = .{ 0, 0, 0, 0.35 },
                    .shadow_offset = .{ 3, 3 },
                });
                cb.pushGroup(.{ .direction = .vertical, .padding = 1, .gap = 0, .bg = pal.bg_panel, .border = pal.border, .align_cross = .stretch, .width = o.panel_w });
                for (items, 0..) |it, i| {
                    if (it.separator) {
                        cb.pushGroup(.{ .direction = .vertical, .pad_x = 0, .pad_y = 4, .gap = 0, .align_cross = .stretch });
                        cb.divider();
                        cb.popGroup();
                        continue;
                    }
                    var style = cb.theme.button;
                    style.min_width = o.panel_w - 2; // inside the 1 px panel border (not over it)
                    style.height = o.row_h;
                    style.label_align = .start;
                    style.bg = pal.bg_panel;
                    style.border = null;
                    const highlighted = i == st.sel[level] and st.open;
                    if (highlighted) {
                        style.bg = pal.fg;
                        style.fg = pal.bg;
                        style.hover_bg = pal.fg;
                        style.hover_fg = pal.bg;
                    } else {
                        style.hover_bg = pal.bg_hover;
                    }
                    const label = rowText(cb, it, o);
                    const mn = if (mnemonicIndex(it.label)) |k| k + 2 else null; // after the 2-char lead
                    if (!it.enabled) {
                        cb.buttonStyledDisabled(msgs.menu(.close), label, style);
                    } else if (it.isSub()) {
                        var s = st;
                        s.depth = @intCast(level + 1);
                        s.sel[level] = @intCast(i);
                        if (level + 1 < max_depth) s.sel[level + 1] = firstSelectable(it.children) orelse 0;
                        cb.buttonStyledUnderlined(msgs.menu(.{ .goto = s }), label, style, mn);
                    } else if (it.action) |a| {
                        cb.buttonStyledUnderlined(msgs.run(a), label, style, mn);
                    } else {
                        cb.buttonStyled(msgs.menu(.close), label, style);
                    }
                }
                cb.popGroup();
                cb.popOverlay();

                const parent_row = st.sel[level];
                y += rowOffset(items, parent_row, o); // the submenu's own first row lines up with the parent row (both panels inset 1 px)
                x += o.panel_w;
                if (x + o.panel_w > o.window_w) x = @max(0, x - 2 * o.panel_w);
            }
        }
    };
}

pub fn MenuBar(comptime Action: type) type {
    const N = Nav(Action);
    return struct {
        pub const Item = MenuItem(Action);

        pub const Model = struct {
            st: State = .{},
        };

        pub const Msg = union(enum) {
            /// Replace the navigation state (build by the view / `keyMsg`).
            goto: State,
            /// Dismiss: close any panel and deactivate the bar.
            close,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .goto => |s| model.st = s,
                .close => model.st = .{},
            }
        }

        /// True while the bar owns the keyboard (route keys / chars to it first).
        pub fn isActive(model: *const Model) bool {
            return model.st.active;
        }

        /// Component-contract view (the bar needs its items; use `viewWith`).
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            _ = model;
            _ = cb;
            _ = msgs;
        }

        fn wrap(out: Outcome(Action), msgs: anytype) ?@TypeOf(msgs.menu(Msg.close)) {
            return switch (out) {
                .none => null,
                .state => |s| msgs.menu(.{ .goto = s }),
                .close => msgs.menu(.close),
                .run => |a| msgs.run(a),
            };
        }

        /// The Msg for a key press (or null): F10 / Alt activate, arrows / Enter /
        /// Escape navigate, Enter on a leaf yields `msgs.run(action)`.
        pub fn keyMsg(model: *const Model, key: keys.SpecialKey, items: []const Item, msgs: anytype) ?@TypeOf(msgs.menu(Msg.close)) {
            return wrap(N.key(items, model.st, key, true), msgs);
        }

        /// The Msg for a typed letter while active: a mnemonic.
        pub fn charMsg(model: *const Model, c: u8, items: []const Item, msgs: anytype) ?@TypeOf(msgs.menu(Msg.close)) {
            return wrap(N.mnemonic(items, model.st, c, true), msgs);
        }

        /// The bar and, when open, its drop-down chain. `msgs.menu(Msg)` and
        /// `msgs.run(Action)` wrap into the app's Msg.
        pub fn viewWith(model: *const Model, cb: anytype, items: []const Item, msgs: anytype, o: ViewOpts) void {
            const pal = cb.theme.palette;
            const st = model.st;

            cb.pushGroup(.{
                .direction = .horizontal,
                .padding = 0,
                .gap = 0,
                .bg = if (o.bar_bg) pal.bg_panel else null,
                .width = if (o.bar_bg) o.window_w else 0,
                .height = o.bar_height,
            });
            for (items, 0..) |it, i| {
                var style = cb.theme.button;
                style.min_width = o.top_width;
                style.height = o.bar_height;
                style.label_align = .center;
                style.border = null;
                style.bg = pal.bg_panel;
                const lit = st.active and st.hot == i;
                if (lit) {
                    style.bg = pal.fg;
                    style.fg = pal.bg;
                    style.hover_bg = pal.fg;
                    style.hover_fg = pal.bg;
                }
                const label = displayLabel(cb, it.label);
                if (!it.enabled) {
                    cb.buttonStyledDisabled(msgs.menu(.close), label, style);
                } else {
                    const same_open = st.open and st.hot == i;
                    const target: State = if (same_open) .{} else N.openTop(items, st, @intCast(i));
                    cb.buttonStyledUnderlined(msgs.menu(.{ .goto = target }), label, style, mnemonicIndex(it.label));
                }
            }
            cb.popGroup();

            if (st.open and st.hot < items.len) {
                util.scrim(cb, msgs.menu(.close), o.window_w, o.window_h);
                var x = o.x;
                for (items[0..st.hot]) |_| x += o.top_width;
                N.emitPanels(cb, items, st, true, x, o.y + o.bar_height, msgs, o);
            }
        }
    };
}

pub fn ContextMenu(comptime Action: type) type {
    const N = Nav(Action);
    return struct {
        pub const Item = MenuItem(Action);

        pub const Model = struct {
            /// Where the menu was opened (window coordinates).
            x: f32 = 0,
            y: f32 = 0,
            st: State = .{},
        };

        pub const Msg = union(enum) {
            /// Open at a point, e.g. from the app's `contextMsg` hook.
            open_at: struct { x: f32, y: f32 },
            goto: State,
            close,
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .open_at => |p| {
                    model.x = p.x;
                    model.y = p.y;
                    model.st = .{ .open = true };
                },
                .goto => |s| model.st = s,
                .close => model.st = .{},
            }
        }

        pub fn isOpen(model: *const Model) bool {
            return model.st.open;
        }

        pub fn openAt(x: f32, y: f32) Msg {
            return .{ .open_at = .{ .x = x, .y = y } };
        }

        /// Component-contract view (the menu needs its items; use `viewWith`).
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            _ = model;
            _ = cb;
            _ = msgs;
        }

        /// Opening needs the items to pick the first row; the first
        /// selectable row is highlighted after `open_at` by `keyMsg`'s first
        /// Down. (A freshly opened menu has no keyboard highlight.)
        fn wrap(out: Outcome(Action), msgs: anytype) ?@TypeOf(msgs.menu(Msg.close)) {
            return switch (out) {
                .none => null,
                .state => |s| msgs.menu(.{ .goto = s }),
                .close => msgs.menu(.close),
                .run => |a| msgs.run(a),
            };
        }

        pub fn keyMsg(model: *const Model, key: keys.SpecialKey, items: []const Item, msgs: anytype) ?@TypeOf(msgs.menu(Msg.close)) {
            var st = model.st;
            if (st.open and st.sel[0] == 0 and (key == .down or key == .up) and items.len > 0 and !items[0].selectable()) {
                st.sel[0] = firstSelectable(items) orelse 0;
            }
            return wrap(N.key(items, st, key, false), msgs);
        }

        pub fn charMsg(model: *const Model, c: u8, items: []const Item, msgs: anytype) ?@TypeOf(msgs.menu(Msg.close)) {
            return wrap(N.mnemonic(items, model.st, c, false), msgs);
        }

        pub fn viewWith(model: *const Model, cb: anytype, items: []const Item, msgs: anytype, o: ViewOpts) void {
            if (!model.st.open) return;
            util.scrim(cb, msgs.menu(.close), o.window_w, o.window_h);
            N.emitPanels(cb, items, model.st, false, model.x, model.y, msgs, o);
        }
    };
}

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text_mod = @import("../text.zig");

const Act = enum { new, open, save, quit, copy, paste, zoom_in, zoom_out, about, close_all };
const MB = MenuBar(Act);
const CM = ContextMenu(Act);
const App = union(enum) { bar: MB.Msg, ctx: CM.Msg, run: Act };

fn wrapBar(m: MB.Msg) App {
    return .{ .bar = m };
}
fn wrapCtx(m: CM.Msg) App {
    return .{ .ctx = m };
}
fn wrapRun(a: Act) App {
    return .{ .run = a };
}
const bar_msgs = .{ .menu = wrapBar, .run = wrapRun };
const ctx_msgs = .{ .menu = wrapCtx, .run = wrapRun };

const zoom_menu = [_]MB.Item{
    .{ .label = "Zoom &In", .action = .zoom_in },
    .{ .label = "Zoom &Out", .action = .zoom_out },
};
const file_menu = [_]MB.Item{
    .{ .label = "&New", .action = .new, .shortcut = "Ctrl+N" },
    .{ .label = "&Open...", .action = .open, .shortcut = "Ctrl+O" },
    MB.Item.sep,
    .{ .label = "&Save", .action = .save, .enabled = false },
    .{ .label = "E&xit", .action = .quit },
};
const edit_menu = [_]MB.Item{
    .{ .label = "&Copy", .action = .copy },
    .{ .label = "&Paste", .action = .paste },
    .{ .label = "&View", .children = &zoom_menu },
};
const empty_menu = [_]MB.Item{};
const menus = [_]MB.Item{
    .{ .label = "&File", .children = &file_menu },
    .{ .label = "&Edit", .children = &edit_menu },
    .{ .label = "&Help", .action = .about, .children = &.{.{ .label = "&About", .action = .about }} },
};

fn press(m: *MB.Model, k: keys.SpecialKey) ?Act {
    const msg = MB.keyMsg(m, k, &menus, bar_msgs) orelse return null;
    switch (msg) {
        .bar => |b| MB.update(m, b),
        .run => |a| return a,
        .ctx => unreachable,
    }
    return null;
}
