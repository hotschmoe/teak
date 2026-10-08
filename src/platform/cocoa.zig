//! macOS host backend (Cocoa, via the Objective-C runtime). Implements the
//! `platform/host.zig` contract with AppKit objects driven through
//! `objc.zig` — libobjc and the frameworks are dlopened, so building needs
//! no macOS SDK (cross-compiling from Linux works) and there is no
//! Objective-C or Swift source: the two classes AppKit needs us to subclass
//! (`TeakView`, `TeakWindowDelegate`) are registered at run time with Zig
//! functions as their methods.
//!
//!   - window: NSWindow + a layer-backed NSView whose layer is a
//!     CAMetalLayer (`nativeHandle()` is that layer; the wgpu-native Metal
//!     surface renders into it). Sizes and pointer coordinates are logical
//!     points; `scaleFactor()` is `backingScaleFactor`.
//!   - events are pulled with `nextEventMatchingMask:` (never blocking) and
//!     dispatched to the view: mouse, precise scroll, flags, keys. Text goes
//!     through `interpretKeyEvents:` so the view's NSTextInputClient methods
//!     receive committed text and IME marked text (`imeState`). Navigation
//!     keys and Cmd chords are decoded by `cocoa_data.zig` (Cmd is the
//!     primary modifier).
//!   - clipboard: NSPasteboard (text; a PNG on the pasteboard pastes as an
//!     image drop). Dropped files: NSFilenamesPboardType.
//!   - cursors: NSCursor through cursor rects; file dialogs: NSOpenPanel /
//!     NSSavePanel.
//!
//! Host state lives in one heap `State`; AppKit callbacks reach it through an
//! ivar on the view.

const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");
const native_effects = @import("native_effects.zig");
const drops = @import("native_drops.zig");
const objc = @import("objc.zig");
const cd = @import("cocoa_data.zig");
const x11_data = @import("x11_data.zig");

const Id = objc.Id;
const Sel = objc.Sel;
const msg = objc.msg;
const sel = objc.sel;
const cls = objc.cls;

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const InputQueue = teak.InputQueue;
pub const TextMeasurer = teak.TextMeasurer;
pub const TextMetrics = teak.TextMetrics;
pub const FontSpec = teak.FontSpec;
pub const Clipboard = teak.Clipboard;
pub const ImeState = teak.ImeState;
pub const A11yNode = teak.A11yNode;
pub const FileDialogResult = teak.FileDialogResult;
pub const FileDialogFilter = teak.FileDialogFilter;
pub const FileDialogPoll = teak.FileDialogPoll;

const gpa = std.heap.page_allocator;

const NSBackingStoreBuffered: u64 = 2;
const STYLE_MASK: u64 = 1 | 2 | 4 | 8; // titled | closable | miniaturizable | resizable
const NSEventMaskAny: u64 = std.math.maxInt(u64);
const PB_STRING = "public.utf8-plain-text";
const PB_PNG = "public.png";
const PB_FILENAMES = "NSFilenamesPboardType";

const State = struct {
    app: Id,
    window: Id,
    view: Id,
    layer: Id,
    running: bool = true,
    /// Logical size in points (content view bounds) and the backing scale.
    width: u32,
    height: u32,
    scale: f32 = 1,
    first_resize: bool = true,
    resized_pending: bool = false,
    queue: InputQueue = .{},
    paste_requested: bool = false,

    // IME marked text (UTF-8) and where the caret sits in it, in bytes.
    marked: [128]u8 = undefined,
    marked_len: usize = 0,
    marked_cursor: usize = 0,
    has_marked: bool = false,
    /// Caret position handed to the input method (view coords, points).
    ime_spot: objc.CGPoint = .{},

    cursor: Id = null,
    /// Result of the last `Clipboard.read` / file dialog (host-owned).
    scratch: ?[]u8 = null,
    /// Files dropped on the window, as a `text/uri-list`, delivered by the
    /// next `pollEffectResults`.
    drop_uris: std.ArrayList(u8) = .empty,
    effects: *native_effects.Service,

    fn clearMarked(self: *State) void {
        self.has_marked = false;
        self.marked_len = 0;
        self.marked_cursor = 0;
    }

    /// Route a key event through the input system: it calls back into the
    /// view's `insertText:` / `setMarkedText:` methods.
    fn interpret(self: *State, ev: Id) void {
        const arr = msg(Id, cls("NSArray"), sel("arrayWithObject:"), .{ev});
        msg(void, self.view, sel("interpretKeyEvents:"), .{arr});
    }

    /// Append `path` to the pending drop list as a percent-encoded
    /// `file://` URI (the shared drop code decodes it again).
    fn appendUri(self: *State, path: []const u8) void {
        appendFileUri(&self.drop_uris, path);
    }
};

