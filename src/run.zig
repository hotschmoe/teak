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
//!     interactive canvases (`CanvasCmd.pointer`): down / move / up / wheel /
//!     leave, plus `layout` on first layout and resize. A press captures the
//!     pointer for its canvas until every button is released. A wheel over a
//!     pointer canvas becomes a `wheel` event INSTEAD of `wheelMsg`.
//!   - `scrollMsg(*const Model, id, dx, dy) ?Msg`     — wheel over the
//!     innermost hovered scroll region with `ScrollStyle.id != 0` (a pointer
//!     canvas inside it wins when it is the innermost).
//!   - `scrollLayoutMsg(*const Model, id, vw, vh, cw, ch) ?Msg` — viewport and
//!     content size of every `ScrollStyle.id != 0` region, on its first layout
//!     and whenever either changes, so the app can clamp offsets and draw
//!     scrollbars (the view cannot read layout).
//!   - `focusedMsg(*const Model) ?Msg`                — the focus Msg of the
//!     currently-focused widget; `run` maps it to a cmd index via
//!     `indexOfFocusMsg` (stable across conditional/reordered widgets)
//!     to drive the focus ring + cursor blink. Also enables built-in
//!     Tab / Shift+Tab traversal between focusable widgets.
//!   - `submitMsg(*const Model) ?Msg`                 — dispatched on the
//!     Enter key (takes precedence over `keySpecialMsg` for Enter)
//!   - `themeFor(*const Model) Theme`                 — per-frame theme
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
const snapshot = @import("core/snapshot.zig");
const sub_mod = @import("core/sub.zig");
const transient = @import("core/transient.zig");
const text = @import("core/text.zig");
const theme_mod = @import("core/theme.zig");
const pointer = @import("core/pointer.zig");
const layout = @import("layout/engine.zig");
const scroll_extent = @import("layout/scroll_extent.zig");
const hit_test = @import("input/hit_test.zig");
const focus = @import("input/focus.zig");
const keys = @import("input/keys.zig");
const render = @import("render/build.zig");
const vertex = @import("render/vertex.zig");

const Rect = layout.Rect;
const TransientState = transient.TransientState;

