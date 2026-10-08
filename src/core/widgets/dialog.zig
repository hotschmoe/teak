//! Modal dialog helper: a centred card over a dimmed window with a title,
//! a message (or app content) and Cancel / Confirm buttons.
//!
//! Built from the modal-overlay pattern the Dropdown uses plus `Msg`-carrying
//! buttons; zero new Cmd variants. The open flag is the app's own `bool` (or
//! enum) in its Model; the dialog is just "view while open":
//!
//! ```zig
//! if (m.confirm_delete) Dialog.view(cb, .{ .window_w = m.w, .window_h = m.h,
//!     .title = "Delete file?", .message = "This cannot be undone.",
//!     .confirm_label = "Delete", .danger = true }, .{ .confirm = .do_delete, .cancel = .cancel_delete });
//! // keys, from keySpecialMsg while open:
//! if (m.confirm_delete) return Dialog.keyMsg(key, .{ .confirm = .do_delete, .cancel = .cancel_delete }, true);
//! ```
//!
//! Focus trap: the dialog is a *modal* overlay, so the hit-test pass sends
//! every click outside the card to its backdrop (which cancels) instead of
//! the widgets behind it, and `teak.run`'s Tab traversal stays inside a
//! modal overlay (`focus.nextFocusable`). Enter confirms, Escape cancels.
//! For content beyond a message, use `begin` / `end` around your own cmds.

const std = @import("std");
const cmd = @import("../cmd.zig");
const keys = @import("../../input/keys.zig");

pub const Opts = struct {
    window_w: f32,
    window_h: f32,
    title: []const u8,
    /// A single-line message; use `begin` / `end` for richer content.
    message: []const u8 = "",
    confirm_label: []const u8 = "OK",
    /// Null = a one-button (acknowledge) dialog.
    cancel_label: ?[]const u8 = "Cancel",
    /// Card width.
    width: f32 = 380,
    /// Draw the confirm button in the danger colour.
    danger: bool = false,
    /// A click on the dimmed backdrop cancels (confirms, for a one-button dialog).
    dismiss_on_backdrop: bool = true,
    /// Backdrop dim colour.
    scrim: [4]f32 = .{ 0, 0, 0, 0.55 },
};

/// A complete message dialog. `msgs` is `.{ .confirm = AppMsg, .cancel = AppMsg }`.
pub fn view(cb: anytype, o: Opts, msgs: anytype) void {
    begin(cb, o, msgs);
    if (o.message.len > 0) cb.text(o.message);
    end(cb, o, msgs);
}

/// Open the dialog: the dim backdrop, the card, the title. Emit the body next.
pub fn begin(cb: anytype, o: Opts, msgs: anytype) void {
    const pal = cb.theme.palette;
    const dismiss = if (o.cancel_label != null) msgs.cancel else msgs.confirm;
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = o.window_w,
        .height = o.window_h,
        .padding = 0,
        .gap = 0,
        .backdrop = o.scrim,
        .modal = true,
        .backdrop_msg = if (o.dismiss_on_backdrop) dismiss else null,
        .align_cross = .center,
    });
    cb.spacer(1);
    cb.pushGroup(.{
        .direction = .vertical,
        .padding = 18,
        .gap = 12,
        .width = o.width,
        .bg = pal.bg_panel,
        .border = pal.fg_muted,
        .align_cross = .stretch,
    });
    cb.heading(o.title);
}

/// Close the dialog: the button row, the card, the backdrop.
pub fn end(cb: anytype, o: Opts, msgs: anytype) void {
    const pal = cb.theme.palette;
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .justify = .end });
    if (o.cancel_label) |label| cb.button(msgs.cancel, label);
    var st = cb.theme.button;
    if (o.danger) {
        st.bg = pal.danger;
        st.hover_bg = pal.danger;
        st.fg = pal.bg;
        st.hover_fg = pal.bg;
    }
    cb.buttonStyled(msgs.confirm, o.confirm_label, st);
    cb.popGroup();
    cb.popGroup(); // card
    cb.spacer(1);
    cb.popOverlay();
}