/// `file://` URI for `path` with everything outside the unreserved set
/// percent-encoded, plus CRLF, appended to `list`.
fn appendFileUri(list: *std.ArrayList(u8), path: []const u8) void {
    list.appendSlice(gpa, "file://") catch return;
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            list.append(gpa, c) catch return;
        } else {
            var buf: [3]u8 = undefined;
            const enc = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch return;
            list.appendSlice(gpa, enc) catch return;
        }
    }
    list.appendSlice(gpa, "\r\n") catch return;
}

// ── Class registration ─────────────────────────────────────────────

var view_class: objc.Class = null;
var delegate_class: objc.Class = null;

fn stateOf(self: Id) ?*State {
    return @ptrCast(@alignCast(objc.getState(self)));
}

fn defineClasses() void {
    if (view_class != null) return;
    const M = objc.Method;
    const view_methods = [_]M{
        .{ .name = "acceptsFirstResponder", .imp = @ptrCast(&yes), .types = "c@:" },
        .{ .name = "acceptsFirstMouse:", .imp = @ptrCast(&yes1), .types = "c@:@" },
        .{ .name = "isFlipped", .imp = @ptrCast(&yes), .types = "c@:" },
        .{ .name = "keyDown:", .imp = @ptrCast(&keyDown), .types = "v@:@" },
        .{ .name = "keyUp:", .imp = @ptrCast(&ignoreEvent), .types = "v@:@" },
        .{ .name = "flagsChanged:", .imp = @ptrCast(&flagsChanged), .types = "v@:@" },
        .{ .name = "mouseDown:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "mouseUp:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "mouseMoved:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "mouseDragged:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "rightMouseDown:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "rightMouseUp:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "rightMouseDragged:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "otherMouseDown:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "otherMouseUp:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "otherMouseDragged:", .imp = @ptrCast(&mouseEvent), .types = "v@:@" },
        .{ .name = "scrollWheel:", .imp = @ptrCast(&scrollWheel), .types = "v@:@" },
        .{ .name = "resetCursorRects", .imp = @ptrCast(&resetCursorRects), .types = "v@:" },
        // NSTextInputClient
        .{ .name = "insertText:replacementRange:", .imp = @ptrCast(&insertText), .types = "v@:@{_NSRange=QQ}" },
        .{ .name = "setMarkedText:selectedRange:replacementRange:", .imp = @ptrCast(&setMarkedText), .types = "v@:@{_NSRange=QQ}{_NSRange=QQ}" },
        .{ .name = "unmarkText", .imp = @ptrCast(&unmarkText), .types = "v@:" },
        .{ .name = "hasMarkedText", .imp = @ptrCast(&hasMarkedText), .types = "c@:" },
        .{ .name = "markedRange", .imp = @ptrCast(&markedRange), .types = "{_NSRange=QQ}@:" },
        .{ .name = "selectedRange", .imp = @ptrCast(&selectedRange), .types = "{_NSRange=QQ}@:" },
        .{ .name = "attributedSubstringForProposedRange:actualRange:", .imp = @ptrCast(&attributedSubstring), .types = "@@:{_NSRange=QQ}^{_NSRange=QQ}" },
        .{ .name = "validAttributesForMarkedText", .imp = @ptrCast(&validAttributes), .types = "@@:" },
        .{ .name = "firstRectForCharacterRange:actualRange:", .imp = @ptrCast(&firstRect), .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}" },
        .{ .name = "characterIndexForPoint:", .imp = @ptrCast(&characterIndex), .types = "Q@:{CGPoint=dd}" },
        .{ .name = "doCommandBySelector:", .imp = @ptrCast(&doCommand), .types = "v@::" },
        // Drag and drop (files)
        .{ .name = "draggingEntered:", .imp = @ptrCast(&draggingEntered), .types = "Q@:@" },
        .{ .name = "prepareForDragOperation:", .imp = @ptrCast(&yes1), .types = "c@:@" },
        .{ .name = "performDragOperation:", .imp = @ptrCast(&performDrag), .types = "c@:@" },
    };
    view_class = objc.defineClass("TeakView", "NSView", &view_methods, &.{"NSTextInputClient"});
    const delegate_methods = [_]M{
        .{ .name = "windowShouldClose:", .imp = @ptrCast(&windowShouldClose), .types = "c@:@" },
    };
    delegate_class = objc.defineClass("TeakWindowDelegate", "NSObject", &delegate_methods, &.{});
}

// ── View methods ───────────────────────────────────────────────────

fn yes(_: Id, _: Sel) callconv(.c) bool {
    return true;
}
fn yes1(_: Id, _: Sel, _: Id) callconv(.c) bool {
    return true;
}
fn ignoreEvent(_: Id, _: Sel, _: Id) callconv(.c) void {}

fn windowShouldClose(self: Id, _: Sel, _: Id) callconv(.c) bool {
    if (stateOf(self)) |s| s.running = false;
    return false; // we tear the window down ourselves in `deinit`
}

fn eventFlags(ev: Id) u64 {
    return msg(u64, ev, sel("modifierFlags"), .{});
}

fn flagsChanged(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const s = stateOf(self) orelse return;
    s.queue.mods = cd.modsFromFlags(eventFlags(ev));
}

fn keyDown(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const s = stateOf(self) orelse return;
    const flags = eventFlags(ev);
    s.queue.mods = cd.modsFromFlags(flags);
    if (s.has_marked) return s.interpret(ev); // a composition owns the keys
    const code = msg(u16, ev, sel("keyCode"), .{});
    const chars = objc.utf8Of(msg(Id, ev, sel("charactersIgnoringModifiers"), .{}));
    const ch: u8 = if (chars.len > 0 and chars[0] < 0x80) std.ascii.toLower(chars[0]) else 0;
    const d = cd.decodeKey(code, flags, ch);
    if (d.quit) {
        s.running = false;
        return;
    }
    if (d.special) |sk| {
        s.queue.pushKey(sk);
        if (d.paste) s.paste_requested = true;
        return;
    }
    // Other Cmd / Ctrl chords are not text.
    if (flags & (cd.FLAG_COMMAND | cd.FLAG_CONTROL) != 0) return;
    s.interpret(ev);
}

fn mouseEvent(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const s = stateOf(self) orelse return;
    const q = &s.queue;
    q.mods = cd.modsFromFlags(eventFlags(ev));
    const in_window = msg(objc.CGPoint, ev, sel("locationInWindow"), .{});
    const p = msg(objc.CGPoint, s.view, sel("convertPoint:fromView:"), .{ in_window, @as(Id, null) });
    q.pointerMoved(@floatCast(p.x), @floatCast(p.y));
    switch (msg(u64, ev, sel("type"), .{})) {
        1 => q.buttonDown(.left),
        2 => q.buttonUp(.left),
        3 => q.buttonDown(.right),
        4 => q.buttonUp(.right),
        25 => if (otherButton(ev)) |b| q.buttonDown(b),
        26 => if (otherButton(ev)) |b| q.buttonUp(b),
        else => {}, // moved / dragged: position only
    }
}

fn otherButton(ev: Id) ?teak.Button {
    return switch (msg(i64, ev, sel("buttonNumber"), .{})) {
        2 => .middle,
        else => null,
    };
}

fn scrollWheel(self: Id, _: Sel, ev: Id) callconv(.c) void {
    const s = stateOf(self) orelse return;
    const precise = msg(bool, ev, sel("hasPreciseScrollingDeltas"), .{});
    const d = cd.scrollDelta(
        msg(f64, ev, sel("scrollingDeltaX"), .{}),
        msg(f64, ev, sel("scrollingDeltaY"), .{}),
        precise,
    );
    s.queue.mods = cd.modsFromFlags(eventFlags(ev));
    s.queue.wheel(d.x, d.y);
}

fn resetCursorRects(self: Id, _: Sel) callconv(.c) void {
    const s = stateOf(self) orelse return;
    if (s.cursor == null) return;
    msg(void, self, sel("addCursorRect:cursor:"), .{ msg(objc.CGRect, self, sel("bounds"), .{}), s.cursor });
}

// NSTextInputClient

/// The text of an `insertText:` / `setMarkedText:` argument, which is an
/// NSString or an NSAttributedString.
fn stringArg(obj: Id) []const u8 {
    if (obj == null) return "";
    const is_attr = msg(bool, obj, sel("isKindOfClass:"), .{cls("NSAttributedString")});
    return objc.utf8Of(if (is_attr) msg(Id, obj, sel("string"), .{}) else obj);
}

fn insertText(self: Id, _: Sel, str: Id, _: objc.NSRange) callconv(.c) void {
    const s = stateOf(self) orelse return;
    s.clearMarked();
    const t = stringArg(str);
    if (!std.unicode.utf8ValidateSlice(t)) return;
    var it = std.unicode.Utf8View.initUnchecked(t).iterator();
    while (it.nextCodepoint()) |cp| s.queue.pushCodepoint(cp);
}

fn setMarkedText(self: Id, _: Sel, str: Id, selected: objc.NSRange, _: objc.NSRange) callconv(.c) void {
    const s = stateOf(self) orelse return;
    const t = stringArg(str);
    if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) return s.clearMarked();
    var n = @min(t.len, s.marked.len);
    // Never cut a code point in half.
    while (n > 0 and n < t.len and (t[n] & 0xC0) == 0x80) n -= 1;
    s.marked_len = n;
    @memcpy(s.marked[0..n], t[0..n]);
    s.marked_cursor = cd.utf16IndexToByte(s.marked[0..n], @intCast(@min(selected.location, std.math.maxInt(u32))));
    s.has_marked = true;
}

