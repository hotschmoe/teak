//! Kerf mesh viewer: a Kerf `mesh.json` (docs/features/scene.md section 7)
//! in a 3D viewport with orbit / pan / zoom-to-cursor, view presets, an
//! ortho/persp toggle, CPU click-picking and a parts inspector, in Kerf's
//! 1970s engineering-office look (kerf/spec/DESIGN.md).
//!
//! Rendering is `viewport3d`: every part is its own mesh resource (key =
//! part id, uploaded once per document) and each frame places them as
//! `Item`s. Selection is the `highlight` flag and hover a brighter tint on
//! the item, so interacting never touches or re-uploads geometry.
//!
//! Model sources: a bundled fixture (default), `?mesh=<fixture|url>` /
//! `--mesh=<fixture|url>` read through the `query_param` effect, an
//! `open_file` effect (OPEN button; native: `TEAK_OPEN=path`) and dropped
//! `.json` files. Every request is data the app lists; the answers arrive as
//! Msgs.

const std = @import("std");
const teak = @import("teak");
const kerf = @import("kerf_mesh.zig");

const scene = teak.scene;
const Orbit = scene.Orbit;

// ── Palette (kerf/spec/DESIGN.md section 1) and theme ──────────────

pub const paper: [4]f32 = .{ 0.949, 0.937, 0.902, 1 }; // #F2EFE6
pub const paper2: [4]f32 = .{ 0.914, 0.898, 0.847, 1 }; // #E9E5D8
pub const ink: [4]f32 = .{ 0.102, 0.102, 0.102, 1 }; // #1A1A1A
pub const ink2: [4]f32 = .{ 0.333, 0.322, 0.294, 1 }; // #55524B
pub const blue: [4]f32 = .{ 0.114, 0.306, 0.620, 1 }; // #1D4E9E
const red: [4]f32 = .{ 0.784, 0.063, 0.180, 1 }; // #C8102E
const manila: [4]f32 = .{ 0.914, 0.851, 0.651, 1 }; // #E9D9A6
const term_bg: [4]f32 = .{ 0.055, 0.071, 0.055, 1 }; // #0E120E
const term_fg: [4]f32 = .{ 0.361, 0.949, 0.478, 1 }; // #5CF27A
const clear: [4]f32 = .{ 0, 0, 0, 0 };

const plex: teak.FontSpec = .{ .size_px = 13, .family = .mono };
const plex_bold: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold, .letter_spacing = 1 };
/// Bold without tracking, so table headers line up with their rows.
const plex_tight: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold };
const plex_wordmark: teak.FontSpec = .{ .size_px = 22, .family = .mono, .weight = .bold, .letter_spacing = 4 };

pub const theme: teak.Theme = .{
    .palette = .{
        .bg = paper,
        .bg_panel = paper,
        .bg_sunken = paper2,
        .bg_raised = paper,
        .bg_hover = ink,
        .bg_press = ink,
        .fg = ink,
        .fg_muted = ink2,
        .accent = blue,
        .danger = red,
        .border = ink,
    },
    .typography = .{ .body = plex, .mono = plex, .small = plex, .heading = plex_bold },
    .text_color = ink,
    .heading_color = ink,
    .muted_color = ink2,
    .danger_color = red,
    .panel_bg = paper,
    .button = key_button,
    .divider = .{ .thickness = 1, .color = ink },
    .card = .{ .padding = 10, .gap = 6, .bg = paper, .border = ink, .align_cross = .stretch },
};

const key_button: teak.ButtonStyle = .{
    .bg = paper,
    .hover_bg = ink,
    .press_bg = ink,
    .fg = ink,
    .hover_fg = paper,
    .press_fg = paper,
    .press_offset_y = 1,
    .border = ink,
    .label_align = .center,
    .height = 26,
    .min_width = 0,
    .h_padding = 12,
};

const header_button: teak.ButtonStyle = .{
    .bg = ink,
    .hover_bg = paper,
    .press_bg = paper,
    .fg = paper,
    .hover_fg = ink,
    .press_fg = ink,
    .border = paper,
    .label_align = .center,
    .height = 26,
    .min_width = 0,
    .h_padding = 12,
};

/// Bracketed tab text; the underline bar under it marks the active one.
const tab_button: teak.ButtonStyle = .{
    .bg = clear,
    .hover_bg = paper2,
    .press_bg = paper2,
    .fg = ink,
    .label_align = .center,
    .height = 24,
    .min_width = 0,
    .h_padding = 8,
};

const row_height: f32 = 22;
const row_button: teak.ButtonStyle = .{
    .bg = clear,
    .hover_bg = paper2,
    .press_bg = paper2,
    .fg = ink,
    .label_align = .start,
    .height = row_height,
    .min_width = 0,
    .h_padding = 6,
};
const row_button_on: teak.ButtonStyle = .{
    .bg = ink,
    .hover_bg = ink,
    .press_bg = ink,
    .fg = paper,
    .label_align = .start,
    .height = row_height,
    .min_width = 0,
    .h_padding = 6,
};

// ── Model ──────────────────────────────────────────────────────────

pub const scene_id: u32 = 7;
pub const list_id: u32 = 8;
const click_slop_px: f32 = 4;
const highlight: [4]f32 = .{ 0.114, 0.306, 0.620, 1 };

const Fixture = struct { name: []const u8, bytes: []const u8 };
pub const fixtures = [_]Fixture{
    .{ .name = "palmer-sd1-like", .bytes = kerf.large_fixture },
    .{ .name = "flush-psl-2x6", .bytes = kerf.small_fixture },
};

/// Backs `Loaded` (a single arena per model). Works on native and wasm.
const gpa = std.heap.page_allocator;