/// Enter confirms; Escape cancels (confirms, when `has_cancel` is false).
pub fn keyMsg(key: keys.SpecialKey, msgs: anytype, has_cancel: bool) ?@TypeOf(msgs.confirm) {
    return switch (key) {
        .enter => msgs.confirm,
        .escape => if (has_cancel) msgs.cancel else msgs.confirm,
        else => null,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text_mod = @import("../text.zig");
const focus = @import("../../input/focus.zig");
const hit_test = @import("../../input/hit_test.zig");

const TMsg = union(enum) { ok, cancel, behind, field };
const dmsgs = .{ .confirm = TMsg.ok, .cancel = TMsg.cancel };
const dopts: Opts = .{ .window_w = 600, .window_h = 400, .title = "Delete file?", .message = "This cannot be undone.", .confirm_label = "Delete" };

fn layoutFor(cb: anytype, rects: []engine.Rect) []const engine.Rect {
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 600, 400, text_mod.monoMeasurer());
    return rects[0..n];
}

test "dialog: Enter confirms, Escape cancels (or confirms when there is no cancel)" {
    try testing.expectEqual(TMsg.ok, keyMsg(.enter, dmsgs, true).?);
    try testing.expectEqual(TMsg.cancel, keyMsg(.escape, dmsgs, true).?);
    try testing.expectEqual(TMsg.ok, keyMsg(.escape, dmsgs, false).?);
    try testing.expect(keyMsg(.tab, dmsgs, true) == null);
}

test "dialog: the card is centred and both buttons carry the app's Msgs" {
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.button(.behind, "Behind");
    cb.popGroup();
    view(&cb, dopts, dmsgs);
    var rects: [32]engine.Rect = undefined;
    const r = layoutFor(&cb, &rects);
    try testing.expect(cmd.validateBalance(cb.cmds.items) == null);

    // Find the card (the sized group) and check it is centred in the window.
    for (cb.cmds.items, 0..) |c, i| switch (c) {
        .push_group => |g| if (g.width == 380) {
            try testing.expectApproxEqAbs(@as(f32, 300), r[i].x + r[i].w / 2, 1);
            try testing.expectApproxEqAbs(@as(f32, 200), r[i].y + r[i].h / 2, 1);
        },
        else => {},
    };
    // Clicking the buttons behind the dialog is impossible: the backdrop wins.
    const behind = hit_test.hitTest(cb.cmds.items, r, 10, 10).?;
    try testing.expectEqual(TMsg.cancel, behind.msg.?);
}

test "dialog: a one-button dialog confirms on backdrop click; opt-out keeps it modal without a Msg" {
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    var o = dopts;
    o.cancel_label = null;
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.popGroup();
    view(&cb, o, dmsgs);
    var rects: [32]engine.Rect = undefined;
    const r = layoutFor(&cb, &rects);
    try testing.expectEqual(TMsg.ok, hit_test.hitTest(cb.cmds.items, r, 5, 5).?.msg.?);

    cb.reset();
    o.dismiss_on_backdrop = false;
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.popGroup();
    view(&cb, o, dmsgs);
    const r2 = layoutFor(&cb, &rects);
    const hit = hit_test.hitTest(cb.cmds.items, r2, 5, 5).?;
    try testing.expect(hit.msg == null); // consumed, but nothing dispatched
}

test "dialog: Tab traversal is trapped inside the dialog" {
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textInput(.field, "", 0); // idx 1: behind the dialog
    cb.popGroup();
    begin(&cb, dopts, dmsgs);
    cb.textInput(.field, "", 0); // a field inside the dialog
    end(&cb, dopts, dmsgs);
    var inside: ?usize = null;
    for (cb.cmds.items, 0..) |c, i| if (c == .text_input and i > 3) {
        inside = i;
    };
    try testing.expectEqual(inside, focus.nextFocusable(cb.cmds.items, 1));
    try testing.expectEqual(inside, focus.prevFocusable(cb.cmds.items, 1));
}

test "dialog: snapshot golden" {
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.button(.behind, "Behind");
    cb.popGroup();
    var o = dopts;
    o.danger = true;
    view(&cb, o, dmsgs);
    var rects: [32]engine.Rect = undefined;
    const r = layoutFor(&cb, &rects);
    try snapshot.expectSnapshot(cb.cmds.items, r, .{},
        \\group (0,0,600,400) vertical
        \\  button (0,0,76,36) "Behind"
        \\overlay (0,0,600,400) layer=1 [modal]
        \\  group (300,0,0,132) vertical
        \\  group (110,132,380,136) vertical bg border
        \\    text (128,150,344,20) "Delete file?"
        \\    text (128,182,344,20) "This cannot be undone."
        \\    group (128,214,344,36) horizontal
        \\      button (312,214,76,36) "Cancel"
        \\      button (396,214,76,36) "Delete"
        \\  group (300,268,0,132) vertical
        \\
    );
}
