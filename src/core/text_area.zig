//! `TextArea(cap)`: the canonical multi-line editor component -- an `Editor`
//! plus scroll state, driven by the runtime's `TextEvent`s.
//!
//! Composition (the whole app-side wiring):
//!
//! ```zig
//! const Notes = teak.TextArea(4096);
//! // Model:  notes: Notes.Model = .{},          Msg: notes: Notes.Msg, focus_notes
//! // update: .notes => |m| Notes.update(&model.notes, m)
//! // view:   Notes.viewWith(&m.notes, cb, .{ .focus = .focus_notes }, .{ .id = 1, .height = 200 });
//! // hooks:  textMsg(m, ev)        -> .{ .notes = Notes.eventMsg(ev) }   // pointer, wheel, metrics, motion
//! //         keyCharMsg(m, c)      -> .{ .notes = Notes.charMsg(c) }     // when focused
//! //         keySpecialMsg(m, k)   -> Notes.keyMsg(k) wrapped            // Enter, editing chords
//! //         focusedMsg(m)         -> focus_notes when focused
//! ```
//!
//! State lives in `Model` (buffer, cursor, selection, undo, sticky column,
//! scroll offsets, last metrics). The runtime resolves everything that needs
//! the measurer (click -> byte index, visual Up/Down/Home/End, wrapped
//! content size, caret rect) and reports it as `TextEvent`s; `update` stays a
//! pure function of `(Model, Msg)`.

const std = @import("std");
const cmd = @import("cmd.zig");
const text_field = @import("text_field.zig");
const text_event = @import("text_event.zig");
const text_wrap = @import("text_wrap.zig");
const keys = @import("../input/keys.zig");

pub const TextEvent = text_event.TextEvent;

/// Options for `viewWith`.
pub const ViewOpts = struct {
    /// Distinct non-zero id: names this area in `TextEvent.id`.
    id: u32 = 1,
    width: f32 = 0,
    min_width: f32 = 160,
    height: f32 = 140,
    flex: f32 = 0,
    wrap: cmd.Wrap = .word,
    padding: f32 = 6,
    /// null = the theme's `text_input` style / body font.
    style: ?cmd.TextInputStyle = null,
    font: ?cmd.FontSpec = null,
    disabled: bool = false,
};

