const std = @import("std");
const teak = @import("teak");

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var model = teak.Model{};
    var cb = teak.CmdBuffer.init(gpa);
    defer cb.deinit();

    // Build the view once to demonstrate the pipeline
    teak.view(model, &cb);

    var rects: [64]teak.Rect = undefined;
    const cmds = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    // Print the command buffer and layout results
    std.debug.print("── Teak Prototype ──\n", .{});
    std.debug.print("Model: count = {d}\n\n", .{model.count});

    for (cmds, 0..) |c, i| {
        const r = rects[i];
        switch (c) {
            .push_group => |grp| std.debug.print("[{d}] push_{s}:  x={d:<6.0} y={d:<6.0} w={d:<6.0} h={d:<6.0}\n", .{
                i,
                @tagName(grp.direction),
                r.x,
                r.y,
                r.w,
                r.h,
            }),
            .pop_group => std.debug.print("[{d}] pop_group\n", .{i}),
            .text => |txt| std.debug.print("[{d}] text \"{s}\":  x={d:<6.0} y={d:<6.0} w={d:<6.0} h={d:<6.0}\n", .{
                i,
                txt.content,
                r.x,
                r.y,
                r.w,
                r.h,
            }),
            .button => |btn| std.debug.print("[{d}] btn \"{s}\":  x={d:<6.0} y={d:<6.0} w={d:<6.0} h={d:<6.0}\n", .{
                i,
                btn.label,
                r.x,
                r.y,
                r.w,
                r.h,
            }),
        }
    }

    // Simulate clicks
    std.debug.print("\n── Simulated Clicks ──\n", .{});

    const clicks = [_]struct { x: f32, y: f32, label: []const u8 }{
        .{ .x = 50, .y = 75, .label = "on '+' button" },
        .{ .x = 120, .y = 75, .label = "on '-' button" },
        .{ .x = 40, .y = 130, .label = "on 'Reset' button" },
        .{ .x = 300, .y = 250, .label = "on empty space" },
    };

    for (clicks) |click| {
        if (teak.hitTest(cmds, rects[0..cmds.len], click.x, click.y)) |hit| {
            teak.update(&model, hit.msg);
            std.debug.print("Click {s} -> {s} -> count = {d}\n", .{
                click.label,
                @tagName(hit.msg),
                model.count,
            });
        } else {
            std.debug.print("Click {s} -> miss\n", .{click.label});
        }
    }
}

test "full loop: click updates model" {
    const testing = std.testing;
    var model = teak.Model{};
    var cb = teak.CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Frame 1: build view
    teak.view(model, &cb);
    var rects: [32]teak.Rect = undefined;
    var cmds = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    // Simulate click on "+" button
    if (teak.hitTest(cmds, rects[0..cmds.len], 50, 75)) |hit| {
        teak.update(&model, hit.msg);
    }
    try testing.expectEqual(@as(i32, 1), model.count);

    // Frame 2: rebuild view with updated model
    cb.reset();
    teak.view(model, &cb);
    cmds = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    // Verify text updated
    try testing.expectEqualStrings("Count: 1", cmds[1].text.content);

    // Click "+" again
    if (teak.hitTest(cmds, rects[0..cmds.len], 50, 75)) |hit| {
        teak.update(&model, hit.msg);
    }
    try testing.expectEqual(@as(i32, 2), model.count);

    // Click "Reset"
    cb.reset();
    teak.view(model, &cb);
    cmds = cb.cmds.items;
    teak.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    if (teak.hitTest(cmds, rects[0..cmds.len], 40, 130)) |hit| {
        teak.update(&model, hit.msg);
    }
    try testing.expectEqual(@as(i32, 0), model.count);
}