pub const Model = struct {
    loaded: ?kerf.Loaded = null,
    doc_buf: [64]u8 = undefined,
    doc_len: usize = 0,
    cam: Orbit = .{},
    /// Viewport size in logical px, reported by the scene's `layout` events.
    vp: [2]f32 = .{ 800, 600 },
    selected: u32 = 0,
    hovered: u32 = 0,
    edges: bool = true,
    /// Ground grid (at the model's lowest Y) and the corner axis gizmo.
    grid: bool = true,
    /// Re-frame on the first `layout` event (the real viewport size).
    fit_pending: bool = true,
    /// Document revision: stamped on every part's mesh resource (so a new
    /// document re-uploads the keys) and used as the scene's `key`.
    rev: u32 = 0,
    /// Pixels travelled since the left button went down; a small value on
    /// release is a click (pick), a large one was an orbit / pan.
    drag_px: f32 = 0,
    status_buf: [96]u8 = undefined,
    status_len: usize = 0,
    list_scroll: f32 = 0,
    list_viewport: f32 = 0,
    list_content: f32 = 0,
    next_id: u32 = 2,
    /// The one request in flight (`effects()` returns it while `req_len == 1`).
    reqs: [1]teak.Effect = undefined,
    req_len: usize = 0,
    url_buf: [256]u8 = undefined,

    pub fn init() Model {
        var m: Model = .{};
        m.reqs[0] = .{ .query_param = .{ .id = 1, .name = "mesh" } };
        m.req_len = 1;
        m.loadBytes(fixtures[0].name, fixtures[0].bytes);
        m.fit_pending = true; // re-frame once the first `layout` event gives the real size
        return m;
    }

    pub fn doc(m: *const Model) []const u8 {
        return m.doc_buf[0..m.doc_len];
    }

    pub fn status(m: *const Model) []const u8 {
        return if (m.status_len == 0) "READY" else m.status_buf[0..m.status_len];
    }

    fn setStatus(m: *Model, comptime fmt: []const u8, args: anytype) void {
        const out: []const u8 = std.fmt.bufPrint(&m.status_buf, fmt, args) catch &.{};
        m.status_len = out.len;
    }

    fn setDoc(m: *Model, name: []const u8) void {
        if (name.ptr == &m.doc_buf) return; // already the stored name
        const n = @min(name.len, m.doc_buf.len);
        @memcpy(m.doc_buf[0..n], name[0..n]);
        m.doc_len = n;
    }

    /// Parse `bytes` and, on success, replace the document (frames the
    /// camera, clears the selection). A failure keeps the old document.
    fn loadBytes(m: *Model, name: []const u8, bytes: []const u8) void {
        var next = kerf.parse(gpa, bytes) catch |e| {
            m.setStatus("ERR {s}: {s}", .{ name, @errorName(e) });
            return;
        };
        if (m.loaded) |*old| old.deinit();
        m.rev +%= 1;
        next.setRev(m.rev);
        m.loaded = next;
        m.setDoc(name);
        m.selected = 0;
        m.hovered = 0;
        m.list_scroll = 0;
        m.fitView();
        m.status_len = 0;
    }

    /// Centre the model and pull in a little from the conservative sphere fit.
    fn fitView(m: *Model) void {
        const l = &(m.loaded orelse return);
        m.cam.frame(l.lo, l.hi, m.aspect());
        m.cam.dist *= 0.9;
        m.fit_pending = false;
    }

    fn aspect(m: *const Model) f32 {
        return if (m.vp[1] > 0) m.vp[0] / m.vp[1] else 1;
    }

    fn takeId(m: *Model) u32 {
        const id = m.next_id;
        m.next_id +%= 1;
        if (m.next_id == 0) m.next_id = 2;
        return id;
    }

    fn partCount(m: *const Model) u32 {
        return if (m.loaded) |l| @intCast(l.parts.len) else 0;
    }

    /// `?mesh=` value: a bundled fixture name (with or without `.json`), else
    /// a URL / path fetched with an `http` effect (web: relative URLs work).
    fn loadNamed(m: *Model, value: []const u8) void {
        const name = std.mem.trimEnd(u8, value, "/");
        const stem = if (std.mem.endsWith(u8, name, ".json")) name[0 .. name.len - 5] else name;
        for (fixtures) |f| {
            if (std.mem.eql(u8, f.name, stem)) return m.loadBytes(f.name, f.bytes);
        }
        const n = @min(value.len, m.url_buf.len);
        @memcpy(m.url_buf[0..n], value[0..n]);
        m.reqs[0] = .{ .http = .{ .id = m.takeId(), .url = m.url_buf[0..n], .timeout_ms = 30_000 } };
        m.req_len = 1;
        m.setDoc(std.fs.path.basename(value));
        m.setStatus("FETCHING {s}", .{value});
    }

    /// The part under viewport-local px `(x, y)` (1-based id, 0 = empty space).
    fn pickAt(m: *const Model, x: f32, y: f32, w: f32, h: f32) u32 {
        const l = &(m.loaded orelse return 0);
        const ray = scene.pickRay(camera(m), w, h, x, y);
        const hit = scene.pick.items(ray, l.pick_items, l.pick_refs, .{}) orelse return 0;
        return hit.id;
    }

    fn selectPart(m: *Model, id: u32) void {
        const next: u32 = if (id <= m.partCount()) id else 0;
        if (next == m.selected) return;
        m.selected = next;
        // Keep the row visible in the panel.
        if (next != 0 and m.list_viewport > 0) {
            const top = @as(f32, @floatFromInt(next - 1)) * row_height;
            if (top < m.list_scroll) m.list_scroll = top;
            if (top + row_height > m.list_scroll + m.list_viewport) m.list_scroll = top + row_height - m.list_viewport;
            m.list_scroll = clampScroll(m, m.list_scroll);
        }
    }
};