fn unmarkText(self: Id, _: Sel) callconv(.c) void {
    if (stateOf(self)) |s| s.clearMarked();
}

fn hasMarkedText(self: Id, _: Sel) callconv(.c) bool {
    return if (stateOf(self)) |s| s.has_marked else false;
}

fn markedRange(self: Id, _: Sel) callconv(.c) objc.NSRange {
    const s = stateOf(self) orelse return .{ .location = objc.NSNotFound, .length = 0 };
    if (!s.has_marked) return .{ .location = objc.NSNotFound, .length = 0 };
    return .{ .location = 0, .length = cd.utf16Len(s.marked[0..s.marked_len]) };
}

fn selectedRange(self: Id, _: Sel) callconv(.c) objc.NSRange {
    const s = stateOf(self) orelse return .{ .location = objc.NSNotFound, .length = 0 };
    return .{ .location = if (s.has_marked) cd.utf16Len(s.marked[0..s.marked_cursor]) else 0, .length = 0 };
}

fn attributedSubstring(_: Id, _: Sel, _: objc.NSRange, _: ?*objc.NSRange) callconv(.c) Id {
    return null;
}

fn validAttributes(_: Id, _: Sel) callconv(.c) Id {
    return msg(Id, cls("NSArray"), sel("array"), .{});
}