pub const RunOptions = struct {
    /// Scene clear color passed to `Gpu.renderFrame` each frame.
    clear_color: [4]f32 = .{ 0.08, 0.08, 0.1, 1.0 },
    /// Frames between forced vertex rebuilds while a widget is focused,
    /// so the text cursor blink animates. 0 disables the blink tick
    /// (apps with no text input pay nothing). The renderer toggles the
    /// cursor on a 30-frame phase, so 30 matches it.
    blink_period: u32 = 30,
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
    while (!host.shouldClose()) try rt.frame();
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
        const has_scroll_hook = @hasDecl(App, "scrollMsg");
        const has_scroll_layout_hook = @hasDecl(App, "scrollLayoutMsg");
        const has_secondary = @hasDecl(App, "secondaryWindow") and @hasDecl(App, "secondaryView") and
            @hasDecl(Gpu, "openSecondarySurface");

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

        ts: TransientState = .{},
        prev_ts: TransientState = .{},

        /// Interactive-canvas routing: which canvas has the pointer
        /// captured / is hovered (by `CanvasCmd.id`, stable across frames
        /// unlike cmd indices) and the last position a canvas saw, for
        /// `move` deltas. Loop bookkeeping like `press_target`; the app's
        /// own state still lives in its Model.
        canvas_ptr: CanvasPointer = .{},

        /// Press model: arm on mousedown over a widget, fire the click only
        /// if mouseup lands on the same widget; drag-off cancels.
        press_target: ?usize = null,

        /// The previous frame's `nowMs`. `runSubs` is stateless — it decides
        /// fire/skip from (last_sub_ms, now_ms, sub data) — so this single
        /// timestamp is all the bookkeeping the loop holds. `null` until the
        /// first frame binds it: no sub fires on the opening tick.
        last_sub_ms: ?u64 = null,

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
            if (input.resized) self.gpu.resize(input.width, input.height);

            // Input is routed against the PREVIOUS frame's layout — the one
            // the user is looking at — so `prev` is captured before the swap.
            const prev = self.current;
            self.routeMouse(input, prev);
            self.routeCanvasPointer(input, prev);
            self.routeKeys(input, prev);
            self.routeWheel(input, prev);
            self.fireSubs();

            const cur = try self.buildView(input);
            self.reportLayout(prev, cur);
            const cur_cmds = self.bufs[cur].cmds.items;
            const cur_rects = self.rects[cur].items;
            self.updateTransient(input, cur);
            self.pushTitle();

            // Frame diff: skip the vertex rebuild + upload when nothing
            // observable changed. The blink tick forces a rebuild on a phase
            // boundary so a focused cursor animates.
            const diff = FrameDiff{
                .cmds_same = cmdsEqual(Msg, cur_cmds, self.bufs[prev].cmds.items),
                .rects_same = rectsEqual(cur_rects, self.rects[prev].items),
                .ts_same = transientSame(self.ts, self.prev_ts),
            };
            const blink_tick = self.opts.blink_period > 0 and self.ts.focus_index != null and
                (self.ts.frame_counter % self.opts.blink_period == 0);
            // A live secondary window re-uploads into the shared Gpu scratch
            // buffers after the primary present, so the primary must rebuild
            // its own vertices every frame while it's open.
            const secondary_open = has_secondary and App.secondaryWindow(&self.model) != null;
            if (diff.changed() or blink_tick or secondary_open) {
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

        /// Every Msg is routed through here so the live snapshot's header can
        /// name the last transition. Adds nothing to the TEA loop — it is
        /// `App.update` plus one string assignment.
        fn dispatch(self: *Self, msg: Msg) void {
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

            if (input.mouse_down) self.press_target = hover;
            if (input.mouse_up) {
                if (self.press_target != null and hover == self.press_target) {
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

            if (has_canvas_hook) {
                // A captured canvas takes every wheel event, wherever the cursor is.
                if (self.canvas_ptr.capture) |id| return self.sendCanvasEvent(id, .wheel, input, prev, .none);
            }
            if (has_canvas_hook or has_scroll_hook) {
                if (hit_test.wheelTarget(cmds, rects, input.mouse_x, input.mouse_y)) |target| switch (target) {
                    .canvas => |c| if (has_canvas_hook) return self.sendCanvasEvent(c.id, .wheel, input, prev, .none),
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
            if (!has_canvas_hook) return;
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
            var ev = canvasEventAt(id, kind, input, self.rects[prev].items[idx], button);
            if (kind == .wheel) {
                ev.dx = input.wheel_dx;
                ev.dy = input.wheel_dy;
            }
            self.dispatchCanvas(ev);
        }

        fn dispatchCanvas(self: *Self, ev: pointer.CanvasEvent) void {
            if (App.canvasMsg(&self.model, ev)) |m| self.dispatch(m);
        }

        /// Tell the app about layout results it cannot read from `view`:
        /// a pointer canvas's size (`CanvasEvent.layout`) and an id-bearing
        /// scroll region's viewport + content size (`scrollLayoutMsg`), each
        /// on first layout and whenever the value differs from the previous
        /// frame's. The resulting Msg takes effect in the NEXT frame's view.
        fn reportLayout(self: *Self, prev: u1, cur: u1) void {
            if (!has_canvas_hook and !has_scroll_layout_hook) return;
            const cmds = self.bufs[cur].cmds.items;
            const rects = self.rects[cur].items;
            const prev_cmds = self.bufs[prev].cmds.items;
            const prev_rects = self.rects[prev].items;
            for (cmds, 0..) |c, i| switch (c) {
                .canvas => |cv| if (has_canvas_hook and cv.pointer) {
                    const old = findPointerCanvas(prev_cmds, cv.id);
                    if (old == null or prev_rects[old.?].w != rects[i].w or prev_rects[old.?].h != rects[i].h) {
                        self.dispatchCanvas(.{ .id = cv.id, .kind = .layout, .w = rects[i].w, .h = rects[i].h });
                    }
                },
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
            sub_mod.runSubs(Msg, App.subscribe(&self.model), since, now_ms, Dispatch{ .rt = self });
            self.last_sub_ms = now_ms;
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
            debugCheckBalance(cmds, "view");

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
            render.buildVertices(&self.verts, &self.text_draws, &self.image_draws, self.gpa, cmds, rects, ts, self.measurer);
            self.gpu.uploadVertices(self.verts.items);
            self.gpu.uploadText(self.text_draws.items);
            self.gpu.uploadImages(self.image_draws.items);
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
            debugCheckBalance(cmds, "secondaryView");
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

/// Cmd index of the pointer canvas with `id`, if the buffer has one.
fn findPointerCanvas(cmds: anytype, id: u32) ?usize {
    for (cmds, 0..) |c, i| switch (c) {
        .canvas => |cv| if (cv.pointer and cv.id == id) return i,
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
        a.ime_active == b.ime_active and
        a.ime_cursor == b.ime_cursor and
        std.mem.eql(u8, a.ime_text, b.ime_text);
}

/// Debug-only cmd-buffer balance check. A missed pop_group (or friends)
/// is otherwise a silent layout bug; in Debug builds this panics naming
/// the offending cmd index before the layout passes consume the buffer.
/// Compiled out entirely in release modes. run.zig sits outside the
/// framework-core dirs, so the builtin.mode gate is allowed here
/// (HARDLINE §3 scopes the conditional-compilation ban to core).
fn debugCheckBalance(cmds: anytype, view_name: []const u8) void {
    if (@import("builtin").mode != .Debug) return;
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
// Shared with what every example's ui_main hand-rolled. Compares the
// observable content of two cmd buffers: tags, styles, and — for
// variants carrying slices — string/span content (not pointer identity,
// since the arena hands out fresh addresses each frame).

/// True if two cmd buffers would render identically.
pub fn cmdsEqual(comptime Msg: type, a: []const cmd.Cmd(Msg), b: []const cmd.Cmd(Msg)) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.meta.activeTag(ca) != std.meta.activeTag(cb)) return false;
        switch (ca) {
            .push_group => |g| if (!std.meta.eql(g, cb.push_group)) return false,
            .pop_group => {},
            .push_scroll => |s| if (!std.meta.eql(s, cb.push_scroll)) return false,
            .pop_scroll => {},
            .push_overlay => |o| if (!std.meta.eql(o, cb.push_overlay)) return false,
            .pop_overlay => {},
            .push_virtual_list => |v| if (!std.meta.eql(v, cb.push_virtual_list)) return false,
            .pop_virtual_list => {},
            .text => |t| {
                const o = cb.text;
                if (!std.mem.eql(u8, t.content, o.content)) return false;
                if (!std.meta.eql(t.font, o.font) or !std.meta.eql(t.color, o.color)) return false;
            },
            .button => |x| {
                // Compare the FULL payload: label (slice) by content, then
                // msg / style / font / disabled. Omitting style or font makes
                // a theme flip or a per-widget restyle (e.g. a danger-colored
                // button) skip the vertex rebuild AND the snapshot write —
                // stale pixels.
                const o = cb.button;
                if (!std.mem.eql(u8, x.label, o.label)) return false;
                if (!std.meta.eql(x.msg, o.msg)) return false;
                if (!std.meta.eql(x.style, o.style)) return false;
                if (!std.meta.eql(x.font, o.font)) return false;
                if (x.disabled != o.disabled) return false;
            },
            .text_input => |x| {
                const o = cb.text_input;
                if (x.cursor != o.cursor or x.selection_anchor != o.selection_anchor) return false;
                if (x.disabled != o.disabled) return false;
                if (!std.mem.eql(u8, x.content, o.content)) return false;
                if (!std.meta.eql(x.focus_msg, o.focus_msg)) return false;
                if (!std.meta.eql(x.style, o.style)) return false;
                if (!std.meta.eql(x.font, o.font)) return false;
            },
            .checkbox => |x| {
                const o = cb.checkbox;
                if (x.checked != o.checked) return false;
                if (!std.mem.eql(u8, x.label, o.label)) return false;
                if (!std.meta.eql(x.msg, o.msg)) return false;
                if (!std.meta.eql(x.style, o.style)) return false;
                if (!std.meta.eql(x.font, o.font)) return false;
            },
            .radio => |x| {
                const o = cb.radio;
                if (x.selected != o.selected) return false;
                if (!std.mem.eql(u8, x.label, o.label)) return false;
                if (!std.meta.eql(x.msg, o.msg)) return false;
                if (!std.meta.eql(x.style, o.style)) return false;
                if (!std.meta.eql(x.font, o.font)) return false;
            },
            .slider => |x| {
                const o = cb.slider;
                if (x.value != o.value) return false;
                if (!std.meta.eql(x.grab_msg, o.grab_msg)) return false;
                if (!std.meta.eql(x.style, o.style)) return false;
            },
            .divider => |d| if (!std.meta.eql(d, cb.divider)) return false,
            .image => |im| if (!std.meta.eql(im, cb.image)) return false,
            .rich_text => |rt| {
                const o = cb.rich_text;
                if (!std.mem.eql(u8, rt.content, o.content)) return false;
                if (!std.meta.eql(rt.default_color, o.default_color)) return false;
                if (!std.meta.eql(rt.default_font, o.default_font)) return false;
                if (rt.spans.len != o.spans.len) return false;
                for (rt.spans, o.spans) |sa, sb| if (!std.meta.eql(sa, sb)) return false;
            },
            .canvas => |x| {
                const o = cb.canvas;
                if (!std.meta.eql(x.style, o.style)) return false;
                if (!std.meta.eql(x.msg, o.msg)) return false;
                if (!std.mem.eql(u8, x.label, o.label)) return false;
                if (x.id != o.id or x.pointer != o.pointer) return false;
                if (x.primitives.len != o.primitives.len) return false;
                // Compare by content, not slice identity — the arena hands
                // out fresh addresses each frame. Polyline carries a nested
                // points slice, so it needs a content walk of its own.
                for (x.primitives, o.primitives) |pa, pb| {
                    if (std.meta.activeTag(pa) != std.meta.activeTag(pb)) return false;
                    switch (pa) {
                        .polyline => |pl| {
                            const ob = pb.polyline;
                            if (!std.meta.eql(pl.color, ob.color) or pl.thickness != ob.thickness) return false;
                            if (pl.points.len != ob.points.len) return false;
                            for (pl.points, ob.points) |qa, qb| if (!std.meta.eql(qa, qb)) return false;
                        },
                        else => if (!std.meta.eql(pa, pb)) return false,
                    }
                }
            },
        }
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

// ── Tests ───────────────────────────────────────────────────────────
//
// Driven by a headless Host + Gpu so the whole loop runs under
// `zig build test` with no window or GPU. The stub Host scripts a click
// over a button across frames; the stub Gpu counts the calls `run`
// makes.

const host_iface = @import("platform/host.zig");
const InputState = host_iface.InputState;
const Clipboard = host_iface.Clipboard;

const TestApp = struct {
    pub const Model = struct { count: i32 = 0 };
    pub const Msg = union(enum) { click };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .click => m.count += 1,
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        // Root group with zero padding so the button sits at the origin
        // with intrinsic size (~60x36 under the mono measurer) — a click
        // at (5,5) lands on it. (A view must start with a container;
        // `doLayout` treats cmds[0] as the root and positionPass expects
        // every leaf to have a parent on the stack.)
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.button(.click, "X");
        cb.popGroup();
    }
};

/// Scripts: frame 1 idle (populates prev), frame 2 mousedown over the
/// button, frame 3 mouseup over the button (fires .click), frame 4
/// closes. All at (5,5) except frame 1 which parks the cursor off-widget.
const StubHost = struct {
    frame: u32 = 0,
    closed: bool = false,

    pub fn deinit(_: *StubHost) void {}
    pub fn shouldClose(self: *const StubHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *StubHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = 5;
        in.mouse_y = 5;
        switch (self.frame) {
            1 => {
                in.mouse_x = -10;
                in.mouse_y = -10;
                in.resized = true;
            },
            2 => in.mouse_down = true,
            3 => in.mouse_up = true,
            else => self.closed = true,
        }
        in.chars = &.{};
        in.keys = &.{};
        return in;
    }
    pub fn nativeHandle(_: *const StubHost) void {}
    pub fn textMeasurer(_: *StubHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *StubHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = stubRead, .write_fn = stubWrite };
    }
    fn stubRead(_: *anyopaque) []const u8 {
        return "";
    }
    fn stubWrite(_: *anyopaque, _: []const u8) void {}
    pub fn imeState(_: *const StubHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *StubHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *StubHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *StubHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *StubHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn pollSecondaryInputs(_: *StubHost, _: u32) ?InputState {
        return null;
    }
    pub fn closeSecondaryWindow(_: *StubHost, _: u32) void {}
    pub fn secondaryWindowHandle(_: *const StubHost, _: u32) ?void {
        return null;
    }
    pub fn requestFileDialog(_: *StubHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn requestSaveFileDialog(_: *StubHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn pollFileDialogResult(_: *StubHost, _: u32) host_iface.FileDialogPoll {
        return .{ .pending = {} };
    }
    pub fn setTitle(_: *StubHost, _: []const u8) void {}
    pub fn nowMs(_: *const StubHost) u64 {
        return 0;
    }
};

const StubGpu = struct {
    resize_calls: u32 = 0,
    upload_vert_calls: u32 = 0,
    render_calls: u32 = 0,

    pub fn deinit(_: *StubGpu) void {}
    pub fn resize(self: *StubGpu, _: u32, _: u32) void {
        self.resize_calls += 1;
    }
    pub fn uploadVertices(self: *StubGpu, _: []const vertex.Vertex) void {
        self.upload_vert_calls += 1;
    }
    pub fn uploadText(_: *StubGpu, _: []const text.TextDraw) void {}
    pub fn uploadImages(_: *StubGpu, _: []const render.ImageDraw) void {}
    pub fn renderFrame(self: *StubGpu, _: [4]f32) void {
        self.render_calls += 1;
    }
    pub fn rasterizeText(_: *StubGpu, _: []const u8, _: text.FontSpec, _: [4]f32, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
    pub fn uploadImage(_: *StubGpu, _: []const u8, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
};

test "run: drives the loop, routes a click through update, presents each frame" {
    // Sanity: the stubs satisfy the real comptime contracts.
    comptime host_iface.validateHost(StubHost);
    comptime @import("gpu/context.zig").validateGpu(StubGpu);

    var host: StubHost = .{};
    var gpu: StubGpu = .{};

    try run(TestApp, std.testing.allocator, &host, &gpu, .{});

    // The scripted mousedown(frame2)+mouseup(frame3) over the button
    // fired exactly one .click.
    // (We can't read model here — run owns it — so assert via the side
    //  effects the stubs recorded plus the loop's own invariants.)
    try std.testing.expectEqual(@as(u32, 1), gpu.resize_calls); // frame 1 resized
    // renderFrame runs once per loop iteration that didn't early-break:
    // frames 1,2,3 present; frame 4 sets closed and breaks before render.
    try std.testing.expectEqual(@as(u32, 3), gpu.render_calls);
    try std.testing.expect(host.frame >= 4);
}

test "run: model state is observable through an app-held side channel" {
    // Same loop, but the app records its own count into a module-level
    // sink so the test can assert the click actually mutated Model.
    const Sink = struct {
        var count: i32 = -1;
    };
    const App = struct {
        pub const Model = struct { count: i32 = 0 };
        pub const Msg = union(enum) { click };
        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .click => m.count += 1,
            }
            Sink.count = m.count;
        }
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.button(.click, "X");
            cb.popGroup();
        }
    };

    var host: StubHost = .{};
    var gpu: StubGpu = .{};
    Sink.count = -1;
    try run(App, std.testing.allocator, &host, &gpu, .{});
    try std.testing.expectEqual(@as(i32, 1), Sink.count);
}

/// Scripts keyboard input: frame 1 idle, frame 2 delivers chars "Hi",
/// frame 3 a backspace special key, frame 4 closes. Exercises the
/// `keyCharMsg` / `keySpecialMsg` forwarding paths.
const KeyHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    char_storage: [2]u8 = .{ 'H', 'i' },
    key_storage: [1]keys.SpecialKey = .{.backspace},

    pub fn deinit(_: *KeyHost) void {}
    pub fn shouldClose(self: *const KeyHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *KeyHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = -10;
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        switch (self.frame) {
            1 => in.resized = true,
            2 => in.chars = self.char_storage[0..],
            3 => in.keys = self.key_storage[0..],
            else => self.closed = true,
        }
        return in;
    }
    pub fn nativeHandle(_: *const KeyHost) void {}
    pub fn textMeasurer(_: *KeyHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *KeyHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const KeyHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *KeyHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *KeyHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *KeyHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *KeyHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn setTitle(_: *KeyHost, _: []const u8) void {}
    pub fn nowMs(_: *const KeyHost) u64 {
        return 0;
    }
};

test "run: routes typed chars + special keys through the optional hooks" {
    const Sink = struct {
        var typed: [8]u8 = undefined;
        var typed_len: usize = 0;
        var backspaces: u32 = 0;
        var theme_was_read: bool = false;
    };
    const App = struct {
        pub const Model = struct { focused: bool = true };
        pub const Msg = union(enum) { char: u8, backspace };
        pub fn update(_: *Model, msg: Msg) void {
            switch (msg) {
                .char => |c| {
                    Sink.typed[Sink.typed_len] = c;
                    Sink.typed_len += 1;
                },
                .backspace => Sink.backspaces += 1,
            }
        }
        pub fn view(_: *const Model, cb: anytype) void {
            // Read theme so themeFor's effect is observable, then emit a
            // focusable input inside a root group.
            Sink.theme_was_read = cb.theme.typography.body.size_px > 0;
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.textInput(.{ .char = 0 }, "", 0);
            cb.popGroup();
        }
        pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
            return if (m.focused) Msg{ .char = c } else null;
        }
        pub fn keySpecialMsg(m: *const Model, k: keys.SpecialKey) ?Msg {
            if (!m.focused) return null;
            return switch (k) {
                .backspace => Msg.backspace,
                else => null,
            };
        }
        pub fn themeFor(_: *const Model) theme_mod.Theme {
            return theme_mod.Theme.light_default;
        }
    };

    Sink.typed_len = 0;
    Sink.backspaces = 0;
    Sink.theme_was_read = false;

    var host: KeyHost = .{};
    var gpu: StubGpu = .{};
    try run(App, std.testing.allocator, &host, &gpu, .{});

    try std.testing.expectEqualStrings("Hi", Sink.typed[0..Sink.typed_len]);
    try std.testing.expectEqual(@as(u32, 1), Sink.backspaces);
    try std.testing.expect(Sink.theme_was_read);
}

/// Scripts: frame 1 idle, frames 2-3 each a Tab, frame 4 Enter, frame 5
/// close. Exercises built-in Tab traversal + Enter-to-submit.
const TabHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    tab: [1]keys.SpecialKey = .{.tab},
    enter: [1]keys.SpecialKey = .{.enter},

    pub fn deinit(_: *TabHost) void {}
    pub fn shouldClose(self: *const TabHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *TabHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 300;
        in.height = 200;
        in.mouse_x = -10;
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        switch (self.frame) {
            1 => in.resized = true,
            2, 3 => in.keys = self.tab[0..],
            4 => in.keys = self.enter[0..],
            else => self.closed = true,
        }
        return in;
    }
    pub fn nativeHandle(_: *const TabHost) void {}
    pub fn textMeasurer(_: *TabHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *TabHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const TabHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *TabHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *TabHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *TabHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *TabHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn setTitle(_: *TabHost, _: []const u8) void {}
    pub fn nowMs(_: *const TabHost) u64 {
        return 0;
    }
};

test "run: Tab advances focus across inputs and Enter fires submitMsg" {
    const Sink = struct {
        var final_focus: u8 = 255;
        var submitted: bool = false;
    };
    const App = struct {
        pub const Focus = enum(u8) { none = 0, a = 1, b = 2 };
        pub const Model = struct { focus: Focus = .none };
        pub const Msg = union(enum) { focus_a, focus_b, submit };
        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .focus_a => m.focus = .a,
                .focus_b => m.focus = .b,
                .submit => Sink.submitted = true,
            }
            Sink.final_focus = @intFromEnum(m.focus);
        }
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .direction = .vertical });
            cb.textInput(.focus_a, "", 0);
            cb.textInput(.focus_b, "", 0);
            cb.popGroup();
        }
        pub fn focusedMsg(m: *const Model) ?Msg {
            return switch (m.focus) {
                .none => null,
                .a => Msg.focus_a,
                .b => Msg.focus_b,
            };
        }
        pub fn submitMsg(_: *const Model) ?Msg {
            return Msg.submit;
        }
    };

    Sink.final_focus = 255;
    Sink.submitted = false;

    var host: TabHost = .{};
    var gpu: StubGpu = .{};
    try run(App, std.testing.allocator, &host, &gpu, .{});

    // Frame 2 Tab: none -> first input (a). Frame 3 Tab: a -> b.
    try std.testing.expectEqual(@as(u8, @intFromEnum(App.Focus.b)), Sink.final_focus);
    // Frame 4 Enter fired submitMsg.
    try std.testing.expect(Sink.submitted);
}

// ── IME-aliasing (F6) + title-syscall (F7) tests ────────────────────
//
// One host serves both: it reports a per-frame IME composition (so a
// same-length composition edit can be observed) and counts `setTitle`
// calls (so a title longer than the run's 256-byte cache can be shown NOT
// to re-fire every frame).

const ImeTitleHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    set_title_calls: u32 = 0,
    // A SINGLE mutable composition buffer that `imeState` hands out slices
    // into — exactly the Host-owned global the finding describes. `run` must
    // copy out of it, or prev/cur will alias the same (overwritten) bytes.
    ime_buf: [8]u8 = undefined,
    ime_len: usize = 0,
    ime_on: bool = false,

    pub fn deinit(_: *ImeTitleHost) void {}
    pub fn shouldClose(self: *const ImeTitleHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *ImeTitleHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = -10; // parked off-widget: no hover/press churn
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        // Two DIFFERENT compositions of the SAME length on consecutive frames,
        // written IN PLACE into the one shared buffer — the exact case the
        // aliasing bug reported as "equal".
        switch (self.frame) {
            1 => in.resized = true,
            2 => {
                @memcpy(self.ime_buf[0..2], "ab");
                self.ime_len = 2;
                self.ime_on = true;
            },
            3 => {
                @memcpy(self.ime_buf[0..2], "cd"); // overwrites "ab" in place
                self.ime_len = 2;
                self.ime_on = true;
            },
            else => self.closed = true,
        }
        return in;
    }
    pub fn nativeHandle(_: *const ImeTitleHost) void {}
    pub fn textMeasurer(_: *ImeTitleHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *ImeTitleHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(self: *const ImeTitleHost) host_iface.ImeState {
        return .{ .active = self.ime_on, .text = self.ime_buf[0..self.ime_len], .cursor = 2 };
    }
    pub fn publishA11yTree(_: *ImeTitleHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *ImeTitleHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *ImeTitleHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *ImeTitleHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn setTitle(self: *ImeTitleHost, _: []const u8) void {
        self.set_title_calls += 1;
    }
    pub fn nowMs(_: *const ImeTitleHost) u64 {
        return 0;
    }
};

test "run: a same-length IME composition change forces a rebuild (F6)" {
    const App = struct {
        pub const Model = struct {};
        pub const Msg = union(enum) { noop };
        pub fn update(_: *Model, _: Msg) void {}
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.button(.noop, "X");
            cb.popGroup();
        }
    };

    var host: ImeTitleHost = .{};
    var gpu: StubGpu = .{};
    // Blink disabled so the ONLY rebuild triggers are content/transient
    // changes — the IME composition edit must be one of them.
    try run(App, std.testing.allocator, &host, &gpu, .{ .blink_period = 0 });

    // Frame 1: first content → rebuild. Frame 2: IME activates ("ab") →
    // rebuild. Frame 3: composition changes to a same-length "cd" → rebuild
    // ONLY if run-owned buffers keep prev/cur distinct (the fix). A buggy
    // alias would make frame 3 compare equal → 2 rebuilds total.
    try std.testing.expectEqual(@as(u32, 3), gpu.upload_vert_calls);
}

test "run: an over-long window title fires setTitle once, not every frame (F7)" {
    const App = struct {
        pub const Model = struct {};
        pub const Msg = union(enum) { noop };
        // 300 bytes — longer than run's 256-byte title cache.
        const long_title = "T" ** 300;
        pub fn update(_: *Model, _: Msg) void {}
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.text("hi");
            cb.popGroup();
        }
        pub fn windowTitle(_: *const Model) ?[]const u8 {
            return long_title;
        }
    };

    var host: ImeTitleHost = .{};
    var gpu: StubGpu = .{};
    try run(App, std.testing.allocator, &host, &gpu, .{});

    // The title never changes, so after the first push it must compare equal
    // to the stored (truncated) prefix and never re-fire. A prior bug compared
    // the full 300-byte title against the 256-byte cache — always unequal —
    // and re-issued the syscall every frame.
    try std.testing.expectEqual(@as(u32, 1), host.set_title_calls);
}

test "cmdsEqual: detects label, disabled, and length changes" {
    const Msg = union(enum) { a };
    var x = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer x.deinit();
    var y = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer y.deinit();

    x.button(.a, "Go");
    y.button(.a, "Go");
    try std.testing.expect(cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Different label.
    y.reset();
    y.button(.a, "No");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Same label, different disabled state.
    y.reset();
    y.buttonDisabled(.a, "Go");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Different length.
    y.reset();
    y.button(.a, "Go");
    y.button(.a, "Go");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));
}

test "cmdsEqual: a style-only change (button bg) compares unequal (F1)" {
    const Msg = union(enum) { a };
    var x = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer x.deinit();
    var y = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer y.deinit();

    // Same label + msg, but a different background color — the kind of
    // difference a themeFor flip or a `buttonStyled` danger color produces.
    // If cmdsEqual ignores style, the vertex rebuild + snapshot write are
    // skipped and the screen keeps stale pixels.
    var danger = cmd.ButtonStyle{};
    danger.bg = .{ 0.8, 0.1, 0.1, 1.0 };
    x.buttonStyled(.a, "Go", .{});
    y.buttonStyled(.a, "Go", danger);
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Identical styles still compare equal.
    y.reset();
    y.buttonStyled(.a, "Go", .{});
    try std.testing.expect(cmdsEqual(Msg, x.cmds.items, y.cmds.items));
}

// ── Live-snapshot sink test ─────────────────────────────────────────
//
// Drives the loop with the snapshot sink pointed at a tmpDir file, scripts
// a click, and asserts the mirrored file reflects post-click state — and,
// via the header's frame counter, that idle frames after the last change
// did NOT rewrite it.

/// Scripts 7 frames, mouse parked over the button at (5,5) throughout:
/// 1 idle (first write), 2 idle (no write), 3 mousedown, 4 mouseup (fires
/// .click), 5-6 idle (no write), 7 close. The last content change is frame
/// 4, so a correct sink stamps `frame=4` in the file — higher would mean an
/// idle frame rewrote it.
const SnapHost = struct {
    frame: u32 = 0,
    closed: bool = false,

    pub fn deinit(_: *SnapHost) void {}
    pub fn shouldClose(self: *const SnapHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *SnapHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = 5;
        in.mouse_y = 5;
        switch (self.frame) {
            1 => in.resized = true,
            2 => {}, // idle
            3 => in.mouse_down = true,
            4 => in.mouse_up = true,
            5, 6 => {}, // idle
            else => self.closed = true,
        }
        in.chars = &.{};
        in.keys = &.{};
        return in;
    }
    pub fn nativeHandle(_: *const SnapHost) void {}
    pub fn textMeasurer(_: *SnapHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *SnapHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const SnapHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *SnapHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *SnapHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *SnapHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *SnapHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn setTitle(_: *SnapHost, _: []const u8) void {}
    pub fn nowMs(_: *const SnapHost) u64 {
        return 0;
    }
};

/// Button "X" over a live count label; the label changes on click so the
/// snapshot diff is observable.
const SnapApp = struct {
    pub const Model = struct {
        count: i32 = 0,
        buf: [16]u8 = undefined,
        len: usize = 0,

        pub fn init() Model {
            var m = Model{};
            m.format();
            return m;
        }
        fn format(m: *Model) void {
            const s = std.fmt.bufPrint(&m.buf, "count: {d}", .{m.count}) catch "count: ?";
            m.len = s.len;
        }
        fn label(m: *const Model) []const u8 {
            return m.buf[0..m.len];
        }
    };
    pub const Msg = union(enum) { click };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .click => {
                m.count += 1;
                m.format();
            },
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.button(.click, "X");
        cb.text(m.label());
        cb.popGroup();
    }
};

test "run: live snapshot mirrors the frame and skips idle rewrites" {
    const gpa = std.testing.allocator;
    const io = std.Options.debug_io;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    // A cwd-relative path into the tmpDir (the sink writes via cwd()); read
    // it back through the tmpDir handle.
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/app.snap", .{td.sub_path});
    defer gpa.free(path);

    var host: SnapHost = .{};
    var gpu: StubGpu = .{};
    try run(SnapApp, gpa, &host, &gpu, .{ .snapshot_path = path });

    const contents = try td.dir.readFileAlloc(io, "app.snap", gpa, .limited(1 << 20));
    defer gpa.free(contents);

    // Header present and well-formed.
    try std.testing.expect(std.mem.startsWith(u8, contents, "window="));
    // The known widget line and post-click state are both present…
    try std.testing.expect(std.mem.indexOf(u8, contents, "button") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"X\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"count: 1\"") != null);
    // …and the pre-click label is gone (the file holds only the latest frame).
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"count: 0\"") == null);
    // last_msg names the last dispatched transition.
    try std.testing.expect(std.mem.indexOf(u8, contents, "last_msg=click") != null);

    // The header frame counter proves idle frames 5-6 did NOT rewrite: the
    // last content change was frame 4, so the mirrored file must stamp
    // frame=4 (a later number would mean an idle frame overwrote it).
    const marker = "frame=";
    const fi = std.mem.indexOf(u8, contents, marker).?;
    const after = contents[fi + marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const frame_val = try std.fmt.parseInt(u32, after[0..end], 10);
    try std.testing.expectEqual(@as(u32, 4), frame_val);
}