pub const Msg = union(enum) {
    view_event: teak.CanvasEvent,
    select: u32,
    select_step: i8,
    preset: Orbit.Preset,
    toggle_ortho,
    toggle_edges,
    toggle_grid,
    fit,
    load_fixture: u8,
    open_file,
    /// `?mesh=` / `--mesh=` answer.
    mesh_param: ?[]const u8,
    file_opened: struct { name: []const u8, bytes: []const u8 },
    file_cancelled,
    http_done: struct { status: u16, body: []const u8, err: []const u8 },
    list_scroll_by: f32,
    list_extent: [2]f32,
    noop,
};

// ── update ─────────────────────────────────────────────────────────

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .view_event => |ev| viewEvent(m, ev),
        .select => |id| m.selectPart(id),
        .select_step => |d| {
            const n = m.partCount();
            if (n == 0) return;
            const cur: i64 = if (m.selected == 0) (if (d > 0) 0 else n + 1) else m.selected;
            const next = @mod(cur - 1 + d, @as(i64, n)) + 1;
            m.selectPart(@intCast(next));
        },
        .preset => |p| m.cam.setPreset(p),
        .toggle_ortho => m.cam.toggleProjection(),
        .toggle_edges => m.edges = !m.edges,
        .toggle_grid => m.grid = !m.grid,
        .fit => m.fitView(),
        .load_fixture => |i| if (i < fixtures.len) m.loadBytes(fixtures[i].name, fixtures[i].bytes),
        .open_file => if (m.req_len == 0) {
            m.reqs[0] = .{ .open_file = .{ .id = m.takeId(), .accept = ".json" } };
            m.req_len = 1;
        },
        .mesh_param => |v| {
            m.req_len = 0;
            if (v) |name| m.loadNamed(name);
        },
        .file_opened => |f| {
            m.req_len = 0;
            m.loadBytes(f.name, f.bytes);
        },
        .file_cancelled => m.req_len = 0,
        .http_done => |h| {
            m.req_len = 0;
            if (h.status >= 200 and h.status < 300) {
                m.loadBytes(m.doc(), h.body);
            } else {
                m.setStatus("FETCH FAILED {d} {s}", .{ h.status, h.err });
            }
        },
        .list_scroll_by => |dy| m.list_scroll = clampScroll(m, m.list_scroll + dy),
        .list_extent => |e| {
            m.list_viewport = e[0];
            m.list_content = e[1];
            m.list_scroll = clampScroll(m, m.list_scroll);
        },
        .noop => {},
    }
}

fn clampScroll(m: *const Model, y: f32) f32 {
    return std.math.clamp(y, 0, @max(0, m.list_content - m.list_viewport));
}

/// Placement of the axis gizmo (shared by the view and its hit test).
const gizmo_view: teak.scene.Gizmo = .{
    .corner = .bottom_left,
    .size_px = 100,
    .margin_px = 10,
    // X / Y / Z in Kerf's red, green and blue
    .colors = .{ .{ 0.784, 0.063, 0.180, 1 }, .{ 0.180, 0.490, 0.196, 1 }, .{ 0.114, 0.306, 0.620, 1 } },
};

fn gizmoHit(m: *const Model, x: f32, y: f32, w: f32, h: f32) ?scene.pick.GizmoAxis {
    const layout: scene.pick.GizmoLayout = .{ .corner = .bottom_left, .size_px = gizmo_view.size_px, .margin_px = gizmo_view.margin_px };
    return scene.pick.gizmoHit(m.cam, layout, w, h, x, y);
}

fn viewEvent(m: *Model, ev: teak.CanvasEvent) void {
    switch (ev.kind) {
        .layout => {
            m.vp = .{ ev.w, ev.h };
            if (m.fit_pending) m.fitView();
        },
        .down => if (ev.button == .left) {
            m.drag_px = 0;
        },
        .move => {
            if (ev.buttons.any()) {
                m.drag_px += @abs(ev.dx) + @abs(ev.dy);
            } else {
                m.hovered = m.pickAt(ev.x, ev.y, ev.w, ev.h);
            }
        },
        .up => if (ev.button == .left and m.drag_px < click_slop_px and !ev.mods.shift) {
            // A click on a gizmo cap looks down that axis; anywhere else it picks a part.
            const axis = if (m.grid) gizmoHit(m, ev.x, ev.y, ev.w, ev.h) else null;
            if (axis) |a| {
                m.cam.setPreset(a.preset(m.cam.up));
            } else {
                m.selectPart(m.pickAt(ev.x, ev.y, ev.w, ev.h));
            }
        },
        .leave => m.hovered = 0,
        .wheel => {},
    }
    _ = m.cam.onEvent(ev, .{});
}

// ── Host hooks ─────────────────────────────────────────────────────

pub fn canvasMsg(_: *const Model, ev: teak.CanvasEvent) ?Msg {
    return if (ev.id == scene_id) Msg{ .view_event = ev } else null;
}

pub fn scrollMsg(_: *const Model, id: u32, _: f32, dy: f32) ?Msg {
    return if (id == list_id) Msg{ .list_scroll_by = dy } else null;
}

pub fn scrollLayoutMsg(_: *const Model, id: u32, _: f32, vh: f32, _: f32, ch: f32) ?Msg {
    return if (id == list_id) Msg{ .list_extent = .{ vh, ch } } else null;
}

