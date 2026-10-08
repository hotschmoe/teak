//! Canonical application loop — the `teak.run` wrapper.
//!
//! Every consumer used to hand-copy ~200 lines of host-loop glue:
//! double-buffered `CmdBuffer` + rect storage, the press-target
//! mousedown/up dance, keyboard + wheel routing, clipboard glue, the
//! frame-diff vertex-rebuild skip, layout, transient-state update,
//! `buildVertices` + upload, and `renderFrame`. ~80% of that is
//! identical across apps. `Runtime` ships it once (one `frame` per loop
//! iteration) and `run` is the native `while (!shouldClose())` wrapper.
//!
//! ## Where this sits (HARDLINE)
//!
//! `run` is the host-loop orchestrator. It imports the framework's pure
//! passes (`core`, `layout`, `input`, `render`) but takes the concrete
//! `Host` and `Gpu` as `anytype` parameters — it imports **neither**
//! `platform/*` nor `gpu/*`. The dependency arrow still points inward
//! (HARDLINE §3): the consumer's entry point picks the backends and
//! hands them in; `run` only duck-types the `validateHost` /
//! `validateGpu` surfaces. It lives at `src/run.zig` (a sibling of the
//! library root), not in `src/{core,layout,input,render}/*`, so it is
//! outside the "framework core" the drift audit scans.
//!
//! ## The App contract
//!
//! Required public decls (the existing component shape):
//!   - `Model`            — default-initializable, or expose `Model.init()`
//!   - `Msg`              — tagged union
//!   - `update(*Model, Msg) void`
//!   - `view(*const Model, *CmdBuffer(Msg)) void`
//!
//! Optional decls, each detected at comptime via `@hasDecl` — present
//! only the ones the app needs:
//!   - `keyCharMsg(*const Model, u8) ?Msg`            — typed character
//!   - `keySpecialMsg(*const Model, SpecialKey) ?Msg` — arrows/enter/etc
//!   - `keyNeedsClipboard(SpecialKey) bool`           — pairs with…
//!   - `handleClipboard(*Model, SpecialKey, Clipboard) void` — cut/copy/paste
//!   - `wheelMsg(*const Model, f32) ?Msg`             — vertical wheel
//!   - `canvasMsg(*const Model, CanvasEvent) ?Msg`    — pointer input over
//!     interactive canvases and scenes (`CanvasCmd.pointer`,
//!     `SceneCmd.pointer`, same `id` space): down / move / up / wheel /
//!     leave, plus `layout` on first layout and resize. A press captures the
//!     pointer for its canvas until every button is released. A wheel over a
//!     pointer canvas becomes a `wheel` event INSTEAD of `wheelMsg`.
//!   - `textMsg(*const Model, TextEvent) ?Msg`        — input over `text_area`
//!     cmds (core/text_event.zig): down / drag / up / double + triple click /
//!     wheel with the nearest grapheme `index` resolved against the wrapped
//!     layout; `move` for Up/Down/PageUp/PageDown/Home/End of the FOCUSED
//!     area (resolved visually, the key is consumed); and `metrics` (viewport,
//!     content and caret rect) on first layout and whenever they change, so
//!     the app can clamp scroll and reveal the caret. A press captures the
//!     pointer (drag-select continues outside the rect). The focused caret
//!     rect also feeds `Host.setImeSpot` when the Host has it.
//!   - `scrollMsg(*const Model, id, dx, dy) ?Msg`     — wheel over the
//!     innermost hovered scroll region with `ScrollStyle.id != 0` (a pointer
//!     canvas inside it wins when it is the innermost).
//!   - `virtualRowsMsg(*const Model, id, first_row, heights: []const f32) ?Msg` —
//!     measured main-axis extents of the rows a `VirtualListStyle.id != 0`
//!     list emitted (direct children, from `visible_start`), whenever they
//!     change: how a variable-height list learns real heights from layout.
//!   - `modsMsg(*const Model, mods: Modifiers) ?Msg`  — the modifier keys
//!     (Shift/Ctrl/Alt/Meta) whenever they change, dispatched before the
//!     frame's pointer and key routing, so a click Msg can read them from the Model.
//!   - `scrollLayoutMsg(*const Model, id, vw, vh, cw, ch) ?Msg` — viewport and
//!     content size of every `ScrollStyle.id != 0` region, on its first layout
//!     and whenever either changes, so the app can clamp offsets and draw
//!     scrollbars (the view cannot read layout).
//!   - `hoverMsg(*const Model, PointerEvent(Msg)) ?Msg` — the interactive widget
//!     under the pointer changed (entered, left, or replaced by another).
//!     `ev.hit` is that widget's click Msg, `ev.box` its rect, `ev.now_ms` the
//!     host clock: enough to drive a tooltip (`teak.Tooltip`) with a
//!     `Sub.at` delay, all in the Model.
//!   - `contextMsg(*const Model, PointerEvent(Msg)) ?Msg` — the right button
//!     went down. `ev.hit` is the Msg of the widget under the cursor (null on
//!     empty space), so one hook opens a context menu for any region
//!     (`teak.ContextMenu`); the app maps `hit` to "which row / which panel".
//!   - `sliderMsg(*const Model, grab: Msg, value: f32) ?Msg` — a `slider` cmd is
//!     being dragged: `grab` is its `grab_msg` (which slider), `value` the
//!     0..1 position under the pointer. Fired on press and every frame the
//!     left button stays down (the pointer is captured: the drag keeps
//!     working off the track), and the slider's plain click Msg is NOT
//!     dispatched. Without the hook a slider is click-only.
//!   - `focusedMsg(*const Model) ?Msg`                — the focus Msg of the
//!     currently-focused widget; `run` maps it to a cmd index via
//!     `indexOfFocusMsg` (stable across conditional/reordered widgets)
//!     to drive the focus ring + cursor blink. Also enables built-in
//!     Tab / Shift+Tab traversal between focusable widgets.
//!   - `submitMsg(*const Model) ?Msg`                 — dispatched on the
//!     Enter key (takes precedence over `keySpecialMsg` for Enter)
//!   - `themeFor(*const Model) Theme`                 — per-frame theme
//!   - `windowMsg(*const Model, w: f32, h: f32) ?Msg` — the window (viewport) size, on the first frame and on every resize
//!   - `windowTitle(*const Model) ?[]const u8`        — dynamic title bar
//!   - `secondaryWindow(*const Model) ?SecondaryWindowSpec` — declares a
//!     second top-level window (title + size) that should be open this
//!     frame, or `null` to keep it closed. `run` owns the create/destroy
//!     lifecycle; the app only flips the data-shaped spec. Requires…
//!   - `secondaryView(*const Model, *CmdBuffer(Msg)) void` — the second
//!     window's view (same Cmd type as the primary; a different surface).
//!   - `secondaryClosedMsg(*const Model) ?Msg`        — dispatched when the
//!     user closes the secondary window from the OS, so the app can clear
//!     its own "is it open" state. Optional even within the secondary set.
//!   - `subscribe(*const Model) []const Sub(Msg)`     — declarative timers
//!     (HARDLINE §2 hatch 6). Pure: the app *declares* what to watch; `run`
//!     services the returned subs each frame via `runSubs` on the host's
//!     monotonic clock (`Host.nowMs`) and dispatches any fired `Msg`
//!     through the normal `update` loop. See `docs/features/subscriptions.md`.
//!   - `animationMsg(*const Model, dt_ms: u32) ?Msg`   — frame time while a `Sub.animation_frame` is listed (core/anim.zig)
//!   - `effects(*const Model) []const Effect`         — declarative effects
//!     (HARDLINE §2 hatch 7): HTTP, downloads, file picker, storage, clock,
//!     clipboard, query params. Pure; each effect `id` is handed to the host
//!     once while listed and forgotten when no longer listed.
//!   - `effectMsg(*const Model, EffectResult) ?Msg`   — turns a result into a
//!     Msg. Also receives unsolicited results (images / files dropped on the
//!     window, pasted text), so an app may declare it without `effects`.
//!     See `docs/features/effects.md`.
//!   - `resources(*const Model) []const Resource`     — declarative GPU
//!     resources (HARDLINE §2 hatch 8): meshes and RGBA images keyed by
//!     (`key`, `rev`). `run` uploads on a new key / changed rev, releases
//!     vanished keys, and maps the app keys in `ImageCmd.handle` /
//!     `SceneCmd.mesh` to backend handles. Requires a Gpu with the scene
//!     extension (`uploadMesh`, `releaseMesh`, `renderScenes`,
//!     `releaseImage`). See `docs/features/scene3d.md`.
//!
//! IME composition state (`Host.imeState`) is folded into `TransientState`
//! every frame with no opt-in — hosts without IME report inactive and it
//! costs nothing.
//!
//! Anything the app omits is simply skipped — a static read-only view is
//! just `Model` / `Msg` / `update` / `view`.

const std = @import("std");
const builtin = @import("builtin");

const cmd = @import("core/cmd.zig");
const eql = @import("core/eql.zig");
const snapshot = @import("core/snapshot.zig");
const sub_mod = @import("core/sub.zig");
const effects_mod = @import("core/effects.zig");
const transient = @import("core/transient.zig");
const text = @import("core/text.zig");
const pointer = @import("core/pointer.zig");
const text_event = @import("core/text_event.zig");
const text_wrap = @import("core/text_wrap.zig");
const layout = @import("layout/engine.zig");
const scroll_extent = @import("layout/scroll_extent.zig");
const virtual_rows = @import("layout/virtual_rows.zig");
const hit_test = @import("input/hit_test.zig");
const focus = @import("input/focus.zig");
const render = @import("render/build.zig");
const vertex = @import("render/vertex.zig");
const resources = @import("resources.zig");

const Rect = layout.Rect;
const TransientState = transient.TransientState;