/// Where the candidate window goes: a small rect at `setImeSpot`, in screen
/// coordinates.
fn firstRect(self: Id, _: Sel, _: objc.NSRange, _: ?*objc.NSRange) callconv(.c) objc.CGRect {
    const s = stateOf(self) orelse return .{};
    const r = objc.CGRect{ .origin = s.ime_spot, .size = .{ .w = 1, .h = 16 } };
    const in_window = msg(objc.CGRect, s.view, sel("convertRect:toView:"), .{ r, @as(Id, null) });
    return msg(objc.CGRect, s.window, sel("convertRectToScreen:"), .{in_window});
}

fn characterIndex(_: Id, _: Sel, _: objc.CGPoint) callconv(.c) u64 {
    return objc.NSNotFound;
}

fn doCommand(_: Id, _: Sel, _: Sel) callconv(.c) void {}

// Drag and drop

fn draggingEntered(_: Id, _: Sel, _: Id) callconv(.c) u64 {
    return 1; // NSDragOperationCopy
}

fn performDrag(self: Id, _: Sel, info: Id) callconv(.c) bool {
    const s = stateOf(self) orelse return false;
    const pb = msg(Id, info, sel("draggingPasteboard"), .{});
    const list = msg(Id, pb, sel("propertyListForType:"), .{objc.nsString(PB_FILENAMES)});
    if (list == null) return false;
    const n = msg(u64, list, sel("count"), .{});
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        s.appendUri(objc.utf8Of(msg(Id, list, sel("objectAtIndex:"), .{i})));
    }
    return n > 0;
}