pub fn keyCharMsg(_: *const Model, c: u8) ?Msg {
    return switch (c) {
        '1' => Msg{ .preset = .front },
        '2' => Msg{ .preset = .iso },
        '3' => Msg{ .preset = .top },
        '4' => Msg{ .preset = .right },
        'o', 'O' => .toggle_ortho,
        'f', 'F' => .fit,
        'e', 'E' => .toggle_edges,
        'g', 'G' => .toggle_grid,
        else => null,
    };
}

pub fn keySpecialMsg(_: *const Model, key: teak.SpecialKey) ?Msg {
    return switch (key) {
        .up => Msg{ .select_step = -1 },
        .down => Msg{ .select_step = 1 },
        .escape => Msg{ .select = 0 },
        else => null,
    };
}

pub fn effects(m: *const Model) []const teak.Effect {
    return m.reqs[0..m.req_len];
}

pub fn effectMsg(_: *const Model, r: teak.EffectResult) ?Msg {
    return switch (r) {
        .query_value => |q| Msg{ .mesh_param = q.value },
        .file_opened => |f| Msg{ .file_opened = .{ .name = f.name, .bytes = f.bytes } },
        .file_cancelled => .file_cancelled,
        .http => |h| Msg{ .http_done = .{ .status = h.status, .body = h.body, .err = h.err } },
        .dropped => |d| if (d.kind == .file) Msg{ .file_opened = .{ .name = d.name, .bytes = d.bytes } } else null,
        else => null,
    };
}

pub fn resources(m: *const Model) []const teak.Resource {
    return if (m.loaded) |l| l.resources else &.{};
}

pub fn themeFor(_: *const Model) teak.Theme {
    return theme;
}

pub fn windowTitle(_: *const Model) ?[]const u8 {
    return "Kerf mesh viewer";
}

// ── Camera ─────────────────────────────────────────────────────────

pub fn camera(m: *const Model) teak.Camera {
    const b: ?scene.Bounds = if (m.loaded) |l| l.bounds() else null;
    var cam = m.cam.camera(m.vp[0], m.vp[1], b);
    cam.light_dir = .{ 0, 0, 0 }; // headlight: whatever faces the viewer is lit
    return cam;
}

// ── View ───────────────────────────────────────────────────────────

pub fn view(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 0, .gap = 0, .bg = paper, .align_cross = .stretch });
    header(m, cb);
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .flex = 1, .align_cross = .stretch });
    centerColumn(m, cb);
    rightColumn(m, cb);
    cb.popGroup();
    statusBar(m, cb);
    cb.popGroup();
}

fn header(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 12, .height = 40, .bg = ink, .align_cross = .center });
    cb.textStyled("KERF", plex_wordmark, paper);
    // The three saw-kerf bars of the wordmark.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 3, .align_cross = .center });
    for (0..3) |_| {
        cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 6, .height = 14, .bg = paper });
        cb.popGroup();
    }
    cb.popGroup();
    cb.textStyled("MESH VIEWER", plex, .{ 0.72, 0.70, 0.64, 1 });
    const a = cb.arena.allocator();
    cb.textStyled(std.fmt.allocPrint(a, "DOC: {s}", .{std.ascii.allocUpperString(a, m.doc()) catch m.doc()}) catch "", plex, paper);
    cb.spacer(1);
    for (fixtures, 0..) |f, i| {
        cb.buttonStyled(.{ .load_fixture = @intCast(i) }, std.ascii.allocUpperString(a, f.name) catch f.name, header_button);
    }
    cb.buttonStyled(.open_file, "OPEN...", header_button);
    cb.popGroup();
    // 2px rule under the header (DESIGN section 1).
    cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 2, .bg = ink });
    cb.popGroup();
}

fn centerColumn(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 12, .gap = 8, .flex = 1, .bg = paper2, .align_cross = .stretch });

    // View-cube style presets as bracketed tabs, then projection / fit / edges.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4, .align_cross = .center });
    const presets = [_]struct { label: []const u8, p: Orbit.Preset }{
        .{ .label = "[FRONT]", .p = .front },
        .{ .label = "[ISO]", .p = .iso },
        .{ .label = "[TOP]", .p = .top },
        .{ .label = "[RIGHT]", .p = .right },
    };
    for (presets) |p| cb.buttonStyled(.{ .preset = p.p }, p.label, tab_button);
    cb.spacer(1);
    cb.buttonStyled(.toggle_ortho, if (m.cam.projection == .ortho) "[ORTHO]" else "[PERSP]", tab_button);
    cb.buttonStyled(.toggle_edges, if (m.edges) "[EDGES ON]" else "[EDGES OFF]", tab_button);
    cb.buttonStyled(.toggle_grid, if (m.grid) "[GRID ON]" else "[GRID OFF]", tab_button);
    cb.buttonStyled(.fit, "[FIT]", tab_button);
    cb.popGroup();

    viewport(m, cb);
    cb.popGroup();
}

/// One `Item` per part, placed at the identity: selection is the
/// `highlight` flag, hover a slightly brighter tint, edges a per-item flag.
fn partItems(m: *const Model, arena: std.mem.Allocator) []const teak.SceneItem {
    const l = &(m.loaded orelse return &.{});
    const items = arena.alloc(teak.SceneItem, l.parts.len) catch return &.{};
    for (items, l.parts) |*it, p| {
        const id = p.index + 1;
        it.* = .{
            .mesh = id,
            .id = id,
            .tint = if (m.hovered == id and m.selected != id) .{ 1.18, 1.18, 1.18, 1 } else .{ 1, 1, 1, 1 },
            .flags = .{ .highlight = m.selected == id, .no_edges = !m.edges },
        };
    }
    return items;
}