/// Effect ids the loop remembers at once (see `effects.IssuedTable`). More
/// distinct ids listed than this simply wait for a slot to free up.
const max_issued_effects = 32;
/// Results fetched from the host per frame; the rest wait for the next one.
const effect_batch = 16;

pub const RunOptions = struct {
    /// Scene clear color passed to `Gpu.renderFrame` each frame.
    clear_color: [4]f32 = .{ 0.08, 0.08, 0.1, 1.0 },
    /// Text-cursor blink half-period in ms of the Host clock (500 = 500 ms on,
    /// 500 ms off). 0 disables blinking (the caret stays on). While a text
    /// input is focused the loop wakes at each toggle and re-renders only the
    /// caret change (vertices from the last built frame; no view/layout), so
    /// a focused field costs two cheap frames per second when idle.
    blink_half_ms: u32 = 500,
    /// Live-snapshot sink. When non-null (or the `TEAK_SNAPSHOT` env var is
    /// set — env wins), `run` mirrors the current frame's snapshot text to
    /// this file every time the frame content changes, so an LLM agent
    /// driving the running app can read the GUI as data instead of pixels.
    /// The env var is read once at `run` start (never per frame). The write
    /// is atomic (`<path>.tmp` then rename) so a reader never sees a torn
    /// file. A path that can't be written disables the sink for the rest of
    /// the run after one `std.log.warn` — it never crashes or slows the app.
    /// See `docs/features/snapshot.md`. On a target with no host filesystem
    /// (wasm/freestanding) the whole sink compiles out.
    snapshot_path: ?[]const u8 = null,
    /// Names the app for hosts that keep per-app files (native storage lives
    /// under `<config>/teak/<app_name>/`). Empty: the Host's default, the
    /// window title. Ignored by hosts without `setAppName`.
    app_name: []const u8 = "",
    /// Event-driven idle. When true, a frame in which nothing happened (no
    /// input event, no Msg dispatched by a sub / effect result / window hook,
    /// secondary window, not the first frame; a caret toggle is a cheap
    /// re-render of the last frame, see `blink_half_ms`) skips view, layout, diff, upload and present entirely —
    /// `Runtime.quiet` reports it — and `run` then blocks in the Host's
    /// optional `waitEvents(timeout_ms)` until input or the next sub is due.
    /// Set false for an app that needs a frame every tick. The web Host stays
    /// rAF-driven but still skips the work. See docs/features/run.md.
    idle_skip: bool = true,
};

/// The target has a host filesystem to mirror snapshots into. Freestanding
/// (wasm) has none — and never instantiates `run` anyway — so gating the
/// sink on this compiles the file/env machinery out there entirely. run.zig
/// sits outside the framework-core dirs, so the `builtin` reference is
/// allowed here (HARDLINE §3 scopes the conditional-compilation ban to core).
const snapshot_fs_capable = builtin.os.tag != .freestanding;

/// Live-snapshot sink: mirrors each changed frame's `snapshot.write` text to
/// a file for an out-of-band agent to read. Loop-orchestration state only
/// (like `press_target` / the title buffer) — it holds no *application*
/// state and only reflects what the pure passes already produced.
///
/// File I/O goes through `std.Options.debug_io` (the globally-available `Io`
/// std itself uses for diagnostics) and `std.Io.Dir` rather than libc, so the
/// sink works in every build that reaches `run` — including the library test
/// runner, which links no libc. The `TEAK_SNAPSHOT` override is read from the
/// process environment the same globally-available handle exposes. Both are
/// compiled out on `!snapshot_fs_capable`.
const SnapshotSink = struct {
    /// Actively mirroring. Flips to false permanently on the first write
    /// failure (a broken sink must never crash or throttle the app).
    enabled: bool = false,
    /// One-shot latch so the disable-warning is logged at most once.
    failed: bool = false,
    gpa: std.mem.Allocator = undefined,
    /// Destination path and its `<dest>.tmp` sibling (both owned; non-empty
    /// exactly when the sink allocated its resources).
    dest: []const u8 = &.{},
    tmp: []const u8 = &.{},
    /// Reused serialization buffer — bulk-managed like verts/text_draws, so
    /// steady-state frames allocate nothing.
    buf: std.Io.Writer.Allocating = undefined,

    /// Resolve the destination (env `TEAK_SNAPSHOT` wins over `opt_path`,
    /// read exactly once here) and allocate the reusable buffers. Any failure
    /// yields a disabled no-op sink rather than an error.
    fn init(gpa: std.mem.Allocator, opt_path: ?[]const u8) SnapshotSink {
        if (comptime !snapshot_fs_capable) return .{};

        const env_owned = envSnapshotPath(gpa);
        defer if (env_owned) |e| gpa.free(e);

        const chosen = env_owned orelse opt_path orelse return .{};
        if (chosen.len == 0) return .{};

        const dest = gpa.dupe(u8, chosen) catch return .{};
        const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{chosen}) catch {
            gpa.free(dest);
            return .{};
        };
        return .{
            .enabled = true,
            .gpa = gpa,
            .dest = dest,
            .tmp = tmp,
            .buf = std.Io.Writer.Allocating.init(gpa),
        };
    }

    fn deinit(self: *SnapshotSink) void {
        if (comptime !snapshot_fs_capable) return;
        if (self.dest.len == 0) return; // never activated — nothing allocated
        self.buf.deinit();
        self.gpa.free(self.dest);
        self.gpa.free(self.tmp);
    }

    /// Owned dupe of `TEAK_SNAPSHOT` if set and non-empty, else null. Read
    /// from the process environment via the same globally-available `Io`
    /// handle std uses for diagnostics — no libc, no `Io` threaded into
    /// `main` (this fork's bare `main()` gets neither).
    fn envSnapshotPath(gpa: std.mem.Allocator) ?[]u8 {
        if (comptime !snapshot_fs_capable) return null;
        const threaded = std.Options.debug_threaded_io orelse return null;
        var map = threaded.environ.process_environ.createMap(gpa) catch return null;
        defer map.deinit();
        const v = map.get("TEAK_SNAPSHOT") orelse return null;
        if (v.len == 0) return null;
        return gpa.dupe(u8, v) catch null;
    }

    /// Serialize the primary frame (and, when open, the secondary window
    /// below a marker line) and mirror it atomically. Called only when the
    /// loop's frame-diff signals the content changed, so idle frames never
    /// reach here.
    fn writeFrame(
        self: *SnapshotSink,
        header: snapshot.Header,
        cmds: anytype,
        rects: []const Rect,
        ts: *const TransientState,
        sec_title: ?[]const u8,
        sec_cmds: anytype,
        sec_rects: []const Rect,
    ) void {
        if (comptime !snapshot_fs_capable) return;
        if (!self.enabled) return;

        self.buf.clearRetainingCapacity();
        const w = &self.buf.writer;
        snapshot.write(w, cmds, rects, .{ .header = header, .transient = ts }) catch return self.fail();
        if (sec_title) |title| {
            w.print("=== secondary \"{s}\" ===\n", .{title}) catch return self.fail();
            snapshot.write(w, sec_cmds, sec_rects, .{}) catch return self.fail();
        }

        // Atomic swap: write the temp sibling, then rename over the target so
        // a reader mid-write never observes a partial file.
        const io = std.Options.debug_io;
        const dir = std.Io.Dir.cwd();
        dir.writeFile(io, .{ .sub_path = self.tmp, .data = self.buf.written() }) catch return self.fail();
        dir.rename(self.tmp, dir, self.dest, io) catch return self.fail();
    }

    fn fail(self: *SnapshotSink) void {
        self.enabled = false;
        if (self.failed) return;
        self.failed = true;
        std.log.warn("teak: snapshot sink disabled — could not write \"{s}\"", .{self.dest});
    }
};

/// Declares a second top-level window the app wants open this frame.
/// Data-only (HARDLINE §3): `secondaryWindow(*const Model)` returns this
/// or `null`; `run` diffs it against the live window to open / close /
/// resize the OS window + its GPU surface. The app never touches
/// `Host.openSecondaryWindow` / `Gpu.openSecondarySurface` itself.
pub const SecondaryWindowSpec = struct {
    title: []const u8,
    width: u32,
    height: u32,
};

/// Per-frame lifecycle + render state for the optional secondary window.
/// Loop-orchestration state only (like `press_target` / the title buffer)
/// — it holds no *application* state and routes user-close back through
/// `update`. Always instantiated; the `run` loop only drives it when the
/// App exposes the secondary hooks (comptime-gated), so a stub Gpu without
/// `openSecondarySurface` still compiles.
fn SecondaryDriver(comptime CmdBufT: type) type {
    return struct {
        /// Double-buffered like the primary loop, so the snapshot gate can
        /// diff this window's content across frames: the just-built frame is
        /// `bufs[cur]`, the previous one `bufs[cur ^ 1]`. Without the diff a
        /// sub- or input-driven change confined to the secondary view would
        /// never re-mirror the snapshot file.
        bufs: [2]CmdBufT,
        rects: [2]std.ArrayList(Rect),
        cur: u1 = 0,
        /// Host + Gpu id of the live secondary window (lock-step: the
        /// same id keys the Host window slot and the Gpu surface slot).
        window_id: ?u32 = null,

        fn init(gpa: std.mem.Allocator) @This() {
            return .{
                .bufs = .{ CmdBufT.init(gpa), CmdBufT.init(gpa) },
                .rects = .{ .empty, .empty },
            };
        }
        fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            for (&self.bufs) |*b| b.deinit();
            for (&self.rects) |*r| r.deinit(gpa);
        }
    };
}

/// True when two secondary-window specs are identical. Used to suppress an
/// immediate reopen after the user closes the OS window when the app leaves
/// its intent spec unchanged (it omits `secondaryClosedMsg`).
fn secondarySpecEql(a: SecondaryWindowSpec, b: SecondaryWindowSpec) bool {
    return a.width == b.width and a.height == b.height and std.mem.eql(u8, a.title, b.title);
}

