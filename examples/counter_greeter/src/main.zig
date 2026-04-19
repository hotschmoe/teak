const std = @import("std");
const teak = @import("teak");
const App = @import("app.zig");

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var model: App.Model = .{};
    var cb = teak.CmdBuffer(App.Msg).init(gpa);
    defer cb.deinit();

    App.view(&model, &cb);

    var rects: [128]teak.Rect = undefined;
    const cmds = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 800, 400, teak.monoMeasurer());

    std.debug.print("── Teak Prototype 2: Composed App ──\n", .{});
    std.debug.print("counter.count = {d}, greeter = \"{s}\", focused = {?}\n\n", .{
        model.counter.count,
        model.greeter.name[0..model.greeter.name_len],
        model.focused,
    });

    printFrame(cmds, rects[0..cmds.len]);

    // Simulated interaction trace: click "+", click "+", click text input, type "Hi", backspace.
    std.debug.print("\n── Simulated Interaction ──\n", .{});

    // Locate widget rects.
    var plus_rect: ?teak.Rect = null;
    var input_rect: ?teak.Rect = null;
    for (cmds, 0..) |c, i| switch (c) {
        .button => |btn| if (std.mem.eql(u8, btn.label, "+") and plus_rect == null) {
            plus_rect = rects[i];
        },
        .text_input => if (input_rect == null) {
            input_rect = rects[i];
        },
        else => {},
    };

    if (plus_rect) |r| {
        if (teak.hitTest(cmds, rects[0..cmds.len], r.x + 2, r.y + 2)) |hit| {
            App.update(&model, hit.msg);
            App.update(&model, hit.msg);
            std.debug.print("clicked '+' twice -> counter.count = {d}\n", .{model.counter.count});
        }
    }

    if (input_rect) |r| {
        if (teak.hitTest(cmds, rects[0..cmds.len], r.x + 5, r.y + 5)) |hit| {
            App.update(&model, hit.msg);
            std.debug.print("clicked text input -> focused = {?}\n", .{model.focused});
        }
    }

    for ([_]u8{ 'H', 'i' }) |ch| {
        if (App.keyCharMsg(&model, ch)) |m| App.update(&model, m);
    }
    std.debug.print("typed 'Hi'      -> greeter.name = \"{s}\"\n", .{model.greeter.name[0..model.greeter.name_len]});

    if (App.keySpecialMsg(&model, .backspace)) |m| App.update(&model, m);
    std.debug.print("backspace       -> greeter.name = \"{s}\"\n", .{model.greeter.name[0..model.greeter.name_len]});

    // Rebuild to show the updated frame.
    cb.reset();
    App.view(&model, &cb);
    const cmds2 = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds2.len], cmds2, 800, 400, teak.monoMeasurer());

    std.debug.print("\n── Frame After Updates ──\n", .{});
    printFrame(cmds2, rects[0..cmds2.len]);
}

fn printFrame(cmds: []const teak.Cmd(App.Msg), rects: []const teak.Rect) void {
    for (cmds, 0..) |c, i| {
        const r = rects[i];
        switch (c) {
            .push_group => |grp| std.debug.print("[{d:2}] push_{s:10} x={d:<5.0} y={d:<5.0} w={d:<5.0} h={d:<5.0}\n", .{
                i,
                @tagName(grp.direction),
                r.x,
                r.y,
                r.w,
                r.h,
            }),
            .pop_group => std.debug.print("[{d:2}] pop_group\n", .{i}),
            .text => |txt| std.debug.print("[{d:2}] text \"{s}\"\n", .{ i, txt.content }),
            .button => |btn| std.debug.print("[{d:2}] btn  \"{s}\"  x={d:<5.0} y={d:<5.0} w={d:<5.0} h={d:<5.0}\n", .{
                i,
                btn.label,
                r.x,
                r.y,
                r.w,
                r.h,
            }),
            .text_input => |ti| std.debug.print("[{d:2}] input \"{s}\" (cursor={d})  x={d:<5.0} y={d:<5.0} w={d:<5.0} h={d:<5.0}\n", .{
                i,
                ti.content,
                ti.cursor,
                r.x,
                r.y,
                r.w,
                r.h,
            }),
            // Other Cmd variants (checkbox, radio, slider, divider, scroll)
            // aren't emitted by this app. The canary only prints what
            // counter + greeter actually produce.
            else => {},
        }
    }
}

test "full composed loop: click + keyboard updates model" {
    const testing = std.testing;
    var model: App.Model = .{};
    var cb = teak.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    App.view(&model, &cb);
    var rects: [128]teak.Rect = undefined;
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 400, teak.monoMeasurer());

    // Click the "+" button.
    var plus_rect: ?teak.Rect = null;
    for (cb.cmds.items, 0..) |c, i| switch (c) {
        .button => |btn| if (std.mem.eql(u8, btn.label, "+")) {
            plus_rect = rects[i];
        },
        else => {},
    };
    try testing.expect(plus_rect != null);

    const pr = plus_rect.?;
    if (teak.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], pr.x + 2, pr.y + 2)) |hit| {
        App.update(&model, hit.msg);
    }
    try testing.expectEqual(@as(i32, 1), model.counter.count);

    // Click the text input -> focus greeter.
    var input_rect: ?teak.Rect = null;
    for (cb.cmds.items, 0..) |c, i| switch (c) {
        .text_input => {
            input_rect = rects[i];
        },
        else => {},
    };
    try testing.expect(input_rect != null);
    const ir = input_rect.?;
    if (teak.hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], ir.x + 5, ir.y + 5)) |hit| {
        App.update(&model, hit.msg);
    }
    try testing.expectEqual(@as(?App.FocusField, .greeter), model.focused);

    // Type 'X' routed through keyCharMsg.
    if (App.keyCharMsg(&model, 'X')) |m| App.update(&model, m);
    try testing.expectEqualStrings("X", model.greeter.name[0..model.greeter.name_len]);
}