/// DESIGN section 4: ground grid in `grid-2` / `grid` on the paper, in feet
/// (the mesh units are inches), sitting on the model's lowest point.
fn groundGrid(m: *const Model) teak.scene.Grid {
    const floor_y: f32 = if (m.loaded) |l| l.lo[1] else 0;
    return .{
        .plane = .xz,
        .offset = floor_y,
        .spacing = 12,
        .major_every = 5,
        .minor = .{ 0.827, 0.878, 0.933, 1 }, // #D3E0EE
        .major = .{ 0.663, 0.757, 0.867, 1 }, // #A9C1DD
        .axis_a = .{ 0.784, 0.063, 0.180, 0.8 },
        .axis_b = .{ 0.114, 0.306, 0.620, 0.8 },
    };
}

fn viewport(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 1, .gap = 0, .flex = 1, .border = ink, .bg = paper, .align_cross = .stretch });
    cb.viewport3d(.{
        .style = .{ .width = 480, .height = 320, .flex = 1 },
        .view = .{
            .items = partItems(m, cb.arena.allocator()),
            .highlight_color = highlight,
            .highlight_mix = 0.6,
            .grid = if (m.grid) groundGrid(m) else null,
            .gizmo = if (m.grid) gizmo_view else null,
        },
        .camera = camera(m),
        .clear = paper,
        .edge_color = .{ 1, 1, 1, 1 },
        .edge_px = 1.25,
        .key = m.rev,
        .id = scene_id,
        .pointer = true,
        .label = "3D model viewport",
    });
    cb.popGroup();
}

fn rightColumn(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .width = 340, .padding = 12, .gap = 10, .bg = paper, .border = ink, .align_cross = .stretch });

    // Parts table: header band + clickable rows, selection synced both ways.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .space_between });
    cb.heading("PARTS");
    cb.textMuted(std.fmt.allocPrint(a, "{d}", .{m.partCount()}) catch "");
    cb.popGroup();
    cb.pushGroup(.{ .padding = 1, .gap = 0, .flex = 1, .border = ink, .align_cross = .stretch });
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 6, .pad_y = 3, .gap = 0, .bg = ink, .align_cross = .stretch });
    cb.textStyled("NO  PART                  TRIS", plex_tight, paper);
    cb.popGroup();
    cb.pushScroll(.{ .gap = 0, .flex = 1, .align_cross = .stretch, .scroll_y = m.list_scroll, .id = list_id });
    if (m.loaded) |l| {
        for (l.parts, 0..) |p, i| {
            const id: u32 = @intCast(i + 1);
            cb.buttonStyled(.{ .select = id }, partRow(a, p), if (m.selected == id) row_button_on else row_button);
        }
    }
    cb.popScroll();
    cb.popGroup();

    detailCard(m, cb);
    notesCard(cb);
    cb.popGroup();
}

fn partRow(a: std.mem.Allocator, p: kerf.Part) []const u8 {
    const label = if (p.name.len > 0)
        std.fmt.allocPrint(a, "{s}/{s}", .{ p.src, p.name }) catch p.src
    else if (p.instance > 0)
        std.fmt.allocPrint(a, "{s}#{d}", .{ p.src, p.instance }) catch p.src
    else
        p.src;
    const cut = label[0..@min(label.len, 20)];
    return std.fmt.allocPrint(a, "{d:0>2}  {s:<20}  {d:>4}", .{ p.index + 1, cut, p.tri_count }) catch "?";
}

fn detailCard(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(cb.theme.card);
    cb.heading("DETAIL");
    cb.divider();
    if (m.loaded) |*l| if (l.partById(m.selected)) |p| {
        property(cb, "PART", std.fmt.allocPrint(a, "{d:0>2} {s}", .{ p.index + 1, p.src }) catch "");
        property(cb, "MATERIAL", p.material);
        property(cb, "TRIANGLES", std.fmt.allocPrint(a, "{d}", .{p.tri_count}) catch "");
        property(cb, "SHELL", if (p.closed) "CLOSED" else "OPEN");
        property(cb, "WIDTH  X", kerf.fmtFtIn(a, p.hi[0] - p.lo[0]));
        property(cb, "HEIGHT Y", kerf.fmtFtIn(a, p.hi[1] - p.lo[1]));
        property(cb, "DEPTH  Z", kerf.fmtFtIn(a, p.hi[2] - p.lo[2]));
        cb.popGroup();
        return;
    };
    cb.textMuted("NO PART SELECTED");
    cb.textMuted("CLICK THE MODEL OR A ROW");
    if (m.loaded) |*l| {
        property(cb, "OVERALL X", kerf.fmtFtIn(a, l.hi[0] - l.lo[0]));
        property(cb, "OVERALL Y", kerf.fmtFtIn(a, l.hi[1] - l.lo[1]));
        property(cb, "OVERALL Z", kerf.fmtFtIn(a, l.hi[2] - l.lo[2]));
    }
    cb.popGroup();
}

/// Placeholder for the multi-line notes editor (a `TextArea` lands with the
/// text lane); the card and its slot are final, only the body swaps.
fn notesCard(cb: anytype) void {
    cb.pushGroup(.{ .padding = 10, .gap = 6, .height = 104, .bg = manila, .border = ink, .align_cross = .stretch });
    cb.heading("NOTES");
    cb.divider();
    cb.textMuted("TEXT AREA PLACEHOLDER");
    cb.textMuted("(multi-line editor pending)");
    cb.popGroup();
}

fn property(cb: anytype, label: []const u8, value: []const u8) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .space_between });
    cb.textMuted(label);
    cb.text(value);
    cb.popGroup();
}

