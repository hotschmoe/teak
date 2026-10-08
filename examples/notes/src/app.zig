//! Notes: a multi-line editor and a chat box, both `teak.TextArea`s.
//!
//! The wiring per area is the whole story: a Model field, a Msg variant, one
//! `update` arm, one `viewWith` call, and the shared hooks below -- `textMsg`
//! is a one-liner per area because the runtime already resolved clicks,
//! drags, wheel, Up/Down/Home/End and layout metrics into `TextEvent`s.

const std = @import("std");
const teak = @import("teak");

pub const bg: [4]f32 = .{ 0.08, 0.09, 0.11, 1 };

const Notes = teak.TextArea(8192);
const Chat = teak.TextArea(512);

const NOTES_ID = 1;
const CHAT_ID = 2;
const LOG_CAP = 6;
const MSG_CAP = 200;

const sample_head =
    \\Teak text areas wrap to their width, scroll, and keep the caret visible.
    \\
    \\Try it: click anywhere to place the caret, drag to select across wrapped lines (the selection keeps growing when you drag outside the box), double-click a word, triple-click a line, use Up/Down/Home/End (they follow the wrapped lines and remember the column), Ctrl+Left/Right for words, Ctrl+Z / Ctrl+Y to undo and redo.
    \\
    \\Longer paragraphs wrap at word boundaries; a very long unbroken token like supercalifragilisticexpialidocious_supercalifragilisticexpialidocious breaks at grapheme boundaries instead of overflowing. Combining marks stay with their letter:
;

const sample = sample_head ++ " cafe\u{0301}, and so do emoji sequences.";

const Focus = enum { none, notes, chat };

pub const Model = struct {
    notes: Notes.Model = initialNotes(),
    chat: Chat.Model = .{},
    focus: Focus = .notes,
    log: [LOG_CAP][MSG_CAP]u8 = undefined,
    log_len: [LOG_CAP]u8 = @splat(0),
    log_n: u8 = 0,
    /// Show the complex-script line (Arabic / Hebrew / Devanagari).
    scripts: bool = false,

    pub fn logItem(self: *const Model, i: usize) []const u8 {
        return self.log[i][0..self.log_len[i]];
    }
};

fn initialNotes() Notes.Model {
    var m: Notes.Model = .{};
    m.set(sample);
    m.ed.cursor = 0;
    return m;
}

pub const Msg = union(enum) {
    notes: Notes.Msg,
    chat: Chat.Msg,
    send,
    clear_chat,
    toggle_scripts,
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .notes => |a| {
            if (a == .focus) m.focus = .notes;
            Notes.update(&m.notes, a);
        },
        .chat => |a| {
            if (a == .focus) m.focus = .chat;
            Chat.update(&m.chat, a);
        },
        .send => {
            const text = std.mem.trim(u8, m.chat.content(), " \n\t");
            if (text.len == 0) return;
            if (m.log_n == LOG_CAP) {
                // Drop the oldest.
                for (1..LOG_CAP) |i| {
                    m.log[i - 1] = m.log[i];
                    m.log_len[i - 1] = m.log_len[i];
                }
                m.log_n -= 1;
            }
            const n = @min(text.len, MSG_CAP);
            @memcpy(m.log[m.log_n][0..n], text[0..n]);
            m.log_len[m.log_n] = @intCast(n);
            m.log_n += 1;
            m.chat.set("");
        },
        .clear_chat => m.chat.set(""),
        .toggle_scripts => m.scripts = !m.scripts,
    }
}

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 16, .gap = 16, .align_cross = .stretch });

    // Left: the notes editor.
    cb.pushGroup(.{ .padding = 0, .gap = 8, .flex = 1, .align_cross = .stretch });
    cb.heading("NOTES");
    Notes.viewWith(&m.notes, cb, .{ .focus = Msg{ .notes = .focus } }, .{ .id = NOTES_ID, .flex = 1, .height = 200 });
    cb.textMuted("Click, drag, double/triple-click, Up/Down/Home/End, Ctrl+arrows, Ctrl+Z/Y, Ctrl+C/X/V");
    cb.button(.toggle_scripts, if (m.scripts) "Hide scripts" else "Show scripts");
    if (m.scripts) scriptsLine(cb);
    cb.popGroup();

    // Right: chat log + multi-line input.
    cb.pushGroup(.{ .width = 380, .padding = 0, .gap = 8, .align_cross = .stretch });
    cb.heading("CHAT");
    cb.pushGroup(.{ .padding = 10, .gap = 8, .flex = 1, .bg = cb.theme.palette.bg_sunken, .align_cross = .stretch });
    if (m.log_n == 0) cb.textMuted("No messages yet.");
    for (0..m.log_n) |i| cb.paragraph(m.logItem(i));
    cb.popGroup();
    Chat.viewWith(&m.chat, cb, .{ .focus = Msg{ .chat = .focus } }, .{ .id = CHAT_ID, .height = 84 });
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .justify = .end });
    cb.button(.clear_chat, "Clear");
    cb.button(.send, "Send  (Enter)");
    cb.popGroup();
    cb.popGroup();

    cb.popGroup();
}

