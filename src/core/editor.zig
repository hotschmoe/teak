//! Text-editing state: a fixed-capacity UTF-8 buffer with a cursor, an
//! optional selection anchor, a sticky-column goal and an undo log. Pure data
//! plus pure methods; the whole thing lives in the component Model (HARDLINE:
//! all state in Model).
//!
//! Invariants (property-tested): `cursor <= len`; `cursor` and `selection_anchor`
//! always sit on grapheme boundaries (`unicode.zig`); `buf[0..len]` is whatever
//! was typed -- invalid UTF-8 is tolerated, each bad byte is one unit -- and no
//! operation can split a multi-byte sequence or a grapheme cluster.
//!
//! Every edit funnels through one primitive (`replaceRange`): it truncates the
//! inserted text on a grapheme boundary when capacity runs out, records an undo
//! entry, and re-snaps cursor/anchor to boundaries (inserting a combining mark
//! in front of existing text can change cluster boundaries).
//!
//! Layout-dependent motions (visual Home/End, Up/Down with a sticky column,
//! Page Up/Down) take the same `(font, max_w, mode, measurer)` arguments as
//! `text_wrap` and go through its line walk, so the editor needs no hidden
//! layout state. The caller (update, from a metrics event) supplies them.
//!
//! Undo is a bounded log of `{pos, removed bytes, inserted bytes}` records.
//! Consecutive single-grapheme word-character inserts coalesce into one record;
//! any motion, deletion or non-adjacent edit closes the group. When the log is
//! full the oldest records are dropped and `undo.dropped` counts them.

const std = @import("std");
const unicode = @import("unicode.zig");
const bidi_text = @import("bidi_text.zig");
const text_wrap = @import("text_wrap.zig");
const text_mod = @import("text.zig");
const keys = @import("../input/keys.zig");
const text_event = @import("text_event.zig");

const SpecialKey = keys.SpecialKey;
const FontSpec = text_mod.FontSpec;
const TextMeasurer = text_mod.TextMeasurer;

const NO_ANCHOR: u32 = std.math.maxInt(u32);

/// Bounded undo history. `byte_cap` bounds the stored bytes (removed + inserted
/// text of all records); `rec_cap` bounds the record count.
pub fn UndoLog(comptime rec_cap: usize, comptime byte_cap: usize) type {
    return struct {
        const Self = @This();

        const Rec = struct {
            pos: u32,
            removed_len: u32,
            inserted_len: u32,
            /// Offset in `bytes`: removed text, then inserted text.
            off: u32,
            cursor_before: u32,
            /// `NO_ANCHOR` when there was no selection anchor.
            anchor_before: u32,
            cursor_after: u32,
        };

        recs: [rec_cap]Rec = undefined,
        /// Records stored; `at` of them are applied (the rest are redo).
        n: u32 = 0,
        at: u32 = 0,
        bytes: [byte_cap]u8 = undefined,
        bytes_len: u32 = 0,
        /// Last record may absorb the next adjacent word-character insert.
        open: bool = false,
        /// Records discarded because the log was full (surface in a status line).
        dropped: u32 = 0,

        pub fn canUndo(self: *const Self) bool {
            return self.at > 0;
        }

        pub fn canRedo(self: *const Self) bool {
            return self.at < self.n;
        }

        /// Close the current coalescing group.
        pub fn breakGroup(self: *Self) void {
            self.open = false;
        }

        pub fn clear(self: *Self) void {
            self.n = 0;
            self.at = 0;
            self.bytes_len = 0;
            self.open = false;
        }

        /// Text inserted by the newest record (empty when none).
        fn lastInserted(self: *const Self) []const u8 {
            if (self.n == 0) return "";
            const r = self.recs[self.n - 1];
            return self.bytes[r.off + r.removed_len ..][0..r.inserted_len];
        }

        fn dropOldest(self: *Self) void {
            const r0 = self.recs[0];
            const size = r0.removed_len + r0.inserted_len;
            std.mem.copyForwards(u8, self.bytes[0 .. self.bytes_len - size], self.bytes[size..self.bytes_len]);
            self.bytes_len -= size;
            var i: usize = 1;
            while (i < self.n) : (i += 1) {
                self.recs[i - 1] = self.recs[i];
                self.recs[i - 1].off -= size;
            }
            self.n -= 1;
            self.at -|= 1;
            self.dropped +|= 1;
        }

        /// Drop redo records (a new edit invalidates them).
        fn truncateRedo(self: *Self) void {
            self.n = self.at;
            self.bytes_len = if (self.n == 0) 0 else blk: {
                const r = self.recs[self.n - 1];
                break :blk r.off + r.removed_len + r.inserted_len;
            };
        }

        /// Can an insert of `w` bytes at `pos` extend the newest record?
        fn canCoalesce(self: *const Self, pos: usize, w: usize) bool {
            if (!self.open or self.n == 0 or self.at != self.n) return false;
            const r = self.recs[self.n - 1];
            return r.removed_len == 0 and r.pos + r.inserted_len == pos and self.bytes_len + w <= byte_cap;
        }

        /// Reserve room for an edit; returns the slice `[removed ++ inserted]`
        /// to fill (for a coalesced extension only `inserted`), or null when the
        /// edit cannot be recorded (history is then cleared).
        fn reserve(self: *Self, pos: usize, removed_len: usize, w: usize, coalesce: bool) ?[]u8 {
            if (byte_cap == 0 or rec_cap == 0) return null;
            if (coalesce and removed_len == 0 and self.canCoalesce(pos, w)) {
                return self.bytes[self.bytes_len..][0..w];
            }
            self.truncateRedo();
            const need = removed_len + w;
            if (need > byte_cap) {
                self.dropped +|= self.n;
                self.clear();
                return null;
            }
            while (self.n == rec_cap or self.bytes_len + need > byte_cap) self.dropOldest();
            return self.bytes[self.bytes_len..][0..need];
        }

        /// Finish a `reserve`d edit.
        fn commit(self: *Self, coalesced: bool, pos: usize, removed_len: usize, w: usize, cursor_before: usize, anchor_before: ?usize, cursor_after: usize, may_open: bool) void {
            if (coalesced) {
                const r = &self.recs[self.n - 1];
                r.inserted_len += @intCast(w);
                r.cursor_after = @intCast(cursor_after);
                self.bytes_len += @intCast(w);
                return;
            }
            self.recs[self.n] = .{
                .pos = @intCast(pos),
                .removed_len = @intCast(removed_len),
                .inserted_len = @intCast(w),
                .off = self.bytes_len,
                .cursor_before = @intCast(cursor_before),
                .anchor_before = if (anchor_before) |a| @intCast(a) else NO_ANCHOR,
                .cursor_after = @intCast(cursor_after),
            };
            self.bytes_len += @intCast(removed_len + w);
            self.n += 1;
            self.at = self.n;
            self.open = may_open;
        }
    };
}