// ── Secondary-window tests ──────────────────────────────────────────
//
// Drives the optional secondary-window hooks headlessly: a stub Host
// that hands out a window id + native handle then reports a user-close,
// and a stub Gpu that records the secondary surface/render/teardown
// calls `run` makes.

/// Stub Host with a scripted secondary window. The primary loop runs 5
/// frames; the secondary poll returns input twice, then `null` (user
/// closed the window from the OS) so the close path + `secondaryClosedMsg`
/// are exercised.
const SecHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    sec_polls: u32 = 0,

    /// Structurally arbitrary — the Gpu's `openSecondarySurface` takes the
    /// handle as `anytype`, so any shape flows through unread.
    pub const NativeHandle = struct { tag: u32 = 7 };

    pub fn deinit(_: *SecHost) void {}
    pub fn shouldClose(self: *const SecHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *SecHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 400;
        in.height = 300;
        in.mouse_x = -10;
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        if (self.frame == 1) in.resized = true;
        if (self.frame >= 5) self.closed = true;
        return in;
    }
    pub fn nativeHandle(_: *const SecHost) void {}
    pub fn textMeasurer(_: *SecHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *SecHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const SecHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *SecHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *SecHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *SecHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn requestFileDialog(_: *SecHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn requestSaveFileDialog(_: *SecHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn pollFileDialogResult(_: *SecHost, _: u32) host_iface.FileDialogPoll {
        return .{ .pending = {} };
    }
    pub fn openSecondaryWindow(_: *SecHost, _: []const u8, _: u32, _: u32) ?u32 {
        return 1;
    }
    pub fn secondaryWindowHandle(_: *const SecHost, _: u32) ?NativeHandle {
        return .{};
    }
    pub fn pollSecondaryInputs(self: *SecHost, _: u32) ?InputState {
        self.sec_polls += 1;
        if (self.sec_polls > 2) return null; // user closed after 2 frames
        var in = std.mem.zeroes(InputState);
        in.width = 360;
        in.height = 200;
        in.chars = &.{};
        in.keys = &.{};
        return in;
    }
    pub fn closeSecondaryWindow(_: *SecHost, _: u32) void {}
    pub fn setTitle(_: *SecHost, _: []const u8) void {}
    pub fn nowMs(_: *const SecHost) u64 {
        return 0;
    }
};

/// Stub Gpu with the secondary-surface surface-extension methods (which
/// are outside `validateGpu`), recording each call for assertions.
const SecGpu = struct {
    opened: u32 = 0,
    rendered_to_window: u32 = 0,
    closed_surface: u32 = 0,

    pub fn deinit(_: *SecGpu) void {}
    pub fn resize(_: *SecGpu, _: u32, _: u32) void {}
    pub fn uploadVertices(_: *SecGpu, _: []const vertex.Vertex) void {}
    pub fn uploadText(_: *SecGpu, _: []const text.TextDraw) void {}
    pub fn uploadImages(_: *SecGpu, _: []const render.ImageDraw) void {}
    pub fn renderFrame(_: *SecGpu, _: [4]f32) void {}
    pub fn rasterizeText(_: *SecGpu, _: []const u8, _: text.FontSpec, _: [4]f32, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
    pub fn uploadImage(_: *SecGpu, _: []const u8, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
    // Surface extensions (not in validateGpu) — only reachable when the
    // App opts into the secondary hooks.
    pub fn openSecondarySurface(self: *SecGpu, _: anytype, _: u32, _: u32) ?u32 {
        self.opened += 1;
        return 1;
    }
    pub fn closeSecondarySurface(self: *SecGpu, _: u32) void {
        self.closed_surface += 1;
    }
    pub fn resizeWindow(_: *SecGpu, _: u32, _: u32, _: u32) void {}
    pub fn renderToWindow(self: *SecGpu, _: u32, _: [4]f32) void {
        self.rendered_to_window += 1;
    }
};

test "run: drives the secondary window open -> render -> user-close lifecycle" {
    const Sink = struct {
        var closed_msg: bool = false;
    };
    const App = struct {
        pub const Model = struct { stats_open: bool = true };
        pub const Msg = union(enum) { close_stats };
        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .close_stats => {
                    m.stats_open = false;
                    Sink.closed_msg = true;
                },
            }
        }
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.text("main");
            cb.popGroup();
        }
        pub fn secondaryWindow(m: *const Model) ?SecondaryWindowSpec {
            return if (m.stats_open) .{ .title = "Stats", .width = 360, .height = 200 } else null;
        }
        pub fn secondaryView(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.text("stats");
            cb.popGroup();
        }
        pub fn secondaryClosedMsg(_: *const Model) ?Msg {
            return Msg.close_stats;
        }
    };

    Sink.closed_msg = false;
    var host: SecHost = .{};
    var gpu: SecGpu = .{};
    try run(App, std.testing.allocator, &host, &gpu, .{});

    // Opened exactly one secondary surface, rendered into it while the
    // OS window was alive (2 polls returned input), then tore it down on
    // the user-close poll and mirrored the close back through `update`.
    try std.testing.expectEqual(@as(u32, 1), gpu.opened);
    try std.testing.expectEqual(@as(u32, 2), gpu.rendered_to_window);
    try std.testing.expectEqual(@as(u32, 1), gpu.closed_surface);
    try std.testing.expect(Sink.closed_msg);
}

test "run: user-close without secondaryClosedMsg does not immediately reopen (F9)" {
    // The app keeps requesting the window open every frame but omits
    // `secondaryClosedMsg`, so after the user closes it (SecHost's 3rd
    // secondary poll returns null) the loop must NOT reopen it while the spec
    // is unchanged — otherwise the window flickers back every frame and the
    // optional hook isn't really optional.
    const App = struct {
        pub const Model = struct {};
        pub const Msg = union(enum) { noop };
        pub fn update(_: *Model, _: Msg) void {}
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.text("main");
            cb.popGroup();
        }
        pub fn secondaryWindow(_: *const Model) ?SecondaryWindowSpec {
            return .{ .title = "Stats", .width = 360, .height = 200 };
        }
        pub fn secondaryView(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.text("stats");
            cb.popGroup();
        }
    };

    var host: SecHost = .{};
    var gpu: SecGpu = .{};
    try run(App, std.testing.allocator, &host, &gpu, .{});

    // Opened exactly once for the whole run (a missing suppression would
    // reopen it on every frame after the user-close).
    try std.testing.expectEqual(@as(u32, 1), gpu.opened);
}

