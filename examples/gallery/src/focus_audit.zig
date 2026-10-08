//! Keyboard-focus audit of the gallery: on every page, in every look, each
//! interactive leaf (button, checkbox, radio, slider, text field) is reachable
//! with Tab (a list is ONE Tab stop; its other rows must be arrow-reachable, i.e. roving),
//! disabled ones are not, and Tab visits each exactly once per cycle.

const std = @import("std");
const teak = @import("teak");
const app = @import("app.zig");
const model_mod = @import("model.zig");

fn interactive(c: anytype) bool {
    return switch (c) {
        .button, .checkbox, .radio, .slider, .text_input, .text_area => true,
        .canvas => |cv| cv.msg != null, // the toggle switch
        else => false,
    };
}

/// Tab skips it: a disabled widget, or a list row that is not the list's Tab stop.
fn disabled(c: anytype) bool {
    return switch (c) {
        .button => |b| b.disabled or !b.tab_stop,
        .text_input => |t| t.disabled,
        .text_area => |t| t.disabled,
        else => false,
    };
}

test "every enabled interactive widget on every page is reachable with Tab, exactly once" {
    for (std.enums.values(model_mod.Page)) |page| for (std.enums.values(app.Look)) |look| {
        var cb = teak.CmdBuffer(app.Msg).init(std.testing.allocator);
        defer cb.deinit();
        var m: app.Model = .{};
        m.page = page;
        m.look = look;
        cb.theme = app.themeFor(&m);
        app.view(&m, &cb);
        const cmds = cb.cmds.items;

        var want: usize = 0;
        for (cmds) |c| {
            if (c == .button and !c.button.tab_stop) try std.testing.expect(c.button.roving != .none);
            if (interactive(c) and !disabled(c)) want += 1;
        }
        var seen = try std.testing.allocator.alloc(bool, cmds.len);
        defer std.testing.allocator.free(seen);
        @memset(seen, false);
        var visited: usize = 0;
        var cur: ?usize = null;
        while (visited <= want) {
            cur = teak.nextNavigable(cmds, cur);
            const i = cur orelse break;
            if (seen[i]) break; // wrapped around
            seen[i] = true;
            visited += 1;
            try std.testing.expect(interactive(cmds[i]) and !disabled(cmds[i]));
        }
        std.testing.expectEqual(want, visited) catch |e| {
            std.debug.print("page {s} look {s}: {d} enabled interactive, Tab reaches {d}\n", .{ @tagName(page), @tagName(look), want, visited });
            return e;
        };
    };
}