pub fn TextArea(comptime cap: usize) type {
    return struct {
        const TF = text_field.TextField(cap);
        pub const capacity = cap;

        pub const Msg = union(enum) {
            /// Click on the area: the app records focus (the Msg carries no data).
            focus,
            /// One typed byte of UTF-8 (assembled atomically by the editor).
            char: u8,
            /// Enter: insert a newline.
            newline,
            /// A layout-independent editing key (`Editor.applyKey`).
            key: keys.SpecialKey,
            /// Replace the selection with pasted text.
            paste: []const u8,
            /// A runtime event: pointer, wheel, resolved motion, metrics.
            event: TextEvent,
        };

        pub const Model = struct {
            ed: TF.Model = .{ .multiline = true },
            scroll_x: f32 = 0,
            scroll_y: f32 = 0,
            /// Last `metrics` event: inner box, wrapped content, caret rect.
            viewport_w: f32 = 0,
            viewport_h: f32 = 0,
            content_w: f32 = 0,
            content_h: f32 = 0,
            caret_x: f32 = 0,
            caret_y: f32 = 0,
            caret_h: f32 = 0,

            pub fn content(self: *const @This()) []const u8 {
                return self.ed.content();
            }
            pub fn selectionText(self: *const @This()) []const u8 {
                return self.ed.selection();
            }
            /// Replace the whole text (cursor at the end, history cleared).
            pub fn set(self: *@This(), s: []const u8) void {
                self.ed.set(s);
                self.scroll_x = 0;
                self.scroll_y = 0;
            }
        };

        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                .focus => {},
                .char => |c| model.ed.typeByte(c),
                .newline => model.ed.insert("\n"),
                .key => |k| _ = model.ed.applyKey(k),
                .paste => |bytes| model.ed.insert(bytes),
                .event => |ev| onEvent(model, ev),
            }
        }

        fn onEvent(model: *Model, ev: TextEvent) void {
            if (model.ed.applyPointer(ev)) return;
            switch (ev.kind) {
                .wheel => {
                    model.scroll_y = clampScroll(model.scroll_y + ev.dy, model.content_h, model.viewport_h);
                    model.scroll_x = clampScroll(model.scroll_x + ev.dx, model.content_w, model.viewport_w);
                },
                .metrics => {
                    model.viewport_w = ev.viewport_w;
                    model.viewport_h = ev.viewport_h;
                    model.content_w = ev.content_w;
                    model.content_h = ev.content_h;
                    model.caret_x = ev.caret_x;
                    model.caret_y = ev.caret_y;
                    model.caret_h = ev.caret_h;
                    reveal(model);
                },
                else => {},
            }
        }

        fn clampScroll(v: f32, content: f32, viewport: f32) f32 {
            return std.math.clamp(v, 0, @max(0, content - viewport));
        }

        /// Scroll just enough to bring the caret rect inside the viewport,
        /// then clamp to the content (a shrunk document pulls scroll back).
        fn reveal(model: *Model) void {
            var sy = model.scroll_y;
            if (model.caret_y < sy) sy = model.caret_y;
            if (model.caret_y + model.caret_h > sy + model.viewport_h) sy = model.caret_y + model.caret_h - model.viewport_h;
            model.scroll_y = clampScroll(sy, model.content_h, model.viewport_h);
            var sx = model.scroll_x;
            if (model.caret_x < sx) sx = model.caret_x;
            if (model.caret_x + 2 > sx + model.viewport_w) sx = model.caret_x + 2 - model.viewport_w;
            model.scroll_x = clampScroll(sx, model.content_w + 2, model.viewport_w);
        }

        // ── Host-hook helpers ─────────────────────────────────────

        pub fn eventMsg(ev: TextEvent) Msg {
            return .{ .event = ev };
        }

        pub fn charMsg(c: u8) Msg {
            return .{ .char = c };
        }

        pub fn pasteMsg(bytes: []const u8) Msg {
            return .{ .paste = bytes };
        }

        /// Msg for a special key, or null when it is not an editing key
        /// (Up/Down/PageUp/PageDown/Home/End reach the area as `move` events
        /// from the runtime, not as keys; clipboard chords belong to the host).
        pub fn keyMsg(key: keys.SpecialKey) ?Msg {
            return switch (key) {
                .enter => .newline,
                .tab => null,
                .backspace, .delete, .left, .right, .shift_left, .shift_right, .ctrl_left, .ctrl_right, .ctrl_shift_left, .ctrl_shift_right, .ctrl_home, .ctrl_end, .ctrl_shift_home, .ctrl_shift_end, .ctrl_backspace, .ctrl_delete, .ctrl_a, .ctrl_z, .ctrl_y, .ctrl_shift_z, .escape => .{ .key = key },
                else => null,
            };
        }

        // ── View ──────────────────────────────────────────────────

        /// Canonical component view (composes through `Components`).
        pub fn view(model: *const Model, cb: anytype, msgs: anytype) void {
            viewWith(model, cb, msgs, .{});
        }

        /// `msgs` carries `.focus`, the AppMsg fired by a click.
        pub fn viewWith(model: *const Model, cb: anytype, msgs: anytype, opts: ViewOpts) void {
            cb.textArea(.{
                .focus_msg = msgs.focus,
                .id = opts.id,
                .content = model.ed.content(),
                .cursor = model.ed.cursor,
                .selection_anchor = model.ed.selection_anchor,
                .scroll_x = model.scroll_x,
                .scroll_y = model.scroll_y,
                .goal_x = model.ed.goal_x,
                .wrap = opts.wrap,
                .font = opts.font orelse cb.theme.typography.body,
                .style = opts.style orelse cb.theme.text_input,
                .width = opts.width,
                .min_width = opts.min_width,
                .height = opts.height,
                .flex = opts.flex,
                .padding = opts.padding,
                .disabled = opts.disabled,
            });
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const component = @import("component.zig");

const TA = TextArea(256);

fn type_(m: *TA.Model, s: []const u8) void {
    for (s) |c| TA.update(m, .{ .char = c });
}

test "validateComponent: TextArea satisfies the component contract" {
    component.validateComponent(TA);
}

test "typing, newline, editing keys" {
    var m: TA.Model = .{};
    type_(&m, "ab");
    TA.update(&m, TA.keyMsg(.enter).?);
    type_(&m, "cd");
    try testing.expectEqualStrings("ab\ncd", m.content());
    TA.update(&m, TA.keyMsg(.backspace).?);
    TA.update(&m, TA.keyMsg(.ctrl_a).?);
    try testing.expectEqualStrings("ab\nc", m.content());
    try testing.expectEqualStrings("ab\nc", m.selectionText());
    try testing.expect(TA.keyMsg(.up) == null);
    try testing.expect(TA.keyMsg(.ctrl_c) == null);
}

test "pointer events set caret, extend, select words and lines" {
    var m: TA.Model = .{};
    TA.update(&m, TA.pasteMsg("one two\nthree four"));
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .down, .index = 5 } });
    try testing.expectEqual(@as(usize, 5), m.ed.cursor);
    try testing.expect(!m.ed.hasSelection());
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .drag, .index = 12 } });
    try testing.expectEqualStrings("wo\nthre", m.selectionText());
    // Shift-click extends from the caret.
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .down, .index = 2 } });
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .down, .index = 7, .mods = .{ .shift = true } } });
    try testing.expectEqualStrings("e two", m.selectionText());
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .double_click, .index = 9 } });
    try testing.expectEqualStrings("three", m.selectionText());
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .triple_click, .index = 9 } });
    try testing.expectEqualStrings("three four", m.selectionText());
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .triple_click, .index = 3 } });
    try testing.expectEqualStrings("one two\n", m.selectionText()); // includes the newline
    // Resolved motion keeps / clears the sticky column.
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .move, .index = 12, .goal_x = 40, .keep_goal = true } });
    try testing.expectEqual(@as(?f32, 40), m.ed.goal_x);
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .move, .index = 8 } });
    try testing.expectEqual(@as(?f32, null), m.ed.goal_x);
}

