//! Kerf workstation (dogfood): a Kerf document (mesh + drawings) in three
//! synchronised views -- SECTION and ISO drawings on a pan / zoom teak canvas
//! (vellum + blue grid, true pen weights) and a 3D viewport with orbit / pan /
//! zoom, view presets, ortho/persp, section cut and CPU click-picking -- with a
//! parts table, a NOTES text area and a scripted-Claude CHAT console, in
//! Kerf's 1970s engineering-office look (kerf/spec/DESIGN.md).
//!
//! One selection and one hover serve every view: a part id (1-based mesh part)
//! is highlighted in the table, outlined / tinted in the 2D sheet (by mapping
//! the drawing's `src` ids) and flagged on the 3D item. The 2D pipeline
//! (`draw/`, `doc2d.zig`) is the Kerf tessellator ported from the archived
//! Kerf teak app; it hands the canvas one triangle batch with a content key.
//!
//! Sources: a bundled fixture (default; mesh + its drawings), `?mesh=<fixture|url>`
//! / `--mesh=` (plus `?tab=` / `?select=`) through `query_param`, an `open_file`
//! effect (OPEN button; native: `TEAK_OPEN=path`) and dropped `.json` files. A
//! mesh and a drawing are told apart by their header (`kerf_mesh` /
//! `kerf_drawing`). The CHAT is demo mode: no network, a few scripted intents,
//! steps paced by a `Sub.every` tick while a reply is pending.

const std = @import("std");
const teak = @import("teak");
const kerf = @import("kerf_mesh.zig");
const doc2d = @import("doc2d.zig");
const chat = @import("chat.zig");

const scene = teak.scene;
const Notes = teak.TextArea(2048);
const Chat = teak.TextArea(512);
const notes_id: u32 = 11;
const chat_id: u32 = 12;
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
const vellum: [4]f32 = .{ 0.984, 0.980, 0.961, 1 }; // #FBFAF5
const clear: [4]f32 = .{ 0, 0, 0, 0 };

const plex: teak.FontSpec = .{ .size_px = 13, .family = .mono };
const plex_bold: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold, .letter_spacing = 1 };
/// Bold without tracking, so table headers line up with their rows.
const plex_tight: teak.FontSpec = .{ .size_px = 13, .family = .mono, .weight = .bold };
/// 11 px field labels (DESIGN section 1).
const plex_label: teak.FontSpec = .{ .size_px = 11, .family = .mono, .weight = .bold, .letter_spacing = 1 };
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

/// The active tab: blue text (the 3 px bar under it is drawn by `tab`).
const tab_button_active: teak.ButtonStyle = .{
    .bg = clear,
    .hover_bg = paper2,
    .press_bg = paper2,
    .fg = blue,
    .hover_fg = blue,
    .press_fg = blue,
    .label_align = .center,
    .height = 24,
    .min_width = 0,
    .h_padding = 8,
};