// ── Subscription (timer) test ───────────────────────────────────────
//
// Drives the loop with an app that declares a `.every` sub and a Host whose
// `nowMs` advances across frames. Asserts the fired Msg reaches `update`
// (Model changes) and — the bonus — the live snapshot mirrors the post-fire
// frame with `last_msg` set to the sub's Msg tag.

/// Advancing-clock stub Host. `nowMs` reads a clock that `pollInputs` steps
/// per frame (nowMs' receiver is `*const`, so the step happens on poll):
/// frame 1 → 50 ms (idle, populates prev), frame 2 → 250 ms (crosses the
/// 100 & 200 boundaries → two `.every` fires), frame 3 → close.
const TimerHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    clock_ms: u64 = 0,

    pub fn deinit(_: *TimerHost) void {}
    pub fn shouldClose(self: *const TimerHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *TimerHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = -10;
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        switch (self.frame) {
            1 => {
                self.clock_ms = 50;
                in.resized = true;
            },
            2 => self.clock_ms = 250,
            else => self.closed = true,
        }
        return in;
    }
    pub fn nativeHandle(_: *const TimerHost) void {}
    pub fn textMeasurer(_: *TimerHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *TimerHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const TimerHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *TimerHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *TimerHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *TimerHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn requestFileDialog(_: *TimerHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn requestSaveFileDialog(_: *TimerHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn pollFileDialogResult(_: *TimerHost, _: u32) host_iface.FileDialogPoll {
        return .{ .pending = {} };
    }
    pub fn openSecondaryWindow(_: *TimerHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn pollSecondaryInputs(_: *TimerHost, _: u32) ?InputState {
        return null;
    }
    pub fn closeSecondaryWindow(_: *TimerHost, _: u32) void {}
    pub fn secondaryWindowHandle(_: *const TimerHost, _: u32) ?void {
        return null;
    }
    pub fn setTitle(_: *TimerHost, _: []const u8) void {}
    pub fn nowMs(self: *const TimerHost) u64 {
        return self.clock_ms;
    }
};

/// A tick counter driven purely by a `.every` subscription — no input. The
/// label is formatted into the per-frame cmd arena (not aliased from Model),
/// so the two frame buffers hold distinct copies and the frame-diff can see
/// the count change with no accompanying transient-state change.
const TimerApp = struct {
    pub const Model = struct { ticks: i32 = 0 };
    pub const Msg = union(enum) { tick };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .tick => m.ticks += 1,
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.text(std.fmt.allocPrint(cb.arena.allocator(), "ticks: {d}", .{m.ticks}) catch "ticks: ?");
        cb.popGroup();
    }
    pub fn subscribe(_: *const Model) []const sub_mod.Sub(Msg) {
        // Fire `.tick` on every crossed 100 ms boundary.
        return &.{.{ .every = .{ .interval_ms = 100, .msg = .tick } }};
    }
};

test "run: services a .every subscription and mirrors the fired Msg to the snapshot" {
    comptime host_iface.validateHost(TimerHost);

    const gpa = std.testing.allocator;
    const io = std.Options.debug_io;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/timer.snap", .{td.sub_path});
    defer gpa.free(path);

    var host: TimerHost = .{};
    var gpu: StubGpu = .{};
    try run(TimerApp, gpa, &host, &gpu, .{ .snapshot_path = path });

    // Frame 1 (50 ms) is the first frame — no window to compare, no fire.
    // Frame 2 (250 ms) crosses the 100 & 200 ms boundaries → two `.tick`s.
    const contents = try td.dir.readFileAlloc(io, "timer.snap", gpa, .limited(1 << 20));
    defer gpa.free(contents);

    // The Model changed twice through `update` (the snapshot is the only
    // channel — `run` owns the Model — and it holds the latest frame).
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 2\"") != null);
    // …and a sub-fired Msg drives `last_msg` exactly like an input Msg.
    try std.testing.expect(std.mem.indexOf(u8, contents, "last_msg=tick") != null);
    // The pre-fire label is gone — the file holds only the latest frame.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 0\"") == null);
}