/// Editor with `cap` bytes of text and `undo_cap` bytes of undo history
/// (`0` disables undo). The record count is `undo_cap / 16` (at least 4).
pub fn Editor(comptime cap: usize, comptime undo_cap: usize) type {
    return struct {
        const Self = @This();
        pub const capacity = cap;
        pub const Undo = UndoLog(if (undo_cap == 0) 0 else @max(4, undo_cap / 16), undo_cap);

        buf: [cap]u8 = @splat(0),
        len: usize = 0,
        /// Byte offset, always on a grapheme boundary.
        cursor: usize = 0,
        /// Selection anchor (named like `text_input.selection_anchor`); the
        /// selection is `[min, max)` of anchor and cursor.
        selection_anchor: ?usize = null,
        /// Sticky x for Up/Down (logical px). Cleared by every other operation.
        goal_x: ?f32 = null,
        /// Newlines/tabs are kept (true) or become spaces (false, single-line).
        multiline: bool = false,
        undo: Undo = .{},
        /// Incomplete UTF-8 sequence from `typeByte`.
        pending: [4]u8 = undefined,
        pending_len: u8 = 0,

        pub const Move = enum {
            left,
            right,
            /// Start/end of the logical (hard) line.
            home,
            end,
            word_left,
            word_right,
            doc_start,
            doc_end,
        };

        // ── Queries ───────────────────────────────────────────────

        pub fn content(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn hasSelection(self: *const Self) bool {
            return if (self.selection_anchor) |a| a != self.cursor else false;
        }

        /// Selected range, or null when empty.
        pub fn selectionRange(self: *const Self) ?struct { lo: usize, hi: usize } {
            const a = self.selection_anchor orelse return null;
            if (a == self.cursor) return null;
            return .{ .lo = @min(a, self.cursor), .hi = @max(a, self.cursor) };
        }

        pub fn selection(self: *const Self) []const u8 {
            const r = self.selectionRange() orelse return "";
            return self.buf[r.lo..r.hi];
        }

        /// Alias used by the TextField model.
        pub fn selectionText(self: *const Self) []const u8 {
            return self.selection();
        }

        // ── Whole-buffer operations ───────────────────────────────

        /// Replace the whole content (truncated at capacity on a grapheme
        /// boundary), cursor at the end, history cleared.
        pub fn set(self: *Self, s: []const u8) void {
            var n: usize = @min(s.len, cap);
            if (n < s.len) n = unicode.snapBackward(s, n);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
            self.cursor = n;
            self.selection_anchor = null;
            self.goal_x = null;
            self.pending_len = 0;
            self.undo.clear();
        }

        pub fn clear(self: *Self) void {
            self.set("");
        }

        pub fn selectAll(self: *Self) void {
            self.goal_x = null;
            self.undo.breakGroup();
            self.selection_anchor = 0;
            self.cursor = self.len;
        }

        pub fn deselect(self: *Self) void {
            self.selection_anchor = null;
        }

        /// Select `[anchor, cursor]` (snapped to grapheme boundaries).
        pub fn setSelection(self: *Self, anchor: usize, cursor_pos: usize) void {
            self.goal_x = null;
            self.undo.breakGroup();
            self.selection_anchor = unicode.snapBackward(self.content(), anchor);
            self.cursor = unicode.snapBackward(self.content(), cursor_pos);
        }

        /// Select the word (run of one class) at byte offset `i` (double-click).
        pub fn selectWordAt(self: *Self, i: usize) void {
            const r = unicode.wordRangeAt(self.content(), i);
            self.setSelection(r.start, r.end);
        }

        // ── Motion ────────────────────────────────────────────────

        /// Move the cursor to `i` (snapped back to a grapheme boundary),
        /// extending the selection when `extend`.
        pub fn moveTo(self: *Self, i: usize, extend: bool) void {
            self.goal_x = null;
            self.moveToKeepGoal(i, extend);
        }

        fn moveToKeepGoal(self: *Self, i: usize, extend: bool) void {
            self.undo.breakGroup();
            if (extend) {
                if (self.selection_anchor == null) self.selection_anchor = self.cursor;
            } else self.selection_anchor = null;
            self.cursor = unicode.snapBackward(self.content(), i);
        }

        pub fn move(self: *Self, m: Move, extend: bool) void {
            self.goal_x = null;
            if (!extend and self.hasSelection()) {
                // Collapse toward the direction of travel, like every text box.
                const r = self.selectionRange().?;
                switch (m) {
                    .left, .word_left, .home, .doc_start => self.cursor = r.lo,
                    .right, .word_right, .end, .doc_end => self.cursor = r.hi,
                }
                self.selection_anchor = null;
                self.undo.breakGroup();
                if (m == .left or m == .right) return;
            }
            const t = self.content();
            const target: usize = switch (m) {
                .left => self.visualStep(.left) orelse if (self.cursor == 0) 0 else unicode.prevGrapheme(t, self.cursor),
                .right => self.visualStep(.right) orelse if (self.cursor >= self.len) self.len else unicode.nextGrapheme(t, self.cursor),
                .home => lineStart(t, self.cursor),
                .end => lineEnd(t, self.cursor),
                .word_left => unicode.prevWordBoundary(t, self.cursor),
                .word_right => wordRight(t, self.cursor),
                .doc_start => 0,
                .doc_end => self.len,
            };
            self.moveToKeepGoal(target, extend);
        }

        /// Left / Right in visual order over the cursor's hard line when the text
        /// mixes directions (single-line fields; a text area's runtime resolves
        /// wrapped lines itself). Null: plain text or already at the visual edge.
        fn visualStep(self: *Self, arrow: bidi_text.bidi.Arrow) ?usize {
            const t = self.content();
            if (!bidi_text.mayBeRtl(t)) return null;
            var sc: bidi_text.Scratch = .{};
            return bidi_text.arrowTarget(t, lineStart(t, self.cursor), lineEnd(t, self.cursor), self.cursor, arrow, &sc);
        }

        /// Home/End of the *visual* line (the wrapped line the cursor is on).
        pub fn moveLineEdge(self: *Self, edge: enum { start, end }, extend: bool, font: FontSpec, max_w: f32, mode: text_wrap.Wrap, m: TextMeasurer) void {
            const r = text_wrap.resolveNav(self.content(), self.cursor, null, if (edge == .start) .line_start else .line_end, 1, font, max_w, mode, m);
            self.moveTo(r.index, extend);
        }

        /// Up/Down/Page: move `lines` visual lines (negative = up), keeping the
        /// sticky column in `goal_x`. Past the first/last line the cursor goes
        /// to the start/end of the text.
        pub fn moveVertical(self: *Self, lines: i32, extend: bool, font: FontSpec, max_w: f32, mode: text_wrap.Wrap, m: TextMeasurer) void {
            const kind: text_wrap.NavKind = if (lines < 0) (if (lines == -1) .up else .page_up) else (if (lines == 1) .down else .page_down);
            const page: u32 = @intCast(@abs(lines));
            const r = text_wrap.resolveNav(self.content(), self.cursor, self.goal_x, kind, page, font, max_w, mode, m);
            self.moveToKeepGoal(r.index, extend);
            self.goal_x = r.goal_x;
        }

        /// Apply a pointer / navigation `TextEvent` (core/text_event.zig):
        /// click sets the caret (Shift extends), drag extends from the press
        /// point, double click selects the word, triple click the hard line,
        /// and a resolved `move` goes to its target keeping the sticky column.
        /// Wheel / metrics concern scrolling and are the caller's (see
        /// `TextArea`). Returns true when the event was a caret / selection one.
        pub fn applyPointer(self: *Self, ev: text_event.TextEvent) bool {
            switch (ev.kind) {
                .down => self.moveTo(ev.index, ev.mods.shift),
                .drag => self.moveTo(ev.index, true),
                .double_click => self.selectWordAt(ev.index),
                .triple_click => {
                    const t = self.content();
                    const lo = lineStart(t, ev.index);
                    var hi = lineEnd(t, ev.index);
                    if (hi < t.len) hi = unicode.nextGrapheme(t, hi); // include the newline
                    self.setSelection(lo, hi);
                },
                .move => {
                    self.moveToKeepGoal(ev.index, ev.mods.shift);
                    self.goal_x = if (ev.keep_goal) ev.goal_x else null;
                },
                .up, .wheel, .metrics, .leave => return false,
            }
            return true;
        }

        // ── Editing ───────────────────────────────────────────────

        /// Insert text at the cursor, replacing the selection. Control
        /// characters are dropped; newline and tab become spaces unless
        /// `multiline`. Truncates on a grapheme boundary at capacity. Also the
        /// paste primitive. `bytes` must not alias the buffer.
        pub fn insert(self: *Self, bytes: []const u8) void {
            const lo, const hi = if (self.selectionRange()) |r| .{ r.lo, r.hi } else .{ self.cursor, self.cursor };
            self.replaceRange(lo, hi, bytes);
        }

        /// Alias of `insert` for clipboard text.
        pub fn paste(self: *Self, bytes: []const u8) void {
            self.insert(bytes);
        }

        /// Feed one byte of typed UTF-8 (the `TextField.char` path). Bytes of a
        /// multi-byte sequence are buffered until complete so a full character
        /// is inserted (or dropped) atomically.
        pub fn typeByte(self: *Self, c: u8) void {
            if (self.pending_len > 0) {
                if (c & 0xC0 == 0x80) {
                    self.pending[self.pending_len] = c;
                    self.pending_len += 1;
                    if (self.pending_len == seqLen(self.pending[0])) {
                        const n = self.pending_len;
                        self.pending_len = 0;
                        self.insert(self.pending[0..n]);
                    }
                    return;
                }
                // Broken sequence: keep the bytes as-is (each is an invalid unit).
                const n = self.pending_len;
                self.pending_len = 0;
                self.insert(self.pending[0..n]);
            }
            if (c >= 0xC2 and c <= 0xF4) {
                self.pending[0] = c;
                self.pending_len = 1;
                return;
            }
            self.insert(&[1]u8{c});
        }

        pub fn backspace(self: *Self) void {
            if (self.hasSelection()) return self.insert("");
            if (self.cursor == 0) return;
            self.replaceRange(unicode.prevGrapheme(self.content(), self.cursor), self.cursor, "");
        }

        pub fn delete(self: *Self) void {
            if (self.hasSelection()) return self.insert("");
            if (self.cursor >= self.len) return;
            self.replaceRange(self.cursor, unicode.nextGrapheme(self.content(), self.cursor), "");
        }

        /// Ctrl+Backspace: delete back to the previous word start.
        pub fn deleteWordLeft(self: *Self) void {
            if (self.hasSelection()) return self.insert("");
            const lo = unicode.prevWordBoundary(self.content(), self.cursor);
            if (lo < self.cursor) self.replaceRange(lo, self.cursor, "");
        }

        /// Ctrl+Delete: delete forward to the next word start.
        pub fn deleteWordRight(self: *Self) void {
            if (self.hasSelection()) return self.insert("");
            const hi = wordRight(self.content(), self.cursor);
            if (hi > self.cursor) self.replaceRange(self.cursor, hi, "");
        }

        /// The single edit primitive: replace `[lo, hi)` with filtered `input`.
        fn replaceRange(self: *Self, lo: usize, hi: usize, input: []const u8) void {
            self.goal_x = null;
            const tail_len = self.len - hi;
            const room = cap - lo - tail_len;
            const w = filterInsert(self.multiline, input, room, null);
            if (hi == lo and w == 0) return;

            const cursor_before = self.cursor;
            const anchor_before = self.selection_anchor;

            // Coalesce a typed word character into the previous record.
            const single_word = w > 0 and hi == lo and blk: {
                const first = unicode.nextGrapheme(input, 0);
                if (first != input.len) break :blk false;
                if (unicode.wordClass(unicode.firstCodepoint(input)) != .word) break :blk false;
                if (lo == 0) break :blk false;
                const prev = unicode.prevGrapheme(self.content(), lo);
                break :blk unicode.wordClass(unicode.firstCodepoint(self.buf[prev..lo])) == .word and
                    self.undo.canCoalesce(lo, w);
            };

            const slot = self.undo.reserve(lo, hi - lo, w, single_word);
            var inserted_in_log = false;
            if (slot) |s| {
                const rm = hi - lo;
                if (single_word) {
                    _ = filterInsert(self.multiline, input, room, s[0..w]);
                } else {
                    @memcpy(s[0..rm], self.buf[lo..hi]);
                    _ = filterInsert(self.multiline, input, room, s[rm..][0..w]);
                }
                inserted_in_log = true;
            }

            @memmove(self.buf[lo + w ..][0..tail_len], self.buf[hi..][0..tail_len]);
            if (inserted_in_log) {
                const s = slot.?;
                const rm = if (single_word) 0 else hi - lo;
                @memcpy(self.buf[lo..][0..w], s[rm..][0..w]);
            } else {
                _ = filterInsert(self.multiline, input, room, self.buf[lo..][0..w]);
            }
            self.len = lo + w + tail_len;
            self.cursor = snapForward(self.content(), lo + w);
            self.selection_anchor = null;
            if (inserted_in_log) {
                self.undo.commit(single_word, lo, hi - lo, w, cursor_before, anchor_before, self.cursor, w > 0 and hi == lo and self.isWordInsert(lo, w));
            } else self.undo.breakGroup();
        }

        fn isWordInsert(self: *const Self, lo: usize, w: usize) bool {
            const t = self.buf[lo .. lo + w];
            if (unicode.nextGrapheme(t, 0) != t.len) return false;
            return unicode.wordClass(unicode.firstCodepoint(t)) == .word;
        }

        // ── Undo / redo ───────────────────────────────────────────

        /// Raw splice used by undo/redo (sizes always fit: they replay states
        /// that existed).
        fn splice(self: *Self, pos: usize, del: usize, ins: []const u8) void {
            const tail = self.len - pos - del;
            @memmove(self.buf[pos + ins.len ..][0..tail], self.buf[pos + del ..][0..tail]);
            @memcpy(self.buf[pos..][0..ins.len], ins);
            self.len = pos + ins.len + tail;
        }

        pub fn undoEdit(self: *Self) bool {
            const u = &self.undo;
            if (u.at == 0) return false;
            const r = u.recs[u.at - 1];
            self.splice(r.pos, r.inserted_len, u.bytes[r.off..][0..r.removed_len]);
            self.cursor = r.cursor_before;
            self.selection_anchor = if (r.anchor_before == NO_ANCHOR) null else r.anchor_before;
            u.at -= 1;
            u.open = false;
            self.goal_x = null;
            return true;
        }

        pub fn redoEdit(self: *Self) bool {
            const u = &self.undo;
            if (u.at >= u.n) return false;
            const r = u.recs[u.at];
            self.splice(r.pos, r.removed_len, u.bytes[r.off + r.removed_len ..][0..r.inserted_len]);
            self.cursor = r.cursor_after;
            self.selection_anchor = null;
            u.at += 1;
            u.open = false;
            self.goal_x = null;
            return true;
        }

        // ── Key dispatch ──────────────────────────────────────────

        /// Apply a layout-independent editing key. Returns false when the key
        /// is not handled here (Up/Down/PageUp/PageDown need layout -- use
        /// `moveVertical`; clipboard chords belong to the Host; Enter/Tab are
        /// the app's).
        pub fn applyKey(self: *Self, key: SpecialKey) bool {
            switch (key) {
                .backspace => self.backspace(),
                .delete => self.delete(),
                .ctrl_backspace => self.deleteWordLeft(),
                .ctrl_delete => self.deleteWordRight(),
                .left => self.move(.left, false),
                .right => self.move(.right, false),
                .home => self.move(.home, false),
                .end => self.move(.end, false),
                .shift_left => self.move(.left, true),
                .shift_right => self.move(.right, true),
                .shift_home => self.move(.home, true),
                .shift_end => self.move(.end, true),
                .ctrl_left => self.move(.word_left, false),
                .ctrl_right => self.move(.word_right, false),
                .ctrl_shift_left => self.move(.word_left, true),
                .ctrl_shift_right => self.move(.word_right, true),
                .ctrl_home => self.move(.doc_start, false),
                .ctrl_end => self.move(.doc_end, false),
                .ctrl_shift_home => self.move(.doc_start, true),
                .ctrl_shift_end => self.move(.doc_end, true),
                .ctrl_a => self.selectAll(),
                .ctrl_z => _ = self.undoEdit(),
                .ctrl_y, .ctrl_shift_z => _ = self.redoEdit(),
                .escape => self.deselect(),
                else => return false,
            }
            return true;
        }

        // ── Display window (fields wider than their box) ─────────

        pub const Window = struct { start: usize, end: usize, cursor: usize, anchor: ?usize };

        /// Bytes `[start, end)` to display in a box that fits `max_cols`
        /// monospace columns (one per grapheme), keeping the cursor visible.
        pub fn window(self: *const Self, max_cols: usize) Window {
            const t = self.content();
            const total = unicode.graphemeCount(t);
            if (total <= max_cols or max_cols == 0) return .{ .start = 0, .end = self.len, .cursor = self.cursor, .anchor = self.selection_anchor };
            const cur_col = unicode.graphemeCount(t[0..self.cursor]);
            const first_col = if (cur_col + 1 > max_cols) cur_col + 1 - max_cols else 0;
            const start = byteOfColumn(t, first_col);
            const end = byteOfColumn(t, first_col + max_cols);
            return .{
                .start = start,
                .end = end,
                .cursor = self.cursor - start,
                .anchor = if (self.selection_anchor) |a| (if (a < start) 0 else if (a > end) end - start else a - start) else null,
            };
        }
    };
}

// ── Helpers ───────────────────────────────────────────────────────

fn seqLen(lead: u8) usize {
    return if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else 2;
}

fn byteOfColumn(s: []const u8, col: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < col) : (n += 1) i = unicode.nextGrapheme(s, i);
    return i;
}