/// Run the application against `host` + `gpu` until the host signals
/// close. `gpa` backs the per-frame command buffers, the rect store,
/// and the vertex/text/image upload lists (all bulk-managed, never
/// per-widget). `host` must satisfy `validateHost`, `gpu`
/// `validateGpu`; both are taken as `anytype` pointers so `run` never
/// imports a backend.
///
/// This is `Runtime` driven in a `while (!host.shouldClose())` loop. Hosts
/// that own the loop themselves (the web: the browser calls an exported
/// `frame` once per rAF tick) build a `Runtime` and call `frame` directly.
pub fn run(
    comptime App: type,
    gpa: std.mem.Allocator,
    host: anytype,
    gpu: anytype,
    opts: RunOptions,
) !void {
    var rt = try Runtime(App, @TypeOf(host.*), @TypeOf(gpu.*)).init(gpa, host, gpu, opts);
    defer rt.deinit();
    while (!host.shouldClose()) {
        try rt.frame();
        if (comptime @hasDecl(@TypeOf(host.*), "waitEvents")) {
            if (rt.quiet and !host.shouldClose()) host.waitEvents(rt.idleTimeoutMs());
        }
    }
}

/// The canonical loop body, one `frame` call per iteration, parameterized on
/// the App and the concrete Host/Gpu types (duck-typed against
/// `validateHost` / `validateGpu`; this file imports neither backend).
///
/// `init` builds the retained loop-orchestration state — double-buffered
/// cmd + rect storage, the Model, the press target, the snapshot sink — and
/// `frame` runs exactly one iteration: poll input, route it against the
/// PREVIOUS frame's layout, service subscriptions, build + lay out the
/// view, fold transient state, rebuild/upload vertices when something
/// changed, present, then the secondary window and the snapshot mirror.
///
/// The value must not move after `init` returns anything that points into
/// it; none does today, but keep it in one place (a local or a module-level
/// `var`, as the web entry does).
pub fn Runtime(comptime App: type, comptime Host: type, comptime Gpu: type) type {
    return struct {
        const Self = @This();
        const Msg = App.Msg;
        const CmdBufT = cmd.CmdBuffer(Msg);
        /// The Host's per-frame input snapshot type (`platform/host.zig`'s
        /// `InputState`), recovered from `pollInputs` so this file imports no
        /// platform module.
        const Input = @typeInfo(@TypeOf(Host.pollInputs)).@"fn".return_type.?;
        /// Optional secondary window. Comptime, so the machinery (including
        /// the Gpu surface extensions outside `validateGpu`) is only analyzed
        /// for apps that opt in AND a Gpu that supports secondary surfaces —
        /// the web Gpu has none (and its Host never opens a second window),
        /// so the hooks compile away there.
        const has_canvas_hook = @hasDecl(App, "canvasMsg");
        const has_text_hook = @hasDecl(App, "textMsg");
        /// Any hook that consumes pointer input over id-bearing surfaces.
        const has_pointer_hook = has_canvas_hook or has_text_hook;
        const has_scroll_hook = @hasDecl(App, "scrollMsg");
        const has_scroll_layout_hook = @hasDecl(App, "scrollLayoutMsg");
        const has_rows_hook = @hasDecl(App, "virtualRowsMsg");
        const has_mods_hook = @hasDecl(App, "modsMsg");
        const has_resources = @hasDecl(App, "resources");
        const has_secondary = @hasDecl(App, "secondaryWindow") and @hasDecl(App, "secondaryView") and
            @hasDecl(Gpu, "openSecondarySurface");
        const has_effects = @hasDecl(App, "effects");
        const has_effect_msg = @hasDecl(App, "effectMsg");
        /// The Host's optional effects extension (`submit` + `pollEffectResults`,
        /// validated as a pair). Without it every effect is answered "unsupported".
        const host_effects = @hasDecl(Host, "submit");
        comptime {
            if (has_effects and !has_effect_msg)
                @compileError("App declares `effects` but not `effectMsg`: results would have nowhere to go");
        }

        gpa: std.mem.Allocator,
        host: *Host,
        gpu: *Gpu,
        opts: RunOptions,
        measurer: text.TextMeasurer,

        model: App.Model,
        /// `@tagName` of the last dispatched Msg, for the live snapshot header.
        last_msg: []const u8 = "",

        /// Double-buffered command buffers + parallel rect store: build into
        /// one while input is routed against the other (one-frame input
        /// latency, imperceptible). `current` indexes the newest frame.
        /// Rects grow to fit the frame — there is no fixed cap.
        bufs: [2]CmdBufT,
        rects: [2]std.ArrayList(Rect) = .{ .empty, .empty },
        current: u1 = 0,

        verts: std.ArrayList(vertex.Vertex) = .empty,
        text_draws: std.ArrayList(text.TextDraw) = .empty,
        image_draws: std.ArrayList(render.ImageDraw) = .empty,
        scene_draws: std.ArrayList(render.SceneDraw) = .empty,
        scene_items: std.ArrayList(render.SceneItem) = .empty,

        /// Declarative GPU resources (HARDLINE §2 hatch 8): which
        /// (kind, key, rev) is resident and under which Gpu handle. Loop
        /// bookkeeping — a safely-losable cache of GPU residency.
        res_table: resources.Table = .{},

        ts: TransientState = .{},
        prev_ts: TransientState = .{},

        /// Interactive-canvas routing: which canvas has the pointer
        /// captured / is hovered (by `CanvasCmd.id`, stable across frames
        /// unlike cmd indices) and the last position a canvas saw, for
        /// `move` deltas. Loop bookkeeping like `press_target`; the app's
        /// own state still lives in its Model.
        canvas_ptr: CanvasPointer = .{},

        /// Click-count tracking for text areas (same spot within 400 ms).
        text_click: TextClick = .{},
        /// Last `metrics` reported per text area (by id). Loop bookkeeping:
        /// only used to decide when to re-send; extra areas beyond the table
        /// are re-reported every frame they differ from "unknown".
        text_metrics: [8]TextMetricsSlot = @splat(.{}),
        /// Last IME spot pushed to the Host (avoid per-frame calls).
        ime_spot: ?[2]i32 = null,

        /// Press model: arm on mousedown over a widget, fire the click only
        /// if mouseup lands on the same widget; drag-off cancels.
        press_target: ?usize = null,

        /// Cmd index last reported to `hoverMsg`; loop bookkeeping like
        /// `press_target` (a lost value only repeats one hover event).
        hover_reported: ?usize = null,
        hover_seen: bool = false,
        /// The `grab_msg` of the slider being dragged (`sliderMsg` hook).
        slider_grab: ?Msg = null,

        /// The previous frame's `nowMs`. `runSubs` is stateless — it decides
        /// fire/skip from (last_sub_ms, now_ms, sub data) — so this single
        /// timestamp is all the bookkeeping the loop holds. `null` until the
        /// first frame binds it: no sub fires on the opening tick.
        last_sub_ms: ?u64 = null,
        /// Modifier state last reported through `modsMsg`.
        last_mods: pointer.Modifiers = .{},

        /// Effect ids handed to the host and still listed by the app.
        issued: effects_mod.IssuedTable(max_issued_effects) = .{},

        secondary: SecondaryDriver(CmdBufT),
        /// After the user closes the OS window, the spec that was open, so
        /// we don't immediately reopen it while the app still reports the
        /// same spec (it omits `secondaryClosedMsg`). Cleared once the spec
        /// changes (or goes null).
        suppressed_spec: ?SecondaryWindowSpec = null,

        snap: SnapshotSink,
        /// Force a first snapshot write even if the opening frame happens to
        /// match the empty previous buffer.
        snap_first: bool = true,
        prev_secondary_open: bool = false,

        /// True when the last `frame()` found nothing to do and skipped the
        /// pipeline (see `RunOptions.idle_skip`). `run` blocks in
        /// `Host.waitEvents` while this holds.
        quiet: bool = false,
        /// Count of Msgs dispatched so far; a frame that leaves it unchanged
        /// changed no state.
        dispatch_count: u64 = 0,
        /// Pointer position / buttons of the previous frame, to tell a still
        /// mouse from a moved one.
        last_mouse_x: f32 = -1,
        last_mouse_y: f32 = -1,
        last_buttons: pointer.Buttons = .{},
        /// A `Sub.animation_frame` is listed: frames must keep flowing.
        animating: bool = false,
        /// The first frame always builds (nothing to show yet).
        built_once: bool = false,

        /// Last title pushed to the host, so `setTitle` fires only on change.
        title_buf: [256]u8 = undefined,
        title_len: usize = 0,

        /// Loop-owned IME composition buffers. `Host.imeState().text`
        /// aliases the Host's single mutable global, so `ts.ime_text` and
        /// `prev_ts.ime_text` would point at the SAME memory — a same-length
        /// composition edit would compare equal and render stale. Each
        /// frame's composition is copied into the buffer keyed by `current`
        /// so the two reference distinct storage.
        ime_bufs: [2][128]u8 = undefined,

        pub fn init(gpa: std.mem.Allocator, host: *Host, gpu: *Gpu, opts: RunOptions) !Self {
            if (comptime @hasDecl(Host, "setAppName")) {
                if (opts.app_name.len > 0) host.setAppName(opts.app_name);
            }
            return .{
                .gpa = gpa,
                .host = host,
                .gpu = gpu,
                .opts = opts,
                .measurer = host.textMeasurer(),
                .model = if (@hasDecl(App.Model, "init")) App.Model.init() else .{},
                .bufs = .{ CmdBufT.init(gpa), CmdBufT.init(gpa) },
                .secondary = SecondaryDriver(CmdBufT).init(gpa),
                .snap = SnapshotSink.init(gpa, opts.snapshot_path),
            };
        }

        pub fn deinit(self: *Self) void {
            if (has_secondary) {
                if (self.secondary.window_id) |wid| {
                    self.gpu.closeSecondarySurface(wid);
                    self.host.closeSecondaryWindow(wid);
                }
            }
            self.snap.deinit();
            self.secondary.deinit(self.gpa);
            if (has_resources) self.res_table.deinit(self.gpu);
            self.scene_draws.deinit(self.gpa);
            self.scene_items.deinit(self.gpa);
            self.image_draws.deinit(self.gpa);
            self.text_draws.deinit(self.gpa);
            self.verts.deinit(self.gpa);
            for (&self.rects) |*r| r.deinit(self.gpa);
            for (&self.bufs) |*b| b.deinit();
        }

        /// One loop iteration. Returns early, before presenting, when the
        /// host reports close during the input poll.
        pub fn frame(self: *Self) !void {
            const input = self.host.pollInputs();
            if (self.host.shouldClose()) return;
            // A Host with logical pixels (Win32 per-monitor DPI) tells the
            // Gpu how many physical pixels back each one, before resizing.
            if (comptime @hasDecl(Host, "renderScale") and @hasDecl(Gpu, "setScale")) {
                self.gpu.setScale(self.host.renderScale());
            }
            if (input.resized) {
                self.gpu.resize(input.width, input.height);
                if (@hasDecl(App, "windowMsg")) {
                    if (App.windowMsg(&self.model, @floatFromInt(input.width), @floatFromInt(input.height))) |m| self.dispatch(m);
                }
            }

            if (has_mods_hook and !std.meta.eql(input.mods, self.last_mods)) {
                self.last_mods = input.mods;
                if (App.modsMsg(&self.model, input.mods)) |m| self.dispatch(m);
            }

            // Input is routed against the PREVIOUS frame's layout — the one
            // the user is looking at — so `prev` is captured before the swap.
            const prev = self.current;
            const dispatched_before = self.dispatch_count;
            self.routeMouse(input, prev);
            self.routePointerHooks(input, prev);
            self.routeCanvasPointer(input, prev);
            self.routeKeys(input, prev);
            self.routeWheel(input, prev);
            self.deliverEffectResults();
            self.fireSubs();
            self.serviceEffects();

            // Event-driven idle: nothing changed since the frame on screen.
            self.quiet = self.opts.idle_skip and self.built_once and
                self.dispatch_count == dispatched_before and self.inputIdle(input);
            self.last_mouse_x = input.mouse_x;
            self.last_mouse_y = input.mouse_y;
            self.last_buttons = input.buttons;
            if (self.quiet) {
                // Idle, but the caret may be due to toggle: redraw the last
                // built frame with the new phase (no view / layout / diff).
                if (self.blinkDue()) {
                    self.ts.blink_on = !self.ts.blink_on;
                    const last = self.current;
                    self.uploadFrame(self.bufs[last].cmds.items, self.rects[last].items, self.ts);
                    self.prev_ts = self.ts;
                    self.gpu.renderFrame(self.opts.clear_color);
                }
                return;
            }
            self.built_once = true;

            const cur = try self.buildView(input);
            self.reportLayout(prev, cur);
            const cur_cmds = self.bufs[cur].cmds.items;
            const cur_rects = self.rects[cur].items;
            self.updateTransient(input, cur);
            self.updateImeSpot(cur);
            self.pushTitle();

            // Frame diff: skip the vertex rebuild + upload when nothing
            // observable changed. The blink tick forces a rebuild on a phase
            // boundary so a focused cursor animates.
            const res_changed = has_resources and self.res_table.sync(self.gpu, App.resources(&self.model));
            const diff = FrameDiff{
                .cmds_same = cmdsEqual(Msg, cur_cmds, self.bufs[prev].cmds.items),
                .rects_same = rectsEqual(cur_rects, self.rects[prev].items),
                .ts_same = transientSame(self.ts, self.prev_ts),
            };
            // A live secondary window re-uploads into the shared Gpu scratch
            // buffers after the primary present, so the primary must rebuild
            // its own vertices every frame while it's open.
            const secondary_open = has_secondary and App.secondaryWindow(&self.model) != null;
            // A resource upload/release changes the handles the draws map to
            // even when no Cmd changed, so it forces a re-stage too.
            if (diff.changed() or secondary_open or res_changed) {
                self.uploadFrame(cur_cmds, cur_rects, self.ts);
            }
            self.prev_ts = self.ts;

            self.gpu.renderFrame(self.opts.clear_color);

            const sec = if (has_secondary) try self.driveSecondary() else SecondaryFrame{};

            // Live snapshot: mirror only when the content changed (the same
            // signal that gates the vertex rebuild, minus the cosmetic blink
            // tick) so idle frames never touch disk. A secondary open/close
            // transition also counts, and the very first frame always writes.
            if (self.snap.enabled) {
                const sec_open_now = sec.title != null;
                if (self.snap_first or diff.changed() or sec_open_now != self.prev_secondary_open or sec.content_changed) {
                    self.snap.writeFrame(.{
                        .window_w = @floatFromInt(input.width),
                        .window_h = @floatFromInt(input.height),
                        .frame = self.ts.frame_counter,
                        .last_msg = self.last_msg,
                    }, cur_cmds, cur_rects, &self.ts, sec.title, self.secondary.bufs[self.secondary.cur].cmds.items, self.secondary.rects[self.secondary.cur].items);
                }
                self.snap_first = false;
                self.prev_secondary_open = sec_open_now;
            }
        }

        /// True when `input` carries nothing the pipeline must react to and no
        /// loop-owned animation (cursor blink, live secondary window, IME
        /// composition) needs the next frame.
        fn inputIdle(self: *Self, input: Input) bool {
            if (input.resized or input.mouse_down or input.mouse_up) return false;
            if (input.mouse_x != self.last_mouse_x or input.mouse_y != self.last_mouse_y) return false;
            if (!std.meta.eql(input.buttons, self.last_buttons)) return false;
            if (input.wheel_dx != 0 or input.wheel_dy != 0) return false;
            if (input.chars.len != 0 or input.keys.len != 0) return false;
            if (self.animating) return false;
            if (self.ts.ime_active or self.host.imeState().active) return false;
            if (has_secondary and App.secondaryWindow(&self.model) != null) return false;
            if (has_secondary and self.secondary.window_id != null) return false;
            return true;
        }

        /// The caret phase the Host clock says should be showing right now.
        fn blinkPhase(self: *Self) bool {
            const half = self.opts.blink_half_ms;
            if (half == 0) return true;
            return (self.host.nowMs() / half) & 1 == 0;
        }

        /// A focused text input's caret is showing the wrong phase.
        fn blinkDue(self: *Self) bool {
            if (self.opts.blink_half_ms == 0 or self.ts.focus_index == null) return false;
            return self.blinkPhase() != self.ts.blink_on;
        }

        /// How long the Host may block after a quiet frame: until the next
        /// `Sub` is due, capped so a Host without its own wake-ups is polled.
        pub fn idleTimeoutMs(self: *Self) u32 {
            // Effect results arrive from the Host asynchronously; poll them
            // at frame rate while any effect is outstanding.
            const cap: u32 = if (self.issued.len != 0) 16 else 1000;
            var wait: u32 = cap;
            const now = self.host.nowMs();
            if (self.opts.blink_half_ms != 0 and self.ts.focus_index != null) {
                // Sleep until the caret's next toggle.
                const half = self.opts.blink_half_ms;
                wait = @min(wait, @as(u32, @intCast(half - now % half)));
            }
            if (@hasDecl(App, "subscribe")) {
                if (sub_mod.nextDueMs(Msg, App.subscribe(&self.model), now)) |due| wait = @intCast(@min(due, wait));
            }
            return wait;
        }

        /// Every Msg is routed through here so the live snapshot's header can
        /// name the last transition. Adds nothing to the TEA loop — it is
        /// `App.update` plus one string assignment.
        fn dispatch(self: *Self, msg: Msg) void {
            self.dispatch_count +%= 1;
            self.last_msg = @tagName(std.meta.activeTag(msg));
            App.update(&self.model, msg);
        }

        /// Press target + click dispatch against the previous frame.
        fn routeMouse(self: *Self, input: Input, prev: u1) void {
            const prev_cmds = self.bufs[prev].cmds.items;
            const prev_rects = self.rects[prev].items;
            const hover: ?usize = if (prev_cmds.len > 0)
                hit_test.hoverTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)
            else
                null;

            var slider_consumed = false;
            if (comptime @hasDecl(App, "sliderMsg")) slider_consumed = self.routeSlider(input, prev_cmds, prev_rects, hover);

            if (input.mouse_down) self.press_target = hover;
            if (input.mouse_up) {
                if (!slider_consumed and self.press_target != null and hover == self.press_target) {
                    if (hit_test.hitTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)) |hit| {
                        // `hit.msg` is null when a modal overlay consumed the
                        // click but asked for no Msg (HARDLINE §2 hatch 5) —
                        // swallow it, don't fall through.
                        if (hit.msg) |m| self.dispatch(m);
                    }
                }
                self.press_target = null;
            }
            if (self.press_target != null and hover != self.press_target) self.press_target = null;
        }

        /// `hoverMsg` / `contextMsg`: both resolve the pointer against the
        /// previous frame's layout like a click does.
        fn routePointerHooks(self: *Self, input: Input, prev: u1) void {
            const has_hover = comptime @hasDecl(App, "hoverMsg");
            const has_context = comptime @hasDecl(App, "contextMsg");
            if (!has_hover and !has_context) return;
            const cmds = self.bufs[prev].cmds.items;
            const rects = self.rects[prev].items;
            const hit = if (cmds.len > 0) hit_test.hitTest(cmds, rects, input.mouse_x, input.mouse_y) else null;
            const under: ?usize = if (hit) |h| h.index else null;

            if (has_hover) {
                if (!self.hover_seen or under != self.hover_reported) {
                    const first = !self.hover_seen;
                    self.hover_seen = true;
                    self.hover_reported = under;
                    // Nothing to report before the first frame laid anything out.
                    if (!(first and under == null)) {
                        if (App.hoverMsg(&self.model, self.pointerEvent(input, hit, rects))) |m| self.dispatch(m);
                    }
                }
            }
            if (has_context and input.button_down.right) {
                if (App.contextMsg(&self.model, self.pointerEvent(input, hit, rects))) |m| self.dispatch(m);
            }
        }

        fn pointerEvent(self: *Self, input: Input, hit: anytype, rects: []const Rect) pointer.PointerEvent(Msg) {
            var ev: pointer.PointerEvent(Msg) = .{
                .x = input.mouse_x,
                .y = input.mouse_y,
                .mods = input.mods,
                .now_ms = self.host.nowMs(),
            };
            if (hit) |h| {
                // A modal backdrop that swallows the click has no Msg: report it as empty space.
                ev.hit = h.msg;
                if (h.msg != null and h.index < rects.len) {
                    const r = rects[h.index];
                    ev.box = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
                }
            }
            return ev;
        }

        /// Slider drag with pointer capture (`sliderMsg`). Returns true when
        /// this frame's press / release belongs to a slider, so the plain
        /// click dispatch must be skipped.
        fn routeSlider(self: *Self, input: Input, cmds: anytype, rects: []const Rect, hover: ?usize) bool {
            var consumed = false;
            if (input.mouse_down) {
                if (hover) |idx| if (idx < cmds.len and idx < rects.len) switch (cmds[idx]) {
                    .slider => |sl| {
                        self.slider_grab = sl.grab_msg;
                        consumed = true;
                    },
                    else => {},
                };
            }
            if (self.slider_grab) |grab| {
                consumed = true;
                if (focus.indexOfFocusMsg(cmds, grab)) |idx| {
                    if (idx < rects.len) {
                        const v = hit_test.sliderValueAt(rects[idx], input.mouse_x);
                        if (App.sliderMsg(&self.model, grab, v)) |m| self.dispatch(m);
                    }
                }
                if (!input.buttons.left) self.slider_grab = null;
            }
            return consumed;
        }

        /// Characters first, then special keys; clipboard chords route to the
        /// app's own handler with the Host clipboard vtable (the app owns
        /// cut/copy/paste policy).
        fn routeKeys(self: *Self, input: Input, prev: u1) void {
            const prev_cmds = self.bufs[prev].cmds.items;
            if (@hasDecl(App, "keyCharMsg")) {
                for (input.chars) |ch| {
                    if (App.keyCharMsg(&self.model, ch)) |m| self.dispatch(m);
                }
            }
            for (input.keys) |k| {
                // Visual motion in a focused text area is resolved against the
                // wrapped layout, so it becomes a `move` TextEvent (key consumed).
                if (has_text_hook) {
                    if (self.sendTextNav(k, input, prev)) continue;
                }
                // Built-in Tab / Shift+Tab focus traversal — only for apps
                // that expose `focusedMsg` (so the loop knows the current
                // focus and how to move it). Walk the PREVIOUS frame's
                // focusables, then dispatch the landing widget's focus Msg
                // so the app advances its focus field.
                if (@hasDecl(App, "focusedMsg")) {
                    if (k == .tab or k == .shift_tab) {
                        const cur_idx = if (App.focusedMsg(&self.model)) |fm|
                            focus.indexOfFocusMsg(prev_cmds, fm)
                        else
                            null;
                        const target = if (k == .tab)
                            focus.nextFocusable(prev_cmds, cur_idx)
                        else
                            focus.prevFocusable(prev_cmds, cur_idx);
                        if (target) |ti| {
                            if (focus.focusMsgAt(prev_cmds, ti)) |fm| self.dispatch(fm);
                        }
                        continue;
                    }
                }
                // Enter-to-submit — apps opt in with `submitMsg`. Takes
                // precedence over `keySpecialMsg` for the Enter key only.
                if (@hasDecl(App, "submitMsg")) {
                    if (k == .enter) {
                        if (App.submitMsg(&self.model)) |m| self.dispatch(m);
                        continue;
                    }
                }
                const clipboard_capable = comptime (@hasDecl(App, "keyNeedsClipboard") and @hasDecl(App, "handleClipboard"));
                if (clipboard_capable and App.keyNeedsClipboard(k)) {
                    App.handleClipboard(&self.model, k, self.host.clipboard());
                } else if (@hasDecl(App, "keySpecialMsg")) {
                    if (App.keySpecialMsg(&self.model, k)) |m| self.dispatch(m);
                }
            }
        }

        /// Wheel routing, innermost consumer first: a captured or hovered
        /// pointer canvas, else the innermost id-bearing scroll region, else
        /// the app's plain `wheelMsg`.
        fn routeWheel(self: *Self, input: Input, prev: u1) void {
            if (input.wheel_dy == 0 and input.wheel_dx == 0) return;
            const cmds = self.bufs[prev].cmds.items;
            const rects = self.rects[prev].items;

            if (has_pointer_hook) {
                // A captured canvas takes every wheel event, wherever the cursor is.
                if (self.canvas_ptr.capture) |id| return self.sendCanvasEvent(id, .wheel, input, prev, .none);
            }
            if (has_pointer_hook or has_scroll_hook) {
                if (hit_test.wheelTarget(cmds, rects, input.mouse_x, input.mouse_y)) |target| switch (target) {
                    .canvas => |c| if (has_pointer_hook) return self.sendCanvasEvent(c.id, .wheel, input, prev, .none),
                    .scroll => |sc| if (has_scroll_hook) {
                        if (App.scrollMsg(&self.model, sc.id, input.wheel_dx, input.wheel_dy)) |m| self.dispatch(m);
                        return;
                    },
                };
            }
            if (@hasDecl(App, "wheelMsg")) {
                if (App.wheelMsg(&self.model, input.wheel_dy)) |m| self.dispatch(m);
            }
        }

        /// Pointer input over interactive canvases (`CanvasCmd.pointer`),
        /// resolved against the previous frame's layout: hover enter / leave,
        /// `move`, button `down` / `up`, and capture — a press on a canvas
        /// sends it every following event (even off its rect) until all
        /// buttons are released. A button held since before the cursor reached
        /// a canvas (pressed elsewhere) does not hover it, so dragging a
        /// slider across a canvas does not poke the canvas. Wheel is routed
        /// separately (`routeWheel`).
        fn routeCanvasPointer(self: *Self, input: Input, prev: u1) void {
            if (!has_pointer_hook) return;
            const cmds = self.bufs[prev].cmds.items;
            const rects = self.rects[prev].items;
            const p = &self.canvas_ptr;
            const under = hit_test.pointerTarget(cmds, rects, input.mouse_x, input.mouse_y);

            // A capture whose canvas left the view can never see its release.
            if (p.capture) |id| {
                if (findPointerCanvas(cmds, id) == null) p.* = .{};
            }

            // Hover enter / leave (suspended while captured).
            if (p.capture == null) {
                const pressed_elsewhere = heldBeforeFrame(input).any();
                const want: ?u32 = if (under != null and !pressed_elsewhere) under.?.id else null;
                if (p.hover != want) {
                    if (p.hover) |old| self.sendCanvasEvent(old, .leave, input, prev, .none);
                    p.hover = want;
                    p.has_last = false;
                }
            }

            // Move: on entry (dx = dy = 0) and whenever the cursor moved.
            if (p.capture orelse p.hover) |id| {
                if (!p.has_last or p.last_x != input.mouse_x or p.last_y != input.mouse_y) {
                    const dx = if (p.has_last) input.mouse_x - p.last_x else 0;
                    const dy = if (p.has_last) input.mouse_y - p.last_y else 0;
                    p.has_last = true;
                    p.last_x = input.mouse_x;
                    p.last_y = input.mouse_y;
                    self.sendCanvasMove(id, input, prev, dx, dy);
                }
            }

            const buttons = [_]pointer.Button{ .left, .middle, .right };
            for (buttons) |b| {
                if (!buttonSet(input.button_down, b)) continue;
                if (p.capture == null) {
                    const u = under orelse continue;
                    p.capture = u.id;
                    p.hover = u.id;
                }
                self.sendCanvasEvent(p.capture.?, .down, input, prev, b);
            }
            for (buttons) |b| {
                if (!buttonSet(input.button_up, b)) continue;
                if (p.capture) |id| self.sendCanvasEvent(id, .up, input, prev, b);
            }

            // Capture ends with the last release; if the cursor is no longer
            // over the canvas it has now left it.
            if (p.capture) |id| {
                if (!input.buttons.any()) {
                    p.capture = null;
                    if (under == null or under.?.id != id) {
                        self.sendCanvasEvent(id, .leave, input, prev, .none);
                        p.hover = null;
                        p.has_last = false;
                    }
                }
            }
        }

        fn sendCanvasMove(self: *Self, id: u32, input: Input, prev: u1, dx: f32, dy: f32) void {
            const cmds = self.bufs[prev].cmds.items;
            const idx = findPointerCanvas(cmds, id) orelse return;
            if (cmds[idx] == .text_area) return self.sendTextPointer(idx, .move, input, prev, .none);
            var ev = canvasEventAt(id, .move, input, self.rects[prev].items[idx], .none);
            ev.dx = dx;
            ev.dy = dy;
            self.dispatchCanvas(ev);
        }

        /// Deliver one event to canvas `id`, located in the previous frame's
        /// layout. A canvas no longer in that layout is skipped.
        fn sendCanvasEvent(self: *Self, id: u32, kind: pointer.CanvasEventKind, input: Input, prev: u1, button: pointer.Button) void {
            const cmds = self.bufs[prev].cmds.items;
            const idx = findPointerCanvas(cmds, id) orelse return;
            if (cmds[idx] == .text_area) return self.sendTextPointer(idx, kind, input, prev, button);
            var ev = canvasEventAt(id, kind, input, self.rects[prev].items[idx], button);
            if (kind == .wheel) {
                ev.dx = input.wheel_dx;
                ev.dy = input.wheel_dy;
            }
            self.dispatchCanvas(ev);
        }

        fn dispatchCanvas(self: *Self, ev: pointer.CanvasEvent) void {
            if (!has_canvas_hook) return;
            if (App.canvasMsg(&self.model, ev)) |m| self.dispatch(m);
        }

        // ── text_area routing ──────────────────────────────────────────

        /// Wrap mode + width a text area lays its content out with.
        fn textAreaGeometry(ta: anytype, rect: Rect) struct { inner: Rect, wrap_w: f32, mode: text_wrap.Wrap } {
            const inner = layout.textAreaInner(rect, ta);
            return .{
                .inner = inner,
                .wrap_w = layout.textAreaWrapWidth(inner, ta),
                .mode = if (ta.wrap == .ellipsis) .none else ta.wrap,
            };
        }

        /// A pointer event over (or captured by) text area `idx`, resolved
        /// against the previous frame's layout into a `TextEvent`.
        fn sendTextPointer(self: *Self, idx: usize, kind: pointer.CanvasEventKind, input: Input, prev: u1, button: pointer.Button) void {
            if (!has_text_hook) return;
            const ta = self.bufs[prev].cmds.items[idx].text_area;
            const rect = self.rects[prev].items[idx];
            const g = textAreaGeometry(ta, rect);
            var ev: text_event.TextEvent = .{
                .id = ta.id,
                .kind = .down,
                .x = input.mouse_x - rect.x,
                .y = input.mouse_y - rect.y,
                .mods = input.mods,
            };
            switch (kind) {
                .down => {
                    if (button != .left) return;
                    const now = self.host.nowMs();
                    const c = &self.text_click;
                    const near = @abs(input.mouse_x - c.x) <= 4 and @abs(input.mouse_y - c.y) <= 4;
                    c.count = if (c.count > 0 and c.count < 3 and near and now -| c.ms <= 400) c.count + 1 else 1;
                    c.ms = now;
                    c.x = input.mouse_x;
                    c.y = input.mouse_y;
                    ev.clicks = c.count;
                    ev.kind = switch (c.count) {
                        1 => .down,
                        2 => .double_click,
                        else => .triple_click,
                    };
                },
                .move => {
                    if (!input.buttons.left) return;
                    ev.kind = .drag;
                },
                .up => {
                    if (button != .left) return;
                    ev.kind = .up;
                },
                .wheel => {
                    ev.kind = .wheel;
                    ev.dx = input.wheel_dx;
                    ev.dy = input.wheel_dy;
                },
                .leave => ev.kind = .leave,
                .layout => return,
            }
            switch (ev.kind) {
                .down, .drag, .double_click, .triple_click, .up => {
                    const lx = input.mouse_x - g.inner.x + ta.scroll_x;
                    const ly = input.mouse_y - g.inner.y + ta.scroll_y;
                    const at = text_wrap.indexAt(ta.content, lx, ly, ta.font, g.wrap_w, g.mode, 0, self.measurer);
                    ev.index = @intCast(at);
                    ev.line = text_wrap.caretPos(ta.content, at, ta.font, g.wrap_w, g.mode, 0, self.measurer).line;
                },
                else => {},
            }
            if (App.textMsg(&self.model, ev)) |m| self.dispatch(m);
        }

        /// Up/Down/PageUp/PageDown/Home/End (and Shift variants) while a text
        /// area has focus: resolve against the wrapped layout and deliver a
        /// `move` event instead of the key. Returns true when consumed.
        fn sendTextNav(self: *Self, k: @import("input/keys.zig").SpecialKey, input: Input, prev: u1) bool {
            const Nav = struct { kind: text_wrap.NavKind, extend: bool };
            const nav: Nav = switch (k) {
                .up => .{ .kind = .up, .extend = false },
                .shift_up => .{ .kind = .up, .extend = true },
                .down => .{ .kind = .down, .extend = false },
                .shift_down => .{ .kind = .down, .extend = true },
                .page_up => .{ .kind = .page_up, .extend = false },
                .page_down => .{ .kind = .page_down, .extend = false },
                .home => .{ .kind = .line_start, .extend = false },
                .shift_home => .{ .kind = .line_start, .extend = true },
                .end => .{ .kind = .line_end, .extend = false },
                .shift_end => .{ .kind = .line_end, .extend = true },
                else => return false,
            };
            const cmds = self.bufs[prev].cmds.items;
            const fi = focusIndex(App, &self.model, cmds) orelse return false;
            if (fi >= cmds.len or cmds[fi] != .text_area) return false;
            const ta = cmds[fi].text_area;
            const g = textAreaGeometry(ta, self.rects[prev].items[fi]);
            const lh = text_wrap.lineHeight(ta.font, self.measurer);
            const rows: f32 = if (lh > 0) @floor(g.inner.h / lh) else 1;
            const page: u32 = @intFromFloat(@max(1, rows - 1));
            const r = text_wrap.resolveNav(ta.content, ta.cursor, ta.goal_x, nav.kind, page, ta.font, g.wrap_w, g.mode, self.measurer);
            var mods = input.mods;
            mods.shift = nav.extend;
            const ev: text_event.TextEvent = .{
                .id = ta.id,
                .kind = .move,
                .index = @intCast(r.index),
                .line = r.line,
                .goal_x = r.goal_x orelse 0,
                .keep_goal = r.goal_x != null,
                .mods = mods,
            };
            if (App.textMsg(&self.model, ev)) |m| self.dispatch(m);
            return true;
        }

        /// The layout facts of text area `i` as a `metrics` event.
        fn textMetricsAt(self: *Self, cmds: anytype, rects: []const Rect, i: usize) text_event.TextEvent {
            const ta = cmds[i].text_area;
            const g = textAreaGeometry(ta, rects[i]);
            const mw = text_wrap.measureWrapped(ta.content, ta.font, g.wrap_w, g.mode, 0, self.measurer);
            const c = text_wrap.caretPos(ta.content, ta.cursor, ta.font, g.wrap_w, g.mode, 0, self.measurer);
            return .{
                .id = ta.id,
                .kind = .metrics,
                .line = c.line,
                .viewport_w = g.inner.w,
                .viewport_h = g.inner.h,
                .content_w = mw.w,
                .content_h = mw.h,
                .caret_x = c.x,
                .caret_y = c.y,
                .caret_h = text_wrap.lineHeight(ta.font, self.measurer),
            };
        }

        /// Send `metrics` for text area `i` on first sight and on change.
        fn reportTextMetrics(self: *Self, cmds: anytype, rects: []const Rect, i: usize) void {
            const ev = self.textMetricsAt(cmds, rects, i);
            var free: ?usize = null;
            for (&self.text_metrics, 0..) |*slot, s| {
                if (slot.id == ev.id) {
                    if (std.meta.eql(slot.ev, ev)) return;
                    slot.ev = ev;
                    break;
                }
                if (slot.id == 0 and free == null) free = s;
            } else if (free) |s| {
                self.text_metrics[s] = .{ .id = ev.id, .ev = ev };
            }
            if (App.textMsg(&self.model, ev)) |m| self.dispatch(m);
        }

        /// Tell the Host where the focused caret is so an IME candidate
        /// window opens next to it (window logical px, just below the caret).
        fn updateImeSpot(self: *Self, cur: u1) void {
            if (!@hasDecl(Host, "setImeSpot")) return;
            const cmds = self.bufs[cur].cmds.items;
            const rects = self.rects[cur].items;
            const fi = self.ts.focus_index orelse return;
            if (fi >= cmds.len) return;
            var sx: f32 = undefined;
            var sy: f32 = undefined;
            switch (cmds[fi]) {
                .text_area => |ta| {
                    const g = textAreaGeometry(ta, rects[fi]);
                    const c = text_wrap.caretPos(ta.content, ta.cursor, ta.font, g.wrap_w, g.mode, 0, self.measurer);
                    sx = g.inner.x - ta.scroll_x + c.x;
                    sy = g.inner.y - ta.scroll_y + c.y + text_wrap.lineHeight(ta.font, self.measurer);
                },
                .text_input => |ti| {
                    sx = rects[fi].x + 6 + self.measurer.prefixWidth(ti.content, ti.font, ti.cursor);
                    sy = rects[fi].y + rects[fi].h;
                },
                else => return,
            }
            const spot = [2]i32{ @intFromFloat(sx), @intFromFloat(sy) };
            if (self.ime_spot) |old| if (old[0] == spot[0] and old[1] == spot[1]) return;
            self.ime_spot = spot;
            self.host.setImeSpot(spot[0], spot[1]);
        }

        /// Tell the app about layout results it cannot read from `view`:
        /// a pointer canvas's rect (`CanvasEvent.layout`: size + window origin) and an id-bearing
        /// scroll region's viewport + content size (`scrollLayoutMsg`), each
        /// on first layout and whenever the value differs from the previous
        /// frame's. The resulting Msg takes effect in the NEXT frame's view.
        fn reportLayout(self: *Self, prev: u1, cur: u1) void {
            if (!has_pointer_hook and !has_scroll_layout_hook and !has_rows_hook) return;
            const cmds = self.bufs[cur].cmds.items;
            const rects = self.rects[cur].items;
            const prev_cmds = self.bufs[prev].cmds.items;
            const prev_rects = self.rects[prev].items;
            for (cmds, 0..) |c, i| switch (c) {
                .canvas, .scene3d => if (has_canvas_hook) if (hit_test.pointerSurface(cmds, i)) |t| {
                    const old = findPointerCanvas(prev_cmds, t.id);
                    const same = old != null and std.meta.eql(prev_rects[old.?], rects[i]);
                    if (!same) {
                        self.dispatchCanvas(.{ .id = t.id, .kind = .layout, .x = rects[i].x, .y = rects[i].y, .w = rects[i].w, .h = rects[i].h });
                    }
                },
                .text_area => if (has_text_hook) self.reportTextMetrics(cmds, rects, i),
                .push_scroll => |sc| if (has_scroll_layout_hook and sc.id != 0) {
                    const now = scroll_extent.scrollExtent(cmds, rects, i);
                    const unchanged = if (findScroll(prev_cmds, sc.id)) |old|
                        std.meta.eql(now, scroll_extent.scrollExtent(prev_cmds, prev_rects, old))
                    else
                        false;
                    if (!unchanged) {
                        if (App.scrollLayoutMsg(&self.model, sc.id, now.viewport_w, now.viewport_h, now.content_w, now.content_h)) |m| self.dispatch(m);
                    }
                },
                .push_virtual_list => |vl| if (has_rows_hook and vl.id != 0) {
                    var now: [max_reported_rows]f32 = undefined;
                    const n = virtual_rows.rowExtents(cmds, rects, i, &now);
                    var unchanged = false;
                    if (findVirtualList(prev_cmds, vl.id)) |old| {
                        var was: [max_reported_rows]f32 = undefined;
                        const pn = virtual_rows.rowExtents(prev_cmds, prev_rects, old, &was);
                        unchanged = prev_cmds[old].push_virtual_list.visible_start == vl.visible_start and
                            std.mem.eql(f32, now[0..n], was[0..pn]);
                    }
                    if (!unchanged) {
                        if (App.virtualRowsMsg(&self.model, vl.id, vl.visible_start, now[0..n])) |m| self.dispatch(m);
                    }
                },
                else => {},
            };
        }

        /// Fire the app's declared timers before building this frame's view,
        /// so a sub-driven Model change is reflected in the frame we're about
        /// to emit (and mirrored to the snapshot through the normal
        /// frame-diff). Pure `subscribe` declares; `runSubs` watches on the
        /// host clock; fired subs dispatch as ordinary Msgs through `update`.
        fn fireSubs(self: *Self) void {
            if (!@hasDecl(App, "subscribe")) return;
            // `runSubs` invokes `dispatch.call(msg)`; the loop pointer rides
            // inside a per-call value, never a module-level static (two
            // concurrent runtimes over the same types must not cross-wire).
            const Dispatch = struct {
                rt: *Self,
                pub fn call(d: @This(), msg: Msg) void {
                    d.rt.dispatch(msg);
                }
            };
            const now_ms = self.host.nowMs();
            const since = self.last_sub_ms orelse now_ms; // first frame: no window, no fire
            const subs = App.subscribe(&self.model);
            sub_mod.runSubs(Msg, subs, since, now_ms, Dispatch{ .rt = self });
            self.last_sub_ms = now_ms;
            // `.animation_frame`: feed the frame time to the App while it asks
            // for it, and keep frames flowing (no idle skip) meanwhile.
            self.animating = sub_mod.wantsAnimationFrame(Msg, subs);
            if (self.animating and @hasDecl(App, "animationMsg")) {
                const dt: u32 = @intCast(@min(now_ms -| since, sub_mod.max_animation_dt_ms));
                if (App.animationMsg(&self.model, dt)) |m| self.dispatch(m);
            }
        }

        /// Hand the host's finished effect results (and unsolicited drops /
        /// pastes) to the app. Runs after key routing so a Ctrl+V handled by
        /// `handleClipboard` has already claimed its paste. A result whose id
        /// is no longer listed was cancelled by the app: dropped.
        fn deliverEffectResults(self: *Self) void {
            if (comptime !(has_effect_msg and host_effects)) return;
            var buf: [effect_batch]effects_mod.EffectResult = undefined;
            const n = self.host.pollEffectResults(&buf);
            for (buf[0..n]) |r| self.deliverEffectResult(r);
        }

        fn deliverEffectResult(self: *Self, r: effects_mod.EffectResult) void {
            if (comptime !has_effect_msg) return;
            if (effects_mod.resultId(r)) |id| {
                if (!self.issued.contains(id)) return;
            }
            if (App.effectMsg(&self.model, r)) |m| self.dispatch(m);
        }

        /// Issue the app's newly listed effects to the host and forget the
        /// ones it stopped listing. `effects()` borrows from the Model, so
        /// nothing is dispatched while iterating it: answers the host cannot
        /// give (unsupported kinds) are collected and delivered afterwards.
        fn serviceEffects(self: *Self) void {
            if (comptime !has_effects) return;
            var failed: [max_issued_effects]effects_mod.EffectResult = undefined;
            var n_failed: usize = 0;

            // Pass 1: forget what is no longer listed, so its slot is free for
            // the new effects of this same frame.
            const list = App.effects(&self.model);
            self.issued.beginFrame();
            for (list) |e| _ = self.issued.listed(e.id());
            self.issued.sweep();

            // Pass 2: hand the host whatever is not issued yet.
            for (list) |e| {
                if (self.issued.contains(e.id())) continue;
                if (self.issued.isFull()) break; // the rest wait for a free slot
                const status: effects_mod.EffectSubmit = if (comptime host_effects)
                    self.host.submit(e)
                else
                    .unsupported;
                switch (status) {
                    .busy => continue,
                    .accepted => {},
                    .unsupported => if (effects_mod.unsupportedResult(e)) |r| {
                        failed[n_failed] = r;
                        n_failed += 1;
                    },
                }
                _ = self.issued.issue(e.id());
            }

            for (failed[0..n_failed]) |r| self.deliverEffectResult(r);
        }

        /// Build this frame's view into the other buffer and lay it out.
        /// Returns the index of the new frame.
        fn buildView(self: *Self, input: Input) !u1 {
            self.current ^= 1;
            const cur = self.current;
            self.bufs[cur].reset();
            if (@hasDecl(App, "themeFor")) self.bufs[cur].theme = App.themeFor(&self.model);
            App.view(&self.model, &self.bufs[cur]);
            const cmds = self.bufs[cur].cmds.items;
            checkBalance(cmds, "view");

            try self.rects[cur].resize(self.gpa, cmds.len);
            layout.LayoutEngine.doLayout(
                self.rects[cur].items,
                cmds,
                @floatFromInt(input.width),
                @floatFromInt(input.height),
                self.measurer,
            );
            return cur;
        }

        /// Fold hover/press/focus/IME into `TransientState` against THIS
        /// frame's layout. Presentation only — nothing here reaches `update`.
        fn updateTransient(self: *Self, input: Input, cur: u1) void {
            const cmds = self.bufs[cur].cmds.items;
            self.ts.hover_index = hit_test.hoverTest(cmds, self.rects[cur].items, input.mouse_x, input.mouse_y);
            self.ts.press_index = self.press_target;
            self.ts.focus_index = focusIndex(App, &self.model, cmds);
            self.ts.mouse_x = input.mouse_x;
            self.ts.mouse_y = input.mouse_y;
            self.ts.frame_counter +%= 1;
            self.ts.blink_on = self.blinkPhase();

            // Folded in unconditionally: inactive/empty on hosts without IME.
            const ime = self.host.imeState();
            self.ts.ime_active = ime.active;
            const n = @min(ime.text.len, self.ime_bufs[cur].len);
            @memcpy(self.ime_bufs[cur][0..n], ime.text[0..n]);
            self.ts.ime_text = self.ime_bufs[cur][0..n];
            self.ts.ime_cursor = ime.cursor;
        }

        /// Push the app's dynamic window title, only on change.
        fn pushTitle(self: *Self) void {
            if (!@hasDecl(App, "windowTitle")) return;
            const t = App.windowTitle(&self.model) orelse return;
            // Compare against the (possibly truncated) prefix we actually
            // stored — a title longer than `title_buf` would otherwise never
            // match its stored copy and re-fire `setTitle` every frame.
            const n = @min(t.len, self.title_buf.len);
            if (std.mem.eql(u8, t[0..n], self.title_buf[0..self.title_len])) return;
            self.host.setTitle(t);
            @memcpy(self.title_buf[0..n], t[0..n]);
            self.title_len = n;
        }

        fn uploadFrame(self: *Self, cmds: []const cmd.Cmd(Msg), rects: []const Rect, ts: TransientState) void {
            const split = render.buildFrame(&self.verts, &self.text_draws, &self.image_draws, &self.scene_draws, &self.scene_items, self.gpa, cmds, rects, ts, self.measurer);
            // Tell a layering-aware Gpu where the overlay layer starts, so an
            // opaque overlay hides the base layer's text and images.
            if (comptime @hasDecl(Gpu, "setOverlayStart")) self.gpu.setOverlayStart(split);
            self.gpu.uploadVertices(self.verts.items);
            self.gpu.uploadText(self.text_draws.items);
            resources.stageDraws(self.gpu, if (has_resources) &self.res_table else null, self.image_draws.items, self.scene_draws.items, self.scene_items.items);
        }

        /// What the secondary window did this frame, for the snapshot gate.
        const SecondaryFrame = struct {
            /// Set on the frames the window actually rendered, so the
            /// snapshot can append its body below a marker.
            title: ?[]const u8 = null,
            /// The secondary view's content changed — lets a secondary-only
            /// change (e.g. a `.every` sub updating just that view) re-mirror.
            content_changed: bool = false,
        };

        /// Open / close / render the secondary window. The Model drives
        /// intent via `secondaryWindow`; the loop owns the Host + Gpu
        /// resources keyed off `secondary.window_id` (one id covers the Host
        /// window slot and the Gpu surface slot).
        fn driveSecondary(self: *Self) !SecondaryFrame {
            const spec = App.secondaryWindow(&self.model);

            // Clear a stale reopen-suppression once the app's intent moves
            // off the spec that was open when the user closed the window.
            if (self.suppressed_spec) |sup| {
                const still_same = if (spec) |s| secondarySpecEql(sup, s) else false;
                if (!still_same) self.suppressed_spec = null;
            }

            if (spec != null and self.secondary.window_id == null and self.suppressed_spec == null) {
                self.openSecondary(spec.?);
            } else if (spec == null and self.secondary.window_id != null) {
                // The app cleared its intent.
                self.closeSecondary(self.secondary.window_id.?);
            }

            const wid = self.secondary.window_id orelse return .{};
            const si = self.host.pollSecondaryInputs(wid) orelse {
                // A null poll means the user closed the window from the OS:
                // tear down and mirror it back into the Model via the app's
                // close Msg so its own flag flips. Remember the spec so it is
                // not reopened next frame if the app leaves it in place.
                self.closeSecondary(wid);
                self.suppressed_spec = spec;
                if (@hasDecl(App, "secondaryClosedMsg")) {
                    if (App.secondaryClosedMsg(&self.model)) |m| self.dispatch(m);
                }
                return .{};
            };
            if (si.resized) self.gpu.resizeWindow(wid, si.width, si.height);

            const sec = &self.secondary;
            const sprev = sec.cur;
            sec.cur ^= 1;
            const scur = sec.cur;
            sec.bufs[scur].reset();
            if (@hasDecl(App, "themeFor")) sec.bufs[scur].theme = App.themeFor(&self.model);
            App.secondaryView(&self.model, &sec.bufs[scur]);

            const cmds = sec.bufs[scur].cmds.items;
            checkBalance(cmds, "secondaryView");
            try sec.rects[scur].resize(self.gpa, cmds.len);
            layout.LayoutEngine.doLayout(
                sec.rects[scur].items,
                cmds,
                @floatFromInt(si.width),
                @floatFromInt(si.height),
                self.measurer,
            );
            // The secondary window has no interactive/transient state of its
            // own — a fresh default is correct.
            self.uploadFrame(cmds, sec.rects[scur].items, .{});
            self.gpu.renderToWindow(wid, self.opts.clear_color);
            return .{
                .title = if (spec) |s| s.title else "secondary",
                .content_changed = !cmdsEqual(Msg, cmds, sec.bufs[sprev].cmds.items) or
                    !rectsEqual(sec.rects[scur].items, sec.rects[sprev].items),
            };
        }

        /// Create the OS window, then its GPU surface. Back out cleanly if
        /// either half fails so we never leak a window with no renderer.
        fn openSecondary(self: *Self, s: SecondaryWindowSpec) void {
            const wid = self.host.openSecondaryWindow(s.title, s.width, s.height) orelse return;
            const handle = self.host.secondaryWindowHandle(wid) orelse return self.host.closeSecondaryWindow(wid);
            if (self.gpu.openSecondarySurface(handle, s.width, s.height) == null) return self.host.closeSecondaryWindow(wid);
            self.secondary.window_id = wid;
        }

        fn closeSecondary(self: *Self, wid: u32) void {
            self.gpu.closeSecondarySurface(wid);
            self.host.closeSecondaryWindow(wid);
            self.secondary.window_id = null;
        }
    };
}