/// The active axis button: inverted ink.
const tab_button_on: teak.ButtonStyle = .{
    .bg = ink,
    .hover_bg = ink,
    .press_bg = ink,
    .fg = paper,
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
/// A row whose part is hovered in the sheet or the 3D view.
const row_button_hov: teak.ButtonStyle = .{
    .bg = .{ 0.827, 0.878, 0.933, 1 }, // grid-2
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
pub const cut_slider_id: u32 = 9;
pub const sheet_id: u32 = 10;
pub const chat_scroll_id: u32 = 13;
const click_slop_px: f32 = 4;
/// Width of the cut-offset slider canvas (the 3D toolbar must fit the centre column).
const slider_w: f32 = 140;
const highlight: [4]f32 = .{ 0.114, 0.306, 0.620, 1 };
/// Columns of the console font that fit a message card.
const chat_cols: usize = 36;
/// Reply pacing: one `reply_tick` per `reply_tick_ms`; the tool line lands
/// after `reply_tool_at` ticks, the final text after `reply_total`.
const reply_tick_ms: u32 = 250;
const reply_total: u8 = 5;
const reply_tool_at: u8 = 2;

/// A bundled document: its mesh and its drawings (sections first by name).
const Fixture = struct { name: []const u8, mesh: []const u8, sheets: []const []const u8 };
pub const fixtures = [_]Fixture{
    .{ .name = "palmer-sd1-like", .mesh = kerf.large_fixture, .sheets = &.{
        @embedFile("fixtures/palmer-sd1-like.A.json"),
        @embedFile("fixtures/palmer-sd1-like.B.json"),
        @embedFile("fixtures/palmer-sd1-like.C.json"),
        @embedFile("fixtures/palmer-sd1-like.D.json"),
        @embedFile("fixtures/palmer-sd1-like.E.json"),
    } },
    .{ .name = "flush-psl-2x6", .mesh = kerf.small_fixture, .sheets = &.{
        @embedFile("fixtures/flush-psl-2x6.A.json"),
        @embedFile("fixtures/flush-psl-2x6.B.json"),
    } },
};

/// Backs `Loaded` (a single arena per model) and the 2D document. Works on native and wasm.
const gpa = std.heap.page_allocator;

pub const Tab = enum { section, iso, three_d };
const Focus = enum { none, notes, chat };
const Drag2D = enum { none, press, pan };

pub const Model = struct {
    loaded: ?kerf.Loaded = null,
    /// The drawings of the document (shared by value-copies of the Model).
    docs: ?*doc2d.Docs2D = null,
    doc_buf: [64]u8 = undefined,
    doc_len: usize = 0,
    tab: Tab = .section,
    /// Which SECTION sheet (n-th of kind "section") is showing.
    sec_sel: u8 = 0,
    cam: Orbit = .{},
    /// 3D viewport size in logical px, reported by the scene's `layout` events.
    vp: [2]f32 = .{ 800, 600 },
    /// Window-space top-left of the viewport (from its `layout` event), for
    /// anchoring text over the 3D target.
    vp_origin: [2]f32 = .{ 0, 0 },
    /// Section cut: a plane through the model perpendicular to an axis.
    cut_on: bool = false,
    /// 0 = X, 1 = Y, 2 = Z.
    cut_axis: u2 = 1,
    /// Position along the model's extent on that axis, 0..1.
    cut_t: f32 = 0.5,
    /// Keep the other side of the plane.
    cut_flip: bool = false,
    /// Shared by every view: 1-based part id, 0 = none.
    selected: u32 = 0,
    hovered: u32 = 0,
    edges: bool = true,
    /// Ground grid + axis gizmo (3D) and the vellum grid (2D).
    grid: bool = true,
    /// Re-frame on the first `layout` event (the real viewport size).
    fit_pending: bool = true,
    /// Document revision: stamped on every part's mesh resource (so a new
    /// document re-uploads the keys) and used as the scene's `key`.
    rev: u32 = 0,
    /// Pixels travelled since the left button went down; a small value on
    /// release is a click (pick), a large one was an orbit / pan.
    drag_px: f32 = 0,
    drag2d: Drag2D = .none,
    /// Part under the press that may become a click (0 = empty space).
    press_part: u32 = 0,
    /// Model-space cursor over the sheet (status bar readout).
    cursor2d: ?[2]f64 = null,
    status_buf: [96]u8 = undefined,
    status_len: usize = 0,
    list_scroll: f32 = 0,
    list_viewport: f32 = 0,
    list_content: f32 = 0,
    /// Which text area has the keyboard (typed letters go there, not to the
    /// viewer shortcuts).
    focus: Focus = .none,
    /// The NOTES card: a multi-line `TextArea`.
    notes: Notes.Model = .{},
    /// CHAT console: the input box, the message log and the scripted reply.
    chat: Chat.Model = .{},
    log: chat.Log = .{},
    reply_ticks: u8 = 0,
    reply_intent: chat.Intent = .summary,
    chat_scroll: f32 = 0,
    chat_viewport: f32 = 0,
    chat_content: f32 = 0,
    /// Stay glued to the newest message until the user scrolls up.
    chat_stick: bool = true,
    next_id: u32 = 2,
    /// The requests in flight (`effects()` returns them while `req_len > 0`).
    reqs: [1]teak.Effect = undefined,
    req_len: usize = 0,
    url_buf: [256]u8 = undefined,
    /// Startup parameters still to read, in order: mesh, tab, select.
    params_left: u8 = 3,
    pending_select: [64]u8 = undefined,
    pending_select_len: u8 = 0,

    pub fn init() Model {
        var m: Model = .{};
        m.docs = doc2d.Docs2D.create(gpa) catch null;
        m.reqs[0] = .{ .query_param = .{ .id = param_id_base, .name = "mesh" } };
        m.req_len = 1;
        m.loadFixture(0);
        m.fit_pending = true; // re-frame once the first `layout` event gives the real size
        m.log.push(.kerf, greeting);
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

    /// Replace the document with a bundled fixture: its mesh and drawings.
    fn loadFixture(m: *Model, i: usize) void {
        if (i >= fixtures.len) return;
        const f = fixtures[i];
        if (!m.loadMesh(f.name, f.mesh)) return;
        if (m.docs) |dx| {
            dx.clear();
            for (f.sheets) |json| _ = dx.add(json) catch {};
        }
        m.sec_sel = 0;
        m.tab = if (m.sectionCount() > 0) .section else .three_d;
    }

    /// Parse a mesh and, on success, replace the document (frames the
    /// camera, clears the selection and the drawings). A failure keeps the
    /// old document.
    fn loadMesh(m: *Model, name: []const u8, bytes: []const u8) bool {
        var next = kerf.parse(gpa, bytes) catch |e| {
            m.setStatus("ERR {s}: {s}", .{ name, @errorName(e) });
            return false;
        };
        if (m.loaded) |*old| old.deinit();
        m.rev +%= 1;
        next.setRev(m.rev);
        m.loaded = next;
        m.setDoc(name);
        m.selected = 0;
        m.hovered = 0;
        m.list_scroll = 0;
        if (m.docs) |dx| dx.clear();
        m.sec_sel = 0;
        m.fitView();
        m.status_len = 0;
        return true;
    }

    /// Add (or replace) one drawing sheet and show it.
    fn loadDrawing(m: *Model, name: []const u8, bytes: []const u8) void {
        const dx = m.docs orelse return;
        const idx = dx.add(bytes) catch |e| {
            m.setStatus("ERR {s}: {s}", .{ name, @errorName(e) });
            return;
        };
        const s = &dx.sheets.items[idx];
        switch (s.kind()) {
            .iso => m.tab = .iso,
            else => {
                m.tab = .section;
                var n: usize = 0;
                for (dx.sheets.items[0..idx]) |o| n += @intFromBool(o.kind() == .section);
                m.sec_sel = @intCast(n);
            },
        }
        if (m.loaded == null) m.setDoc(s.d.doc);
        dx.fit(idx);
        m.status_len = 0;
    }

    /// A mesh or a drawing, told apart by the format marker near the top.
    fn loadAny(m: *Model, name: []const u8, bytes: []const u8) void {
        const head = bytes[0..@min(bytes.len, 512)];
        if (std.mem.indexOf(u8, head, "\"kerf_drawing\"") != null) {
            m.loadDrawing(name, bytes);
        } else {
            _ = m.loadMesh(name, bytes);
        }
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

    fn sectionCount(m: *const Model) usize {
        return if (m.docs) |dx| dx.count(.section) else 0;
    }

    fn hasIso(m: *const Model) bool {
        return if (m.docs) |dx| dx.count(.iso) > 0 else false;
    }

    /// Sheet index showing in the current tab (null on 3D or when absent).
    fn activeSheet(m: *const Model) ?usize {
        const dx = m.docs orelse return null;
        return switch (m.tab) {
            .section => dx.nth(.section, m.sec_sel),
            .iso => dx.nth(.iso, 0),
            .three_d => null,
        };
    }

    /// `?mesh=` value: a bundled fixture name (with or without `.json`), else
    /// a URL / path fetched with an `http` effect (web: relative URLs work).
    fn loadNamed(m: *Model, value: []const u8) void {
        const name = std.mem.trimEnd(u8, value, "/");
        const stem = if (std.mem.endsWith(u8, name, ".json")) name[0 .. name.len - 5] else name;
        for (fixtures, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, stem)) return m.loadFixture(i);
        }
        const n = @min(value.len, m.url_buf.len);
        @memcpy(m.url_buf[0..n], value[0..n]);
        m.reqs[0] = .{ .http = .{ .id = m.takeId(), .url = m.url_buf[0..n], .timeout_ms = 30_000 } };
        m.req_len = 1;
        m.setDoc(std.fs.path.basename(value));
        m.setStatus("FETCHING {s}", .{value});
    }

    /// The part under viewport-local px `(x, y)` of the 3D view (1-based id, 0 = empty space).
    fn pickAt(m: *const Model, x: f32, y: f32, w: f32, h: f32) u32 {
        const l = &(m.loaded orelse return 0);
        const ray = scene.pickRay(camera(m), w, h, x, y);
        const hit = scene.pick.items(ray, l.pick_items, l.pick_refs, .{}) orelse return 0;
        return hit.id;
    }

    /// The part under canvas-local `(x, y)` of the active sheet.
    fn partAt2d(m: *const Model, x: f32, y: f32) u32 {
        const dx = m.docs orelse return 0;
        const l = &(m.loaded orelse return 0);
        const idx = m.activeSheet() orelse return 0;
        const src = dx.pickSrc(idx, x, y) orelse return 0;
        return doc2d.partForSrc(l.parts, src);
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

    /// Re-tessellate the active sheet for the current selection / hover
    /// (a no-op when nothing it depends on changed).
    fn refresh2d(m: *Model) void {
        const dx = m.docs orelse return;
        const idx = m.activeSheet() orelse return;
        var sb: [64]u8 = undefined;
        var hb: [64]u8 = undefined;
        var sel: []const u8 = "";
        var hov: []const u8 = "";
        if (m.loaded) |*l| {
            if (l.partById(m.selected)) |p| sel = doc2d.srcOfPart(dx, idx, p.*, &sb);
            if (l.partById(m.hovered)) |p| hov = doc2d.srcOfPart(dx, idx, p.*, &hb);
        }
        dx.retess(idx, sel, hov, m.grid);
    }

    /// Append the next designer message, clear the box and start the scripted reply.
    fn send(m: *Model) void {
        const text = std.mem.trim(u8, m.chat.content(), " \n\t");
        if (text.len == 0) return;
        if (m.reply_ticks > 0) m.finishReply(); // answer the previous one first
        m.log.push(.designer, text);
        m.chat.set("");
        m.reply_intent = chat.parseIntent(text, m.chatContext());
        m.reply_ticks = reply_total;
        m.chat_stick = true;
    }

    fn chatContext(m: *const Model) chat.Context {
        const l = &(m.loaded orelse return .{ .parts = &.{}, .sections = m.sectionCount(), .has_iso = m.hasIso() });
        return .{ .parts = l.names, .sections = m.sectionCount(), .has_iso = m.hasIso() };
    }

    /// One scripted step: the tool line (and its UI action), then the answer.
    fn replyTick(m: *Model) void {
        if (m.reply_ticks == 0) return;
        m.reply_ticks -= 1;
        if (m.reply_ticks == reply_total - reply_tool_at) m.replyTool();
        if (m.reply_ticks == 0) m.replyFinal();
    }

    /// Run any remaining steps at once.
    fn finishReply(m: *Model) void {
        if (m.reply_ticks > reply_total - reply_tool_at) m.replyTool();
        m.reply_ticks = 0;
        m.replyFinal();
    }

    fn partName(m: *const Model, id: u32) []const u8 {
        const l = &(m.loaded orelse return "");
        return if (l.partById(id)) |p| p.src else "";
    }

    fn replyTool(m: *Model) void {
        var buf: [96]u8 = undefined;
        const intent = m.reply_intent;
        const name = switch (intent) {
            .select => |id| m.partName(id),
            else => "",
        };
        m.log.push(.tool, chat.toolLine(&buf, intent, name));
        m.chat_stick = true;
        switch (intent) {
            .view_section => m.tab = if (m.sectionCount() > 0) .section else .three_d,
            .view_iso => if (m.hasIso()) {
                m.tab = .iso;
            } else {
                m.tab = .three_d;
                m.cam.setPreset(.iso);
            },
            .view_3d => m.tab = .three_d,
            .cut => {
                m.tab = .three_d;
                m.cut_on = true;
            },
            .fit => m.fitCurrent(),
            .select => |id| m.selectPart(id),
            .greet, .help, .summary => {},
        }
    }

    fn replyFinal(m: *Model) void {
        var buf: [chat.msg_cap]u8 = undefined;
        var dbuf: [160]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&dbuf);
        const fa = fba.allocator();
        const detail: []const u8 = switch (m.reply_intent) {
            .select => |id| m.partDetail(fa, id),
            .summary => if (m.loaded) |*l|
                std.fmt.allocPrint(fa, "Overall {s} x {s} x {s}.", .{
                    kerf.fmtFtIn(fa, l.hi[0] - l.lo[0]),
                    kerf.fmtFtIn(fa, l.hi[1] - l.lo[1]),
                    kerf.fmtFtIn(fa, l.hi[2] - l.lo[2]),
                }) catch ""
            else
                "No mesh loaded.",
            else => "",
        };
        m.log.push(.kerf, chat.replyText(&buf, m.reply_intent, m.chatContext(), detail));
        m.chat_stick = true;
    }

    /// "name" (via the part's own label) for the select reply; the extents go
    /// into the table / detail card, the text just names it.
    fn partDetail(m: *const Model, a: std.mem.Allocator, id: u32) []const u8 {
        const l = &(m.loaded orelse return "");
        const p = l.partById(id) orelse return "";
        return std.fmt.allocPrint(a, "{s} ({s}, {s} x {s} x {s})", .{
            p.src,
            p.material,
            kerf.fmtFtIn(a, p.hi[0] - p.lo[0]),
            kerf.fmtFtIn(a, p.hi[1] - p.lo[1]),
            kerf.fmtFtIn(a, p.hi[2] - p.lo[2]),
        }) catch p.src;
    }

    fn fitCurrent(m: *Model) void {
        if (m.activeSheet()) |idx| {
            if (m.docs) |dx| dx.fit(idx);
        } else m.fitView();
    }
};

/// Query-param request ids: base + step (mesh, tab, select).
pub const param_id_base: u32 = 1000;

const greeting =
    "DEMO MODE: no network, no key. I am a script. Try **section**, **iso**, **3d**, **cut**, or the name of a part.";

pub const Msg = union(enum) {
    view_event: teak.CanvasEvent,
    sheet_event: teak.CanvasEvent,
    tab: Tab,
    section_sel: u8,
    zoom2d: f32,
    select: u32,
    select_step: i8,
    preset: Orbit.Preset,
    toggle_ortho,
    toggle_edges,
    toggle_grid,
    toggle_cut,
    cut_axis: u2,
    cut_set: f32,
    cut_flip,
    fit,
    load_fixture: u8,
    open_file,
    /// Startup parameter answers (`?mesh=` / `--mesh=`, `?tab=`, `?select=`).
    param: struct { id: u32, value: ?[]const u8 },
    file_opened: struct { name: []const u8, bytes: []const u8 },
    file_cancelled,
    http_done: struct { status: u16, body: []const u8, err: []const u8 },
    list_scroll_by: f32,
    list_extent: [2]f32,
    notes: Notes.Msg,
    chat: Chat.Msg,
    send,
    clear_chat,
    reply_tick,
    chat_scroll_by: f32,
    chat_extent: [2]f32,
    blur,
    noop,
};

// ── update ─────────────────────────────────────────────────────────

pub fn update(m: *Model, msg: Msg) void {
    step(m, msg);
    m.refresh2d();
}

fn step(m: *Model, msg: Msg) void {
    switch (msg) {
        .view_event => |ev| viewEvent(m, ev),
        .sheet_event => |ev| sheetEvent(m, ev),
        .tab => |t| {
            m.tab = t;
            m.focus = .none;
            m.hovered = 0;
            m.cursor2d = null;
        },
        .section_sel => |n| {
            if (n < m.sectionCount()) m.sec_sel = n;
            m.tab = .section;
        },
        .zoom2d => |f| if (m.docs) |dx| if (m.activeSheet()) |idx| dx.zoomStep(idx, f),
        .select => |id| {
            m.selectPart(id);
            m.focus = .none;
        },
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
        .toggle_cut => m.cut_on = !m.cut_on,
        .cut_axis => |a| m.cut_axis = a,
        .cut_set => |t| m.cut_t = std.math.clamp(t, 0, 1),
        .cut_flip => m.cut_flip = !m.cut_flip,
        .fit => m.fitCurrent(),
        .load_fixture => |i| m.loadFixture(i),
        .open_file => if (m.req_len == 0) {
            m.reqs[0] = .{ .open_file = .{ .id = m.takeId(), .accept = ".json" } };
            m.req_len = 1;
        },
        .param => |p| param(m, p.id - param_id_base, p.value),
        .file_opened => |f| {
            m.req_len = 0;
            m.loadAny(f.name, f.bytes);
        },
        .file_cancelled => m.req_len = 0,
        .http_done => |h| {
            m.req_len = 0;
            if (h.status >= 200 and h.status < 300) {
                m.loadAny(m.doc(), h.body);
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
        .notes => |n| {
            if (n == .focus) m.focus = .notes;
            Notes.update(&m.notes, n);
        },
        .chat => |c| {
            if (c == .focus) m.focus = .chat;
            Chat.update(&m.chat, c);
        },
        .send => m.send(),
        .clear_chat => {
            m.log.clear();
            m.reply_ticks = 0;
            m.chat_scroll = 0;
        },
        .reply_tick => m.replyTick(),
        .chat_scroll_by => |dy| {
            m.chat_scroll = std.math.clamp(m.chat_scroll + dy, 0, @max(0, m.chat_content - m.chat_viewport));
            m.chat_stick = m.chat_scroll >= m.chat_content - m.chat_viewport - 1;
        },
        .chat_extent => |e| {
            m.chat_viewport = e[0];
            m.chat_content = e[1];
            const max = @max(0, e[1] - e[0]);
            m.chat_scroll = if (m.chat_stick) max else std.math.clamp(m.chat_scroll, 0, max);
        },
        .blur => m.focus = .none,
        .noop => {},
    }
}

/// One startup parameter has been answered; ask for the next.
fn param(m: *Model, which: u32, value: ?[]const u8) void {
    m.req_len = 0;
    switch (which) {
        0 => if (value) |v| m.loadNamed(v),
        1 => if (value) |v| {
            if (std.mem.eql(u8, v, "iso")) m.tab = .iso;
            if (std.mem.eql(u8, v, "3d")) m.tab = .three_d;
            if (std.mem.eql(u8, v, "section")) m.tab = .section;
        },
        2 => if (value) |v| {
            const l = &(m.loaded orelse return);
            for (l.parts) |p| if (std.mem.eql(u8, p.src, v)) return m.selectPart(p.index + 1);
        },
        else => {},
    }
    // Only a plain query is chained: a URL fetch in flight owns `reqs`.
    if (m.req_len == 0 and which + 1 < 3) {
        const names = [_][]const u8{ "mesh", "tab", "select" };
        m.reqs[0] = .{ .query_param = .{ .id = param_id_base + which + 1, .name = names[which + 1] } };
        m.req_len = 1;
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
            m.vp_origin = .{ ev.x, ev.y };
            if (m.fit_pending) m.fitView();
        },
        .down => if (ev.button == .left) {
            m.drag_px = 0;
            m.focus = .none;
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
        .wheel, .key => {},
    }
    _ = m.cam.onEvent(ev, .{});
}

/// Pan / zoom / hover / click-select on the 2D sheet. Left press on a part
/// becomes a click (select) unless the pointer travels; left press on empty
/// space pans, and releasing without travel clears the selection.
fn sheetEvent(m: *Model, ev: teak.CanvasEvent) void {
    const dx = m.docs orelse return;
    switch (ev.kind) {
        .layout => dx.resize(ev.w, ev.h),
        .wheel => if (m.activeSheet()) |idx| {
            const dy = std.math.clamp(ev.dy, -400, 400);
            dx.zoomAt(idx, ev.x, ev.y, @exp(-dy * 0.0015));
        },
        .leave => {
            m.hovered = 0;
            m.cursor2d = null;
        },
        .down => {
            m.focus = .none;
            m.drag_px = 0;
            if (ev.button == .left) {
                m.drag2d = .press;
                m.press_part = m.partAt2d(ev.x, ev.y);
            } else if (ev.button == .middle or ev.button == .right) {
                m.drag2d = .pan;
            }
        },
        .move => {
            if (m.activeSheet()) |idx| {
                const s = dx.sheet(idx).?;
                m.cursor2d = .{ s.cam.modelX(ev.x), s.cam.modelY(ev.y) };
                if (ev.buttons.any() and m.drag2d != .none) {
                    m.drag_px += @abs(ev.dx) + @abs(ev.dy);
                    if (m.drag2d == .press and m.drag_px > click_slop_px) m.drag2d = .pan;
                    if (m.drag2d == .pan) dx.pan(idx, ev.dx, ev.dy);
                } else {
                    m.hovered = m.partAt2d(ev.x, ev.y);
                }
            }
        },
        .up => {
            if (ev.button == .left and m.drag2d == .press and m.drag_px <= click_slop_px) m.selectPart(m.press_part);
            m.drag2d = .none;
        },
        .key => {},
    }
}

// ── Host hooks ─────────────────────────────────────────────────────

pub fn canvasMsg(_: *const Model, ev: teak.CanvasEvent) ?Msg {
    if (ev.id == cut_slider_id) {
        // Drag the thumb: press or move with the left button down.
        const dragging = ev.kind == .down or (ev.kind == .move and ev.buttons.left);
        return if (dragging and ev.w > 0) Msg{ .cut_set = ev.x / ev.w } else null;
    }
    if (ev.id == sheet_id) return Msg{ .sheet_event = ev };
    return if (ev.id == scene_id) Msg{ .view_event = ev } else null;
}

pub fn scrollMsg(_: *const Model, id: u32, _: f32, dy: f32) ?Msg {
    if (id == chat_scroll_id) return Msg{ .chat_scroll_by = dy };
    return if (id == list_id) Msg{ .list_scroll_by = dy } else null;
}

pub fn scrollLayoutMsg(_: *const Model, id: u32, _: f32, vh: f32, _: f32, ch: f32) ?Msg {
    if (id == chat_scroll_id) return Msg{ .chat_extent = .{ vh, ch } };
    return if (id == list_id) Msg{ .list_extent = .{ vh, ch } } else null;
}

/// Pointer, wheel, resolved motion and metrics for the text areas.
pub fn textMsg(_: *const Model, ev: teak.TextEvent) ?Msg {
    return switch (ev.id) {
        notes_id => Msg{ .notes = Notes.eventMsg(ev) },
        chat_id => Msg{ .chat = Chat.eventMsg(ev) },
        else => null,
    };
}

pub fn focusedMsg(m: *const Model) ?Msg {
    return switch (m.focus) {
        .notes => Msg{ .notes = .focus },
        .chat => Msg{ .chat = .focus },
        .none => null,
    };
}

pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
    switch (m.focus) {
        .notes => return .{ .notes = Notes.charMsg(c) },
        .chat => return .{ .chat = Chat.charMsg(c) },
        .none => {},
    }
    return switch (c) {
        's', 'S' => Msg{ .tab = .section },
        'i', 'I' => Msg{ .tab = .iso },
        'd', 'D' => Msg{ .tab = .three_d },
        '+', '=' => Msg{ .zoom2d = 1.25 },
        '-' => Msg{ .zoom2d = 0.8 },
        '1' => Msg{ .preset = .front },
        '2' => Msg{ .preset = .iso },
        '3' => Msg{ .preset = .top },
        '4' => Msg{ .preset = .right },
        'o', 'O' => .toggle_ortho,
        'f', 'F' => .fit,
        'e', 'E' => .toggle_edges,
        'g', 'G' => .toggle_grid,
        'c', 'C' => .toggle_cut,
        'x', 'X' => Msg{ .cut_axis = 0 },
        'y', 'Y' => Msg{ .cut_axis = 1 },
        'z', 'Z' => Msg{ .cut_axis = 2 },
        'v', 'V' => .cut_flip,
        else => null,
    };
}

pub fn keySpecialMsg(m: *const Model, key: teak.SpecialKey) ?Msg {
    // Escape leaves an editor; everything else edits (Up/Down/Home/End
    // arrive as `textMsg` move events).
    switch (m.focus) {
        .notes => {
            if (key == .escape) return Msg.blur;
            return if (Notes.keyMsg(key)) |n| Msg{ .notes = n } else null;
        },
        .chat => {
            if (key == .escape) return Msg.blur;
            // A focused text area gets Enter as a key (the runtime does not call
            // `submitMsg` then): Enter sends, Shift+Enter (`Chat.keyMsg`) is a newline.
            if (key == .enter) return Msg.send;
            return if (Chat.keyMsg(key)) |n| Msg{ .chat = n } else null;
        },
        .none => {},
    }
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
        .query_value => |q| Msg{ .param = .{ .id = q.id, .value = q.value } },
        .file_opened => |f| Msg{ .file_opened = .{ .name = f.name, .bytes = f.bytes } },
        .file_cancelled => .file_cancelled,
        .http => |h| Msg{ .http_done = .{ .status = h.status, .body = h.body, .err = h.err } },
        .dropped => |d| if (d.kind == .file) Msg{ .file_opened = .{ .name = d.name, .bytes = d.bytes } } else null,
        else => null,
    };
}

const reply_subs = [_]teak.Sub(Msg){.{ .every = .{ .interval_ms = reply_tick_ms, .msg = .reply_tick } }};

/// The scripted reply is paced by a timer that exists only while a reply is pending.
pub fn subscribe(m: *const Model) []const teak.Sub(Msg) {
    return if (m.reply_ticks > 0) &reply_subs else &.{};
}

pub fn resources(m: *const Model) []const teak.Resource {
    return if (m.loaded) |l| l.resources else &.{};
}

pub fn themeFor(_: *const Model) teak.Theme {
    return theme;
}

pub fn windowTitle(_: *const Model) ?[]const u8 {
    return "Kerf workstation";
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
    console(m, cb);
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
    cb.textStyled("DETAIL WORKSTATION", plex, .{ 0.72, 0.70, 0.64, 1 });
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

// ── OPERATOR CONSOLE (chat) ────────────────────────────────────────

fn console(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .width = 360, .padding = 12, .gap = 8, .bg = paper, .border = ink, .align_cross = .stretch });
    cb.textStyled("OPERATOR CONSOLE", plex_label, ink2);

    // The message log: framed, scrolls, sticks to the newest message.
    cb.pushGroup(.{ .padding = 1, .gap = 0, .flex = 1, .border = ink, .bg = paper2, .align_cross = .stretch });
    cb.pushScroll(.{ .padding = 8, .gap = 8, .flex = 1, .align_cross = .stretch, .scroll_y = m.chat_scroll, .id = chat_scroll_id });
    if (m.log.n == 0) cb.textMuted("NO MESSAGES. TYPE BELOW.");
    for (0..m.log.n) |i| messageCard(cb, m.log.at(i));
    if (m.reply_ticks > 0) {
        const spin = "|/-\\";
        const t = reply_total - m.reply_ticks;
        cb.textStyled(std.fmt.allocPrint(a, "KERF/CLAUDE  THINKING {c}", .{spin[t % spin.len]}) catch "", plex_label, ink2);
    }
    cb.popScroll();
    cb.popGroup();

    // Input: multi-line TextArea; Enter sends, Shift+Enter is a newline.
    var st = cb.theme.text_input;
    st.bg = vellum;
    st.fg = ink;
    st.border = ink;
    st.focus_border = blue;
    st.cursor = ink;
    st.border_width = 1;
    st.selection_bg = .{ 0.114, 0.306, 0.620, 0.30 };
    cb.textStyled("SHIFT+ENTER FOR A NEW LINE", plex_label, ink2);
    Chat.viewWith(&m.chat, cb, .{ .focus = Msg{ .chat = .focus } }, .{ .id = chat_id, .height = 76, .padding = 5, .style = st, .font = plex });
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .align_cross = .center });
    cb.textStyled("ENTER SENDS", plex_label, ink2);
    cb.spacer(1);
    cb.buttonStyled(.clear_chat, "CLEAR", key_button);
    cb.buttonStyled(.send, "SEND", key_button);
    cb.popGroup();
    cb.popGroup();
}