// ── Secondary-content snapshot diff (F2) ────────────────────────────
//
// A `.every` sub changes ONLY the secondary view; the primary stays static.
// Without a secondary-content term in the snapshot gate the mirror file stays
// frozen at the opening frame (probe: "ticks: 0" while the screen showed
// "ticks: 2"). Assert the file reflects the latest secondary content.

/// Advancing-clock stub Host with a secondary window that stays open for the
/// whole run (the secondary poll never returns null). Clock: frame 1 → 50 ms,
/// 2 → 150 ms, 3 → 250 ms, 4 → close.
const SecSnapHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    clock_ms: u64 = 0,

    pub const NativeHandle = struct { tag: u32 = 7 };

    pub fn deinit(_: *SecSnapHost) void {}
    pub fn shouldClose(self: *const SecSnapHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *SecSnapHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = -10;
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        switch (self.frame) {
            1 => {
                self.clock_ms = 50;
                in.resized = true;
            },
            2 => self.clock_ms = 150,
            3 => self.clock_ms = 250,
            else => self.closed = true,
        }
        return in;
    }
    pub fn nativeHandle(_: *const SecSnapHost) void {}
    pub fn textMeasurer(_: *SecSnapHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *SecSnapHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const SecSnapHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *SecSnapHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *SecSnapHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *SecSnapHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn requestFileDialog(_: *SecSnapHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn requestSaveFileDialog(_: *SecSnapHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn pollFileDialogResult(_: *SecSnapHost, _: u32) host_iface.FileDialogPoll {
        return .{ .pending = {} };
    }
    pub fn openSecondaryWindow(_: *SecSnapHost, _: []const u8, _: u32, _: u32) ?u32 {
        return 1;
    }
    pub fn secondaryWindowHandle(_: *const SecSnapHost, _: u32) ?NativeHandle {
        return .{};
    }
    pub fn pollSecondaryInputs(_: *SecSnapHost, _: u32) ?InputState {
        // Never a user-close: the window stays open every frame.
        var in = std.mem.zeroes(InputState);
        in.width = 360;
        in.height = 200;
        in.chars = &.{};
        in.keys = &.{};
        return in;
    }
    pub fn closeSecondaryWindow(_: *SecSnapHost, _: u32) void {}
    pub fn setTitle(_: *SecSnapHost, _: []const u8) void {}
    pub fn nowMs(self: *const SecSnapHost) u64 {
        return self.clock_ms;
    }
};

/// Primary view is static; a `.every` sub increments a counter shown ONLY in
/// the secondary window's view.
const SecSnapApp = struct {
    pub const Model = struct { ticks: i32 = 0 };
    pub const Msg = union(enum) { tick };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .tick => m.ticks += 1,
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.text("main"); // static — never changes across frames
        cb.popGroup();
    }
    pub fn secondaryWindow(_: *const Model) ?SecondaryWindowSpec {
        return .{ .title = "Stats", .width = 360, .height = 200 };
    }
    pub fn secondaryView(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.text(std.fmt.allocPrint(cb.arena.allocator(), "ticks: {d}", .{m.ticks}) catch "ticks: ?");
        cb.popGroup();
    }
    pub fn subscribe(_: *const Model) []const sub_mod.Sub(Msg) {
        return &.{.{ .every = .{ .interval_ms = 100, .msg = .tick } }};
    }
};

test "run: a secondary-content-only change re-mirrors the snapshot (F2)" {
    comptime host_iface.validateHost(SecSnapHost);

    const gpa = std.testing.allocator;
    const io = std.Options.debug_io;

    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/sec.snap", .{td.sub_path});
    defer gpa.free(path);

    var host: SecSnapHost = .{};
    var gpu: SecGpu = .{};
    try run(SecSnapApp, gpa, &host, &gpu, .{ .snapshot_path = path });

    const contents = try td.dir.readFileAlloc(io, "sec.snap", gpa, .limited(1 << 20));
    defer gpa.free(contents);

    // The primary never changed; only the secondary view did (two `.tick`s
    // over frames 2 & 3). The gate must have re-mirrored on the
    // secondary-content diff, so the file holds the latest secondary body.
    try std.testing.expect(std.mem.indexOf(u8, contents, "=== secondary \"Stats\" ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 2\"") != null);
    // A frozen mirror (the bug) would still show the opening "ticks: 0".
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 0\"") == null);
}

