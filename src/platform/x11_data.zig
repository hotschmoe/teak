//! Pure, display-free helpers for the X11 host's clipboard / drag-and-drop /
//! input-method support. Everything here is plain data + arithmetic so it
//! unit-tests under `zig build test` with no X server:
//!
//!   - `uriToPath` / `UriIter`: `text/uri-list` parsing for XDND drops.
//!   - `pngSize`: width/height from a PNG IHDR (pasted/dropped images).
//!   - `Preedit`: the on-the-spot IME composition state machine driven by the
//!     `XIMPreedit*` callbacks.
//!   - `clipboardTargets`: which selection target the host asks for.

const std = @import("std");


/// Iterates the URIs of a `text/uri-list` payload (RFC 2483): one per line,
/// `#` lines are comments, blank lines are skipped.
pub const UriIter = struct {
    rest: []const u8,

    pub fn next(self: *UriIter) ?[]const u8 {
        while (self.rest.len > 0) {
            const nl = std.mem.indexOfAny(u8, self.rest, "\r\n") orelse self.rest.len;
            const line = self.rest[0..nl];
            self.rest = self.rest[@min(nl + 1, self.rest.len)..];
            if (line.len == 0 or line[0] == '#') continue;
            return line;
        }
        return null;
    }
};

/// Decode a `file://` URI into a filesystem path (percent-decoded) written
/// to `buf`. Accepts an empty authority or `localhost`; any other host (a
/// remote file) and non-`file` schemes yield null.
pub fn uriToPath(uri: []const u8, buf: []u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, prefix)) return null;
    var rest = uri[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
    rest = rest[slash..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (n >= buf.len) return null;
        if (rest[i] == '%') {
            if (i + 2 >= rest.len) return null;
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch return null;
            buf[n] = hi * 16 + lo;
            i += 2;
        } else {
            buf[n] = rest[i];
        }
        n += 1;
    }
    if (n == 0 or std.mem.indexOfScalar(u8, buf[0..n], 0) != null) return null;
    return buf[0..n];
}


pub const ImageSize = struct { w: u32, h: u32 };

/// Pixel size from a PNG's IHDR chunk, or null when `bytes` is not a PNG.
pub fn pngSize(bytes: []const u8) ?ImageSize {
    const sig = "\x89PNG\r\n\x1a\n";
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], sig)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}


/// Pick what to fetch from a `TARGETS` list: text wins over an image (a
/// copied web selection often offers both). Returns an index into the
/// preference table below, `null` when nothing usable is offered.
pub const Want = enum { utf8, string, png };

pub fn chooseTarget(has_utf8: bool, has_string: bool, has_png: bool) ?Want {
    if (has_utf8) return .utf8;
    if (has_string) return .string;
    if (has_png) return .png;
    return null;
}

/// Latin-1 (`STRING` target) to UTF-8, into `out`; returns the used slice
/// (truncated at capacity).
pub fn latin1ToUtf8(src: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (src) |b| {
        if (b < 0x80) {
            if (n + 1 > out.len) break;
            out[n] = b;
            n += 1;
        } else {
            if (n + 2 > out.len) break;
            out[n] = 0xC0 | (b >> 6);
            out[n + 1] = 0x80 | (b & 0x3F);
            n += 2;
        }
    }
    return out[0..n];
}