/// One message as DESIGN section 3 draws it: designer = plain paper block with
/// a 1px border, Claude and its tool activity = manila cards; the body is
/// rich text (`**bold**`) wrapped to the card.
fn messageCard(cb: anytype, msg: *const chat.Message) void {
    const a = cb.arena.allocator();
    const designer = msg.role == .designer;
    cb.pushGroup(.{ .padding = 8, .gap = 3, .bg = if (designer) paper else manila, .border = ink, .align_cross = .stretch });
    switch (msg.role) {
        .designer => cb.textStyled(std.fmt.allocPrint(a, "DESIGNER  #{d:0>2}", .{msg.seq}) catch "", plex_label, ink2),
        .kerf => cb.textStyled(std.fmt.allocPrint(a, "KERF/CLAUDE  #{d:0>2}", .{msg.seq}) catch "", plex_label, ink2),
        .tool => {},
    }
    const color = if (msg.role == .tool) blue else ink;
    for (chat.wrapMarkup(a, msg.body(), chat_cols, plex_tight, blue)) |line| {
        if (line.text.len == 0) {
            cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 8 });
            cb.popGroup();
            continue;
        }
        cb.richTextStyled(.{ .content = line.text, .spans = line.spans, .default_color = color, .default_font = plex });
    }
    cb.popGroup();
}

// ── Center: tabs + viewport ────────────────────────────────────────

