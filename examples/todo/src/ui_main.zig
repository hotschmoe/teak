//! Native entry for the todo example. Win32 + wgpu-native via teak's
//! Host / Gpu backends. The loop shape is the same as counter_greeter:
//! double-buffered CmdBuffer + rects, hit-test against the previous
//! frame, diff-skip vertex rebuild when nothing changed.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-win32");
const gpu_native = @import("teak-gpu-native");
const App = @import("app.zig");

const Host = platform.Host;
const Gpu = gpu_native.Gpu;

comptime {
    teak.validateHost(Host);
    teak.validateGpu(Gpu);
}

// ── Frame diff ─────────────────────────────────────────────────────

fn cmdsEqual(a: []const teak.Cmd(App.Msg), b: []const teak.Cmd(App.Msg)) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.meta.activeTag(ca) != std.meta.activeTag(cb)) return false;
        switch (ca) {
            .push_group => |ga| {
                const gb = cb.push_group;
                if (ga.direction != gb.direction or ga.padding != gb.padding or
                    ga.gap != gb.gap or ga.flex != gb.flex) return false;
            },
            .pop_group => {},
            .push_scroll => |sa| {
                const sb = cb.push_scroll;
                if (sa.direction != sb.direction or sa.padding != sb.padding or
                    sa.gap != sb.gap or sa.flex != sb.flex or
                    sa.width != sb.width or sa.height != sb.height or
                    sa.scroll_x != sb.scroll_x or sa.scroll_y != sb.scroll_y) return false;
            },
            .pop_scroll => {},
            .text => |ta| if (!std.mem.eql(u8, ta.content, cb.text.content)) return false,
            .button => |ba| {
                const bb = cb.button;
                if (!std.mem.eql(u8, ba.label, bb.label)) return false;
                if (!std.meta.eql(ba.msg, bb.msg)) return false;
            },
            .text_input => |tia| {
                const tib = cb.text_input;
                if (tia.cursor != tib.cursor) return false;
                if (!std.mem.eql(u8, tia.content, tib.content)) return false;
            },
            .checkbox => |ka| {
                const kb = cb.checkbox;
                if (ka.checked != kb.checked) return false;
                if (!std.mem.eql(u8, ka.label, kb.label)) return false;
                if (!std.meta.eql(ka.msg, kb.msg)) return false;
            },
            .radio => |ra| {
                const rb = cb.radio;
                if (ra.selected != rb.selected) return false;
                if (!std.mem.eql(u8, ra.label, rb.label)) return false;
                if (!std.meta.eql(ra.msg, rb.msg)) return false;
            },
            .slider => |sa| if (sa.value != cb.slider.value) return false,
            .divider => |da| if (!std.meta.eql(da, cb.divider)) return false,
        }
    }
    return true;
}

fn rectsEqual(a: []const teak.Rect, b: []const teak.Rect) bool {
    if (a.len != b.len) return false;
    for (a, b) |ra, rb| {
        if (ra.x != rb.x or ra.y != rb.y or ra.w != rb.w or ra.h != rb.h) return false;
    }
    return true;
}

fn transientEqual(a: teak.TransientState, b: teak.TransientState) bool {
    return a.hover_index == b.hover_index and
        a.press_index == b.press_index and
        a.focus_index == b.focus_index;
}

// ── Main ───────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try Host.init("Teak — Todo", 720, 600);
    defer host.deinit();

    var gpu = try Gpu.init(host.nativeHandle(), 720, 600);
    defer gpu.deinit();

    const MAX_RECTS: usize = 2048; // Todo lists grow; counter_greeter only needs 256.
    const CmdBufT = teak.CmdBuffer(App.Msg);

    var model: App.Model = .{};

    var bufs: [2]CmdBufT = .{ CmdBufT.init(gpa), CmdBufT.init(gpa) };
    defer for (&bufs) |*b| b.deinit();

    var rects_store: [2][MAX_RECTS]teak.Rect = undefined;
    var rects_len: [2]usize = .{ 0, 0 };
    var current: u1 = 0;

    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(gpa);

    var transient_state: teak.TransientState = .{};
    var prev_transient: teak.TransientState = .{};
    var press_target: ?usize = null;
    var skip_count: u64 = 0;

    while (!host.shouldClose()) {
        const input = host.pollInputs();
        if (host.shouldClose()) break;

        if (input.resized) gpu.resize(input.width, input.height);

        const prev = current;
        const prev_cmds = bufs[prev].cmds.items;
        const prev_rects = rects_store[prev][0..rects_len[prev]];
        const hover_under_mouse: ?usize = if (prev_cmds.len > 0)
            teak.hoverTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)
        else
            null;

        if (input.mouse_down) press_target = hover_under_mouse;

        if (input.mouse_up) {
            if (press_target != null and hover_under_mouse == press_target) {
                if (teak.hitTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)) |hit| {
                    App.update(&model, hit.msg);
                }
            }
            press_target = null;
        }
        if (press_target != null and hover_under_mouse != press_target) {
            press_target = null;
        }

        for (input.chars) |ch| {
            if (App.keyCharMsg(&model, ch)) |m| App.update(&model, m);
        }
        for (input.keys) |k| {
            if (App.keySpecialMsg(&model, k)) |m| App.update(&model, m);
        }

        current ^= 1;
        const cur = current;
        bufs[cur].reset();
        App.view(&model, &bufs[cur]);

        const cur_cmds = bufs[cur].cmds.items;
        if (cur_cmds.len > MAX_RECTS) @panic("Too many commands for MAX_RECTS");

        teak.LayoutEngine.doLayout(
            rects_store[cur][0..cur_cmds.len],
            cur_cmds,
            @floatFromInt(input.width),
            @floatFromInt(input.height),
        );
        rects_len[cur] = cur_cmds.len;

        transient_state.hover_index = teak.hoverTest(cur_cmds, rects_store[cur][0..cur_cmds.len], input.mouse_x, input.mouse_y);
        transient_state.press_index = press_target;
        transient_state.focus_index = focusIndex(cur_cmds, model.input_focused);
        transient_state.mouse_x = input.mouse_x;
        transient_state.mouse_y = input.mouse_y;
        transient_state.frame_counter +%= 1;

        const cmds_same = cmdsEqual(cur_cmds, bufs[prev].cmds.items);
        const rects_same = rectsEqual(rects_store[cur][0..cur_cmds.len], rects_store[prev][0..rects_len[prev]]);
        const transient_same = transientEqual(transient_state, prev_transient);
        const blink_tick = transient_state.focus_index != null and
            (transient_state.frame_counter % 30 == 0);

        const need_rebuild = !cmds_same or !rects_same or !transient_same or blink_tick;

        if (need_rebuild) {
            teak.buildVertices(&verts, gpa, cur_cmds, rects_store[cur][0..cur_cmds.len], transient_state);
            gpu.uploadVertices(verts.items);
        } else {
            skip_count += 1;
        }

        prev_transient = transient_state;
        gpu.renderFrame(.{ 0.08, 0.08, 0.1, 1.0 });
    }

    std.debug.print("Teak Todo exiting. (skipped {d} vertex rebuilds)\n", .{skip_count});
}

/// Locate the add-input in the current frame so TransientState.focus_index
/// can drive the cursor blink. Todo has exactly one text_input.
fn focusIndex(cmds: []const teak.Cmd(App.Msg), focused: bool) ?usize {
    if (!focused) return null;
    for (cmds, 0..) |cc, i| {
        if (cc == .text_input) return i;
    }
    return null;
}
