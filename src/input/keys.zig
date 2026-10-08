//! Framework-authoritative list of non-text keys that Hosts may deliver.
//! Text characters flow through InputState.chars; everything else is a
//! variant here. Hosts map their native key codes onto this enum.
//!
//! Modifier-bearing variants are flat (shift_left, ctrl_c, ...) rather
//! than a separate modifier struct. Apps switch exhaustively on the
//! enum which keeps the routing code linear — adding a chord = adding a
//! variant + a switch arm, same as adding a Msg.

pub const SpecialKey = enum {
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    enter,
    tab,
    escape,

    // Shift-modified motion — selection extension. App-side text input
    // logic uses selection_anchor (cursor start) + cursor (current) to
    // build a selection range.
    shift_left,
    shift_right,
    shift_up,
    shift_down,
    shift_home,
    shift_end,
    // Shift+Tab — backward focus traversal, the companion to plain `tab`.
    // `teak.run` consumes it for Tab/Shift+Tab navigation. A host that
    // hasn't been taught to emit it yet simply never delivers it; forward
    // Tab still works.
    shift_tab,
    // Shift+Enter: a newline where plain Enter submits (chat boxes). `teak.run`
    // treats only plain `enter` as submit; this one reaches `keySpecialMsg`.
    shift_enter,

    // Ctrl chords for the text-input prose path. Apps that don't care
    // can ignore them — the Host still delivers them when the user
    // pressed Ctrl+key.
    ctrl_a, // select all
    ctrl_c, // copy
    ctrl_x, // cut
    ctrl_v, // paste
    ctrl_z, // undo
    ctrl_y, // redo
    ctrl_shift_z, // redo (alternate chord)

    // Ctrl-modified motion and deletion: word jumps and document start/end.
    ctrl_left,
    ctrl_right,
    ctrl_shift_left,
    ctrl_shift_right,
    ctrl_home,
    ctrl_end,
    ctrl_shift_home,
    ctrl_shift_end,
    ctrl_backspace,
    ctrl_delete,

    /// F12. `teak.run` consumes it to toggle the dev inspector panel when
    /// `RunOptions.inspect_hotkey` is on (Debug builds by default); otherwise
    /// it reaches the app like any other key.
    f12,
    // Menu-bar activation (see `teak.MenuBar`). F10 is the portable one; a
    // bare Alt tap (Alt pressed and released with no other key or button in
    // between) activates the bar on hosts that can see Alt on its own. Both
    // are *requests*; the app decides whether a menu bar exists.
    f10,
    alt_tap,
    // Context-menu request: the Menu / Apps key or Shift+F10. The app opens its
    // context menu at the focused widget (a request, like `f10`).
    context_menu,
};

/// A physical key a shortcut can name (layout-independent identity for
/// letters, digits, function keys, navigation and common punctuation).
/// Hosts map their native key codes onto this, like `NavKey`.
pub const Key = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    enter,
    tab,
    escape,
    space,
    backspace,
    delete,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    comma,
    period,
    slash,
    backslash,
    semicolon,
    quote,
    minus,
    equal,
    bracket_left,
    bracket_right,
    grave,

    /// The key for a lower/upper-case ASCII letter or digit (else null).
    pub fn fromAscii(c: u8) ?Key {
        return switch (c) {
            'a'...'z' => @fromBackingInt(@intCast(c - 'a')),
            'A'...'Z' => @fromBackingInt(@intCast(c - 'A')),
            '0'...'9' => @fromBackingInt(@intCast(@backingInt(Key.d0) + (c - '0'))),
            else => null,
        };
    }

    /// Short display name: `S`, `5`, `F12`, `Enter`, `PgUp`, `,`.
    pub fn label(self: Key) []const u8 {
        return switch (self) {
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => {
                const i = @backingInt(self);
                return "ABCDEFGHIJKLMNOPQRSTUVWXYZ"[i .. i + 1];
            },
            .d0 => "0",
            .d1 => "1",
            .d2 => "2",
            .d3 => "3",
            .d4 => "4",
            .d5 => "5",
            .d6 => "6",
            .d7 => "7",
            .d8 => "8",
            .d9 => "9",
            .f1 => "F1",
            .f2 => "F2",
            .f3 => "F3",
            .f4 => "F4",
            .f5 => "F5",
            .f6 => "F6",
            .f7 => "F7",
            .f8 => "F8",
            .f9 => "F9",
            .f10 => "F10",
            .f11 => "F11",
            .f12 => "F12",
            .enter => "Enter",
            .tab => "Tab",
            .escape => "Esc",
            .space => "Space",
            .backspace => "Backspace",
            .delete => "Del",
            .insert => "Ins",
            .left => "Left",
            .right => "Right",
            .up => "Up",
            .down => "Down",
            .home => "Home",
            .end => "End",
            .page_up => "PgUp",
            .page_down => "PgDn",
            .comma => ",",
            .period => ".",
            .slash => "/",
            .backslash => "\\",
            .semicolon => ";",
            .quote => "'",
            .minus => "-",
            .equal => "=",
            .bracket_left => "[",
            .bracket_right => "]",
            .grave => "`",
        };
    }
};

const std = @import("std");

/// Which naming a shortcut label uses for the primary modifier.
pub const Platform = enum {
    /// Ctrl (Windows, Linux, web elsewhere).
    pc,
    /// Cmd / Option naming (macOS).
    mac,
};