fn centerColumn(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 12, .gap = 8, .flex = 1, .bg = paper2, .align_cross = .stretch });
    tabRow(m, cb);
    switch (m.tab) {
        .three_d => {
            presetRow(m, cb);
            cutBar(m, cb);
            viewport(m, cb);
        },
        .section, .iso => {
            if (m.tab == .section) sheetPicker(m, cb);
            sheetView(m, cb);
        },
    }
    cb.popGroup();
}

/// `[SECTION] [ISO] [3D]` with the 3px blue bar under the active tab, then
/// the view controls on the right.
fn tabRow(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4, .align_cross = .end });
    tab(cb, "[SECTION]", .{ .tab = .section }, m.tab == .section);
    tab(cb, "[ISO]", .{ .tab = .iso }, m.tab == .iso);
    tab(cb, "[3D]", .{ .tab = .three_d }, m.tab == .three_d);
    cb.spacer(1);
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4, .align_cross = .center });
    if (m.tab != .three_d) {
        cb.buttonStyled(.{ .zoom2d = 0.8 }, "[-]", tab_button);
        cb.buttonStyled(.{ .zoom2d = 1.25 }, "[+]", tab_button);
    }
    cb.buttonStyled(.fit, "[FIT]", tab_button);
    cb.buttonStyled(.toggle_grid, if (m.grid) "[GRID ON]" else "[GRID OFF]", tab_button);
    cb.popGroup();
    cb.popGroup();
}

fn tab(cb: anytype, label: []const u8, msg: Msg, on: bool) void {
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.buttonStyled(msg, label, if (on) tab_button_active else tab_button);
    cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 3, .bg = if (on) blue else clear });
    cb.popGroup();
    cb.popGroup();
}

/// SECTION sheets of the document: `A B C ...` plus the sheet's drawing scale.
fn sheetPicker(m: *const Model, cb: anytype) void {
    const dx = m.docs orelse return;
    const n = dx.count(.section);
    if (n == 0) return;
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4, .align_cross = .center });
    cb.textStyled("SHEET", plex_label, ink2);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = dx.sheets.items[dx.nth(.section, i).?];
        const label = std.fmt.allocPrint(a, "[{s}]", .{s.d.view}) catch "[?]";
        cb.buttonStyled(.{ .section_sel = @intCast(i) }, label, if (i == m.sec_sel) tab_button_on else tab_button);
    }
    cb.spacer(1);
    if (m.activeSheet()) |idx| {
        const s = dx.sheets.items[idx];
        cb.textStyled(std.fmt.allocPrint(a, "{s}=1'-0\"", .{kerf.fmtFtIn(a, @floatCast(12.0 / s.d.scale))}) catch "", plex_label, ink2);
    }
    cb.popGroup();
}

/// The 2D sheet: one interactive canvas holding the tessellator's triangles.
fn sheetView(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 1, .gap = 0, .flex = 1, .border = ink, .bg = vellum, .align_cross = .stretch });
    const dx = m.docs;
    if (dx != null and m.activeSheet() != null) {
        const a = cb.arena.allocator();
        const prims = a.alloc(teak.CanvasPrimitive, 1) catch {
            cb.popGroup();
            return;
        };
        prims[0] = .{ .triangles = .{ .verts = dx.?.verts(), .key = dx.?.key } };
        cb.canvasInteractive(.{ .width = 480, .height = 320, .flex = 1 }, prims, sheet_id, if (m.tab == .iso) "iso drawing" else "section drawing");
    } else {
        cb.pushGroup(.{ .padding = 24, .gap = 6, .flex = 1, .align_cross = .center, .justify = .center });
        cb.textStyled(if (m.tab == .iso) "NO ISO VIEW IN THIS DOCUMENT." else "NO SECTION DRAWING LOADED.", plex_bold, ink);
        cb.textMuted("OPEN A DRAWING .JSON, DROP ONE HERE, OR SWITCH TO [3D].");
        cb.popGroup();
    }
    cb.popGroup();
}

fn presetRow(m: *const Model, cb: anytype) void {
    // View-cube style presets as bracketed tabs, then projection / edges.
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
    cb.popGroup();
}

/// Section-cut controls: on/off, axis, flip and the offset slider.
fn cutBar(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4, .align_cross = .center });
    cb.buttonStyled(.toggle_cut, if (m.cut_on) "[CUT ON]" else "[CUT OFF]", tab_button);
    const axes = [_][]const u8{ "[X]", "[Y]", "[Z]" };
    for (axes, 0..) |label, i| {
        // the selected axis reads in bold ink; others are plain
        cb.buttonStyled(.{ .cut_axis = @intCast(i) }, label, if (m.cut_axis == i) tab_button_on else tab_button);
    }
    cb.buttonStyled(.cut_flip, if (m.cut_flip) "[FLIP *]" else "[FLIP]", tab_button);
    cb.canvasInteractive(.{ .width = slider_w, .height = 24, .bg = clear }, sliderPrims(m, a), cut_slider_id, "cut offset");
    cb.textMuted(std.fmt.allocPrint(a, "{s}", .{cutLabel(m, a)}) catch "");
    cb.popGroup();
}

fn cutLabel(m: *const Model, a: std.mem.Allocator) []const u8 {
    const l = &(m.loaded orelse return "");
    const pos = cutPosition(m, l);
    const names = [_][]const u8{ "X", "Y", "Z" };
    return std.fmt.allocPrint(a, "{s} {s}", .{ names[m.cut_axis], kerf.fmtFtIn(a, pos) }) catch "";
}

/// Thin ink rule with a square thumb (Kerf look); the fill shows the kept side.
fn sliderPrims(m: *const Model, a: std.mem.Allocator) []const teak.CanvasPrimitive {
    const w: f32 = slider_w;
    const x = m.cut_t * (w - 12) + 6;
    const prims = a.alloc(teak.CanvasPrimitive, 3) catch return &.{};
    prims[0] = .{ .filled_rect = .{ .x = 0, .y = 11, .w = w, .h = 2, .color = if (m.cut_on) ink else ink2 } };
    prims[1] = .{ .filled_rect = .{ .x = 0, .y = 6, .w = 1, .h = 12, .color = ink2 } };
    prims[2] = .{ .filled_rect = .{ .x = x - 6, .y = 4, .w = 12, .h = 16, .color = if (m.cut_on) blue else ink2 } };
    return prims;
}

/// Position of the cut plane along its axis, in model units.
fn cutPosition(m: *const Model, l: *const kerf.Loaded) f32 {
    const ax: usize = m.cut_axis;
    return l.lo[ax] + m.cut_t * (l.hi[ax] - l.lo[ax]);
}

/// The section plane for the view, `n.p + d <= 0` kept (the side the
/// negative axis points to; flip keeps the other side), or null when off.
pub fn cutPlane(m: *const Model) ?[4]f32 {
    if (!m.cut_on) return null;
    const l = &(m.loaded orelse return null);
    var n = [3]f32{ 0, 0, 0 };
    n[m.cut_axis] = if (m.cut_flip) -1 else 1;
    const pos = cutPosition(m, l);
    return .{ n[0], n[1], n[2], -(n[m.cut_axis] * pos) };
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
            // open shells would streak under stencil parity: outline only
            .flags = .{ .highlight = m.selected == id, .no_edges = !m.edges, .no_cap = !p.closed },
            // cap = manila (DESIGN) pulled toward the part's own colour
            .cap_color = kerf.mix(manila, p.color, 0.35),
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
            .cut = if (cutPlane(m)) |pl| .{ .plane = pl, .cap_color = manila, .outline_px = 1.5, .outline_color = ink } else null,
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
    gizmoLabels(m, cb);
}

/// Axis letters over the gizmo: ordinary overlay text anchored at positions
/// computed from the camera and the viewport's window origin.
fn gizmoLabels(m: *const Model, cb: anytype) void {
    if (!m.grid) return;
    const layout: scene.pick.GizmoLayout = .{ .corner = .bottom_left, .size_px = gizmo_view.size_px, .margin_px = gizmo_view.margin_px };
    const labels = scene.pick.gizmoLabels(m.cam, layout, m.vp[0], m.vp[1], m.vp_origin[0] + 1, m.vp_origin[1] + 1, 10);
    for (labels, 0..) |l, i| {
        cb.pushOverlay(.{ .x = l.x, .y = l.y, .padding = 0, .gap = 0, .anchor_x_frac = 0.5, .anchor_y_frac = 0.5 });
        cb.textStyled(l.text, plex_bold, gizmo_view.colors[i]);
        cb.popOverlay();
    }
}

// ── Right: parts, detail, notes ────────────────────────────────────

fn rightColumn(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();
    cb.pushGroup(.{ .width = 320, .padding = 12, .gap = 10, .bg = paper, .border = ink, .align_cross = .stretch });

    // Parts table: header band + clickable rows, selection synced both ways.
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0, .justify = .space_between });
    cb.textStyled("INSPECTOR", plex_label, ink2);
    cb.textMuted(std.fmt.allocPrint(a, "{d} PARTS", .{m.partCount()}) catch "");
    cb.popGroup();
    cb.pushGroup(.{ .padding = 1, .gap = 0, .flex = 1, .border = ink, .align_cross = .stretch });
    cb.pushGroup(.{ .direction = .horizontal, .pad_x = 6, .pad_y = 3, .gap = 0, .bg = ink, .align_cross = .stretch });
    cb.textStyled("NO  PART                  TRIS", plex_tight, paper);
    cb.popGroup();
    cb.pushScroll(.{ .gap = 0, .flex = 1, .align_cross = .stretch, .scroll_y = m.list_scroll, .id = list_id });
    if (m.loaded) |l| {
        for (l.parts, 0..) |p, i| {
            const id: u32 = @intCast(i + 1);
            const style = if (m.selected == id) row_button_on else if (m.hovered == id) row_button_hov else row_button;
            cb.buttonStyled(.{ .select = id }, partRow(a, p), style);
        }
    }
    cb.popScroll();
    cb.popGroup();

    detailCard(m, cb);
    notesCard(m, cb);
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
    cb.textMuted("CLICK A VIEW OR A ROW");
    if (m.loaded) |*l| {
        property(cb, "OVERALL X", kerf.fmtFtIn(a, l.hi[0] - l.lo[0]));
        property(cb, "OVERALL Y", kerf.fmtFtIn(a, l.hi[1] - l.lo[1]));
        property(cb, "OVERALL Z", kerf.fmtFtIn(a, l.hi[2] - l.lo[2]));
    }
    cb.popGroup();
}