fn statusBar(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 12, .pad_y = 0, .gap = 14, .height = 24, .bg = term_bg, .align_cross = .center });
    const mono = plex;
    cb.textStyled(std.ascii.allocUpperString(a, m.status()) catch "READY", plex_bold, term_fg);
    cb.textStyled("|", mono, term_fg);
    const tris: u32 = if (m.loaded) |l| l.tri_total else 0;
    cb.textStyled(std.fmt.allocPrint(a, "{d} PARTS  {d} TRIS", .{ m.partCount(), tris }) catch "", mono, term_fg);
    cb.textStyled("|", mono, term_fg);
    if (m.loaded) |*l| {
        if (l.partById(m.selected)) |p| {
            cb.textStyled(std.fmt.allocPrint(a, "SEL {d:0>2} {s}", .{ p.index + 1, p.src }) catch "", mono, term_fg);
        } else cb.textStyled("SEL -", mono, term_fg);
        if (l.partById(m.hovered)) |p| {
            cb.textStyled("|", mono, term_fg);
            cb.textStyled(std.fmt.allocPrint(a, "HOVER {d:0>2} {s}", .{ p.index + 1, p.src }) catch "", mono, term_fg);
        }
    }
    cb.spacer(1);
    const deg = 180.0 / std.math.pi;
    cb.textStyled(std.fmt.allocPrint(a, "{s}  YAW {d:.0}  PITCH {d:.0}  DIST {s}", .{
        if (m.cam.projection == .ortho) "ORTHO" else "PERSP",
        m.cam.yaw * deg,
        m.cam.pitch * deg,
        kerf.fmtFtIn(a, m.cam.dist),
    }) catch "", mono, term_fg);
    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const test_msr = teak.monoMeasurer();

fn smallModel() Model {
    var m = Model.init();
    update(&m, .{ .load_fixture = 1 }); // flush-psl-2x6
    return m;
}

test "init: bundled fixture loads, camera frames it, mesh resource published" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    try testing.expectEqual(@as(u32, 24), m.partCount());
    // one mesh resource per part, keyed by part id, all at the document revision
    try testing.expectEqual(@as(usize, 24), resources(&m).len);
    for (resources(&m), 1..) |res, id| {
        try testing.expectEqual(@as(u32, @intCast(id)), res.mesh.key);
        try testing.expectEqual(m.rev, res.mesh.rev);
    }
    // the framed camera puts the model centre at the viewport centre
    const l = &m.loaded.?;
    const c = scene.mat.scale(scene.mat.add(l.lo, l.hi), 0.5);
    const s = scene.project(camera(&m), m.vp[0], m.vp[1], c).?;
    try testing.expectApproxEqAbs(m.vp[0] / 2, s[0], 0.5);
    try testing.expectApproxEqAbs(m.vp[1] / 2, s[1], 0.5);
    // the first effect is the `?mesh=` query
    try testing.expect(effects(&m)[0] == .query_param);
}

test "selecting and hovering change items only: no new revision, no geometry edit" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    const rev0 = m.rev;
    const verts_before = m.loaded.?.parts[2].mesh.vertices[0];
    update(&m, .{ .select = 3 });
    try testing.expectEqual(@as(u32, 3), m.selected);
    m.hovered = 5;
    try testing.expectEqual(rev0, m.rev);
    try testing.expectEqual(rev0, resources(&m)[2].mesh.rev);
    try testing.expect(std.meta.eql(verts_before, m.loaded.?.parts[2].mesh.vertices[0]));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const items = partItems(&m, arena.allocator());
    try testing.expectEqual(@as(usize, 10), items.len);
    for (items, 1..) |it, id| {
        try testing.expectEqual(@as(u32, @intCast(id)), it.mesh);
        try testing.expectEqual(@as(u32, @intCast(id)), it.id);
        try testing.expectEqual(id == 3, it.flags.highlight);
        try testing.expect(!it.flags.no_edges);
        try testing.expectEqual(id == 5, it.tint[0] > 1);
    }
    update(&m, .toggle_edges);
    try testing.expect(partItems(&m, arena.allocator())[0].flags.no_edges);
    try testing.expectEqual(rev0, m.rev);

    // out-of-range clears the selection; loading a document bumps the revision
    update(&m, .{ .select = 999 });
    try testing.expectEqual(@as(u32, 0), m.selected);
    update(&m, .{ .load_fixture = 0 });
    try testing.expect(m.rev != rev0);
    try testing.expectEqual(m.rev, resources(&m)[0].mesh.rev);
}

test "select_step wraps in both directions" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .select_step = 1 });
    try testing.expectEqual(@as(u32, 1), m.selected);
    update(&m, .{ .select_step = -1 });
    try testing.expectEqual(@as(u32, 10), m.selected);
    update(&m, .{ .select_step = 1 });
    try testing.expectEqual(@as(u32, 1), m.selected);
}

test "click picks the part under the cursor; a drag orbits instead" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .layout, .w = 900, .h = 600 } });
    try testing.expectEqual(@as(f32, 900), m.vp[0]);
    update(&m, .fit);

    // aim at a triangle centroid of part 2: project it, click there
    const l = &m.loaded.?;
    const pm = l.parts[1].mesh;
    const v0 = pm.vertices[pm.indices[0]].pos;
    const v1 = pm.vertices[pm.indices[1]].pos;
    const v2 = pm.vertices[pm.indices[2]].pos;
    const c = scene.mat.scale(scene.mat.add(scene.mat.add(v0, v1), v2), 1.0 / 3.0);
    const px = scene.project(camera(&m), 900, 600, c).?;
    const ev = teak.CanvasEvent{ .id = scene_id, .kind = .up, .button = .left, .x = px[0], .y = px[1], .w = 900, .h = 600 };
    update(&m, .{ .view_event = ev });
    try testing.expect(m.selected != 0); // some part is hit there (maybe an occluder)

    // empty space deselects
    var corner = ev;
    corner.x = 2;
    corner.y = 2;
    update(&m, .{ .view_event = corner });
    try testing.expectEqual(@as(u32, 0), m.selected);

    // a drag past the slop radius is not a click and moves the camera
    update(&m, .{ .select = 4 });
    const yaw = m.cam.yaw;
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .down, .button = .left, .buttons = .{ .left = true }, .x = px[0], .y = px[1], .w = 900, .h = 600 } });
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .move, .dx = 30, .dy = 0, .buttons = .{ .left = true }, .w = 900, .h = 600 } });
    update(&m, .{ .view_event = corner });
    try testing.expectEqual(@as(u32, 4), m.selected);
    try testing.expect(m.cam.yaw != yaw);
}