/// Click-count state for text areas; see `Runtime.text_click`.
const TextClick = struct {
    count: u8 = 0,
    ms: u64 = 0,
    x: f32 = 0,
    y: f32 = 0,
};

/// One remembered `metrics` event; see `Runtime.text_metrics`.
const TextMetricsSlot = struct {
    id: u32 = 0,
    ev: text_event.TextEvent = .{ .id = 0, .kind = .metrics },
};

/// Pointer-canvas routing state; see `Runtime.canvas_ptr`.
const CanvasPointer = struct {
    /// Canvas that has the pointer captured (a press landed on it and not
    /// every button has been released since).
    capture: ?u32 = null,
    /// Canvas the cursor is over (also the captured one during a capture).
    hover: ?u32 = null,
    /// Cursor position at the last `move` delivered, for deltas.
    has_last: bool = false,
    last_x: f32 = 0,
    last_y: f32 = 0,
};

/// Buttons that were already down when this frame began: held now, or
/// released this frame, minus those pressed this frame.
fn heldBeforeFrame(input: anytype) pointer.Buttons {
    const held: u8 = @bitCast(input.buttons);
    const up: u8 = @bitCast(input.button_up);
    const down: u8 = @bitCast(input.button_down);
    return @bitCast((held | up) & ~down);
}