// ── Interactive canvas / scroll routing tests ───────────────────────
//
// A scripted Host feeds `Runtime.frame` one `Frame` of input per tick and
// closes after the last, so each test reads `rt.model` directly — no
// statics. Input is routed against the PREVIOUS frame's layout, so frame 1
// only builds the view (and reports layout); real pointer events start at
// frame 2.

const Frame = struct {
    x: f32 = -10,
    y: f32 = -10,
    /// Buttons held after this frame's events.
    held: pointer.Buttons = .{},
    down: pointer.Buttons = .{},
    up: pointer.Buttons = .{},
    mods: pointer.Modifiers = .{},
    wheel_dx: f32 = 0,
    wheel_dy: f32 = 0,
    keys: []const keys.SpecialKey = &.{},
};

const left: pointer.Buttons = .{ .left = true };
const right: pointer.Buttons = .{ .right = true };
const both: pointer.Buttons = .{ .left = true, .right = true };

const ScriptHost = struct {
    script: []const Frame,
    next: usize = 0,
    width: u32 = 400,
    height: u32 = 300,

    pub fn deinit(_: *ScriptHost) void {}
    pub fn shouldClose(self: *const ScriptHost) bool {
        return self.next > self.script.len;
    }
    pub fn pollInputs(self: *ScriptHost) InputState {
        defer self.next += 1;
        if (self.next >= self.script.len) return std.mem.zeroes(InputState); // past the end: closes
        const f = self.script[self.next];
        var in = std.mem.zeroes(InputState);
        in.width = self.width;
        in.height = self.height;
        in.resized = self.next == 0;
        in.mouse_x = f.x;
        in.mouse_y = f.y;
        in.buttons = f.held;
        in.button_down = f.down;
        in.button_up = f.up;
        in.mouse_down = f.down.left;
        in.mouse_up = f.up.left;
        in.mods = f.mods;
        in.wheel_dx = f.wheel_dx;
        in.wheel_dy = f.wheel_dy;
        in.keys = f.keys;
        return in;
    }
    pub fn nativeHandle(_: *const ScriptHost) void {}
    pub fn textMeasurer(_: *ScriptHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *ScriptHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const ScriptHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *ScriptHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn requestFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn requestSaveFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn pollFileDialogResult(_: *ScriptHost, _: u32) host_iface.FileDialogPoll {
        return .{ .pending = {} };
    }
    pub fn openSecondaryWindow(_: *ScriptHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn pollSecondaryInputs(_: *ScriptHost, _: u32) ?InputState {
        return null;
    }
    pub fn closeSecondaryWindow(_: *ScriptHost, _: u32) void {}
    pub fn secondaryWindowHandle(_: *const ScriptHost, _: u32) ?void {
        return null;
    }
    pub fn setTitle(_: *ScriptHost, _: []const u8) void {}
    pub fn nowMs(_: *const ScriptHost) u64 {
        return 0;
    }
};

/// Drive `App` through `script` and hand back the finished Runtime (so the
/// test can read `rt.model`). The caller deinits it.
fn playScript(comptime App: type, script: []const Frame) !Runtime(App, ScriptHost, StubGpu) {
    const Rt = Runtime(App, ScriptHost, StubGpu);
    const S = struct {
        var host: ScriptHost = undefined;
        var gpu: StubGpu = .{};
    };
    S.host = .{ .script = script };
    S.gpu = .{};
    var rt = try Rt.init(std.testing.allocator, &S.host, &S.gpu, .{});
    errdefer rt.deinit();
    while (!S.host.shouldClose()) try rt.frame();
    return rt;
}

/// Shared App: a 200x100 pointer canvas (id 7) at the origin with a button
/// below it, logging every Msg into the Model.
/// Fixed-capacity Msg log the test Models keep, so assertions read the
/// Model straight off the finished Runtime.
const EventLog = struct {
    buf: [64]PointerApp.Logged = undefined,
    n: usize = 0,

    fn push(self: *EventLog, l: PointerApp.Logged) void {
        self.buf[self.n] = l;
        self.n += 1;
    }
    fn items(self: *const EventLog) []const PointerApp.Logged {
        return self.buf[0..self.n];
    }
};

const PointerApp = struct {
    const Logged = union(enum) {
        canvas: pointer.CanvasEvent,
        click,
        wheel: f32,
        scroll: struct { id: u32, dx: f32, dy: f32 },
        scroll_layout: struct { id: u32, vw: f32, vh: f32, cw: f32, ch: f32 },
        widen,
    };
    pub const Model = struct {
        log: EventLog = .{},
        wide: bool = false,
    };
    pub const Msg = Logged;
    pub fn update(m: *Model, msg: Msg) void {
        if (msg == .widen) m.wide = true;
        m.log.push(msg);
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.canvasInteractive(.{ .width = if (m.wide) 300 else 200, .height = 100 }, &.{}, 7, "viewport");
        cb.button(.click, "B");
        cb.popGroup();
    }
    pub fn canvasMsg(_: *const Model, ev: pointer.CanvasEvent) ?Msg {
        return .{ .canvas = ev };
    }
    pub fn wheelMsg(_: *const Model, dy: f32) ?Msg {
        return .{ .wheel = dy };
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .enter) Msg.widen else null;
    }
};

fn expectKinds(log: []const PointerApp.Logged, expected: []const pointer.CanvasEventKind) !void {
    var got: [64]pointer.CanvasEventKind = undefined;
    var n: usize = 0;
    for (log) |l| switch (l) {
        .canvas => |ev| {
            got[n] = ev.kind;
            n += 1;
        },
        else => {},
    };
    try std.testing.expectEqualSlices(pointer.CanvasEventKind, expected, got[0..n]);
}

test "canvas events: hover, press captures through a drag outside, release + leave" {
    var rt = try playScript(PointerApp, &.{
        .{}, // 1: view built; canvas laid out -> `layout`
        .{ .x = 50, .y = 40 }, // 2: enters the canvas
        .{ .x = 60, .y = 45 }, // 3: moves within it
        .{ .x = 60, .y = 45, .held = left, .down = left }, // 4: press
        .{ .x = 300, .y = 250, .held = left }, // 5: dragged off the canvas, still captured
        .{ .x = 300, .y = 250, .up = left }, // 6: release outside
        .{ .x = 300, .y = 250 }, // 7: idle
    });
    defer rt.deinit();
    const log = rt.model.log.items();

    try expectKinds(log, &.{ .layout, .move, .move, .down, .move, .up, .leave });

    const layout_ev = log[0].canvas;
    try std.testing.expectEqual(@as(u32, 7), layout_ev.id);
    try std.testing.expectEqual(@as(f32, 200), layout_ev.w);
    try std.testing.expectEqual(@as(f32, 100), layout_ev.h);

    // Entry move: local coords, zero delta. Second move: delta from the first.
    const enter = log[1].canvas;
    try std.testing.expectEqual(@as(f32, 50), enter.x);
    try std.testing.expectEqual(@as(f32, 40), enter.y);
    try std.testing.expectEqual(@as(f32, 0), enter.dx);
    const mv = log[2].canvas;
    try std.testing.expectEqual(@as(f32, 10), mv.dx);
    try std.testing.expectEqual(@as(f32, 5), mv.dy);

    const down = log[3].canvas;
    try std.testing.expectEqual(pointer.Button.left, down.button);
    try std.testing.expect(down.buttons.left);
    try std.testing.expectEqual(@as(f32, 60), down.x);

    // Captured move outside the rect: local coords run past the canvas.
    const drag = log[4].canvas;
    try std.testing.expectEqual(@as(f32, 300), drag.x);
    try std.testing.expectEqual(@as(f32, 240), drag.dx);
    try std.testing.expect(drag.buttons.left);

    const up = log[5].canvas;
    try std.testing.expectEqual(pointer.Button.left, up.button);
    try std.testing.expect(!up.buttons.any());
    // No stray click Msg: a pointer canvas has no click msg.
    for (log) |l| try std.testing.expect(l != .click);
}

test "canvas events: leaving without a press sends leave; wheel goes to the canvas, not wheelMsg" {
    var rt = try playScript(PointerApp, &.{
        .{},
        .{ .x = 50, .y = 40 },
        .{ .x = 50, .y = 40, .wheel_dy = 120, .mods = .{ .ctrl = true } }, // pinch-style wheel on the canvas
        .{ .x = 50, .y = 150 }, // moved onto the button below
        .{ .x = 50, .y = 150, .wheel_dy = 48 }, // wheel over a button: plain wheelMsg
    });
    defer rt.deinit();
    const log = rt.model.log.items();

    try expectKinds(log, &.{ .layout, .move, .wheel, .leave });
    const wheel_ev = log[2].canvas;
    try std.testing.expectEqual(@as(f32, 120), wheel_ev.dy);
    try std.testing.expect(wheel_ev.mods.ctrl);
    try std.testing.expectEqual(@as(f32, 50), wheel_ev.x);
    // Exactly one plain wheel Msg: the one over the button, none for the canvas wheel.
    var plain: usize = 0;
    for (log) |l| if (l == .wheel) {
        plain += 1;
        try std.testing.expectEqual(@as(f32, 48), l.wheel);
    };
    try std.testing.expectEqual(@as(usize, 1), plain);
}

test "canvas events: a press that started elsewhere does not hover the canvas" {
    var rt = try playScript(PointerApp, &.{
        .{},
        .{ .x = 50, .y = 150, .held = left, .down = left }, // press on the button
        .{ .x = 50, .y = 50, .held = left }, // dragged over the canvas
        .{ .x = 50, .y = 50, .up = left }, // released over it
        .{ .x = 55, .y = 50 }, // now hovering is fine
    });
    defer rt.deinit();
    try expectKinds(rt.model.log.items(), &.{ .layout, .move });
    // The release over the canvas did not click the button (drag-off cancel).
    for (rt.model.log.items()) |l| try std.testing.expect(l != .click);
}

test "canvas events: a click inside one frame sends down then up and leaves no capture" {
    var rt = try playScript(PointerApp, &.{
        .{},
        .{ .x = 10, .y = 10, .held = .{}, .down = left, .up = left }, // fast click
        .{ .x = 20, .y = 20 }, // hover continues, nothing captured
    });
    defer rt.deinit();
    try expectKinds(rt.model.log.items(), &.{ .layout, .move, .down, .up, .move });
}

test "canvas events: multiple buttons keep the capture until all are released" {
    var rt = try playScript(PointerApp, &.{
        .{},
        .{ .x = 10, .y = 10 },
        .{ .x = 10, .y = 10, .held = left, .down = left },
        .{ .x = 300, .y = 10, .held = both, .down = right, .mods = .{ .shift = true } }, // 2nd button, off the canvas
        .{ .x = 300, .y = 10, .held = right, .up = left }, // one released: still captured
        .{ .x = 300, .y = 10, .up = right }, // last released outside
    });
    defer rt.deinit();
    const log = rt.model.log.items();
    try expectKinds(log, &.{ .layout, .move, .down, .move, .down, .up, .up, .leave });
    const second_down = log[4].canvas;
    try std.testing.expectEqual(pointer.Button.right, second_down.button);
    try std.testing.expect(second_down.buttons.left and second_down.buttons.right);
    try std.testing.expect(second_down.mods.shift);
}

test "canvas events: layout fires again when the canvas size changes, not otherwise" {
    var rt = try playScript(PointerApp, &.{
        .{}, // 1: layout 200x100
        .{}, // 2: unchanged -> nothing
        .{ .keys = &.{.enter} }, // 3: model.wide = true
        .{}, // 4: view builds the 300-wide canvas -> layout
        .{}, // 5: unchanged
    });
    defer rt.deinit();
    const log = rt.model.log.items();
    var layouts: usize = 0;
    var last_w: f32 = 0;
    for (log) |l| switch (l) {
        .canvas => |ev| if (ev.kind == .layout) {
            layouts += 1;
            last_w = ev.w;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), layouts);
    try std.testing.expectEqual(@as(f32, 300), last_w);
}

/// A scroll region (id 3) with a button list above a plain button, plus an
/// id-0 region, to exercise `scrollMsg` / `scrollLayoutMsg`.
const ScrollApp = struct {
    pub const Model = struct {
        log: EventLog = .{},
        rows: u32 = 3,
    };
    pub const Msg = PointerApp.Logged;
    pub fn update(m: *Model, msg: Msg) void {
        if (msg == .widen) m.rows += 2;
        m.log.push(msg);
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.pushScroll(.{ .id = 3, .width = 200, .height = 80, .padding = 0 }); // 0..80
        for (0..m.rows) |_| cb.button(.click, "row");
        cb.popScroll();
        cb.pushScroll(.{ .id = 0, .width = 200, .height = 80, .padding = 0 }); // 80..160
        cb.button(.click, "plain");
        cb.popScroll();
        cb.popGroup();
    }
    pub fn scrollMsg(_: *const Model, id: u32, dx: f32, dy: f32) ?Msg {
        return .{ .scroll = .{ .id = id, .dx = dx, .dy = dy } };
    }
    pub fn scrollLayoutMsg(_: *const Model, id: u32, vw: f32, vh: f32, cw: f32, ch: f32) ?Msg {
        return .{ .scroll_layout = .{ .id = id, .vw = vw, .vh = vh, .cw = cw, .ch = ch } };
    }
    pub fn wheelMsg(_: *const Model, dy: f32) ?Msg {
        return .{ .wheel = dy };
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .enter) Msg.widen else null;
    }
};