/// A keyboard shortcut: `key` with modifiers. `mod` is the platform's
/// primary shortcut modifier: Ctrl on Windows/Linux/X11 and Cmd on macOS
/// (the host decides what it reports), so one table works everywhere.
pub const Chord = struct {
    key: Key,
    mod: bool = false,
    shift: bool = false,
    alt: bool = false,

    /// Primary modifier + `k`: `Chord.ctrl(.s)` is "Save" on every platform.
    pub fn ctrl(k: Key) Chord {
        return .{ .key = k, .mod = true };
    }
    pub fn ctrlShift(k: Key) Chord {
        return .{ .key = k, .mod = true, .shift = true };
    }
    pub fn altKey(k: Key) Chord {
        return .{ .key = k, .alt = true };
    }
    /// No modifier (function keys).
    pub fn plain(k: Key) Chord {
        return .{ .key = k };
    }

    pub fn eql(a: Chord, b: Chord) bool {
        return a.key == b.key and a.mod == b.mod and a.shift == b.shift and a.alt == b.alt;
    }

    /// `Ctrl+Shift+P` (pc) or `Cmd+Shift+P` (mac); Alt is `Alt` / `Opt`.
    pub fn format(self: Chord, w: *std.Io.Writer, platform: Platform) std.Io.Writer.Error!void {
        if (self.mod) try w.writeAll(if (platform == .mac) "Cmd+" else "Ctrl+");
        if (self.alt) try w.writeAll(if (platform == .mac) "Opt+" else "Alt+");
        if (self.shift) try w.writeAll("Shift+");
        try w.writeAll(self.key.label());
    }

    /// Parse `ctrl+shift+p` / `cmd+k` / `alt+enter` / `f12` (case-insensitive;
    /// `ctrl`, `cmd`, `mod` and `meta` all mean the primary modifier).
    pub fn parse(s: []const u8) ?Chord {
        var c: Chord = .{ .key = .a };
        var have_key = false;
        var it = std.mem.splitScalar(u8, s, '+');
        while (it.next()) |part| {
            if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "cmd") or
                std.ascii.eqlIgnoreCase(part, "mod") or std.ascii.eqlIgnoreCase(part, "meta"))
            {
                c.mod = true;
            } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
                c.shift = true;
            } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "opt")) {
                c.alt = true;
            } else {
                if (have_key) return null;
                have_key = true;
                c.key = parseKey(part) orelse return null;
            }
        }
        return if (have_key) c else null;
    }

    fn parseKey(part: []const u8) ?Key {
        if (part.len == 1) if (Key.fromAscii(part[0])) |k| return k;
        for (std.enums.values(Key)) |k| {
            if (std.ascii.eqlIgnoreCase(part, @tagName(k)) or std.ascii.eqlIgnoreCase(part, k.label())) return k;
        }
        return null;
    }

    /// The `SpecialKey` hosts also deliver for this chord (the text-editing
    /// chords: Ctrl+A/C/X/V/Y/Z, word jumps, ...), so the runtime can
    /// swallow it when a command claims the chord. Null when none.
    pub fn special(self: Chord) ?SpecialKey {
        if (self.key == .f12 and !self.mod and !self.shift and !self.alt) return .f12;
        if (!self.mod or self.alt) return null;
        if (!self.shift) return switch (self.key) {
            .a => .ctrl_a,
            .c => .ctrl_c,
            .x => .ctrl_x,
            .v => .ctrl_v,
            .y => .ctrl_y,
            .z => .ctrl_z,
            .left => .ctrl_left,
            .right => .ctrl_right,
            .home => .ctrl_home,
            .end => .ctrl_end,
            .backspace => .ctrl_backspace,
            .delete => .ctrl_delete,
            else => null,
        };
        return switch (self.key) {
            .z => .ctrl_shift_z,
            .left => .ctrl_shift_left,
            .right => .ctrl_shift_right,
            .home => .ctrl_shift_home,
            .end => .ctrl_shift_end,
            else => null,
        };
    }
};

test "Chord format, parse and special" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Chord.ctrlShift(.p).format(&w, .pc);
    try std.testing.expectEqualStrings("Ctrl+Shift+P", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try Chord.ctrl(.s).format(&w, .mac);
    try std.testing.expectEqualStrings("Cmd+S", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try (Chord{ .key = .enter, .alt = true }).format(&w, .pc);
    try std.testing.expectEqualStrings("Alt+Enter", w.buffered());

    try std.testing.expect(Chord.parse("ctrl+shift+P").?.eql(Chord.ctrlShift(.p)));
    try std.testing.expect(Chord.parse("Cmd+K").?.eql(Chord.ctrl(.k)));
    try std.testing.expect(Chord.parse("f12").?.eql(Chord.plain(.f12)));
    try std.testing.expect(Chord.parse("alt+enter").?.eql(Chord.altKey(.enter)));
    try std.testing.expect(Chord.parse("ctrl+5").?.eql(Chord.ctrl(.d5)));
    try std.testing.expect(Chord.parse("ctrl+,").?.eql(Chord.ctrl(.comma)));
    try std.testing.expect(Chord.parse("ctrl+") == null);
    try std.testing.expect(Chord.parse("ctrl+a+b") == null);
    try std.testing.expect(Chord.parse("bogus") == null);

    try std.testing.expectEqual(SpecialKey.ctrl_c, Chord.ctrl(.c).special().?);
    try std.testing.expectEqual(SpecialKey.ctrl_shift_z, Chord.ctrlShift(.z).special().?);
    try std.testing.expect(Chord.ctrl(.s).special() == null);
}