fn buttonSet(set: pointer.Buttons, b: pointer.Button) bool {
    return switch (b) {
        .left => set.left,
        .middle => set.middle,
        .right => set.right,
        .none => false,
    };
}

/// Cmd index of the pointer surface (canvas or scene) with `id`, if the
/// buffer has one.
fn findPointerCanvas(cmds: anytype, id: u32) ?usize {
    for (cmds, 0..) |_, i| {
        if (hit_test.pointerSurface(cmds, i)) |t| if (t.id == id) return i;
    }
    return null;
}

/// Most rows one `virtualRowsMsg` carries.
const max_reported_rows = 256;

/// Cmd index of the `push_virtual_list` with `id`, if the buffer has one.
fn findVirtualList(cmds: anytype, id: u32) ?usize {
    for (cmds, 0..) |c, i| switch (c) {
        .push_virtual_list => |vl| if (vl.id == id) return i,
        else => {},
    };
    return null;
}

/// Cmd index of the `push_scroll` with `id`, if the buffer has one.
fn findScroll(cmds: anytype, id: u32) ?usize {
    for (cmds, 0..) |c, i| switch (c) {
        .push_scroll => |sc| if (sc.id == id) return i,
        else => {},
    };
    return null;
}

/// A `CanvasEvent` for the cursor's current position, canvas-local.
fn canvasEventAt(id: u32, kind: pointer.CanvasEventKind, input: anytype, rect: Rect, button: pointer.Button) pointer.CanvasEvent {
    return .{
        .id = id,
        .kind = kind,
        .x = input.mouse_x - rect.x,
        .y = input.mouse_y - rect.y,
        .button = button,
        .buttons = input.buttons,
        .mods = input.mods,
        .w = rect.w,
        .h = rect.h,
    };
}