test "scrollMsg: wheel over an id-bearing region; elsewhere falls to wheelMsg" {
    var rt = try playScript(ScrollApp, &.{
        .{},
        .{ .x = 50, .y = 40, .wheel_dy = 96, .wheel_dx = 12 }, // over region id 3
        .{ .x = 50, .y = 120, .wheel_dy = 48 }, // over the id-0 region: no consumer
    });
    defer rt.deinit();
    var scrolls: usize = 0;
    var wheels: usize = 0;
    for (rt.model.log.items()) |l| switch (l) {
        .scroll => |s| {
            scrolls += 1;
            try std.testing.expectEqual(@as(u32, 3), s.id);
            try std.testing.expectEqual(@as(f32, 96), s.dy);
            try std.testing.expectEqual(@as(f32, 12), s.dx);
        },
        .wheel => |dy| {
            wheels += 1;
            try std.testing.expectEqual(@as(f32, 48), dy);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), scrolls);
    try std.testing.expectEqual(@as(usize, 1), wheels);
}

test "scrollLayoutMsg: first layout and content changes, not idle frames" {
    var rt = try playScript(ScrollApp, &.{
        .{}, // 1: first layout of region 3
        .{}, // 2: idle -> nothing
        .{ .keys = &.{.enter} }, // 3: 3 -> 5 rows
        .{}, // 4: new content size reported
        .{}, // 5: idle
    });
    defer rt.deinit();
    var reports: [8]@TypeOf(@as(PointerApp.Logged, undefined).scroll_layout) = undefined;
    var n: usize = 0;
    for (rt.model.log.items()) |l| switch (l) {
        .scroll_layout => |r| {
            reports[n] = r;
            n += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 3), reports[0].id);
    try std.testing.expectEqual(@as(f32, 200), reports[0].vw);
    try std.testing.expectEqual(@as(f32, 80), reports[0].vh);
    try std.testing.expectEqual(@as(f32, 3 * 36), reports[0].ch);
    try std.testing.expectEqual(@as(f32, 5 * 36), reports[1].ch);
    try std.testing.expectEqual(@as(f32, 80), reports[1].vh); // viewport unchanged
}