test "clicking a gizmo cap looks down that axis; elsewhere it still picks" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .layout, .w = 900, .h = 600 } });
    m.cam.setPreset(.front);
    // front view: the +x cap sits right of the gizmo centre (bottom-left corner)
    const layout: scene.pick.GizmoLayout = .{ .corner = .bottom_left, .size_px = gizmo_view.size_px, .margin_px = gizmo_view.margin_px };
    const tips = scene.pick.gizmoTips(m.cam, layout, 900, 600);
    const plus_x = tips[0];
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .up, .button = .left, .x = plus_x.x, .y = plus_x.y, .w = 900, .h = 600 } });
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), m.cam.yaw, 1e-4); // `right` preset
    try testing.expectEqual(@as(u32, 0), m.selected);
    // with the grid (and gizmo) off the same click is just a pick
    update(&m, .toggle_grid);
    m.cam.setPreset(.front);
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .up, .button = .left, .x = plus_x.x, .y = plus_x.y, .w = 900, .h = 600 } });
    try testing.expectEqual(@as(f32, 0), m.cam.yaw);
}

test "wheel zoom changes distance; presets and ortho toggle apply" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    const d = m.cam.dist;
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .wheel, .dy = -100, .x = 100, .y = 80, .w = 800, .h = 600 } });
    try testing.expect(m.cam.dist < d);
    update(&m, .{ .preset = .top });
    try testing.expect(m.cam.pitch > 1.5);
    update(&m, .toggle_ortho);
    try testing.expect(m.cam.projection == .ortho);
    update(&m, .toggle_edges);
    try testing.expect(!m.edges);
}

test "?mesh= selects a fixture, a URL becomes an http effect, errors keep the document" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    update(&m, .{ .mesh_param = "flush-psl-2x6.json" });
    try testing.expectEqualStrings("flush-psl-2x6", m.doc());
    try testing.expectEqual(@as(usize, 0), effects(&m).len);

    update(&m, .{ .mesh_param = "https://example.com/m/part.json" });
    try testing.expect(effects(&m)[0] == .http);
    try testing.expectEqualStrings("https://example.com/m/part.json", effects(&m)[0].http.url);
    update(&m, .{ .http_done = .{ .status = 404, .body = "", .err = "" } });
    try testing.expectEqual(@as(usize, 0), effects(&m).len);
    try testing.expect(std.mem.startsWith(u8, m.status(), "FETCH FAILED"));
    update(&m, .{ .http_done = .{ .status = 200, .body = kerf.small_fixture, .err = "" } });
    try testing.expectEqual(@as(u32, 10), m.partCount());

    update(&m, .{ .file_opened = .{ .name = "bad.json", .bytes = "{nope" } });
    try testing.expectEqual(@as(u32, 10), m.partCount());
    try testing.expect(std.mem.startsWith(u8, m.status(), "ERR bad.json"));

    update(&m, .open_file);
    try testing.expect(effects(&m)[0] == .open_file);
    update(&m, .open_file); // already in flight
    update(&m, .file_cancelled);
    try testing.expectEqual(@as(usize, 0), effects(&m).len);
}

test "effectMsg maps answers and drops" {
    const m = Model{};
    try testing.expect(effectMsg(&m, .{ .query_value = .{ .id = 1, .value = null } }).?.mesh_param == null);
    const f = effectMsg(&m, .{ .dropped = .{ .kind = .file, .name = "a.json", .bytes = "{}" } }).?;
    try testing.expectEqualStrings("a.json", f.file_opened.name);
    try testing.expect(effectMsg(&m, .{ .dropped = .{ .kind = .text, .bytes = "x" } }) == null);
}

test "scroll clamps and selection scrolls its row into view" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    update(&m, .{ .list_extent = .{ 200, 24 * row_height } });
    update(&m, .{ .list_scroll_by = 99999 });
    try testing.expectEqual(24 * row_height - 200, m.list_scroll);
    update(&m, .{ .select = 1 });
    try testing.expectEqual(@as(f32, 0), m.list_scroll);
    update(&m, .{ .select = 24 });
    try testing.expectEqual(24 * row_height - 200, m.list_scroll);
}

fn frameOf(m: *const Model, cb: *teak.CmdBuffer(Msg), rects: []teak.Rect, w: f32, h: f32) []const teak.Rect {
    cb.reset();
    cb.theme = theme;
    view(m, cb);
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, test_msr);
    return rects[0..cb.cmds.items.len];
}