/// Smallest grapheme boundary >= `i`.
fn snapForward(t: []const u8, i: usize) usize {
    if (i >= t.len) return t.len;
    if (unicode.isGraphemeBoundary(t, i)) return i;
    return unicode.nextGrapheme(t, unicode.prevGrapheme(t, i));
}

/// Start of the hard line containing `i`.
pub fn lineStart(t: []const u8, i: usize) usize {
    var p = i;
    while (p > 0) {
        const s = unicode.prevGrapheme(t, p);
        if (isNewline(t[s..p])) break;
        p = s;
    }
    return p;
}

/// End of the hard line containing `i` (before its terminator).
pub fn lineEnd(t: []const u8, i: usize) usize {
    var p = i;
    while (p < t.len) {
        const e = unicode.nextGrapheme(t, p);
        if (isNewline(t[p..e])) break;
        p = e;
    }
    return p;
}

fn isNewline(cluster: []const u8) bool {
    return cluster[0] == '\n' or cluster[0] == '\r';
}

/// Ctrl+Right target: finish the current word, then skip spaces (start of the
/// next word). Han ideographs are one word each.
fn wordRight(t: []const u8, i: usize) usize {
    if (i >= t.len) return t.len;
    var p = i;
    var e = unicode.nextGrapheme(t, p);
    const cls = unicode.wordClass(unicode.firstCodepoint(t[p..e]));
    if (cls != .space) {
        p = e;
        if (cls != .han) {
            while (p < t.len) {
                e = unicode.nextGrapheme(t, p);
                if (unicode.wordClass(unicode.firstCodepoint(t[p..e])) != cls) break;
                p = e;
            }
        }
    }
    while (p < t.len) {
        e = unicode.nextGrapheme(t, p);
        if (unicode.wordClass(unicode.firstCodepoint(t[p..e])) != .space) break;
        p = e;
    }
    return p;
}