/// On-the-spot composition buffer, edited by `XIMPreeditDrawCallback`. The
/// X protocol addresses the buffer in *characters* (`chg_first`,
/// `chg_length`, `caret`), so we hold code points and render UTF-8 on demand.
pub const Preedit = struct {
    pub const CAP = 64;
    /// Max UTF-8 bytes `toUtf8` yields; matches the runtime's 128-byte IME copy.
    pub const MAX_BYTES = 127;

    cps: [CAP]u21 = undefined,
    len: usize = 0,
    /// Caret as a character index (0..len).
    caret: usize = 0,
    active: bool = false,
    /// Rendered text. Stable storage that `ImeState.text` aliases.
    out: [MAX_BYTES + 1]u8 = undefined,
    out_len: usize = 0,
    out_caret: usize = 0,

    pub fn start(self: *Preedit) void {
        self.len = 0;
        self.caret = 0;
        self.active = true;
        self.render();
    }

    pub fn done(self: *Preedit) void {
        self.len = 0;
        self.caret = 0;
        self.active = false;
        self.render();
    }

    /// Apply a draw callback: replace `chg_length` characters at `chg_first`
    /// with `new`, then move the caret. Out-of-range edits clamp rather than
    /// fail (a misbehaving IM must not corrupt memory).
    pub fn draw(self: *Preedit, chg_first: usize, chg_length: usize, new: []const u21, caret: usize) void {
        self.active = true;
        const first = @min(chg_first, self.len);
        const end = @min(first + chg_length, self.len);
        const tail_len = self.len - end;
        const room = CAP - first;
        const take = @min(new.len, room);
        const keep_tail = @min(tail_len, room - take);
        // Shift the tail first (it may move left or right), then drop the new
        // characters into the gap.
        @memmove(self.cps[first + take ..][0..keep_tail], self.cps[end..][0..keep_tail]);
        @memcpy(self.cps[first..][0..take], new[0..take]);
        self.len = first + take + keep_tail;
        self.caret = @min(caret, self.len);
        self.render();
    }

    /// `XIMPreeditCaretCallback` (absolute move; relative styles are rare and
    /// treated as absolute).
    pub fn moveCaret(self: *Preedit, pos: usize) void {
        self.caret = @min(pos, self.len);
        self.render();
    }

    pub fn text(self: *const Preedit) []const u8 {
        return self.out[0..self.out_len];
    }

    fn render(self: *Preedit) void {
        var n: usize = 0;
        var caret_bytes: usize = 0;
        for (self.cps[0..self.len], 0..) |cp, i| {
            if (i == self.caret) caret_bytes = n;
            var tmp: [4]u8 = undefined;
            const k = std.unicode.utf8Encode(cp, &tmp) catch continue;
            if (n + k > MAX_BYTES) break;
            @memcpy(self.out[n..][0..k], tmp[0..k]);
            n += k;
        }
        if (self.caret >= self.len) caret_bytes = n;
        self.out_len = n;
        self.out_caret = @min(caret_bytes, n);
    }
};

/// Decode `bytes` (UTF-8, lenient: invalid bytes become U+FFFD... skipped) to
/// code points in `out`; returns the count.
pub fn decodeUtf8Lossy(bytes: []const u8, out: []u21) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and n < out.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i..][0..len]) catch {
            i += 1;
            continue;
        };
        out[n] = cp;
        n += 1;
        i += len;
    }
    return n;
}


pub const XIMPreeditArea: c_ulong = 0x0001;
pub const XIMPreeditCallbacks: c_ulong = 0x0002;
pub const XIMPreeditPosition: c_ulong = 0x0004;
pub const XIMPreeditNothing: c_ulong = 0x0008;
pub const XIMPreeditNone: c_ulong = 0x0010;
pub const XIMStatusCallbacks: c_ulong = 0x0100;
pub const XIMStatusNothing: c_ulong = 0x0400;
pub const XIMStatusNone: c_ulong = 0x0800;

pub const ImeMode = enum {
    /// Preedit delivered through callbacks; we draw it (on-the-spot).
    callbacks,
    /// The IM draws the preedit near `XNSpotLocation` (over-the-spot).
    position,
    /// The IM draws everything in its own window (root-window style).
    nothing,
};

pub const ImeChoice = struct { style: c_ulong, mode: ImeMode };

/// Pick the best input style the IM offers, in order: on-the-spot
/// (callbacks), over-the-spot (position), root window (nothing). Status is
/// never ours to draw, so only `StatusNothing` / `StatusNone` qualify.
pub fn chooseImStyle(supported: []const c_ulong) ?ImeChoice {
    const status_ok = [_]c_ulong{ XIMStatusNothing, XIMStatusNone };
    const prefs = [_]struct { preedit: c_ulong, mode: ImeMode }{
        .{ .preedit = XIMPreeditCallbacks, .mode = .callbacks },
        .{ .preedit = XIMPreeditPosition, .mode = .position },
        .{ .preedit = XIMPreeditNothing, .mode = .nothing },
    };
    for (prefs) |pref| {
        for (status_ok) |st| {
            const want = pref.preedit | st;
            for (supported) |have| if (have == want) return .{ .style = want, .mode = pref.mode };
        }
    }
    return null;
}

/// UTF-8 to Latin-1 for the `STRING` selection target; code points above
/// U+00FF become '?'. Returns the number of bytes written.
pub fn utf8ToLatin1(src: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < out.len) {
        const len = std.unicode.utf8ByteSequenceLength(src[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > src.len) break;
        const cp = std.unicode.utf8Decode(src[i..][0..len]) catch {
            i += 1;
            continue;
        };
        out[n] = if (cp <= 0xFF) @intCast(cp) else '?';
        n += 1;
        i += len;
    }
    return n;
}