/// Which of the primary frame's observable inputs changed against the
/// previous frame.
const FrameDiff = struct {
    cmds_same: bool,
    rects_same: bool,
    ts_same: bool,

    fn changed(self: FrameDiff) bool {
        return !self.cmds_same or !self.rects_same or !self.ts_same;
    }
};

/// Transient fields whose change must trigger a vertex rebuild. Mouse
/// position and the frame counter are deliberately absent: the renderer
/// reads them only through hover/press/focus/IME, which are compared.
fn transientSame(a: TransientState, b: TransientState) bool {
    return a.hover_index == b.hover_index and
        a.press_index == b.press_index and
        a.focus_index == b.focus_index and
        a.blink_on == b.blink_on and
        a.ime_active == b.ime_active and
        a.ime_cursor == b.ime_cursor and
        std.mem.eql(u8, a.ime_text, b.ime_text);
}

/// Per-frame cmd-buffer balance check, in EVERY optimize mode. An unbalanced
/// or too-deeply-nested buffer (`cmd.MAX_BALANCE_DEPTH`) is otherwise a
/// silent wrong-rects bug or an out-of-bounds stack write in release; this
/// panics naming the view and the offending cmd index before any pass runs.
/// O(n), allocation-free (a few microseconds at thousands of cmds).
fn checkBalance(cmds: anytype, view_name: []const u8) void {
    if (cmd.validateBalance(cmds)) |bal_err| {
        var buf: [128]u8 = undefined;
        std.debug.panic("teak: unbalanced cmd buffer from {s}() — {s}", .{
            view_name, cmd.formatBalanceError(bal_err, &buf),
        });
    }
}

