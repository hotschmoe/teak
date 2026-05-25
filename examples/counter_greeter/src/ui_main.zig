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

// ════════════════════════════════════════════════════════════════════
// Frame Diff
// ════════════════════════════════════════════════════════════════════

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
            .button => |ba| if (!std.mem.eql(u8, ba.label, cb.button.label)) return false,
            .text_input => |tia| {
                const tib = cb.text_input;
                if (tia.cursor != tib.cursor) return false;
                if (tia.selection_anchor != tib.selection_anchor) return false;
                if (!std.mem.eql(u8, tia.content, tib.content)) return false;
            },
            .checkbox => |ka| {
                const kb = cb.checkbox;
                if (ka.checked != kb.checked) return false;
                if (!std.mem.eql(u8, ka.label, kb.label)) return false;
            },
            .radio => |ra| {
                const rb = cb.radio;
                if (ra.selected != rb.selected) return false;
                if (!std.mem.eql(u8, ra.label, rb.label)) return false;
            },
            .slider => |sa| if (sa.value != cb.slider.value) return false,
            .divider => |da| if (!std.meta.eql(da, cb.divider)) return false,
            // New variants: be conservative — force rebuild on any
            // difference rather than re-implementing per-field compare.
            .push_overlay => |oa| if (!std.meta.eql(oa, cb.push_overlay)) return false,
            .pop_overlay => {},
            .push_virtual_list => |va| if (!std.meta.eql(va, cb.push_virtual_list)) return false,
            .pop_virtual_list => {},
            .image => |ia| if (!std.meta.eql(ia, cb.image)) return false,
            .rich_text => |ra| {
                const rb = cb.rich_text;
                if (!std.mem.eql(u8, ra.content, rb.content)) return false;
                if (ra.spans.len != rb.spans.len) return false;
                for (ra.spans, rb.spans) |sa, sb| if (!std.meta.eql(sa, sb)) return false;
            },
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