test "view: balanced, one interactive scene3d, 340px inspector, 24px status bar" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .select = 2 });
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [512]teak.Rect = undefined;
    const rs = frameOf(&m, &cb, &rects, 1280, 800);
    try testing.expect(teak.validateBalance(cb.cmds.items) == null);
    var scenes: usize = 0;
    for (cb.cmds.items, rs) |c, r| switch (c) {
        .scene3d => |s| {
            scenes += 1;
            try testing.expect(s.pointer and s.id == scene_id);
            try testing.expectEqual(@as(usize, 10), s.view.items.len);
            try testing.expect(s.view.items[1].flags.highlight); // part 2 is selected
            try testing.expectEqual(m.rev, @as(u32, @intCast(s.key)));
            try testing.expect(r.w > 600 and r.h > 400); // flexes into the centre
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), scenes);
}

test "view: snapshot golden at a fixed model" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .layout, .w = 700, .h = 500 } });
    update(&m, .{ .select = 2 });
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [512]teak.Rect = undefined;
    const rs = frameOf(&m, &cb, &rects, 1280, 800);
    try teak.expectSnapshot(cb.cmds.items, rs, .{}, golden);
}

const golden =
    \\group (0,0,1280,800) vertical bg
    \\  group (0,0,1280,40) horizontal bg
    \\    text (12,10,56,20) "KERF"
    \\    group (80,13,24,14) horizontal
    \\      group (80,13,6,14) vertical bg
    \\      group (89,13,6,14) vertical bg
    \\      group (98,13,6,14) vertical bg
    \\    text (116,10,110,20) "MESH VIEWER"
    \\    text (238,10,180,20) "DOC: FLUSH-PSL-2X6"
    \\    group (430,20,380,0) vertical
    \\    button (822,7,174,26) "PALMER-SD1-LIKE"
    \\    button (1008,7,154,26) "FLUSH-PSL-2X6"
    \\    button (1174,7,94,26) "OPEN..."
    \\  group (0,40,1280,2) vertical bg
    \\  group (0,42,1280,734) horizontal
    \\    group (0,42,940,734) vertical bg
    \\      group (12,54,916,24) horizontal
    \\        button (12,54,86,24) "[FRONT]"
    \\        button (102,54,66,24) "[ISO]"
    \\        button (172,54,66,24) "[TOP]"
    \\        button (242,54,86,24) "[RIGHT]"
    \\        group (332,66,206,0) vertical
    \\        button (542,54,86,24) "[PERSP]"
    \\        button (632,54,116,24) "[EDGES ON]"
    \\        button (752,54,106,24) "[GRID ON]"
    \\        button (862,54,66,24) "[FIT]"
    \\      group (12,86,916,678) vertical bg border
    \\        scene3d (13,87,914,676) mesh=0 key=2 id=7 items=10 grid gizmo pointer "3D model viewport"
    \\    group (940,42,340,734) vertical bg border
    \\      group (952,54,316,20) horizontal
    \\        text (952,54,55,20) "PARTS"
    \\        text (1248,54,20,20) "10"
    \\      group (952,84,316,327) vertical border
    \\        group (953,85,314,26) horizontal bg
    \\          text (959,88,300,20) "NO  PART                  TRIS"
    \\        scroll (953,111,314,299) vertical id=8
    \\          button (953,111,314,22) "01  bottom_plate            12"
    \\          button (953,133,314,22) "02  beam                    12"
    \\          button (953,155,314,22) "03  jack_studs              12"
    \\          button (953,177,314,22) "04  jack_studs#1            12"
    \\          button (953,199,314,22) "05  lower_plate             12"
    \\          button (953,221,314,22) "06  upper_plate             12"
    \\          button (953,243,314,22) "07  king_stud               12"
    \\          button (953,265,314,22) "08  studs                   12"
    \\          button (953,287,314,22) "09  studs#1                 12"
    \\          button (953,309,314,22) "10  strap                   12"
    \\      group (952,421,316,229) vertical bg border
    \\        text (962,431,296,20) "DETAIL"
    \\        divider (962,457,296,1)
    \\        group (962,464,296,20) horizontal
    \\          text (962,464,40,20) "PART"
    \\          text (1188,464,70,20) "02 beam"
    \\        group (962,490,296,20) horizontal
    \\          text (962,490,80,20) "MATERIAL"
    \\          text (1108,490,150,20) "wood_engineered"
    \\        group (962,516,296,20) horizontal
    \\          text (962,516,90,20) "TRIANGLES"
    \\          text (1238,516,20,20) "12"
    \\        group (962,542,296,20) horizontal
    \\          text (962,542,50,20) "SHELL"
    \\          text (1198,542,60,20) "CLOSED"
    \\        group (962,568,296,20) horizontal
    \\          text (962,568,80,20) "WIDTH  X"
    \\          text (1208,568,50,20) "4'-0\""
    \\        group (962,594,296,20) horizontal
    \\          text (962,594,80,20) "HEIGHT Y"
    \\          text (1188,594,70,20) "11 7/8\""
    \\        group (962,620,296,20) horizontal
    \\          text (962,620,80,20) "DEPTH  Z"
    \\          text (1198,620,60,20) "5 1/4\""
    \\      group (952,660,316,104) vertical bg border
    \\        text (962,670,296,20) "NOTES"
    \\        divider (962,696,296,1)
    \\        text (962,703,296,20) "TEXT AREA PLACEHOLDER"
    \\        text (962,729,296,20) "(multi-line editor pending)"
    \\  group (0,776,1280,24) horizontal bg
    \\    text (12,778,55,20) "READY"
    \\    text (81,778,10,20) "|"
    \\    text (105,778,180,20) "10 PARTS  120 TRIS"
    \\    text (299,778,10,20) "|"
    \\    text (323,778,110,20) "SEL 02 beam"
    \\    group (447,788,397,0) vertical
    \\    text (858,778,410,20) "PERSP  YAW -36  PITCH 29  DIST 14'-4 1/4\""
    \\
;