test "cmdsEqual: canvas id / pointer changes compare unequal" {
    const Msg = union(enum) { a };
    var x = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer x.deinit();
    var y = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer y.deinit();

    x.canvasInteractive(.{}, &.{}, 1, "c");
    y.canvasInteractive(.{}, &.{}, 1, "c");
    try std.testing.expect(cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    y.reset();
    y.canvasInteractive(.{}, &.{}, 2, "c");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    y.reset();
    y.canvasLabeled(.{}, &.{}, "c"); // same label, not interactive
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Scroll region ids are part of the push_scroll payload.
    x.reset();
    y.reset();
    x.pushScroll(.{ .id = 1 });
    y.pushScroll(.{ .id = 2 });
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));
}

/// Canvas (id 7) with a popup button overlapping its corner; `.widen` (Enter)
/// removes the canvas from the view altogether.
const OverlayApp = struct {
    pub const Model = struct {
        log: EventLog = .{},
        canvas_gone: bool = false,
    };
    pub const Msg = PointerApp.Logged;
    pub fn update(m: *Model, msg: Msg) void {
        if (msg == .widen) m.canvas_gone = true;
        m.log.push(msg);
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        if (!m.canvas_gone) cb.canvasInteractive(.{ .width = 200, .height = 100 }, &.{}, 7, "");
        cb.popGroup();
        cb.pushOverlay(.{ .x = 10, .y = 10 });
        cb.button(.click, "Menu"); // 60x36 at (10,10)
        cb.popOverlay();
    }
    pub fn canvasMsg(_: *const Model, ev: pointer.CanvasEvent) ?Msg {
        return .{ .canvas = ev };
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .enter) Msg.widen else null;
    }
};

test "canvas events: an overlay widget over the canvas wins hover, press and click" {
    var rt = try playScript(OverlayApp, &.{
        .{},
        .{ .x = 20, .y = 20 }, // over the popup button, which covers the canvas corner
        .{ .x = 20, .y = 20, .held = left, .down = left },
        .{ .x = 20, .y = 20, .up = left }, // click on the button
        .{ .x = 150, .y = 60 }, // canvas area outside the popup
    });
    defer rt.deinit();
    const log = rt.model.log.items();
    // Only the canvas layout, then the move once the cursor leaves the popup.
    try expectKinds(log, &.{ .layout, .move });
    try std.testing.expectEqual(@as(f32, 150), log[log.len - 1].canvas.x);
    var clicks: usize = 0;
    for (log) |l| if (l == .click) {
        clicks += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), clicks);
}

test "canvas events: a capture whose canvas leaves the view is dropped, not stuck" {
    var rt = try playScript(OverlayApp, &.{
        .{},
        .{ .x = 150, .y = 60 },
        .{ .x = 150, .y = 60, .held = left, .down = left }, // capture
        .{ .x = 150, .y = 60, .held = left, .keys = &.{.enter} }, // canvas removed from the view
        .{ .x = 160, .y = 60, .held = left }, // drag with the canvas gone: no events, no crash
        .{ .x = 160, .y = 60, .up = left },
        .{ .x = 150, .y = 60 },
    });
    defer rt.deinit();
    try expectKinds(rt.model.log.items(), &.{ .layout, .move, .down });
}