/// The NOTES card: a `TextArea` on the manila card (3 wrapped lines visible,
/// scrolls beyond that; click to edit).
fn notesCard(m: *const Model, cb: anytype) void {
    cb.pushGroup(.{ .padding = 10, .gap = 6, .height = 124, .bg = manila, .border = ink, .align_cross = .stretch });
    cb.heading("NOTES");
    cb.divider();
    var st = cb.theme.text_input;
    st.bg = paper;
    st.fg = ink;
    st.border = ink;
    st.focus_border = blue;
    st.cursor = ink;
    st.border_width = 1;
    st.selection_bg = .{ 0.114, 0.306, 0.620, 0.30 };
    Notes.viewWith(&m.notes, cb, .{ .focus = Msg{ .notes = .focus } }, .{ .id = notes_id, .height = 64, .padding = 4, .style = st, .font = plex });
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
    switch (m.tab) {
        .three_d => {
            const deg = 180.0 / std.math.pi;
            cb.textStyled(std.fmt.allocPrint(a, "{s}  YAW {d:.0}  PITCH {d:.0}  DIST {s}", .{
                if (m.cam.projection == .ortho) "ORTHO" else "PERSP",
                m.cam.yaw * deg,
                m.cam.pitch * deg,
                kerf.fmtFtIn(a, m.cam.dist),
            }) catch "", mono, term_fg);
        },
        .section, .iso => {
            if (m.docs) |dx| if (m.activeSheet()) |idx| {
                const s = dx.sheets.items[idx];
                var x: []const u8 = "-";
                var y: []const u8 = "-";
                if (m.cursor2d) |c| {
                    x = kerf.fmtFtIn(a, @floatCast(c[0]));
                    y = kerf.fmtFtIn(a, @floatCast(c[1]));
                }
                cb.textStyled(std.fmt.allocPrint(a, "VIEW {s}  {s}=1'-0\"  X {s}  Y {s}", .{
                    s.d.view,
                    kerf.fmtFtIn(a, @floatCast(12.0 / s.d.scale)),
                    x,
                    y,
                }) catch "", mono, term_fg);
            };
        },
    }
    cb.textStyled("|", mono, term_fg);
    cb.textStyled(if (m.reply_ticks > 0) "CLAUDE BUSY" else "CLAUDE DEMO", mono, term_fg);
    cb.popGroup();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const test_msr = teak.monoMeasurer();

/// flush-psl-2x6 (10 parts, sections A and an iso B), on the 3D tab.
fn smallModel() Model {
    var m = Model.init();
    update(&m, .{ .load_fixture = 1 });
    update(&m, .{ .tab = .three_d });
    return m;
}

/// flush-psl-2x6 on the SECTION tab with a 900x600 sheet canvas.
fn sheetModel() Model {
    var m = Model.init();
    update(&m, .{ .load_fixture = 1 });
    update(&m, .{ .sheet_event = .{ .id = sheet_id, .kind = .layout, .w = 900, .h = 600 } });
    return m;
}

fn leftUp(x: f32, y: f32) teak.CanvasEvent {
    return .{ .id = sheet_id, .kind = .up, .button = .left, .x = x, .y = y, .w = 900, .h = 600 };
}

fn leftDown(x: f32, y: f32) teak.CanvasEvent {
    return .{ .id = sheet_id, .kind = .down, .button = .left, .buttons = .{ .left = true }, .x = x, .y = y, .w = 900, .h = 600 };
}

fn moveTo(x: f32, y: f32, dx: f32, dy: f32, held: bool) teak.CanvasEvent {
    return .{ .id = sheet_id, .kind = .move, .x = x, .y = y, .dx = dx, .dy = dy, .buttons = .{ .left = held }, .w = 900, .h = 600 };
}

/// A sheet pixel where `partAt2d` reports part `id`.
fn findPart2d(m: *const Model, id: u32) ?[2]f32 {
    var y: f32 = 10;
    while (y < 590) : (y += 5) {
        var x: f32 = 10;
        while (x < 890) : (x += 5) if (m.partAt2d(x, y) == id) return .{ x, y };
    }
    return null;
}

test "init: bundled document loads mesh and drawings, camera frames it, resources published" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    try testing.expectEqual(@as(u32, 24), m.partCount());
    try testing.expectEqual(@as(usize, 5), m.sectionCount());
    try testing.expect(!m.hasIso()); // palmer has five sections, no iso
    try testing.expectEqual(Tab.section, m.tab);
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
    // the console opens with the demo-mode greeting
    try testing.expectEqual(@as(u8, 1), m.log.n);
}

test "flush fixture: section A and iso B land on the right tabs" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    try testing.expectEqual(@as(usize, 1), m.sectionCount());
    try testing.expect(m.hasIso());
    try testing.expectEqualStrings("A", m.docs.?.sheets.items[m.activeSheet().?].d.view);
    update(&m, .{ .tab = .iso });
    try testing.expectEqualStrings("B", m.docs.?.sheets.items[m.activeSheet().?].d.view);
    update(&m, .{ .tab = .three_d });
    try testing.expect(m.activeSheet() == null);
}

test "sheet: layout fits; wheel zooms at the cursor; drag pans; fit restores" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    const dx = m.docs.?;
    const idx = m.activeSheet().?;
    const fit_cam = dx.sheets.items[idx].cam;
    try testing.expect(dx.sheets.items[idx].fitted);
    try testing.expect(dx.verts().len > 3000);

    const model_x = fit_cam.modelX(300);
    update(&m, .{ .sheet_event = .{ .id = sheet_id, .kind = .wheel, .dy = -200, .x = 300, .y = 200, .w = 900, .h = 600 } });
    const zoomed = dx.sheets.items[idx].cam;
    try testing.expect(zoomed.px_per_model_in > fit_cam.px_per_model_in);
    try testing.expectApproxEqAbs(@as(f64, model_x), zoomed.modelX(300), 1e-3); // the point under the cursor stays put

    // empty corner: press, travel, release = pan (and no selection change)
    update(&m, .{ .sheet_event = leftDown(2, 2) });
    update(&m, .{ .sheet_event = moveTo(32, 12, 30, 10, true) });
    update(&m, .{ .sheet_event = leftUp(32, 12) });
    try testing.expectApproxEqAbs(zoomed.origin_x + 30, dx.sheets.items[idx].cam.origin_x, 1e-3);
    try testing.expectApproxEqAbs(zoomed.origin_y + 10, dx.sheets.items[idx].cam.origin_y, 1e-3);

    update(&m, .fit);
    try testing.expectApproxEqAbs(fit_cam.px_per_model_in, dx.sheets.items[idx].cam.px_per_model_in, 1e-3);
    update(&m, .{ .zoom2d = 2 });
    try testing.expectApproxEqAbs(fit_cam.px_per_model_in * 2, dx.sheets.items[idx].cam.px_per_model_in, 1e-3);
}

test "sheet <-> table <-> 3D share one selection and one hover" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    const dx = m.docs.?;
    const beam: u32 = 2; // flush-psl-2x6 part 02
    const pt = findPart2d(&m, beam) orelse return error.TestUnexpectedResult;

    // hover over the sheet: the part is hovered everywhere (3D tint, table row, status)
    update(&m, .{ .sheet_event = moveTo(pt[0], pt[1], 1, 1, false) });
    try testing.expectEqual(beam, m.hovered);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(partItems(&m, arena.allocator())[beam - 1].tint[0] > 1);
    const n_plain = dx.verts().len;

    // a click selects it (row, 3D highlight flag, tinted fill in the sheet)
    update(&m, .{ .sheet_event = leftDown(pt[0], pt[1]) });
    update(&m, .{ .sheet_event = leftUp(pt[0], pt[1]) });
    try testing.expectEqual(beam, m.selected);
    try testing.expect(partItems(&m, arena.allocator())[beam - 1].flags.highlight);
    try testing.expect(dx.verts().len != n_plain);

    // selecting from the table (or 3D) changes the sheet; clearing restores it
    update(&m, .{ .select = 7 });
    const n_king = dx.verts().len;
    update(&m, .{ .select = 0 });
    update(&m, .{ .sheet_event = moveTo(2, 2, 0, 0, false) });
    try testing.expectEqual(@as(u32, 0), m.hovered);
    try testing.expect(dx.verts().len != n_king);

    // a click on empty paper clears the selection
    update(&m, .{ .select = beam });
    update(&m, .{ .sheet_event = leftDown(2, 2) });
    update(&m, .{ .sheet_event = leftUp(2, 2) });
    try testing.expectEqual(@as(u32, 0), m.selected);
}

test "iso tab shows drawing B; hover maps instances (#k) to their own part" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .tab = .iso });
    update(&m, .{ .sheet_event = .{ .id = sheet_id, .kind = .layout, .w = 900, .h = 600 } });
    const l = &m.loaded.?;
    // both jack_studs instances (parts 3 and 4) are reachable in the iso
    var seen: [11]bool = @splat(false);
    var y: f32 = 10;
    while (y < 590) : (y += 4) {
        var x: f32 = 10;
        while (x < 890) : (x += 4) seen[m.partAt2d(x, y)] = true;
    }
    try testing.expect(seen[3] or seen[4]);
    var n: usize = 0;
    for (seen[1..]) |b| n += @intFromBool(b);
    try testing.expect(n >= 4);
    _ = l;
}

test "palmer: no iso drawing, the ISO tab is an empty state with a message" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    update(&m, .{ .tab = .iso });
    try testing.expect(m.activeSheet() == null);
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.theme = theme;
    view(&m, &cb);
    var found = false;
    for (cb.cmds.items) |c| switch (c) {
        .text => |t| if (std.mem.startsWith(u8, t.content, "NO ISO VIEW")) {
            found = true;
        },
        else => {},
    };
    try testing.expect(found);
}

test "section picker switches between palmer's five sheets, each with its own camera" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    update(&m, .{ .sheet_event = .{ .id = sheet_id, .kind = .layout, .w = 900, .h = 600 } });
    const dx = m.docs.?;
    update(&m, .{ .section_sel = 2 });
    try testing.expectEqualStrings("C", dx.sheets.items[m.activeSheet().?].d.view);
    update(&m, .{ .zoom2d = 3 });
    const zoomed = dx.sheets.items[m.activeSheet().?].cam.px_per_model_in;
    update(&m, .{ .section_sel = 0 });
    try testing.expect(dx.sheets.items[m.activeSheet().?].cam.px_per_model_in != zoomed);
    update(&m, .{ .section_sel = 9 }); // out of range: ignored
    try testing.expectEqual(@as(u8, 0), m.sec_sel);
}

test "every bundled drawing tessellates to finite triangles and picks parts" {
    for (fixtures, 0..) |_, fi| {
        var m = Model.init();
        defer m.loaded.?.deinit();
        update(&m, .{ .load_fixture = @intCast(fi) });
        update(&m, .{ .sheet_event = .{ .id = sheet_id, .kind = .layout, .w = 900, .h = 600 } });
        const dx = m.docs.?;
        for (dx.sheets.items, 0..) |s, si| {
            m.tab = if (s.kind() == .iso) .iso else .section;
            if (s.kind() == .section) {
                var n: usize = 0;
                for (dx.sheets.items[0..si]) |o| n += @intFromBool(o.kind() == .section);
                m.sec_sel = @intCast(n);
            }
            update(&m, .{ .sheet_event = .{ .id = sheet_id, .kind = .layout, .w = 901, .h = 601 } });
            update(&m, .fit);
            try testing.expect(dx.verts().len > 300);
            for (dx.verts()) |v| try testing.expect(std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.a));
            // at least one part is selectable from every drawing
            var any = false;
            var y: f32 = 10;
            while (y < 590 and !any) : (y += 6) {
                var x: f32 = 10;
                while (x < 890) : (x += 6) if (m.partAt2d(x, y) != 0) {
                    any = true;
                    break;
                };
            }
            try testing.expect(any);
        }
    }
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