/// Filter `input` for insertion (see `Editor.insert`), stopping before `max`
/// output bytes (whole grapheme clusters only). Writes into `dest` when given;
/// returns the output length either way.
fn filterInsert(multiline: bool, input: []const u8, max: usize, dest: ?[]u8) usize {
    var out: usize = 0;
    var p: usize = 0;
    while (p < input.len) {
        const e = unicode.nextGrapheme(input, p);
        const cluster = input[p..e];
        p = e;
        const piece: []const u8 = switch (cluster[0]) {
            '\n', '\r' => if (multiline) "\n" else " ",
            '\t' => if (multiline) "\t" else " ",
            0...8, 11, 12, 14...31, 127 => continue,
            else => cluster,
        };
        if (out + piece.len > max) break;
        if (dest) |d| @memcpy(d[out..][0..piece.len], piece);
        out += piece.len;
    }
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

const E = Editor(256, 512);

// Ported from Kerf's apps/teak editor.zig.

test "kerf: insert, backspace, delete, utf8" {
    var e: E = .{};
    e.insert("ab");
    e.insert("\u{00e9}"); // 2 bytes
    try testing.expectEqualStrings("ab\u{00e9}", e.content());
    e.backspace();
    try testing.expectEqualStrings("ab", e.content());
    e.move(.home, false);
    e.delete();
    try testing.expectEqualStrings("b", e.content());
}

test "kerf: selection replace and word jumps" {
    var e: E = .{};
    e.insert("hello big world");
    e.move(.word_left, true);
    try testing.expectEqualStrings("world", e.selection());
    e.insert("kerf");
    try testing.expectEqualStrings("hello big kerf", e.content());
    e.move(.home, false);
    e.move(.word_right, false);
    try testing.expectEqual(@as(usize, 6), e.cursor);
}

test "kerf: control characters are dropped, newlines become spaces" {
    var e: E = .{};
    e.insert("a\nb\x01c");
    try testing.expectEqualStrings("a bc", e.content());
}

test "kerf: window keeps the cursor visible" {
    var e: E = .{};
    e.insert("0123456789");
    const w = e.window(4);
    try testing.expectEqualStrings("789", e.content()[w.start..w.end]);
    try testing.expectEqual(@as(usize, 3), w.cursor);
}

fn expectInvariants(e: anytype) !void {
    const t = e.content();
    try testing.expect(e.cursor <= e.len);
    try testing.expect(unicode.isGraphemeBoundary(t, e.cursor));
    if (e.selection_anchor) |a| {
        try testing.expect(a <= e.len);
        try testing.expect(unicode.isGraphemeBoundary(t, a));
    }
}

test "backspace over e + U+0301 deletes the whole grapheme" {
    var e: E = .{};
    e.insert("ae\u{0301}");
    e.backspace();
    try testing.expectEqualStrings("a", e.content());
    e.insert("\u{1F468}\u{200D}\u{1F469}");
    e.backspace();
    try testing.expectEqualStrings("a", e.content());
    e.insert("xy");
    e.move(.left, false);
    e.delete();
    try testing.expectEqualStrings("ax", e.content());
}

test "left/right step by grapheme; selection collapses toward travel" {
    var e: E = .{};
    e.insert("a\u{1F1FA}\u{1F1F8}b"); // a, flag, b
    e.move(.left, false);
    e.move(.left, false);
    try testing.expectEqual(@as(usize, 1), e.cursor);
    e.move(.right, true);
    e.move(.right, true);
    try testing.expectEqual(@as(usize, 1), e.selection_anchor.?);
    try testing.expectEqual(e.len, e.cursor);
    e.move(.left, false); // collapses to the start of the selection
    try testing.expectEqual(@as(usize, 1), e.cursor);
    try testing.expect(!e.hasSelection());
}

test "word jumps over classes, CJK and punctuation" {
    var e: E = .{};
    e.insert("foo.bar  baz");
    e.move(.doc_start, false);
    e.move(.word_right, false);
    try testing.expectEqual(@as(usize, 3), e.cursor); // before "."
    e.move(.word_right, false);
    try testing.expectEqual(@as(usize, 4), e.cursor);
    e.move(.word_right, false);
    try testing.expectEqual(@as(usize, 9), e.cursor);
    e.move(.word_left, false);
    try testing.expectEqual(@as(usize, 4), e.cursor);
    e.deleteWordRight();
    try testing.expectEqualStrings("foo.baz", e.content());
    e.deleteWordLeft();
    try testing.expectEqualStrings("foobaz", e.content()); // "." is the previous word
}

test "home/end are per hard line; doc_start/doc_end span the text" {
    var e: E = .{ .multiline = true };
    e.insert("one\ntwo\nthree");
    e.move(.home, false);
    try testing.expectEqual(@as(usize, 8), e.cursor);
    e.move(.left, false);
    e.move(.end, false);
    try testing.expectEqual(@as(usize, 7), e.cursor);
    e.move(.doc_start, true);
    try testing.expectEqual(@as(usize, 0), e.cursor);
    try testing.expectEqual(@as(usize, 7), e.selection_anchor.?);
}

test "insert at capacity truncates on a grapheme boundary" {
    var e = Editor(8, 64){};
    e.insert("abcde");
    e.insert("e\u{0301}x"); // cluster is 3 bytes: only 3 bytes of room left
    try testing.expectEqualStrings("abcdee\u{0301}", e.content());
    e.insert("z");
    try testing.expectEqual(@as(usize, 8), e.len);
    var f = Editor(7, 64){};
    f.insert("abcde");
    f.insert("e\u{0301}"); // 3 bytes, room for 2: dropped entirely, no split
    try testing.expectEqualStrings("abcde", f.content());
    try expectInvariants(f);
    var g = Editor(4, 64){};
    g.insert("\u{1F600}\u{1F600}"); // 4-byte emoji x2
    try testing.expectEqualStrings("\u{1F600}", g.content());
}

test "typeByte assembles multi-byte characters atomically" {
    var e = Editor(4, 64){};
    for ("ab\u{00e9}\u{00e9}") |c| e.typeByte(c); // second é does not fit (2+2 > 4-... )
    try testing.expectEqualStrings("ab\u{00e9}", e.content());
    var f = Editor(16, 64){};
    for ("\u{20AC}x\u{1F600}") |c| f.typeByte(c);
    try testing.expectEqualStrings("\u{20AC}x\u{1F600}", f.content());
    f.typeByte(0xE2);
    f.typeByte('a'); // broken sequence flushed as-is
    try testing.expectEqualStrings("\u{20AC}x\u{1F600}\xE2a", f.content());
}

test "paste is bounded and replaces the selection" {
    var e = Editor(10, 64){};
    e.insert("hello");
    e.selectAll();
    e.paste("0123456789abc");
    try testing.expectEqualStrings("0123456789", e.content());
    try expectInvariants(e);
}

test "undo/redo: replace, delete, coalescing of typed words" {
    var e: E = .{};
    for ("hello") |c| e.typeByte(c);
    e.insert(" ");
    for ("world") |c| e.typeByte(c);
    // "hello", " ", "world" -> 3 groups (word, space, word)
    try testing.expectEqual(@as(u32, 3), e.undo.n);
    try testing.expect(e.undoEdit());
    try testing.expectEqualStrings("hello ", e.content());
    try testing.expect(e.undoEdit());
    try testing.expect(e.undoEdit());
    try testing.expectEqualStrings("", e.content());
    try testing.expect(!e.undoEdit());
    try testing.expect(e.redoEdit());
    try testing.expectEqualStrings("hello", e.content());
    try testing.expect(e.redoEdit());
    try testing.expect(e.redoEdit());
    try testing.expectEqualStrings("hello world", e.content());
    try testing.expectEqual(@as(usize, 11), e.cursor);

    // Replacing a selection undoes back to the selection.
    e.move(.word_left, true);
    e.insert("there");
    try testing.expectEqualStrings("hello there", e.content());
    try testing.expect(e.undoEdit());
    try testing.expectEqualStrings("hello world", e.content());
    try testing.expectEqualStrings("world", e.selection());

    // A new edit discards redo.
    e.deselect();
    e.move(.doc_end, false);
    e.backspace();
    try testing.expect(!e.redoEdit());
}

test "undo: motion closes the coalescing group" {
    var e: E = .{};
    for ("ab") |c| e.typeByte(c);
    e.move(.left, false);
    e.move(.right, false);
    for ("cd") |c| e.typeByte(c);
    try testing.expectEqual(@as(u32, 2), e.undo.n);
    _ = e.undoEdit();
    try testing.expectEqualStrings("ab", e.content());
}

test "undo log overflow drops the oldest records loudly" {
    var e = Editor(128, 64){}; // 64 bytes of history, 4 records
    for (0..10) |i| {
        e.insert("x");
        e.move(.left, false);
        e.move(.right, false);
        _ = i;
    }
    try testing.expect(e.undo.dropped > 0);
    var n: usize = 0;
    while (e.undoEdit()) n += 1;
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(usize, 6), e.len);
}

