//! Canonical application loop — the `teak.run` wrapper.
//!
//! Every consumer used to hand-copy ~200 lines of host-loop glue:
//! double-buffered `CmdBuffer` + rect storage, the press-target
//! mousedown/up dance, keyboard + wheel routing, clipboard glue, the
//! frame-diff vertex-rebuild skip, layout, transient-state update,
//! `buildVertices` + upload, and `renderFrame`. ~80% of that is
//! identical across apps. `run` ships it once.
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
const layout = @import("layout/engine.zig");
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
/// `validateGpu`; both are taken as `anytype` so `run` never imports a
/// backend.
pub fn run(
    comptime App: type,
    gpa: std.mem.Allocator,
    host: anytype,
    gpu: anytype,
    opts: RunOptions,
) !void {
    const Msg = App.Msg;
    const CmdBufT = cmd.CmdBuffer(Msg);

    var model: App.Model = if (@hasDecl(App.Model, "init")) App.Model.init() else .{};

    // Every Msg is routed through `dispatch` so the live snapshot's header
    // can name the last transition (`@tagName`). `dispatch` adds nothing to
    // the TEA loop — it is `App.update` plus one string assignment.
    var last_msg: []const u8 = "";
    const Router = struct {
        fn dispatch(m: *App.Model, msg: Msg, last: *[]const u8) void {
            last.* = @tagName(std.meta.activeTag(msg));
            App.update(m, msg);
        }
    };

    // Subscriptions (HARDLINE §2 hatch 6). If the app declares `subscribe`,
    // `run` services its declared subs once per frame: it calls the pure
    // `subscribe(model)` (the app only *declares* what to watch), then feeds
    // the returned slice through `runSubs` on the host's monotonic clock. A
    // fired sub is routed through `Router.dispatch` exactly like an input Msg
    // — it mutates `Model` through `update` (no second mutation path) and
    // updates `last_msg` for the snapshot sink. `runSubs` invokes
    // `dispatch.call(msg)`, so the model + last_msg pointers the router needs
    // ride *inside* a per-frame dispatcher VALUE (built at the call site
    // below), not on module-level statics — HARDLINE hatch 4 says `run` adds
    // no retained mutable state, and statics would also cross-wire two
    // concurrent `run` calls sharing the same (App, Host, Gpu). Time itself
    // lives on the Host (`nowMs`), never core.
    const has_subscribe = @hasDecl(App, "subscribe");
    const SubDispatch = struct {
        model: *App.Model,
        last: *[]const u8,
        // `pub` so `sub_mod.runSubs` (a different module) can invoke it.
        pub fn call(self: @This(), msg: Msg) void {
            Router.dispatch(self.model, msg, self.last);
        }
    };

    // Live-snapshot sink (opt-in via RunOptions.snapshot_path / TEAK_SNAPSHOT).
    var snap = SnapshotSink.init(gpa, opts.snapshot_path);
    defer snap.deinit();
    // Force a first write even if the opening frame happens to match the empty
    // previous buffer, and detect secondary open/close transitions.
    var snap_first = true;
    var prev_secondary_open = false;

    // Double-buffered command buffers: build into one while hit-testing
    // against the other (one-frame input latency, imperceptible).
    var bufs = [2]CmdBufT{ CmdBufT.init(gpa), CmdBufT.init(gpa) };
    defer for (&bufs) |*b| b.deinit();

    // Parallel rect store, one slice per buffer, grown to fit the frame
    // (no fixed MAX_RECTS cap — the examples panicked past theirs).
    var rects = [2]std.ArrayList(Rect){ .empty, .empty };
    defer for (&rects) |*r| r.deinit(gpa);

    var verts: std.ArrayList(vertex.Vertex) = .empty;
    defer verts.deinit(gpa);
    var text_draws: std.ArrayList(text.TextDraw) = .empty;
    defer text_draws.deinit(gpa);
    var image_draws: std.ArrayList(render.ImageDraw) = .empty;
    defer image_draws.deinit(gpa);

    var ts: TransientState = .{};
    var prev_ts: TransientState = .{};

    // Press model: arm `press_target` on mousedown over a widget; fire
    // the click only if mouseup lands on the same widget; drag-off
    // cancels without firing.
    var press_target: ?usize = null;

    // Subscription timer state: the previous frame's `nowMs`. `runSubs` is
    // stateless — it decides fire/skip purely from (last_sub_ms, now_ms, sub
    // data) — so this single timestamp is all the bookkeeping `run` holds.
    // `null` until the first frame binds it, so no sub fires on the opening
    // tick (it has no window to compare against).
    var last_sub_ms: ?u64 = null;

    // Optional secondary window. `has_secondary` is comptime, so the whole
    // machinery (including the Gpu methods outside `validateGpu`) is only
    // analyzed for apps that opt in.
    const has_secondary = @hasDecl(App, "secondaryWindow") and @hasDecl(App, "secondaryView");
    var secondary = SecondaryDriver(CmdBufT).init(gpa);
    defer secondary.deinit(gpa);
    // After the user closes the OS window, remember the spec that was open so
    // we DON'T immediately reopen it while the app still reports the same
    // spec (which it will if it omits `secondaryClosedMsg`). Cleared once the
    // spec changes (or goes null), so a later reopen with a different spec —
    // or the same one after an explicit close — works.
    var suppressed_spec: ?SecondaryWindowSpec = null;

    const measurer = host.textMeasurer();

    // Last title pushed to the host, so we only call setTitle on change.
    var title_buf: [256]u8 = undefined;
    var title_len: usize = 0;

    // Run-owned IME composition buffers. `Host.imeState().text` aliases the
    // Host's single mutable global, so both `ts.ime_text` and (after the copy
    // at end of frame) `prev_ts.ime_text` would point at the SAME memory —
    // making a same-length composition edit compare equal and render stale.
    // Copy each frame's composition into the buffer keyed by `current` (the
    // frame parity) so `ts` and `prev_ts` reference distinct storage.
    var ime_bufs: [2][128]u8 = undefined;

    var current: u1 = 0;

    while (!host.shouldClose()) {
        // 1. Drain input.
        const input = host.pollInputs();
        if (host.shouldClose()) break;

        // 2. Resize.
        if (input.resized) gpu.resize(input.width, input.height);

        // 3. Input against the PREVIOUS frame's layout (`prev` captured
        //    before the swap below).
        const prev = current;
        const prev_cmds = bufs[prev].cmds.items;
        const prev_rects = rects[prev].items;
        const hover: ?usize = if (prev_cmds.len > 0)
            hit_test.hoverTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)
        else
            null;

        if (input.mouse_down) press_target = hover;
        if (input.mouse_up) {
            if (press_target != null and hover == press_target) {
                if (hit_test.hitTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)) |hit| {
                    // `hit.msg` is null when a modal overlay consumed the
                    // click but asked for no Msg (HARDLINE §2 hatch 5) —
                    // swallow it, don't fall through.
                    if (hit.msg) |m| Router.dispatch(&model, m, &last_msg);
                }
            }
            press_target = null;
        }
        if (press_target != null and hover != press_target) press_target = null;

        // 4. Keyboard. Characters first, then special keys; clipboard
        //    chords route to the app's own handler with the Host
        //    clipboard vtable (the app owns cut/copy/paste policy).
        if (@hasDecl(App, "keyCharMsg")) {
            for (input.chars) |ch| {
                if (App.keyCharMsg(&model, ch)) |m| Router.dispatch(&model, m, &last_msg);
            }
        }
        for (input.keys) |k| {
            // Built-in Tab / Shift+Tab focus traversal — only for apps
            // that expose `focusedMsg` (so `run` knows the current focus
            // and how to move it). Walk the PREVIOUS frame's focusables
            // (the layout the user sees), then dispatch the landing
            // widget's focus Msg so the app advances its focus field.
            if (@hasDecl(App, "focusedMsg")) {
                if (k == .tab or k == .shift_tab) {
                    const cur_idx = if (App.focusedMsg(&model)) |fm|
                        focus.indexOfFocusMsg(prev_cmds, fm)
                    else
                        null;
                    const target = if (k == .tab)
                        focus.nextFocusable(prev_cmds, cur_idx)
                    else
                        focus.prevFocusable(prev_cmds, cur_idx);
                    if (target) |ti| {
                        if (focus.focusMsgAt(prev_cmds, ti)) |fm| Router.dispatch(&model, fm, &last_msg);
                    }
                    continue;
                }
            }
            // Enter-to-submit — apps opt in with `submitMsg`. Takes
            // precedence over `keySpecialMsg` for the Enter key only.
            if (@hasDecl(App, "submitMsg")) {
                if (k == .enter) {
                    if (App.submitMsg(&model)) |m| Router.dispatch(&model, m, &last_msg);
                    continue;
                }
            }
            const handled_by_clipboard = comptime (@hasDecl(App, "keyNeedsClipboard") and @hasDecl(App, "handleClipboard"));
            if (handled_by_clipboard and App.keyNeedsClipboard(k)) {
                App.handleClipboard(&model, k, host.clipboard());
            } else if (@hasDecl(App, "keySpecialMsg")) {
                if (App.keySpecialMsg(&model, k)) |m| Router.dispatch(&model, m, &last_msg);
            }
        }

        // 5. Wheel.
        if (@hasDecl(App, "wheelMsg")) {
            if (input.wheel_dy != 0 or input.wheel_dx != 0) {
                if (App.wheelMsg(&model, input.wheel_dy)) |m| Router.dispatch(&model, m, &last_msg);
            }
        }

        // 5.5. Subscriptions: fire the app's declared timers before building
        //      this frame's view, so a sub-driven Model change is reflected
        //      in the frame we're about to emit (and mirrored to the snapshot
        //      sink through the normal frame-diff). Pure `subscribe` declares;
        //      `runSubs` watches on the host clock; fired subs dispatch as
        //      ordinary Msgs through `update`.
        if (has_subscribe) {
            const now_ms = host.nowMs();
            const since = last_sub_ms orelse now_ms; // first frame: no window, no fire
            sub_mod.runSubs(Msg, App.subscribe(&model), since, now_ms, SubDispatch{ .model = &model, .last = &last_msg });
            last_sub_ms = now_ms;
        }

        // 6. Build this frame into the other buffer.
        current ^= 1;
        const cur = current;
        bufs[cur].reset();
        if (@hasDecl(App, "themeFor")) bufs[cur].theme = App.themeFor(&model);
        App.view(&model, &bufs[cur]);
        const cur_cmds = bufs[cur].cmds.items;
        debugCheckBalance(cur_cmds, "view");

        // 7. Layout into the matching rect slice (grown to fit).
        try rects[cur].resize(gpa, cur_cmds.len);
        layout.LayoutEngine.doLayout(
            rects[cur].items,
            cur_cmds,
            @floatFromInt(input.width),
            @floatFromInt(input.height),
            measurer,
        );

        // 8. Transient state against THIS frame's layout.
        ts.hover_index = hit_test.hoverTest(cur_cmds, rects[cur].items, input.mouse_x, input.mouse_y);
        ts.press_index = press_target;
        ts.focus_index = focusIndex(App, &model, cur_cmds);
        ts.mouse_x = input.mouse_x;
        ts.mouse_y = input.mouse_y;
        ts.frame_counter +%= 1;

        // IME composition snapshot — presentation-only, host-owned, folded
        // in unconditionally (inactive/empty on hosts without IME).
        const ime = host.imeState();
        ts.ime_active = ime.active;
        const ime_n = @min(ime.text.len, ime_bufs[cur].len);
        @memcpy(ime_bufs[cur][0..ime_n], ime.text[0..ime_n]);
        ts.ime_text = ime_bufs[cur][0..ime_n];
        ts.ime_cursor = ime.cursor;

        // 9. Dynamic window title (only on change).
        if (@hasDecl(App, "windowTitle")) {
            if (App.windowTitle(&model)) |t| {
                // Compare against the (possibly truncated) prefix we actually
                // stored — a title longer than `title_buf` would otherwise
                // never match the stored copy and re-fire `setTitle` every
                // frame. `eql` on differing lengths already returns false, so
                // this also detects a length change.
                const n = @min(t.len, title_buf.len);
                if (!std.mem.eql(u8, t[0..n], title_buf[0..title_len])) {
                    host.setTitle(t);
                    @memcpy(title_buf[0..n], t[0..n]);
                    title_len = n;
                }
            }
        }

        // 10. Frame diff — skip the vertex rebuild + upload when nothing
        //     observable changed. The blink tick forces a rebuild on a
        //     phase boundary so a focused cursor animates.
        const cmds_same = cmdsEqual(Msg, cur_cmds, bufs[prev].cmds.items);
        const rects_same = rectsEqual(rects[cur].items, rects[prev].items);
        const ts_same = ts.hover_index == prev_ts.hover_index and
            ts.press_index == prev_ts.press_index and
            ts.focus_index == prev_ts.focus_index and
            ts.ime_active == prev_ts.ime_active and
            ts.ime_cursor == prev_ts.ime_cursor and
            std.mem.eql(u8, ts.ime_text, prev_ts.ime_text);
        const blink_tick = opts.blink_period > 0 and ts.focus_index != null and
            (ts.frame_counter % opts.blink_period == 0);

        // A live secondary window re-uploads into the shared Gpu scratch
        // buffers after the primary present, so the primary must rebuild
        // its own vertices every frame while it's open.
        const secondary_open = has_secondary and App.secondaryWindow(&model) != null;

        if (!cmds_same or !rects_same or !ts_same or blink_tick or secondary_open) {
            render.buildVertices(&verts, &text_draws, &image_draws, gpa, cur_cmds, rects[cur].items, ts, measurer);
            gpu.uploadVertices(verts.items);
            gpu.uploadText(text_draws.items);
            gpu.uploadImages(image_draws.items);
        }

        prev_ts = ts;

        // 11. Present.
        gpu.renderFrame(opts.clear_color);

        // Set to the secondary window's title on the frames it actually
        // renders, so the live snapshot can append its body below a marker.
        var sec_snap_title: ?[]const u8 = null;
        // True when the secondary view's content changed this frame — feeds
        // the snapshot gate so a secondary-only change still re-mirrors.
        var sec_content_changed = false;

        // 12. Secondary window: open / close / render. The Model drives
        //     intent via `secondaryWindow`; `run` owns the Host + Gpu
        //     resources keyed off `secondary.window_id`. Lock-step ids —
        //     the same id covers the Host window slot and the Gpu surface
        //     slot. Whole block is comptime-gated so a stub Gpu lacking
        //     `openSecondarySurface` never analyzes it.
        if (has_secondary) {
            const spec = App.secondaryWindow(&model);

            // Clear a stale reopen-suppression once the app's intent moves
            // off the spec that was open when the user closed the window.
            if (suppressed_spec) |sup| {
                const still_same = if (spec) |s| secondarySpecEql(sup, s) else false;
                if (!still_same) suppressed_spec = null;
            }
            const reopen_suppressed = suppressed_spec != null;

            if (spec != null and secondary.window_id == null and !reopen_suppressed) {
                // Open: create the OS window, then its GPU surface. Back
                // out cleanly if either half fails so we never leak a
                // window with no renderer (or vice versa).
                const s = spec.?;
                if (host.openSecondaryWindow(s.title, s.width, s.height)) |wid| {
                    if (host.secondaryWindowHandle(wid)) |nh| {
                        if (gpu.openSecondarySurface(nh, s.width, s.height)) |_| {
                            secondary.window_id = wid;
                        } else {
                            host.closeSecondaryWindow(wid);
                        }
                    } else {
                        host.closeSecondaryWindow(wid);
                    }
                }
            } else if (spec == null and secondary.window_id != null) {
                // Close: the app cleared its intent.
                const wid = secondary.window_id.?;
                gpu.closeSecondarySurface(wid);
                host.closeSecondaryWindow(wid);
                secondary.window_id = null;
            }

            if (secondary.window_id) |wid| {
                // A null poll means the user closed the window from the OS
                // — tear down and mirror it back into the Model via the
                // app's close Msg so its own flag flips.
                if (host.pollSecondaryInputs(wid)) |si| {
                    if (si.resized) gpu.resizeWindow(wid, si.width, si.height);

                    const sprev = secondary.cur;
                    secondary.cur ^= 1;
                    const scur = secondary.cur;
                    secondary.bufs[scur].reset();
                    if (@hasDecl(App, "themeFor")) secondary.bufs[scur].theme = App.themeFor(&model);
                    App.secondaryView(&model, &secondary.bufs[scur]);

                    const sec_cmds = secondary.bufs[scur].cmds.items;
                    debugCheckBalance(sec_cmds, "secondaryView");
                    secondary.rects[scur].resize(gpa, sec_cmds.len) catch {};
                    if (secondary.rects[scur].items.len == sec_cmds.len) {
                        layout.LayoutEngine.doLayout(
                            secondary.rects[scur].items,
                            sec_cmds,
                            @floatFromInt(si.width),
                            @floatFromInt(si.height),
                            measurer,
                        );
                        // The secondary window has no interactive/transient
                        // state of its own — a fresh default is correct.
                        const sec_ts: TransientState = .{};
                        render.buildVertices(&verts, &text_draws, &image_draws, gpa, sec_cmds, secondary.rects[scur].items, sec_ts, measurer);
                        gpu.uploadVertices(verts.items);
                        gpu.uploadText(text_draws.items);
                        gpu.uploadImages(image_draws.items);
                        gpu.renderToWindow(wid, opts.clear_color);
                        sec_snap_title = if (spec) |s| s.title else "secondary";
                        // Diff against the previous secondary frame so a
                        // secondary-only change (e.g. a `.every` sub updating
                        // just this view) re-mirrors the snapshot file.
                        sec_content_changed = !cmdsEqual(Msg, sec_cmds, secondary.bufs[sprev].cmds.items) or
                            !rectsEqual(secondary.rects[scur].items, secondary.rects[sprev].items);
                    }
                } else {
                    gpu.closeSecondarySurface(wid);
                    host.closeSecondaryWindow(wid);
                    secondary.window_id = null;
                    // Remember what was open so we don't reopen it next frame
                    // when the app leaves the same spec in place (it omits
                    // `secondaryClosedMsg`). Apps that DO handle the close
                    // clear their spec, which clears this above.
                    suppressed_spec = spec;
                    if (@hasDecl(App, "secondaryClosedMsg")) {
                        if (App.secondaryClosedMsg(&model)) |m| Router.dispatch(&model, m, &last_msg);
                    }
                }
            }
        }

        // 13. Live snapshot: mirror the frame to disk only when its content
        //     actually changed (the same primary frame-diff signal that
        //     gates the vertex rebuild, minus the cosmetic blink tick which
        //     the snapshot doesn't show) — so idle frames never touch disk.
        //     A secondary open/close transition also counts, and the very
        //     first frame is always written. Placed after the secondary
        //     render so its body is available to append.
        if (snap.enabled) {
            const sec_open_now = sec_snap_title != null;
            const changed = snap_first or !cmds_same or !rects_same or !ts_same or
                (sec_open_now != prev_secondary_open) or sec_content_changed;
            if (changed) {
                snap.writeFrame(.{
                    .window_w = @floatFromInt(input.width),
                    .window_h = @floatFromInt(input.height),
                    .frame = ts.frame_counter,
                    .last_msg = last_msg,
                }, cur_cmds, rects[cur].items, &ts, sec_snap_title, secondary.bufs[secondary.cur].cmds.items, secondary.rects[secondary.cur].items);
            }
            snap_first = false;
            prev_secondary_open = sec_open_now;
        }
    }

    // Release any secondary resources still open at shutdown.
    if (has_secondary) {
        if (secondary.window_id) |wid| {
            gpu.closeSecondarySurface(wid);
            host.closeSecondaryWindow(wid);
        }
    }
}

/// Resolve the focused widget's cmd index for this frame. Apps that
/// expose `focusedMsg` get stable, Msg-keyed focus (survives
/// conditional/reordered widgets); apps without it have no focus ring.
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