// ── Helpers ────────────────────────────────────────────────────────

fn monotonicMs() u64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds, std.time.ns_per_ms));
}

/// Replace a heap slice owned by the host with a copy of `bytes`.
fn keepCopy(slot: *?[]u8, bytes: []const u8) []const u8 {
    if (slot.*) |old| gpa.free(old);
    slot.* = gpa.dupe(u8, bytes) catch null;
    return slot.* orelse "";
}

/// An autoreleased NSString from arbitrary (not NUL-terminated) bytes.
fn nsStringFrom(bytes: []const u8) Id {
    const z = gpa.allocSentinel(u8, bytes.len, 0) catch return null;
    defer gpa.free(z);
    @memcpy(z, bytes);
    return objc.nsString(z.ptr);
}

pub const Host = struct {
    st: *State,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        try objc.load();
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        defineClasses();

        const app = msg(Id, cls("NSApplication"), sel("sharedApplication"), .{});
        _ = msg(bool, app, sel("setActivationPolicy:"), .{@as(i64, 0)}); // regular app

        const effects = try native_effects.Service.create(title);
        errdefer effects.destroy();
        const s = try gpa.create(State);
        errdefer gpa.destroy(s);

        const frame = objc.CGRect{ .origin = .{ .x = 200, .y = 200 }, .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) } };
        const window = msg(Id, msg(Id, cls("NSWindow"), sel("alloc"), .{}), sel("initWithContentRect:styleMask:backing:defer:"), .{ frame, STYLE_MASK, NSBackingStoreBuffered, false });
        if (window == null) return error.CocoaWindowFailed;
        msg(void, window, sel("setReleasedWhenClosed:"), .{false});
        const view = msg(Id, msg(Id, view_class, sel("alloc"), .{}), sel("initWithFrame:"), .{frame});
        const layer = msg(Id, cls("CAMetalLayer"), sel("layer"), .{});
        const delegate = objc.allocInit(delegate_class);
        s.* = .{ .app = app, .window = window, .view = view, .layer = layer, .width = width, .height = height, .effects = effects };
        objc.setState(view, s);
        objc.setState(delegate, s);

        msg(void, view, sel("setLayer:"), .{layer});
        msg(void, view, sel("setWantsLayer:"), .{true});
        msg(void, window, sel("setContentView:"), .{view});
        msg(void, window, sel("setDelegate:"), .{delegate});
        msg(void, window, sel("setAcceptsMouseMovedEvents:"), .{true});
        msg(void, window, sel("setTitle:"), .{nsStringFrom(title)});
        _ = msg(bool, window, sel("makeFirstResponder:"), .{view});
        msg(void, view, sel("registerForDraggedTypes:"), .{msg(Id, cls("NSArray"), sel("arrayWithObject:"), .{objc.nsString(PB_FILENAMES)})});
        msg(void, window, sel("center"), .{});
        msg(void, window, sel("makeKeyAndOrderFront:"), .{@as(Id, null)});
        msg(void, app, sel("activateIgnoringOtherApps:"), .{true});
        msg(void, app, sel("finishLaunching"), .{});

        var host: Host = .{ .st = s };
        host.syncGeometry();
        s.first_resize = true;
        return host;
    }

    pub fn deinit(self: *Host) void {
        const s = self.st;
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        text.releaseFaces();
        msg(void, s.window, sel("close"), .{});
        s.effects.destroy();
        s.drop_uris.deinit(gpa);
        if (s.scratch) |b| gpa.free(b);
        gpa.destroy(s);
    }

    /// Re-read the view size and backing scale; flag a resize on change and
    /// keep the CAMetalLayer's `contentsScale` in step.
    fn syncGeometry(self: *Host) void {
        const s = self.st;
        const b = msg(objc.CGRect, s.view, sel("bounds"), .{});
        const scale: f32 = @floatCast(msg(f64, s.window, sel("backingScaleFactor"), .{}));
        const w: u32 = @max(1, @as(u32, @intFromFloat(@round(@max(b.size.w, 0)))));
        const h: u32 = @max(1, @as(u32, @intFromFloat(@round(@max(b.size.h, 0)))));
        if (w != s.width or h != s.height or scale != s.scale) {
            s.width = w;
            s.height = h;
            if (scale != s.scale) {
                s.scale = scale;
                msg(void, s.layer, sel("setContentsScale:"), .{@as(f64, scale)});
            }
            s.resized_pending = true;
        }
    }

    pub fn pollInputs(self: *Host) InputState {
        const s = self.st;
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        s.queue.beginFrame();
        s.paste_requested = false;
        // Dispatch everything queued without waiting.
        const mode = objc.nsString("kCFRunLoopDefaultMode");
        while (true) {
            const ev = msg(Id, s.app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), .{ NSEventMaskAny, @as(Id, null), mode, true });
            if (ev == null) break;
            msg(void, s.app, sel("sendEvent:"), .{ev});
        }
        msg(void, s.app, sel("updateWindows"), .{});
        self.syncGeometry();
        const resized = s.resized_pending or s.first_resize;
        s.first_resize = false;
        s.resized_pending = false;
        return s.queue.finish(resized, s.width, s.height);
    }

    pub fn shouldClose(self: *const Host) bool {
        return !self.st.running;
    }

    /// The CAMetalLayer the wgpu Metal surface renders into.
    pub const NativeHandle = struct { layer: *anyopaque };

    pub fn nativeHandle(self: *const Host) NativeHandle {
        return .{ .layer = self.st.layer.? };
    }

    pub fn setTitle(self: *Host, title: []const u8) void {
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        msg(void, self.st.window, sel("setTitle:"), .{nsStringFrom(title)});
    }

    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = stbMeasure };
    }

    fn stbMeasure(_: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        return text.measure(text_bytes, font);
    }

    // ── Effects ─────────────────────────────────────────────────────

    pub fn submit(self: *Host, e: teak.Effect) teak.EffectSubmit {
        switch (e) {
            .write_clipboard => |w| {
                writePasteboard(w.text);
                return .accepted;
            },
            else => return self.st.effects.submit(e),
        }
    }

    pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize {
        const s = self.st;
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        // Cmd+V that `Clipboard.read` did not claim: text, else a PNG.
        if (s.paste_requested) {
            s.paste_requested = false;
            const pb = msg(Id, cls("NSPasteboard"), sel("generalPasteboard"), .{});
            const t = objc.utf8Of(msg(Id, pb, sel("stringForType:"), .{objc.nsString(PB_STRING)}));
            if (t.len > 0) {
                drops.pastedText(s.effects, t);
            } else {
                const data = msg(Id, pb, sel("dataForType:"), .{objc.nsString(PB_PNG)});
                if (data != null) {
                    const len = msg(u64, data, sel("length"), .{});
                    if (msg(?[*]const u8, data, sel("bytes"), .{})) |p| drops.pastedImage(s.effects, p[0..len]);
                }
            }
        }
        if (s.drop_uris.items.len > 0) {
            drops.droppedFiles(s.effects, s.drop_uris.items);
            s.drop_uris.clearRetainingCapacity();
        }
        return s.effects.poll(buf, monotonicMs());
    }

    pub fn setAppName(self: *Host, name: []const u8) void {
        self.st.effects.setAppName(name) catch {};
    }

    pub fn registerFont(_: *Host, family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) !void {
        try text.registerFace(family, weight, ttf);
    }

    // ── Clipboard ───────────────────────────────────────────────────

    pub fn clipboard(self: *Host) Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipRead, .write_fn = clipWrite };
    }

    fn clipRead(ctx: *anyopaque) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const s = self.st;
        s.paste_requested = false; // claimed by the app's own paste
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        const pb = msg(Id, cls("NSPasteboard"), sel("generalPasteboard"), .{});
        return keepCopy(&s.scratch, objc.utf8Of(msg(Id, pb, sel("stringForType:"), .{objc.nsString(PB_STRING)})));
    }

    fn clipWrite(_: *anyopaque, txt: []const u8) void {
        writePasteboard(txt);
    }

    fn writePasteboard(txt: []const u8) void {
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        const pb = msg(Id, cls("NSPasteboard"), sel("generalPasteboard"), .{});
        _ = msg(i64, pb, sel("clearContents"), .{});
        _ = msg(bool, pb, sel("setString:forType:"), .{ nsStringFrom(txt), objc.nsString(PB_STRING) });
    }

    // ── IME ─────────────────────────────────────────────────────────

    pub fn imeState(self: *const Host) ImeState {
        const s = self.st;
        if (!s.has_marked) return .{};
        return .{ .active = true, .text = s.marked[0..s.marked_len], .cursor = s.marked_cursor };
    }

    /// Where the input method puts its candidate window: the caret in
    /// window-relative logical points.
    pub fn setImeSpot(self: *Host, x: i32, y: i32) void {
        self.st.ime_spot = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    }

    // ── Cursor ──────────────────────────────────────────────────────

    pub fn setCursor(self: *Host, shape: teak.CursorShape) void {
        const s = self.st;
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        const names = cd.cursorSel(shape);
        const NSCursor = cls("NSCursor");
        var c: Id = null;
        if (names.private.len > 0 and msg(bool, NSCursor, sel("respondsToSelector:"), .{sel(names.private)})) {
            c = msg(Id, NSCursor, sel(names.private), .{});
        }
        if (c == null) c = msg(Id, NSCursor, sel(names.public), .{});
        s.cursor = c;
        msg(void, s.window, sel("invalidateCursorRectsForView:"), .{s.view});
        if (c != null) msg(void, c, sel("set"), .{});
    }

    // ── File dialogs (modal NSOpenPanel / NSSavePanel) ──────────────

    pub fn openFileDialog(self: *Host, _: FileDialogFilter) FileDialogResult {
        return self.runPanel(cls("NSOpenPanel"), sel("openPanel"));
    }

    pub fn saveFileDialog(self: *Host, _: FileDialogFilter) FileDialogResult {
        return self.runPanel(cls("NSSavePanel"), sel("savePanel"));
    }

    fn runPanel(self: *Host, class: Id, ctor: Sel) FileDialogResult {
        const pool = objc.poolPush();
        defer objc.poolPop(pool);
        const panel = msg(Id, class, ctor, .{});
        if (msg(i64, panel, sel("runModal"), .{}) != 1) return null; // NSModalResponseOK
        const path = objc.utf8Of(msg(Id, msg(Id, panel, sel("URL"), .{}), sel("path"), .{}));
        if (path.len == 0) return null;
        return keepCopy(&self.st.scratch, path);
    }

    pub fn requestFileDialog(_: *Host, _: FileDialogFilter) u32 {
        return 0;
    }

    pub fn requestSaveFileDialog(_: *Host, _: FileDialogFilter) u32 {
        return 0;
    }

    pub fn pollFileDialogResult(_: *Host, _: u32) FileDialogPoll {
        return .{ .pending = {} };
    }

    pub fn publishA11yTree(_: *Host, _: []const A11yNode) void {}

    pub fn openSecondaryWindow(_: *Host, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }

    pub fn pollSecondaryInputs(_: *Host, _: u32) ?InputState {
        return null;
    }

    pub fn closeSecondaryWindow(_: *Host, _: u32) void {}

    pub fn secondaryWindowHandle(_: *const Host, _: u32) ?NativeHandle {
        return null;
    }

    pub fn nowMs(_: *const Host) u64 {
        return monotonicMs();
    }

    /// Device pixels per point (`backingScaleFactor`): 2.0 on Retina. Pass it
    /// as `InitOptions.scale` when creating the Gpu.
    pub fn scaleFactor(self: *const Host) f32 {
        return self.st.scale;
    }
};

comptime {
    teak.validateHost(Host);
}

test "uri encoding of dropped paths round-trips through the shared decoder" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    appendFileUri(&list, "/Users/me/My File #1.txt");
    try std.testing.expectEqualStrings("file:///Users/me/My%20File%20%231.txt\r\n", list.items);
    var buf: [128]u8 = undefined;
    var it = x11_data.UriIter{ .rest = list.items };
    try std.testing.expectEqualStrings("/Users/me/My File #1.txt", x11_data.uriToPath(it.next().?, &buf).?);
}