test "applyKey dispatch" {
    var e: E = .{};
    e.insert("one two");
    try testing.expect(e.applyKey(.ctrl_backspace));
    try testing.expectEqualStrings("one ", e.content());
    try testing.expect(e.applyKey(.ctrl_z));
    try testing.expectEqualStrings("one two", e.content());
    try testing.expect(e.applyKey(.ctrl_shift_z));
    try testing.expectEqualStrings("one ", e.content());
    try testing.expect(e.applyKey(.ctrl_home));
    try testing.expect(e.applyKey(.shift_end));
    try testing.expectEqualStrings("one ", e.selection());
    try testing.expect(!e.applyKey(.up));
    try testing.expect(!e.applyKey(.ctrl_c));
}

test "vertical motion keeps a sticky column; edge keys use visual lines" {
    const mono = text_mod.monoMeasurer();
    const f: FontSpec = .{};
    var e: E = .{ .multiline = true };
    e.insert("hello world\nab\nlonger line here");
    // Put the cursor at column 4 of line 0 (x = 40), move down twice.
    e.moveTo(4, false);
    e.moveVertical(1, false, f, 1000, .word, mono);
    try testing.expectEqual(@as(usize, 12 + 2), e.cursor); // clamped to end of "ab"
    e.moveVertical(1, false, f, 1000, .word, mono);
    try testing.expectEqual(@as(usize, 15 + 4), e.cursor); // sticky column 4 restored
    e.moveVertical(-1, true, f, 1000, .word, mono);
    try testing.expect(e.hasSelection());
    e.moveVertical(-5, false, f, 1000, .word, mono);
    try testing.expectEqual(@as(usize, 0), e.cursor);
    e.moveVertical(9, false, f, 1000, .word, mono);
    try testing.expectEqual(e.len, e.cursor);

    // Wrapped: "hello world" at width 60 -> "hello " / "world".
    var w: E = .{};
    w.insert("hello world");
    w.moveTo(8, false);
    w.moveLineEdge(.start, false, f, 60, .word, mono);
    try testing.expectEqual(@as(usize, 6), w.cursor);
    w.moveLineEdge(.end, false, f, 60, .word, mono);
    try testing.expectEqual(@as(usize, 11), w.cursor);
    w.moveTo(2, false);
    w.moveLineEdge(.end, true, f, 60, .word, mono);
    try testing.expectEqual(@as(usize, 5), w.cursor); // before the hanging space
    try testing.expectEqual(@as(usize, 2), w.selection_anchor.?);
}