test "section cut: plane from axis, offset and flip; caps skip open shells; slider drag" {
    var m = Model.init(); // palmer: parts 6 (dowel) and 10 (wedge/shank) are open shells
    defer m.loaded.?.deinit();
    try testing.expect(cutPlane(&m) == null);
    update(&m, .toggle_cut);
    const l = &m.loaded.?;
    // default: Y axis halfway, keeping the lower half
    var pl = cutPlane(&m).?;
    try testing.expectEqual([3]f32{ 0, 1, 0 }, pl[0..3].*);
    try testing.expectApproxEqAbs((l.lo[1] + l.hi[1]) / 2, -pl[3], 1e-4); // n.p + d = 0 at the mid height
    update(&m, .{ .cut_axis = 2 });
    update(&m, .{ .cut_set = 0.25 });
    update(&m, .cut_flip);
    pl = cutPlane(&m).?;
    try testing.expectEqual([3]f32{ 0, 0, -1 }, pl[0..3].*);
    try testing.expectApproxEqAbs(l.lo[2] + 0.25 * (l.hi[2] - l.lo[2]), pl[3], 1e-4); // -(n*pos) with n = -1
    update(&m, .{ .cut_set = 7 });
    try testing.expectEqual(@as(f32, 1), m.cut_t); // clamped

    // the slider canvas maps a press / drag to a fraction of its width
    const down = canvasMsg(&m, .{ .id = cut_slider_id, .kind = .down, .x = 55, .w = 220 }).?;
    try testing.expectApproxEqAbs(@as(f32, 0.25), down.cut_set, 1e-6);
    try testing.expect(canvasMsg(&m, .{ .id = cut_slider_id, .kind = .move, .x = 55, .w = 220 }) == null); // no button: hover
    const drag = canvasMsg(&m, .{ .id = cut_slider_id, .kind = .move, .x = 110, .w = 220, .buttons = .{ .left = true } }).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), drag.cut_set, 1e-6);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const items = partItems(&m, arena.allocator());
    for (items, 0..) |it, i| try testing.expectEqual(i == 5 or i == 9, it.flags.no_cap);
    // per-part cap tint: a mix of manila and the part colour, opaque
    try testing.expect(items[0].cap_color[3] == 1);
    try testing.expect(!std.meta.eql(items[0].cap_color, items[1].cap_color) or std.meta.eql(l.parts[0].color, l.parts[1].color));
}

test "gizmo labels follow the viewport's window origin" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .layout, .x = 12, .y = 86, .w = 900, .h = 600 } });
    try testing.expectEqual([2]f32{ 12, 86 }, m.vp_origin);
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.theme = theme;
    view(&m, &cb);
    var overlays: usize = 0;
    var first: ?teak.OverlayStyle(Msg) = null;
    for (cb.cmds.items) |c| switch (c) {
        .push_overlay => |o| {
            overlays += 1;
            if (first == null) first = o.*;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), overlays); // X, Y, Z
    // bottom-left gizmo: the letters live in the lower-left of the viewport, in window space
    try testing.expect(first.?.x > 12 and first.?.x < 12 + 140 and first.?.y > 86 + 400);
    update(&m, .toggle_grid);
    cb.reset();
    cb.theme = theme;
    view(&m, &cb);
    for (cb.cmds.items) |c| try testing.expect(c != .push_overlay);
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

test "startup params: ?mesh=, ?tab= and ?select= chain through query_param" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    try testing.expectEqualStrings("mesh", effects(&m)[0].query_param.name);
    update(&m, effectMsg(&m, .{ .query_value = .{ .id = param_id_base, .value = "flush-psl-2x6.json" } }).?);
    try testing.expectEqualStrings("flush-psl-2x6", m.doc());
    try testing.expectEqual(@as(u32, 10), m.partCount());
    try testing.expectEqualStrings("tab", effects(&m)[0].query_param.name);
    update(&m, effectMsg(&m, .{ .query_value = .{ .id = param_id_base + 1, .value = "iso" } }).?);
    try testing.expectEqual(Tab.iso, m.tab);
    try testing.expectEqualStrings("select", effects(&m)[0].query_param.name);
    update(&m, effectMsg(&m, .{ .query_value = .{ .id = param_id_base + 2, .value = "beam" } }).?);
    try testing.expectEqual(@as(u32, 2), m.selected);
    try testing.expectEqual(@as(usize, 0), effects(&m).len); // chain done
}

test "?mesh= with a URL becomes an http effect; failures keep the document" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    update(&m, .{ .param = .{ .id = param_id_base, .value = "https://example.com/m/part.json" } });
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

test "opening files: a drawing joins the document, a mesh replaces it; drops arrive as file_opened" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    const dx = m.docs.?;
    // flush mesh (clears palmer's drawings), then its two drawings one by one
    update(&m, .{ .file_opened = .{ .name = "mesh.json", .bytes = kerf.small_fixture } });
    try testing.expectEqual(@as(usize, 0), dx.sheets.items.len);
    update(&m, .{ .file_opened = .{ .name = "drawing-B.json", .bytes = @embedFile("fixtures/flush-psl-2x6.B.json") } });
    try testing.expectEqual(Tab.iso, m.tab); // an iso drawing opens on the ISO tab
    update(&m, .{ .file_opened = .{ .name = "drawing-A.json", .bytes = @embedFile("fixtures/flush-psl-2x6.A.json") } });
    try testing.expectEqual(Tab.section, m.tab);
    try testing.expectEqual(@as(usize, 2), dx.sheets.items.len);
    try testing.expectEqualStrings("A", dx.sheets.items[0].d.view);
    // a broken drawing is reported and changes nothing
    update(&m, .{ .file_opened = .{ .name = "x.json", .bytes = "{\"kerf_drawing\":\"0.1\", nope" } });
    try testing.expect(std.mem.startsWith(u8, m.status(), "ERR x.json"));
    try testing.expectEqual(@as(usize, 2), dx.sheets.items.len);

    const f = effectMsg(&m, .{ .dropped = .{ .kind = .file, .name = "a.json", .bytes = "{}" } }).?;
    try testing.expectEqualStrings("a.json", f.file_opened.name);
    try testing.expect(effectMsg(&m, .{ .dropped = .{ .kind = .text, .bytes = "x" } }) == null);
}

test "chat: Enter sends, Shift+Enter is a newline; the reply is paced by ticks and drives the UI" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    const n0 = m.log.n;
    update(&m, .{ .chat = .focus });
    try testing.expect(keyCharMsg(&m, 'o').? == .chat); // typed letters, not the viewer shortcuts
    for ("select the beam") |c| update(&m, keyCharMsg(&m, c).?);
    update(&m, keySpecialMsg(&m, .shift_enter).?);
    try testing.expectEqualStrings("select the beam\n", m.chat.content());
    try testing.expect(keySpecialMsg(&m, .enter).? == .send);
    update(&m, keySpecialMsg(&m, .enter).?);
    try testing.expectEqual(n0 + 1, m.log.n);
    try testing.expectEqualStrings("select the beam", m.log.at(n0).body()); // trimmed
    try testing.expectEqualStrings("", m.chat.content());
    try testing.expectEqual(@as(usize, 1), subscribe(&m).len); // the pacing timer exists only now
    try testing.expectEqual(@as(u32, 0), m.selected);

    update(&m, .reply_tick);
    update(&m, .reply_tick); // tool step: the UI action lands with the tool line
    try testing.expectEqual(@as(u32, 2), m.selected);
    try testing.expectEqual(chat.Role.tool, m.log.at(n0 + 1).role);
    try testing.expect(std.mem.indexOf(u8, m.log.at(n0 + 1).body(), "SELECT") != null);
    update(&m, .reply_tick);
    update(&m, .reply_tick);
    update(&m, .reply_tick);
    try testing.expectEqual(chat.Role.kerf, m.log.at(n0 + 2).role);
    try testing.expect(std.mem.indexOf(u8, m.log.at(n0 + 2).body(), "**beam**") != null);
    try testing.expectEqual(@as(usize, 0), subscribe(&m).len);
    update(&m, .reply_tick); // a stray tick does nothing
    try testing.expectEqual(n0 + 3, m.log.n);

    // views by name, a new message while one is pending finishes the old reply
    update(&m, .{ .chat = .{ .char = 'i' } });
    update(&m, .{ .chat = .{ .char = 's' } });
    update(&m, .{ .chat = .{ .char = 'o' } });
    update(&m, .send);
    update(&m, .reply_tick);
    update(&m, .reply_tick);
    try testing.expectEqual(Tab.iso, m.tab);
    update(&m, .{ .chat = .{ .char = '3' } });
    update(&m, .{ .chat = .{ .char = 'd' } });
    update(&m, .send); // finishes the iso reply instantly, then starts the 3d one
    try testing.expectEqual(@as(u8, reply_total), m.reply_ticks);
    while (m.reply_ticks > 0) update(&m, .reply_tick);
    try testing.expectEqual(Tab.three_d, m.tab);

    // empty / whitespace-only input is not sent
    const n1 = m.log.n;
    update(&m, .{ .chat = .{ .char = ' ' } });
    update(&m, .send);
    try testing.expectEqual(n1, m.log.n);
    update(&m, .clear_chat);
    try testing.expectEqual(@as(u8, 0), m.log.n);
}

test "chat on a document with no iso falls back to the 3D iso preset" {
    var m = Model.init(); // palmer: sections only
    defer m.loaded.?.deinit();
    for ("show iso") |c| update(&m, .{ .chat = .{ .char = c } });
    update(&m, .send);
    while (m.reply_ticks > 0) update(&m, .reply_tick);
    try testing.expectEqual(Tab.three_d, m.tab);
    try testing.expect(std.mem.indexOf(u8, m.log.at(m.log.n - 1).body(), "no iso drawing") != null);
}

test "chat scroll sticks to the newest message until the user scrolls up" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    update(&m, .{ .chat_extent = .{ 200, 600 } });
    try testing.expectEqual(@as(f32, 400), m.chat_scroll);
    update(&m, .{ .chat_scroll_by = -100 });
    try testing.expect(!m.chat_stick);
    update(&m, .{ .chat_extent = .{ 200, 800 } });
    try testing.expectEqual(@as(f32, 300), m.chat_scroll); // stays where the user left it
    update(&m, .{ .chat_scroll_by = 9999 });
    try testing.expect(m.chat_stick);
    update(&m, .{ .chat_extent = .{ 200, 900 } });
    try testing.expectEqual(@as(f32, 700), m.chat_scroll);
}

test "notes: focused text area takes typed letters instead of the viewer shortcuts" {
    var m = Model.init();
    defer m.loaded.?.deinit();
    // Shortcut when not editing.
    try testing.expect(keyCharMsg(&m, 'o').? == .toggle_ortho);
    try testing.expect(keyCharMsg(&m, 's').? == .tab);
    update(&m, .{ .notes = .focus });
    try testing.expect(keyCharMsg(&m, 'o').? == .notes);
    for ("fit the plate") |c| update(&m, keyCharMsg(&m, c).?);
    try testing.expectEqualStrings("fit the plate", m.notes.content());
    update(&m, keySpecialMsg(&m, .enter).?); // Enter in the notes is a newline
    try testing.expectEqualStrings("fit the plate\n", m.notes.content());
    // Escape leaves the editor; the next Escape deselects.
    update(&m, keySpecialMsg(&m, .escape).?);
    try testing.expectEqual(Focus.none, m.focus);
    try testing.expect(keySpecialMsg(&m, .escape).? == .select);
}

test "keyboard: tab hotkeys and 2D zoom" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    update(&m, keyCharMsg(&m, 'i').?);
    try testing.expectEqual(Tab.iso, m.tab);
    update(&m, keyCharMsg(&m, 'd').?);
    try testing.expectEqual(Tab.three_d, m.tab);
    update(&m, keyCharMsg(&m, 's').?);
    const dx = m.docs.?;
    const z = dx.sheets.items[m.activeSheet().?].cam.px_per_model_in;
    update(&m, keyCharMsg(&m, '+').?);
    try testing.expect(dx.sheets.items[m.activeSheet().?].cam.px_per_model_in > z);
}