test "wheel scrolls within the content; metrics clamp and reveal the caret" {
    var m: TA.Model = .{};
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .metrics, .viewport_w = 100, .viewport_h = 60, .content_w = 100, .content_h = 200, .caret_h = 20 } });
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .wheel, .dy = 50 } });
    try testing.expectEqual(@as(f32, 50), m.scroll_y);
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .wheel, .dy = 500 } });
    try testing.expectEqual(@as(f32, 140), m.scroll_y); // 200 - 60
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .wheel, .dy = -9999 } });
    try testing.expectEqual(@as(f32, 0), m.scroll_y);
    // Caret below the viewport: scroll so its bottom edge is visible.
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .metrics, .viewport_w = 100, .viewport_h = 60, .content_w = 100, .content_h = 200, .caret_y = 120, .caret_h = 20 } });
    try testing.expectEqual(@as(f32, 80), m.scroll_y);
    // Caret above: scroll up to it.
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .metrics, .viewport_w = 100, .viewport_h = 60, .content_w = 100, .content_h = 200, .caret_y = 20, .caret_h = 20 } });
    try testing.expectEqual(@as(f32, 20), m.scroll_y);
    // Content shrinks below the scroll: pulled back.
    TA.update(&m, .{ .event = .{ .id = 1, .kind = .metrics, .viewport_w = 100, .viewport_h = 60, .content_w = 100, .content_h = 70, .caret_y = 0, .caret_h = 20 } });
    try testing.expectEqual(@as(f32, 0), m.scroll_y);
}