test "inserting a combining mark keeps the cursor on a boundary" {
    var e: E = .{};
    e.insert("ex");
    e.moveTo(1, false);
    e.insert("\u{0301}x"); // merges with the cursor's left neighbour
    try expectInvariants(e);
    try testing.expectEqualStrings("e\u{0301}xx", e.content());
    var f: E = .{};
    f.insert("\u{0301}b"); // mark first
    f.moveTo(0, false);
    f.insert("a"); // 'a' + existing mark merge; cursor must not land between them
    try expectInvariants(f);
}

test "fuzz: edit scripts keep invariants; undo then redo is identity" {
    var prng = std.Random.DefaultPrng.init(0xED17);
    const rnd = prng.random();
    const pieces = [_][]const u8{
        "a",                          "bc",       " ",                  "\n",       "\t",                       "e\u{0301}",
        "\u{1F468}\u{200D}\u{1F469}",
        "שלום",
        "مرحبا",
        "日本",
        "\xFF",                       "\xE2\x82", "\u{1F1FA}\u{1F1F8}", "\u{0301}", "\u{0915}\u{094D}\u{0937}", "-",
        "word",                       "\x01",
    };
    var scratch: [64]u8 = undefined;
    var iter: usize = 0;
    while (iter < 300) : (iter += 1) {
        var e = Editor(48, 4096){ .multiline = rnd.boolean() };
        const steps = rnd.uintLessThan(usize, 40);
        for (0..steps) |_| {
            switch (rnd.uintLessThan(u8, 14)) {
                0, 1, 2 => {
                    const p = pieces[rnd.uintLessThan(usize, pieces.len)];
                    e.insert(p);
                },
                3 => e.typeByte(rnd.int(u8)),
                4 => e.backspace(),
                5 => e.delete(),
                6 => e.move(@fromBackingInt(@intCast(rnd.uintLessThan(u8, 8))), rnd.boolean()),
                7 => e.deleteWordLeft(),
                8 => e.deleteWordRight(),
                9 => e.selectAll(),
                10 => e.moveTo(rnd.uintLessThan(usize, e.len + 3), rnd.boolean()),
                11 => {
                    const n = rnd.uintLessThan(usize, scratch.len);
                    rnd.bytes(scratch[0..n]);
                    e.paste(scratch[0..n]);
                },
                12 => _ = e.undoEdit(),
                else => _ = e.redoEdit(),
            }
            try expectInvariants(e);
        }
        // Undo everything, then redo everything: content identical.
        var final_buf: [48]u8 = undefined;
        // Normalise: close redo by redoing to the end first.
        while (e.redoEdit()) {}
        @memcpy(final_buf[0..e.len], e.content());
        const final_len = e.len;
        while (e.undoEdit()) try expectInvariants(e);
        if (e.undo.dropped == 0) try testing.expectEqual(@as(usize, 0), e.len);
        while (e.redoEdit()) try expectInvariants(e);
        try testing.expectEqualStrings(final_buf[0..final_len], e.content());
    }
}

test "visual arrows: Left/Right walk a mixed line by position and always progress" {
    var e: E = .{};
    e.set("ab \u{5d0}\u{5d1}\u{5d2} cd");
    e.moveTo(0, false);
    var seen: [16]usize = undefined;
    var n: usize = 0;
    while (n < seen.len) {
        const before = e.cursor;
        e.move(.right, false);
        if (e.cursor == before) break;
        seen[n] = e.cursor;
        n += 1;
    }
    try testing.expect(n < seen.len); // terminates
    try testing.expect(n >= 6); // visits (nearly) every position
    // Left goes back the other way and also terminates.
    var m: usize = 0;
    while (m < 16) : (m += 1) {
        const before = e.cursor;
        e.move(.left, false);
        if (e.cursor == before) break;
    }
    try testing.expect(m < 16);
}