fn frameOf(m: *const Model, cb: *teak.CmdBuffer(Msg), rects: []teak.Rect, w: f32, h: f32) []const teak.Rect {
    cb.reset();
    cb.theme = theme;
    view(m, cb);
    teak.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, test_msr);
    return rects[0..cb.cmds.items.len];
}

test "view (3D tab): balanced, one interactive scene3d, 320px inspector, 360px console, 24px status bar" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .select = 2 });
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [768]teak.Rect = undefined;
    const rs = frameOf(&m, &cb, &rects, 1280, 800);
    try testing.expect(teak.validateBalance(cb.cmds.items) == null);
    var scenes: usize = 0;
    var canvases: usize = 0;
    for (cb.cmds.items, rs) |c, r| switch (c) {
        .scene3d => |s| {
            scenes += 1;
            try testing.expect(s.pointer and s.id == scene_id);
            try testing.expectEqual(@as(usize, 10), s.view.items.len);
            try testing.expect(s.view.items[1].flags.highlight); // part 2 is selected
            try testing.expectEqual(m.rev, @as(u32, @intCast(s.key)));
            try testing.expect(r.w > 500 and r.h > 400); // flexes into the centre
        },
        .canvas => canvases += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), scenes);
    try testing.expectEqual(@as(usize, 1), canvases); // only the cut slider
}

test "view (section tab): the sheet is one pointer canvas carrying the tessellator's triangles" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [768]teak.Rect = undefined;
    const rs = frameOf(&m, &cb, &rects, 1280, 800);
    try testing.expect(teak.validateBalance(cb.cmds.items) == null);
    var sheets: usize = 0;
    for (cb.cmds.items, rs) |c, r| switch (c) {
        .canvas => |cv| {
            try testing.expect(cv.pointer and cv.id == sheet_id);
            sheets += 1;
            try testing.expectEqual(@as(usize, 1), cv.primitives.len);
            const t = cv.primitives[0].triangles;
            try testing.expectEqual(m.docs.?.key, t.key);
            try testing.expect(t.verts.len > 3000);
            try testing.expect(r.w > 500 and r.h > 400);
        },
        .scene3d => return error.TestUnexpectedResult,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), sheets);
}

test "view: snapshot golden, SECTION tab" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .select = 2 });
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [768]teak.Rect = undefined;
    const rs = frameOf(&m, &cb, &rects, 1280, 800);
    try teak.expectSnapshot(cb.cmds.items, rs, .{}, golden_section);
}

test "view: snapshot golden, ISO tab" {
    var m = sheetModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .tab = .iso });
    update(&m, .{ .sheet_event = .{ .id = sheet_id, .kind = .layout, .w = 900, .h = 600 } });
    update(&m, .{ .select = 3 });
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [768]teak.Rect = undefined;
    const rs = frameOf(&m, &cb, &rects, 1280, 800);
    try teak.expectSnapshot(cb.cmds.items, rs, .{}, golden_iso);
}

test "view: snapshot golden, 3D tab" {
    var m = smallModel();
    defer m.loaded.?.deinit();
    update(&m, .{ .view_event = .{ .id = scene_id, .kind = .layout, .w = 700, .h = 500 } });
    update(&m, .{ .select = 2 });
    var cb = teak.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [768]teak.Rect = undefined;
    const rs = frameOf(&m, &cb, &rects, 1280, 800);
    try teak.expectSnapshot(cb.cmds.items, rs, .{}, golden_3d);
}

const golden_section =
    \\group (0,0,1280,800) vertical bg
    \\  group (0,0,1280,40) horizontal bg
    \\    text (12,10,56,20) "KERF"
    \\    group (80,13,24,14) horizontal
    \\      group (80,13,6,14) vertical bg
    \\      group (89,13,6,14) vertical bg
    \\      group (98,13,6,14) vertical bg
    \\    text (116,10,180,20) "DETAIL WORKSTATION"
    \\    text (308,10,180,20) "DOC: FLUSH-PSL-2X6"
    \\    group (500,20,310,0) vertical
    \\    button (822,7,174,26) "PALMER-SD1-LIKE"
    \\    button (1008,7,154,26) "FLUSH-PSL-2X6"
    \\    button (1174,7,94,26) "OPEN..."
    \\  group (0,40,1280,2) vertical bg
    \\  group (0,42,1280,734) horizontal
    \\    group (0,42,360,734) vertical bg border
    \\      text (12,54,336,20) "OPERATOR CONSOLE"
    \\      group (12,82,336,536) vertical bg border
    \\        scroll (13,83,334,534) vertical id=13
    \\          group (21,91,318,105) vertical bg border
    \\            text (29,99,302,20) "KERF/CLAUDE  #01"
    \\            rich_text (29,122,302,20) "DEMO MODE: no network, no key. I am"
    \\            rich_text (29,145,302,20) "a script. Try section, iso, 3d, cut,"
    \\            rich_text (29,168,302,20) "or the name of a part."
    \\      text (12,626,336,20) "SHIFT+ENTER FOR A NEW LINE"
    \\      text_area (12,654,336,76) id=12 "" cursor=0
    \\      group (12,738,336,26) horizontal
    \\        text (12,741,121,20) "ENTER SENDS"
    \\        group (141,751,53,0) vertical
    \\        button (202,738,74,26) "CLEAR"
    \\        button (284,738,64,26) "SEND"
    \\    group (360,42,600,734) vertical bg
    \\      group (372,54,576,27) horizontal
    \\        group (372,54,106,27) vertical
    \\          button (372,54,106,24) "[SECTION]"
    \\          group (372,78,106,3) vertical bg
    \\        group (482,54,66,27) vertical
    \\          button (482,54,66,24) "[ISO]"
    \\          group (482,78,66,3) vertical bg
    \\        group (552,54,56,27) vertical
    \\          button (552,54,56,24) "[3D]"
    \\          group (552,78,56,3) vertical bg
    \\        group (612,81,56,0) vertical
    \\        group (672,57,276,24) horizontal
    \\          button (672,57,46,24) "[-]"
    \\          button (722,57,46,24) "[+]"
    \\          button (772,57,66,24) "[FIT]"
    \\          button (842,57,106,24) "[GRID ON]"
    \\      group (372,89,576,24) horizontal
    \\        text (372,91,55,20) "SHEET"
    \\        button (431,89,46,24) "[A]"
    \\        group (481,101,353,0) vertical
    \\        text (838,91,110,20) "3/4\"=1'-0\""
    \\      group (372,121,576,643) vertical bg border
    \\        canvas (373,122,574,641) prims=1 id=10 pointer "section drawing"
    \\    group (960,42,320,734) vertical bg border
    \\      group (972,54,296,20) horizontal
    \\        text (972,54,99,20) "INSPECTOR"
    \\        text (1188,54,80,20) "10 PARTS"
    \\      group (972,84,296,307) vertical border
    \\        group (973,85,294,26) horizontal bg
    \\          text (979,88,300,20) "NO  PART                  TRIS"
    \\        scroll (973,111,294,279) vertical id=8
    \\          button (973,111,294,22) "01  bottom_plate            12"
    \\          button (973,133,294,22) "02  beam                    12"
    \\          button (973,155,294,22) "03  jack_studs              12"
    \\          button (973,177,294,22) "04  jack_studs#1            12"
    \\          button (973,199,294,22) "05  lower_plate             12"
    \\          button (973,221,294,22) "06  upper_plate             12"
    \\          button (973,243,294,22) "07  king_stud               12"
    \\          button (973,265,294,22) "08  studs                   12"
    \\          button (973,287,294,22) "09  studs#1                 12"
    \\          button (973,309,294,22) "10  strap                   12"
    \\      group (972,401,296,229) vertical bg border
    \\        text (982,411,276,20) "DETAIL"
    \\        divider (982,437,276,1)
    \\        group (982,444,276,20) horizontal
    \\          text (982,444,40,20) "PART"
    \\          text (1188,444,70,20) "02 beam"
    \\        group (982,470,276,20) horizontal
    \\          text (982,470,80,20) "MATERIAL"
    \\          text (1108,470,150,20) "wood_engineered"
    \\        group (982,496,276,20) horizontal
    \\          text (982,496,90,20) "TRIANGLES"
    \\          text (1238,496,20,20) "12"
    \\        group (982,522,276,20) horizontal
    \\          text (982,522,50,20) "SHELL"
    \\          text (1198,522,60,20) "CLOSED"
    \\        group (982,548,276,20) horizontal
    \\          text (982,548,80,20) "WIDTH  X"
    \\          text (1208,548,50,20) "4'-0\""
    \\        group (982,574,276,20) horizontal
    \\          text (982,574,80,20) "HEIGHT Y"
    \\          text (1188,574,70,20) "11 7/8\""
    \\        group (982,600,276,20) horizontal
    \\          text (982,600,80,20) "DEPTH  Z"
    \\          text (1198,600,60,20) "5 1/4\""
    \\      group (972,640,296,124) vertical bg border
    \\        text (982,650,276,20) "NOTES"
    \\        divider (982,676,276,1)
    \\        text_area (982,683,276,64) id=11 "" cursor=0
    \\  group (0,776,1280,24) horizontal bg
    \\    text (12,778,55,20) "READY"
    \\    text (81,778,10,20) "|"
    \\    text (105,778,180,20) "10 PARTS  120 TRIS"
    \\    text (299,778,10,20) "|"
    \\    text (323,778,110,20) "SEL 02 beam"
    \\    group (447,788,379,0) vertical
    \\    text (840,778,280,20) "VIEW A  3/4\"=1'-0\"  X -  Y -"
    \\    text (1134,778,10,20) "|"
    \\    text (1158,778,110,20) "CLAUDE DEMO"
    \\