/// Resolve the focused widget's cmd index for this frame. Apps that
/// expose `focusedMsg` get stable, Msg-keyed focus (survives
/// conditional/reordered widgets); apps without it have no focus ring.
fn focusIndex(comptime App: type, model: *const App.Model, cmds: anytype) ?usize {
    if (!@hasDecl(App, "focusedMsg")) return null;
    const fm = App.focusedMsg(model) orelse return null;
    return focus.indexOfFocusMsg(cmds, fm);
}

// ── Frame diff ──────────────────────────────────────────────────────
//
// Compares the observable content of two cmd buffers (slices by content,
// not pointer identity — the arena hands out fresh addresses each frame).

/// True if two cmd buffers would render identically. Derived by comptime
/// reflection over `Cmd(Msg)` (`core/eql.zig`): every field of every
/// variant participates, so a new widget or a new style field can never be
/// forgotten here.
pub fn cmdsEqual(comptime Msg: type, a: []const cmd.Cmd(Msg), b: []const cmd.Cmd(Msg)) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (!eql.deepEql(cmd.Cmd(Msg), ca, cb)) return false;
    }
    return true;
}

/// True if two rect slices are identical (position + size only).
pub fn rectsEqual(a: []const Rect, b: []const Rect) bool {
    if (a.len != b.len) return false;
    for (a, b) |ra, rb| {
        if (ra.x != rb.x or ra.y != rb.y or ra.w != rb.w or ra.h != rb.h) return false;
    }
    return true;
}

test {
    _ = @import("core/eql.zig");
    _ = @import("core/oom.zig");
    _ = @import("core/anim.zig");
    _ = @import("run_test.zig");
    _ = @import("run_effects_test.zig");
}