/// One run per script, each in its own family (so the registered face is the
/// primary one): Arabic (serif regular), Hebrew (serif bold), Devanagari (serif
/// medium). Needs faces that cover them (see docs/features/harfbuzz.md); with
/// HarfBuzz built in (`-Dharfbuzz=true`) joining, mark placement and
/// reordering are applied, otherwise the glyphs are the nominal cmap forms.
fn scriptsLine(cb: anytype) void {
    const ink = cb.theme.palette.fg;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 24, .align_cross = .center });
    cb.textStyled("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{0628}\u{064E}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645}", .{ .size_px = 28, .family = .serif, .weight = .regular, .snap_advance = false }, ink);
    cb.textStyled("\u{05E9}\u{05B8}\u{05C1}\u{05DC}\u{05D5}\u{05B9}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}", .{ .size_px = 28, .family = .serif, .weight = .bold, .snap_advance = false }, ink);
    cb.textStyled("\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} \u{0915}\u{093F}\u{0924}\u{093E}\u{092C} \u{0915}\u{094D}\u{0937}\u{0924}\u{094D}\u{0930}", .{ .size_px = 28, .family = .serif, .weight = .medium, .snap_advance = false }, ink);
    cb.popGroup();
}

// ── Host integration ───────────────────────────────────────────────

pub fn textMsg(_: *const Model, ev: teak.TextEvent) ?Msg {
    return switch (ev.id) {
        NOTES_ID => .{ .notes = Notes.eventMsg(ev) },
        CHAT_ID => .{ .chat = Chat.eventMsg(ev) },
        else => null,
    };
}

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    return switch (m.focus) {
        .notes => .{ .notes = Notes.charMsg(c) },
        .chat => .{ .chat = Chat.charMsg(c) },
        .none => null,
    };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    return switch (m.focus) {
        .notes => if (Notes.keyMsg(key)) |a| Msg{ .notes = a } else null,
        .chat => if (Chat.keyMsg(key)) |a| Msg{ .chat = a } else null,
        .none => null,
    };
}

/// Enter sends from the chat box. In the notes (a `text_area`) the loop does
/// not call this: Enter reaches `keySpecialMsg` as a key and `Notes.keyMsg`
/// turns it into a newline.
pub fn submitMsg(m: *const Model) ?Msg {
    return switch (m.focus) {
        .chat => .send,
        .notes, .none => null,
    };
}

pub fn focusedMsg(m: *const Model) ?Msg {
    return switch (m.focus) {
        .notes => Msg{ .notes = .focus },
        .chat => Msg{ .chat = .focus },
        .none => null,
    };
}

fn focusedSelection(m: *const Model) []const u8 {
    return switch (m.focus) {
        .notes => m.notes.selectionText(),
        .chat => m.chat.selectionText(),
        .none => "",
    };
}

/// What Ctrl+C / Ctrl+X copy: the focused field's selection (a pure query;
/// `teak.run` writes the Host clipboard).
pub fn clipboardText(m: *const Model, key: teak.SpecialKey) ?[]const u8 {
    if (key != .ctrl_c and key != .ctrl_x) return null;
    const sel = focusedSelection(m);
    return if (sel.len > 0) sel else null;
}

/// The Msg for a clipboard chord on the focused field: Ctrl+X deletes the
/// selection (after `clipboardText` copied it), Ctrl+V pastes.
pub fn clipboardMsg(m: *const Model, key: teak.SpecialKey, paste: []const u8) ?Msg {
    if (m.focus == .none) return null;
    const notes = m.focus == .notes;
    return switch (key) {
        .ctrl_x => if (focusedSelection(m).len == 0) null else if (notes) Msg{ .notes = .{ .key = .backspace } } else Msg{ .chat = .{ .key = .backspace } },
        .ctrl_v => if (notes) Msg{ .notes = Notes.pasteMsg(paste) } else Msg{ .chat = Chat.pasteMsg(paste) },
        else => null,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "chat: typing, Enter sends and clears, empty messages are ignored" {
    var m: Model = .{};
    update(&m, .{ .chat = .focus });
    for ("hi there") |c| update(&m, keyCharMsg(&m, c).?);
    update(&m, submitMsg(&m).?);
    try std.testing.expectEqual(@as(u8, 1), m.log_n);
    try std.testing.expectEqualStrings("hi there", m.logItem(0));
    try std.testing.expectEqualStrings("", m.chat.content());
    update(&m, submitMsg(&m).?);
    try std.testing.expectEqual(@as(u8, 1), m.log_n);
}

test "notes: Enter inserts a newline; view is balanced" {
    var m: Model = .{};
    update(&m, .{ .notes = .focus });
    update(&m, .{ .notes = .{ .key = .ctrl_end } });
    const before = m.notes.content().len;
    update(&m, keySpecialMsg(&m, .enter).?); // Enter in a text_area is a key, not a submit
    try std.testing.expectEqual(before + 1, m.notes.content().len);

    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    view(&m, &cb);
    try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
}

test "clipboard hooks: copy reads the focused selection, cut deletes it, paste inserts" {
    var m: Model = .{};
    update(&m, .{ .notes = .focus });
    for ("hello") |c| update(&m, keyCharMsg(&m, c).?);
    try std.testing.expect(clipboardText(&m, .ctrl_c) == null); // nothing selected
    update(&m, .{ .notes = .{ .key = .ctrl_a } });
    try std.testing.expectEqualStrings(m.notes.content(), clipboardText(&m, .ctrl_c).?);
    try std.testing.expect(std.mem.startsWith(u8, clipboardText(&m, .ctrl_c).?, "hello"));
    update(&m, clipboardMsg(&m, .ctrl_x, "").?);
    try std.testing.expectEqualStrings("", m.notes.content());
    update(&m, clipboardMsg(&m, .ctrl_v, "pasted").?);
    try std.testing.expectEqualStrings("pasted", m.notes.content());
}