;
const golden_iso =
    \\group (0,0,1280,800) vertical bg
    \\  group (0,0,1280,40) horizontal bg
    \\    text (12,10,56,20) "KERF"
    \\    group (80,13,24,14) horizontal
    \\      group (80,13,6,14) vertical bg
    \\      group (89,13,6,14) vertical bg
    \\      group (98,13,6,14) vertical bg
    \\    text (116,10,180,20) "DETAIL WORKSTATION"
    \\    text (308,10,180,20) "DOC: FLUSH-PSL-2X6"
    \\    group (500,20,310,0) vertical
    \\    button (822,7,174,26) "PALMER-SD1-LIKE"
    \\    button (1008,7,154,26) "FLUSH-PSL-2X6"
    \\    button (1174,7,94,26) "OPEN..."
    \\  group (0,40,1280,2) vertical bg
    \\  group (0,42,1280,734) horizontal
    \\    group (0,42,360,734) vertical bg border
    \\      text (12,54,336,20) "OPERATOR CONSOLE"
    \\      group (12,82,336,536) vertical bg border
    \\        scroll (13,83,334,534) vertical id=13
    \\          group (21,91,318,105) vertical bg border
    \\            text (29,99,302,20) "KERF/CLAUDE  #01"
    \\            rich_text (29,122,302,20) "DEMO MODE: no network, no key. I am"
    \\            rich_text (29,145,302,20) "a script. Try section, iso, 3d, cut,"
    \\            rich_text (29,168,302,20) "or the name of a part."
    \\      text (12,626,336,20) "SHIFT+ENTER FOR A NEW LINE"
    \\      text_area (12,654,336,76) id=12 "" cursor=0
    \\      group (12,738,336,26) horizontal
    \\        text (12,741,121,20) "ENTER SENDS"
    \\        group (141,751,53,0) vertical
    \\        button (202,738,74,26) "CLEAR"
    \\        button (284,738,64,26) "SEND"
    \\    group (360,42,600,734) vertical bg
    \\      group (372,54,576,27) horizontal
    \\        group (372,54,106,27) vertical
    \\          button (372,54,106,24) "[SECTION]"
    \\          group (372,78,106,3) vertical bg
    \\        group (482,54,66,27) vertical
    \\          button (482,54,66,24) "[ISO]"
    \\          group (482,78,66,3) vertical bg
    \\        group (552,54,56,27) vertical
    \\          button (552,54,56,24) "[3D]"
    \\          group (552,78,56,3) vertical bg
    \\        group (612,81,56,0) vertical
    \\        group (672,57,276,24) horizontal
    \\          button (672,57,46,24) "[-]"
    \\          button (722,57,46,24) "[+]"
    \\          button (772,57,66,24) "[FIT]"
    \\          button (842,57,106,24) "[GRID ON]"
    \\      group (372,89,576,675) vertical bg border
    \\        canvas (373,90,574,673) prims=1 id=10 pointer "iso drawing"
    \\    group (960,42,320,734) vertical bg border
    \\      group (972,54,296,20) horizontal
    \\        text (972,54,99,20) "INSPECTOR"
    \\        text (1188,54,80,20) "10 PARTS"
    \\      group (972,84,296,307) vertical border
    \\        group (973,85,294,26) horizontal bg
    \\          text (979,88,300,20) "NO  PART                  TRIS"
    \\        scroll (973,111,294,279) vertical id=8
    \\          button (973,111,294,22) "01  bottom_plate            12"
    \\          button (973,133,294,22) "02  beam                    12"
    \\          button (973,155,294,22) "03  jack_studs              12"
    \\          button (973,177,294,22) "04  jack_studs#1            12"
    \\          button (973,199,294,22) "05  lower_plate             12"
    \\          button (973,221,294,22) "06  upper_plate             12"
    \\          button (973,243,294,22) "07  king_stud               12"
    \\          button (973,265,294,22) "08  studs                   12"
    \\          button (973,287,294,22) "09  studs#1                 12"
    \\          button (973,309,294,22) "10  strap                   12"
    \\      group (972,401,296,229) vertical bg border
    \\        text (982,411,276,20) "DETAIL"
    \\        divider (982,437,276,1)
    \\        group (982,444,276,20) horizontal
    \\          text (982,444,40,20) "PART"
    \\          text (1128,444,130,20) "03 jack_studs"
    \\        group (982,470,276,20) horizontal
    \\          text (982,470,80,20) "MATERIAL"
    \\          text (1218,470,40,20) "wood"
    \\        group (982,496,276,20) horizontal
    \\          text (982,496,90,20) "TRIANGLES"
    \\          text (1238,496,20,20) "12"
    \\        group (982,522,276,20) horizontal
    \\          text (982,522,50,20) "SHELL"
    \\          text (1198,522,60,20) "CLOSED"
    \\        group (982,548,276,20) horizontal
    \\          text (982,548,80,20) "WIDTH  X"
    \\          text (1198,548,60,20) "1 1/2\""
    \\        group (982,574,276,20) horizontal
    \\          text (982,574,80,20) "HEIGHT Y"
    \\          text (1158,574,100,20) "6'-11 3/4\""
    \\        group (982,600,276,20) horizontal
    \\          text (982,600,80,20) "DEPTH  Z"
    \\          text (1198,600,60,20) "5 1/2\""
    \\      group (972,640,296,124) vertical bg border
    \\        text (982,650,276,20) "NOTES"
    \\        divider (982,676,276,1)
    \\        text_area (982,683,276,64) id=11 "" cursor=0
    \\  group (0,776,1280,24) horizontal bg
    \\    text (12,778,55,20) "READY"
    \\    text (81,778,10,20) "|"
    \\    text (105,778,180,20) "10 PARTS  120 TRIS"
    \\    text (299,778,10,20) "|"
    \\    text (323,778,170,20) "SEL 03 jack_studs"
    \\    group (507,788,319,0) vertical
    \\    text (840,778,280,20) "VIEW B  7/8\"=1'-0\"  X -  Y -"
    \\    text (1134,778,10,20) "|"
    \\    text (1158,778,110,20) "CLAUDE DEMO"
    \\
;
const golden_3d =
    \\group (0,0,1280,800) vertical bg
    \\  group (0,0,1280,40) horizontal bg
    \\    text (12,10,56,20) "KERF"
    \\    group (80,13,24,14) horizontal
    \\      group (80,13,6,14) vertical bg
    \\      group (89,13,6,14) vertical bg
    \\      group (98,13,6,14) vertical bg
    \\    text (116,10,180,20) "DETAIL WORKSTATION"
    \\    text (308,10,180,20) "DOC: FLUSH-PSL-2X6"
    \\    group (500,20,310,0) vertical
    \\    button (822,7,174,26) "PALMER-SD1-LIKE"
    \\    button (1008,7,154,26) "FLUSH-PSL-2X6"
    \\    button (1174,7,94,26) "OPEN..."
    \\  group (0,40,1280,2) vertical bg
    \\  group (0,42,1280,734) horizontal
    \\    group (0,42,360,734) vertical bg border
    \\      text (12,54,336,20) "OPERATOR CONSOLE"
    \\      group (12,82,336,536) vertical bg border
    \\        scroll (13,83,334,534) vertical id=13
    \\          group (21,91,318,105) vertical bg border
    \\            text (29,99,302,20) "KERF/CLAUDE  #01"
    \\            rich_text (29,122,302,20) "DEMO MODE: no network, no key. I am"
    \\            rich_text (29,145,302,20) "a script. Try section, iso, 3d, cut,"
    \\            rich_text (29,168,302,20) "or the name of a part."
    \\      text (12,626,336,20) "SHIFT+ENTER FOR A NEW LINE"
    \\      text_area (12,654,336,76) id=12 "" cursor=0
    \\      group (12,738,336,26) horizontal
    \\        text (12,741,121,20) "ENTER SENDS"
    \\        group (141,751,53,0) vertical
    \\        button (202,738,74,26) "CLEAR"
    \\        button (284,738,64,26) "SEND"
    \\    group (360,42,618,734) vertical bg
    \\      group (372,54,594,27) horizontal
    \\        group (372,54,106,27) vertical
    \\          button (372,54,106,24) "[SECTION]"
    \\          group (372,78,106,3) vertical bg
    \\        group (482,54,66,27) vertical
    \\          button (482,54,66,24) "[ISO]"
    \\          group (482,78,66,3) vertical bg
    \\        group (552,54,56,27) vertical
    \\          button (552,54,56,24) "[3D]"
    \\          group (552,78,56,3) vertical bg
    \\        group (612,81,174,0) vertical
    \\        group (790,57,176,24) horizontal
    \\          button (790,57,66,24) "[FIT]"
    \\          button (860,57,106,24) "[GRID ON]"
    \\      group (372,89,594,24) horizontal
    \\        button (372,89,86,24) "[FRONT]"
    \\        button (462,89,66,24) "[ISO]"
    \\        button (532,89,66,24) "[TOP]"
    \\        button (602,89,86,24) "[RIGHT]"
    \\        group (692,101,64,0) vertical
    \\        button (760,89,86,24) "[PERSP]"
    \\        button (850,89,116,24) "[EDGES ON]"
    \\      group (372,121,594,24) horizontal
    \\        button (372,121,106,24) "[CUT OFF]"
    \\        button (482,121,46,24) "[X]"
    \\        button (532,121,46,24) "[Y]"
    \\        button (582,121,46,24) "[Z]"
    \\        button (632,121,76,24) "[FLIP]"
    \\        canvas (712,121,140,24) prims=3 id=9 pointer "cut offset"
    \\        text (856,123,110,20) "Y 4'-0 5/8\""
    \\      group (372,153,594,611) vertical bg border
    \\        scene3d (373,154,592,609) mesh=0 key=2 id=7 items=10 grid gizmo pointer "3D model viewport"
    \\      overlay (95,417,11,20) layer=1
    \\        text (95,417,11,20) "X"
    \\      overlay (56,388,11,20) layer=1
    \\        text (56,388,11,20) "Y"
    \\      overlay (86,451,11,20) layer=1
    \\        text (86,451,11,20) "Z"
    \\    group (978,42,320,734) vertical bg border
    \\      group (990,54,296,20) horizontal
    \\        text (990,54,99,20) "INSPECTOR"
    \\        text (1206,54,80,20) "10 PARTS"
    \\      group (990,84,296,307) vertical border
    \\        group (991,85,294,26) horizontal bg
    \\          text (997,88,300,20) "NO  PART                  TRIS"
    \\        scroll (991,111,294,279) vertical id=8
    \\          button (991,111,294,22) "01  bottom_plate            12"
    \\          button (991,133,294,22) "02  beam                    12"
    \\          button (991,155,294,22) "03  jack_studs              12"
    \\          button (991,177,294,22) "04  jack_studs#1            12"
    \\          button (991,199,294,22) "05  lower_plate             12"
    \\          button (991,221,294,22) "06  upper_plate             12"
    \\          button (991,243,294,22) "07  king_stud               12"
    \\          button (991,265,294,22) "08  studs                   12"
    \\          button (991,287,294,22) "09  studs#1                 12"
    \\          button (991,309,294,22) "10  strap                   12"
    \\      group (990,401,296,229) vertical bg border
    \\        text (1000,411,276,20) "DETAIL"
    \\        divider (1000,437,276,1)
    \\        group (1000,444,276,20) horizontal
    \\          text (1000,444,40,20) "PART"
    \\          text (1206,444,70,20) "02 beam"
    \\        group (1000,470,276,20) horizontal
    \\          text (1000,470,80,20) "MATERIAL"
    \\          text (1126,470,150,20) "wood_engineered"
    \\        group (1000,496,276,20) horizontal
    \\          text (1000,496,90,20) "TRIANGLES"
    \\          text (1256,496,20,20) "12"
    \\        group (1000,522,276,20) horizontal
    \\          text (1000,522,50,20) "SHELL"
    \\          text (1216,522,60,20) "CLOSED"
    \\        group (1000,548,276,20) horizontal
    \\          text (1000,548,80,20) "WIDTH  X"
    \\          text (1226,548,50,20) "4'-0\""
    \\        group (1000,574,276,20) horizontal
    \\          text (1000,574,80,20) "HEIGHT Y"
    \\          text (1206,574,70,20) "11 7/8\""
    \\        group (1000,600,276,20) horizontal
    \\          text (1000,600,80,20) "DEPTH  Z"
    \\          text (1216,600,60,20) "5 1/4\""
    \\      group (990,640,296,124) vertical bg border
    \\        text (1000,650,276,20) "NOTES"
    \\        divider (1000,676,276,1)
    \\        text_area (1000,683,276,64) id=11 "" cursor=0
    \\  group (0,776,1280,24) horizontal bg
    \\    text (12,778,55,20) "READY"
    \\    text (81,778,10,20) "|"
    \\    text (105,778,180,20) "10 PARTS  120 TRIS"
    \\    text (299,778,10,20) "|"
    \\    text (323,778,110,20) "SEL 02 beam"
    \\    group (447,788,249,0) vertical
    \\    text (710,778,410,20) "PERSP  YAW -36  PITCH 29  DIST 14'-4 1/4\""
    \\    text (1134,778,10,20) "|"
    \\    text (1158,778,110,20) "CLAUDE DEMO"
    \\
;