// ════════════════════════════════════════════════════════════════════
// Main
// ════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var host = try Host.init("Teak — Counter + Greeter", 900, 500);
    defer host.deinit();

    var gpu = try Gpu.init(host.nativeHandle(), 900, 500);
    defer gpu.deinit();

    const measurer = host.textMeasurer();

    std.debug.print("Adapter + device acquired.\n", .{});

    // ── Application state: double-buffered CmdBuffer + rects ──────
    const MAX_RECTS: usize = 256;
    const CmdBufT = teak.CmdBuffer(App.Msg);

    var model: App.Model = .{};

    var bufs: [2]CmdBufT = .{ CmdBufT.init(gpa), CmdBufT.init(gpa) };
    defer for (&bufs) |*b| b.deinit();

    var rects_store: [2][MAX_RECTS]teak.Rect = undefined;
    var rects_len: [2]usize = .{ 0, 0 };
    var current: u1 = 0;

    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(gpa);
    var text_draws: std.ArrayList(teak.TextDraw) = .empty;
    defer text_draws.deinit(gpa);
    var image_draws: std.ArrayList(teak.ImageDraw) = .empty;
    defer image_draws.deinit(gpa);

    var transient_state: teak.TransientState = .{};
    var prev_transient: teak.TransientState = .{};

    // Proto press model: press_index arms on mousedown over a widget;
    // mouseup fires the click Msg only if still over the same index;
    // drag-off cancels without emitting a Msg.
    var press_target: ?usize = null;

    var skip_count: u64 = 0;

    std.debug.print("Teak UI running.\n", .{});

    while (!host.shouldClose()) {
        // 1. Drain events.
        const input = host.pollInputs();
        if (host.shouldClose()) break;

        // 2. Handle resize.
        if (input.resized) gpu.resize(input.width, input.height);

        // 3. Input against the *previous* frame's layout.
        // `prev` captures last frame's write slot before we flip `current`.
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
                    std.debug.print("click -> {s}\n", .{@tagName(hit.msg)});
                }
            }
            press_target = null;
        }

        // Drag-off cancels the press.
        if (press_target != null and hover_under_mouse != press_target) {
            press_target = null;
        }

        // Route keyboard via Model.focused.
        for (input.chars) |ch| {
            if (App.keyCharMsg(&model, ch)) |m| App.update(&model, m);
        }
        for (input.keys) |k| {
            if (App.keyNeedsClipboard(k)) {
                // Host glue: copy/cut → write selectionText to OS clipboard
                // then (for cut) drop the selection via backspace.
                const clip = host.clipboard();
                switch (k) {
                    .ctrl_c => {
                        const sel = App.greeterSelection(&model);
                        if (sel.len > 0) clip.write(sel);
                    },
                    .ctrl_x => {
                        const sel = App.greeterSelection(&model);
                        if (sel.len > 0) {
                            clip.write(sel);
                            App.update(&model, .{ .greeter = .name_backspace });
                        }
                    },
                    .ctrl_v => {
                        const bytes = clip.read();
                        if (bytes.len > 0) App.update(&model, .{ .greeter = .{ .name_replace_selection = bytes } });
                    },
                    else => {},
                }
            } else if (App.keySpecialMsg(&model, k)) |m| {
                App.update(&model, m);
            }
        }

        // 4. Build this frame into the other buffer.
        current ^= 1;
        const cur = current;
        bufs[cur].reset();
        // Theme is presentation context (per HARDLINE §1 it sits at the
        // same layer as TransientState — view reads but doesn't mutate
        // it). The app's `dark_mode` flag flips between the two presets.
        bufs[cur].theme = if (model.dark_mode) teak.Theme.dark_default else teak.Theme.light_default;
        App.view(&model, &bufs[cur]);

        const cur_cmds = bufs[cur].cmds.items;
        if (cur_cmds.len > MAX_RECTS) @panic("Too many commands for MAX_RECTS");

        teak.LayoutEngine.doLayout(
            rects_store[cur][0..cur_cmds.len],
            cur_cmds,
            @floatFromInt(input.width),
            @floatFromInt(input.height),
            measurer,
        );
        rects_len[cur] = cur_cmds.len;

        // 5. Update transient state against THIS frame's layout.
        transient_state.hover_index = teak.hoverTest(cur_cmds, rects_store[cur][0..cur_cmds.len], input.mouse_x, input.mouse_y);
        transient_state.press_index = press_target;
        transient_state.focus_index = focusIndex(cur_cmds, model.focused);
        transient_state.mouse_x = input.mouse_x;
        transient_state.mouse_y = input.mouse_y;
        transient_state.frame_counter +%= 1;

        // 6. Diff against previous frame (bufs[prev] is last frame since
        // `prev` was captured before the swap at step 4).
        const cmds_same = cmdsEqual(cur_cmds, bufs[prev].cmds.items);
        const rects_same = rectsEqual(rects_store[cur][0..cur_cmds.len], rects_store[prev][0..rects_len[prev]]);
        const transient_same = transientEqual(transient_state, prev_transient);

        // Force rebuild every 30 frames while a text input is focused so
        // the cursor blink animates. A real impl would track blink phase.
        const blink_tick = transient_state.focus_index != null and
            (transient_state.frame_counter % 30 == 0);

        const need_rebuild = !cmds_same or !rects_same or !transient_same or blink_tick;

        if (need_rebuild) {
            teak.buildVertices(&verts, &text_draws, &image_draws, gpa, cur_cmds, rects_store[cur][0..cur_cmds.len], transient_state, measurer);
            gpu.uploadVertices(verts.items);
            gpu.uploadText(text_draws.items);
            gpu.uploadImages(image_draws.items);
        } else {
            skip_count += 1;
            if (skip_count % 120 == 0) std.debug.print("diff: skipped vertex rebuild (total skipped = {d})\n", .{skip_count});
        }

        prev_transient = transient_state;

        // 7. Render + present.
        gpu.renderFrame(.{ 0.08, 0.08, 0.1, 1.0 });
    }

    std.debug.print("Teak UI exiting. (skipped {d} vertex rebuilds)\n", .{skip_count});
}

/// Map model.focused → cmd index of its text_input in the current frame.
/// Proto 2 has exactly one text_input (greeter), so a linear scan suffices.
/// When we add more focusable widgets, this needs a predicate per field.
fn focusIndex(cmds: []const teak.Cmd(App.Msg), focused: ?App.FocusField) ?usize {
    if (focused == null) return null;
    for (cmds, 0..) |cc, i| {
        if (cc == .text_input) return i;
    }
    return null;
}
