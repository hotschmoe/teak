# Source notes

## src/core/pointer.zig

Canvas coordinates are local logical pixels, except layout events, which carry the window-space origin and size. Pointer capture retains move and release events until the last held button is released. A drag target of zero means no target.

## src/text/shaper.zig

Fallback searches registered families, then the app chain and system last-resort list. For right-to-left shaping, an output-full result consumes the unresumable source tail; callers must size the output for the run. Kerning finalizes a base glyph when the next base is known. Default-ignorable code points draw nothing. Available precomposed glyphs take precedence over combining marks; otherwise marks have zero advance and missing marks are dropped.

## src/gpu/wgpu_c.zig

Native requests complete during `wgpuInstanceProcessEvents`, with callbacks storing their result through `userdata1`. The device requests adapter limits rather than defaults because software adapters may not support the defaults. `TEAK_GPU_FALLBACK=1` selects a software adapter.

## src/text/hb_shaper.zig

Bidirectional RTL runs remain RTL regardless of guessed script, and RTL run groups are emitted in reverse order. Tracking is disabled for joining scripts. When a run exceeds the output buffer, it is split at a code point boundary so shaping can resume.

## src/gpu/web_scene.zig

Triangle runs read one packed record per instance; line segments use stride zero so they share their item's record. Each section cap uses stencil parity followed by a cap quad that clears the stencil. The grid is depth-tested and the gizmo is always on top.

## src/gpu/web.zig

The image cache grows to 65,536 live images and falls back to a tinted placeholder when full. Scene targets render offscreen and their composite bind groups are rebuilt when targets change. Overlay staging separates base and overlay records: each layer draws solids, images, scene composites, then text, so opaque overlays cover base text. This order matches the native GPU core.

The zunk atlas uses a downward y-axis from the baseline; glyph pixel (0,0) is at `(pen + bearing_x, baseline - bearing_y)`. The solid vertex buffer is also bound read-only in the fragment stage for SDF records.

## src/gpu/wgpu_core.zig

Image handles are slot indices plus one; zero is the sentinel. Scene bind groups are rebuilt when the offscreen target generation changes. Secondary windows share the device, queue, pipelines and caches; rendering rewrites the screen-size uniform for each surface. The swapchain format is fixed to BGRA8Unorm, so a backend that does not support it must query surface capabilities before selecting a format.

Native resource release order is bind groups, views, textures, then vertex buffers. A presented frame texture must be released before reconfiguring the surface; holding it prevents DX12 swapchain resize. The screen-size uniform must be rewritten even for the primary window after a secondary window is rendered.

The solid vertex buffer is bound in the fragment stage for SDF records. The glyph sampler uses nearest magnification to avoid re-blurring rasterized antialiasing and linear minification. Each layer draws solids, images, scene composites and then text; the overlay follows the base so it covers base text. Scene targets use device resolution and are composited 1:1.

## src/gpu/wgpu_scene.zig

Triangle runs read packed records per instance, while lines use stride zero so every segment shares its item's record. Section caps use stencil parity and a cap quad that clears the stencil. The grid is depth-tested and the gizmo is always on top.


## examples/counter_greeter/build.zig

The ARM64 feature override compensates for Zig's missing Windows i8mm detection. The native UI step exists only when Teak has a backend for the selected target; web and CLI builds do not require it.

## examples/todo/build.zig

The native UI and headless driver are enabled only for supported targets. The Linux development loader swaps rebuilt `libapp.so` while retaining compatible model state; see `docs/features/hot-reload.md`.

## examples/chrome/build.zig

The web `-Dstress=N` option substitutes the glyph-atlas stress app with N monospace text runs for the normal Chrome example.

## tools/bench/main.zig

The vector-canvas benchmark builds world-space frame geometry once; its view reuses the segments and node dots under a pan and zoom transform.

## tools/gen_api.zig

The API generator excludes module aliases nested inside modules and emits only names and kinds for nested public types and constants. Public Zig doc comments supply the generated reference and are retained.

## tools/gen_unicode.zig

Line-break and bidirectional classes apply Unicode file defaults before explicit entries. East Asian wide and fullwidth values set bit 7. Paired brackets pack as `cp | pair << 21 | is_close << 42` in code-point order.

## tools/audit.zig

The static-variable check uses column-zero declarations to distinguish module state from indented locals. Public exports are checked against `llms.txt` by substring, deliberately allowing wording to vary. Generated API docs are checked against `tools/gen_api.zig`; module trees must list non-test source files.

## tools/win32_live/driver.zig

A synthetic Alt tap and shared input queue allow the background driver to take foreground; topmost ordering avoids runner setup windows. A black screen capture falls back to the compositor's window pixels. The drag source offers only its real COM interfaces: claiming IMarshal corrupts cross-process drag. OLE requires actual relative mouse events, and a synthetic button press would capture input in the app instead of its drag loop.

Cross-process `DoDragDrop` can block inside OLE on CI runners before reaching the app's drop target. The drag scenario is opt-in through `TEAK_LIVE_DRAG=1` and has a watchdog.

## tools/showcase.sh

Showcase generation requires Zig, Vulkan, Chromium, the tools npm dependencies and Pillow; the HarfBuzz shot additionally needs Noto script fonts. `WEBSHOT_ANGLE=vulkan` selects Vulkan where needed; see `docs/showcase.md`.

## tools/showcase.py

`SHOWCASE_MAC` and `SHOWCASE_WIN` supply screenshots from other hosts. The HiDPI crop uses device pixels without resampling.

## tools/release.sh

`tools/release.sh VERSION` changes the version in `build.zig.zon`, commits, tags and pushes it. The release workflow requires the tag to match the manifest version.

## tools/web-frame-bench.mjs

The benchmark times main-thread animation callbacks while scrolling a headless web example. SwiftShader rasterization runs off-thread, so its result excludes GPU cost. Install the tools npm dependencies and pass the distribution directory; `WEBSHOT_ANGLE=vulkan` selects Vulkan where needed.

## tools/web-startup.mjs

The startup profile reports medians from navigation, resource timing and zunk performance marks. Baseline and candidate distributions are sampled alternately with a fresh browser per run. `first-cb` measures the end of the first animation callback without requiring marks, so older builds remain comparable.

## tools/web-ime-test.mjs

The Chromium acceptance driver exercises focused, preedit, committed and canceled IME composition states through DevTools. It checks the hidden field's focus, page errors and pixel differences, allowing for caret blinking. It takes a distribution directory, output prefix and `--click X,Y`; exit codes are 0 for success, 1 for a failed check and 2 for usage.

## tools/webshot.mjs

The smoke check serves a web distribution in headless Chromium and rejects page errors or a blank canvas. Chromium is selected by `--chrome`, then `CHROME_PATH`, then PATH. Some Mali hosts need `WEBSHOT_ANGLE=vulkan`. Exit codes are 0 for success, 1 for a failed check and 2 for usage.

## tools/qa/web.mjs

The visual QA web driver extends the web smoke check with query parameters, scripted actions and device scale factor options.

## tools/a11yprobe.mjs

The probe exercises the browser accessibility tree and DOM mirror for the todo and notes examples; `dump` prints the tree without assertions. It exits with 0 for success, 1 for a failed check or page error, and 2 for usage. See `docs/features/a11y.md`.

## tools/qa/web.py

`web.py [example|all] [out-dir]` drives each selected web distribution through `tools/qa/web.mjs` at 1x and 2x device scale.

## tools/hot_reload_check.sh

The Linux hot-reload check rewrites the todo example and compares state, layout and screenshots across rebuilds. Its cleanup runs `git checkout` on that source file, so it can discard local edits and must not be run in a dirty worktree.

## tools/qa/run.sh

`tools/qa/run.sh [out-dir]` renders native and web examples at 1x and 2x. It needs Zig, Vulkan, Chromium and the tools npm dependencies; some hosts need `WEBSHOT_ANGLE=vulkan`. The default output directory is `/tmp/qa`.

## shaders/image.wgsl

The image tint arrives through the vertex stream; white is passthrough and tint alpha controls opacity.

## shaders/scene_grid.wgsl

The fullscreen grid intersects a world plane and writes depth so geometry can occlude it. Grid levels fade as cells become too small, and the grid dissolves before the far plane.

## shaders/scene.wgsl

Per-item placement uses `scene_pass.Packed` (80 bytes); normals use the linear transform and are normalized after interpolation. Plane layer depth bias orders coplanar sheets. Screen-space sprites retain pixel size; other sprites use billboard, axis-locked or fixed planes. Section caps invert stencil for kept faces and clear it while drawing the cap where parity is odd. Lines use one instance per segment, stride zero for the item transform, and extend half a width at each end to avoid gaps.

## shaders/glyph.wgsl

Each glyph instance uses raw 32-bit attributes shared by native and web. Positions are device pixels, while the screen uniform is logical size, so clip-space division uses `screen * scale`. Flag bits 0–1 select coverage, distance field or RGBA; bits 16–31 encode quad scale in 1/256 units. Coverage uses exact pixel-aligned fetches; distance fields use bilinear sampling and a derivative-sized edge transition. Colour glyphs use their own RGB and instance alpha.

## shaders/quad.wgsl

Solids, antialiased canvas edges and SDF quads share a stream to preserve painter order. Vertex alpha selects solid (`>= 0`), SDF (`-1`) or antialiased edge (`<= -1.5`, with opacity `-2 - a`); the SDF vertex's red field indexes a six-vertex header containing the 36-float record defined in `src/render/sdf.zig`. UVs are pixel offsets from the rect centre. Radii are ordered bottom-right, top-right, bottom-left, top-left with y increasing downward. Derivatives size antialiasing to a device pixel; gradients and shadows use dither to reduce 8-bit banding.

## examples/gallery/src/page_data.zig

The tree uses one Tab stop at its first row. Arrow keys move focus between rows, and Enter or Space toggles a folder.

## examples/chrome/src/shot_main.zig

Screenshot states advance 40 frames to settle the quick-keys popover; its mid-slide state uses deterministic 16 ms frames. Clear colour follows the selected theme. Stress labels are formatted before timing to exclude allocation.

## examples/kerf_viewer/src/shot_main.zig

Scripted window positions target the 1280×800 showcase layout.

## examples/kerf_viewer/src/draw/tess.zig

End ramps are emitted only for lines at least two pixels wide; hard ends on thinner text and hatch strokes avoid extra geometry. In screen coordinates, fill is left of travel for both positively oriented outer loops and negatively oriented holes, so numeric right is outward.

## src/core/cmd.zig

Accessibility hints let composite patterns built from primitive commands expose roles and state to platform mirrors; the default semantic hint leaves the primitive role unchanged. Overlays draw above and hit-test before base content; zero dimensions are measured from children, and an optional backdrop message carries click-outside handling without function pointers. Virtual lists claim total scroll extent while emitting only the visible window and are intended inside a scroll region. Rich-text spans refer to contiguous byte ranges in per-frame data. Canvas coordinates are local logical pixels; the renderer translates and clips them, while primitives remain plain data allocated for the frame. Scene commands produce offscreen-rendered draw records that are composited into the leaf rectangle. Command-buffer balance validation checks matching push/pop kinds as well as depth, because crossed pairs can otherwise silently produce incorrect layout. Form-row nesting is limited to eight in-flight rows.

## src/layout/engine.zig

Layout uses bottom-up measurement and top-down positioning; frames with wrapped text or shrinkable nodes also resolve widths top-down and remeasure heights bottom-up. Container accumulators carry child totals between passes, avoiding rescans. Flex consumes main-axis leftover before justification, and cross-axis stretch uses the container's inner extent. Overlays do not contribute to parent measurement. Virtual lists claim their full logical extent even when only a visible window is emitted. A flex scroll starts with zero main-axis size unless explicitly sized so overflow remains possible. Layout stack overflow, underflow and empty reads panic in every optimization mode; the passes attach the command index when checking bounds. See `docs/features/layout.md`.

Grid passes rescan direct children while skipping subtrees via `Rect.end`, visiting each command only a bounded number of times; column scratch has fixed capacity and rows use one running accumulator. Positioned scroll children are offset and clipped by render and hit-test, while overlays do not advance the parent cursor. Rich-text measurement uses each span's font and defaults for uncovered bytes.

## src/render/build.zig

Base rendering pushes a zero clip for overlay children, defensively suppressing them until the overlay pass. A group's panel and text-selection highlights are emitted before their contents so painter order places content on top. Missing image handles render tinted placeholders. Disabled controls omit interaction feedback, focus, selection and caret. IME preedit comes from `TransientState`, draws inline with an underline, and is committed through the normal text-input message path; the caret moves to the end of the preedit. Canvas primitives use the intersection of their own rect and enclosing scroll or overlay clip; rotated polylines additionally use data-space Liang–Barsky clipping.

## src/core/dropdown.zig

Dropdown state is app-owned model data (`open` and selected index); option labels remain app-owned. The component emits existing button and modal-overlay primitives, with messages as data and the selection constructor supplied only at compile time. The three-argument component view has no option slice and shows the placeholder; applications use `viewWith` to supply labels. Open-list panels and rows fill the viewport width so clicks beside short labels select the row instead of falling through to the modal backdrop. See HARDLINE §1 and §3.

Opening sets the keyboard cursor to the selection; reveal waits for keyboard movement because the toggle message carries no viewport geometry. A stale cursor is clamped before movement so shrinking the option list cannot push the reveal offset beyond its maximum. Scrolling lists nest a scroll region inside the overlay; render and hit-test intersect both clips, and scroll calculations use `ITEM_HEIGHT` regardless of theme button height.

## src/platform/win32.zig

Integer `MAKEINTRESOURCE` identifiers may be odd and must not be represented as aligned UTF-16 pointers. Per-monitor DPI awareness makes Windows report physical pixels; the Host converts them to logical units. OLE `RegisterDragDrop` receives files, images and Unicode text from `IDataObject`; image conversions live in `win32_data.zig` and produce PNG data limited to 1,568 pixels plus an RGBA thumbnail. IME preedit is read through Imm APIs in UTF-16 units, while committed characters arrive through `WM_CHAR`. UI Automation queries run on a worker thread and share the published tree under `g_a11y_lock`; interface vtable pointers identify their owning provider. The truncated VARIANT layout is used only for the integer, BSTR and boolean values the bridge returns. These platform-owned surfaces remain behind the Host boundary; see HARDLINE §2 and §3.

The UIA snapshot copies arena-backed nodes into locked fixed storage because queries can arrive after the frame ends; it truncates beyond 256 nodes, and individual labels are capped at 512 bytes. Primary and secondary windows share the thread's Win32 message queue but keep separate input queues. Vertical wheel deltas are inverted to match Host coordinates. Alt alone and F10 are consumed for menu activation, while other Alt combinations continue to the system. The IME mirror is a 256-byte UTF-8 buffer and truncates at code point boundaries.

UIA control patterns enqueue actions from the worker thread for `Host.pollA11yActions` to deliver through the normal update path. Only the root delegates to `UiaHostProviderFromHwnd`; fragment children return null. The root provider is a process-lifetime singleton; `WM_GETOBJECT` returns its Simple interface and UIA queries the other interfaces as needed. Its static `AddRef` is safe because module storage owns the provider lifetime.

The Host adopts Windows' suggested rectangle on DPI change, triggering resize and layout, and forces a frame after invalidation even while idle. It suppresses the system IME window while rendering preedit inline; committed text still flows through `DefWindowProcW` and `WM_CHAR`, and the preedit mirror clears at commit. The UIA critical section is initialized per Host lifetime and deleted after listeners disconnect. Input edges survive the message pump, including the initial resize set during initialization.

Published UIA labels and values are copied out of the per-frame arena; labels that do not fit in the shared heap are cleared. Change notification uses the tree length and focused command as a coarse signal. Secondary input slices alias their queue until the next poll, and clearing a closed slot permits immediate ID reuse. Unclaimed Ctrl+V becomes a text or image paste.

## src/platform/wasm.zig

The accessibility mirror sends parents-first, little-endian 64-byte records and a UTF-8 heap synchronously to the zunk DOM shim. Record offsets are: command index 0, role 4, label offset/length 8/12, integer x/y/w/h 16–31, numeric state 32, flags 36, value offset/length 40/44, selection start/end 48/52, parent index 56 (`0xffffffff` for root), and heading/tree level 60. Role codes are defined by `wireRole` and must match zunk. The single-threaded Host reuses fixed buffers of 512 records and 32 KiB of strings; overflow nodes or strings are dropped, with oversized strings leaving an unlabeled record. Actions return in 16-byte records containing kind, command index, string offset and string length; the run loop turns them into input.

Zunk supplies both held input state and per-frame edges, including both edges for a click contained in one frame; wheel units are CSS pixels and positive means down/right. Touch client coordinates match canvas CSS coordinates because the canvas fills the page. Meta acts as Ctrl for chords but remains Meta in reported modifiers. Text arrives as whole UTF-8 code points and is revalidated. Browser file dialogs are asynchronous and gesture-gated, so the synchronous Host variants cannot provide them. Effect result slices remain valid until the next `pollInputs`.

## src/input/hit_test.zig

Overlay hits take precedence over the base layer. A modal overlay containing the pointer consumes the click even when no interactive leaf or backdrop message claims it; nested modals respect the parent clip, and later overlays win in painter order. Hover must claim the modal backdrop too: the Host compares the press target with the release hover before dispatching the hit, so omitting the backdrop there prevents click-outside handling. Decorative canvas and scene leaves pass clicks through unless they expose a click message or pointer surface. Disabled controls are non-interactive. Command-tag switches are exhaustive so new variants require classification.

## src/run.zig

Input is routed using the previous frame's commands and rectangles, which describe what the user actually saw. Idle frames can redraw the cached frame solely for caret blinking without rerunning view or layout. A live secondary window reuses GPU scratch buffers, so the primary frame must rebuild while one is open; resource-table changes also force staging even if commands compare equal. Snapshot output is written on the first frame and content or window transitions, not on cosmetic blink ticks. Outstanding effects and a listening control channel keep input polling active at frame rate, because the Host cannot wake on the control socket itself.

Keyboard navigation keeps text focus in the Model and uses loop navigation focus for non-text controls. Enter invokes `submitMsg` when provided except in a focused text area, where it remains a newline key. Modal backdrops can consume clicks without producing messages. Pointer capture ends on the last release and is dropped if its canvas disappears. Effect reconciliation forgets no-longer-listed effects before issuing new ones. Long window titles compare against the stored truncated prefix so they do not trigger a title update every frame. A user-closed secondary window is suppressed from reopening until the application's window intent changes. See HARDLINE §1 and §2.

Keyboard focus can also produce hover notifications for tooltips. The menu key and Shift+F10 use the context-menu hook when present; focused text-area motion resolves against wrapped layout. Clipboard chords query `clipboardText` and dispatch `clipboardMsg`; the deprecated `handleClipboard` adapter can mutate the Model outside `update`. Captured canvases receive wheel events regardless of pointer location, and hover entry/exit is suspended during capture.

## src/platform/x11.zig

Xlib ABI declarations target 64-bit platforms: Display is opaque; Window, Atom, KeySym and Time are unsigned long; Bool is int. Display scale is resolved before window creation so logical dimensions can be converted to physical pixels. Window-close messages must match both the `WM_PROTOCOLS` type and `WM_DELETE_WINDOW` payload. Input methods may add event masks and get first refusal on each event; committed text is dropped rather than split when the queue overflows. Shortcut events are delivered alongside navigation, while Ctrl or Alt chords do not enter text. Without an input method, Unicode and Latin-1 keysyms map to code points and remaining input uses `XLookupString`. Wheel buttons 4–7 map to Host down/right-positive axes. Expose events force a redraw even while idle. Xcursor must be unloaded after closing the display. Clipboard INCR transfers arrive in property-change chunks; an unclaimed Ctrl+V is delivered asynchronously as text or an image.

## src/core/component.zig

A component provides default-initializable `Model`, tagged-union `Msg`, `update(*Model, Msg)` and `view(*const Model, cb, msgs)`. The view receives a Model pointer because slices emitted into commands may refer to Model storage and must outlive the call. Composed model fields require defaults; validation reports missing defaults at the component boundary. The generated buffer and message parameters are generic, so validation checks the concrete Model parameter and return type. See HARDLINE §2 hatch 1.

## src/core/component_list.zig

List messages carry stable item keys rather than array indices so focused children survive insertion, removal and reordering. A row with multiple text fields can expose separate focus variants; the app stores the item key and field in its Model and routes focused messages using the key. Message tags are selected at compile time.

## src/platform/wayland.zig

Wayland clipboard writes are non-blocking and unfinished bytes are handled by `pumpWrites`, so a slow reader cannot stall a frame. A reader that quits during transfer must not terminate the process. `TEAK_WL_NO_VIEWPORT=1` forces integer buffer scaling for compositor debugging. Unclaimed Ctrl+V begins an asynchronous paste; initial window setup waits for configure and scale announcements.

## src/input/a11y.zig

The tree builder collects overlay nodes first; a modal overlay suppresses base-layer nodes so assistive technology does not expose controls blocked from input. Containers that do not emit a node pass their nearest emitted ancestor through to descendants. Overlay bounds respect the parent clip, and the overlay establishes a clip for its children, matching hit-test behavior. Queued actions retain text storage until the action queue empties, so compaction does not invalidate offsets.

## src/render/canvas_tess.zig

Line clipping trims centre lines to the clip rectangle; a thick quad can extend up to half its thickness past a trimmed endpoint. Polygon ear clipping falls back to a fan if no further ear is found. Triangle-list clipping uses a bounds pass and then per-triangle clipping with two scratch polygons. NaN endpoints must be rejected before Liang–Barsky comparisons because NaNs would otherwise pass the comparisons and produce invalid vertices. With downward y, positive signed area is clockwise on screen and the outside is left of each edge.

## src/platform/cocoa.zig

The view is layer-backed by a CAMetalLayer sized and scaled by AppKit. If a presented frame was dropped while a window was occluded, becoming visible requests a rebuild through the resize input because idle frames otherwise do not redraw. The non-blocking event pump lets Core Animation commit. Unclaimed Cmd+V becomes a text or PNG paste, while other Cmd or Ctrl chords do not enter text. Marked IME text is kept as UTF-8 with a byte-indexed caret and is never truncated within a code point.

## src/control.zig

Commands are driven over frames: a click separates press and release because the runtime routes input against the previous frame's layout. Text is sent in 32-byte batches to stay within the 64-byte per-frame input queue. Selector offsets are relative to the node centre and allow interactions with specific regions of a widget.

## src/input/keys.zig

Shift-modified motion extends selection; Shift+Tab traverses focus backward. Plain Enter may submit, while Shift+Enter remains a newline key delivered to the app. Ctrl-modified motion and deletion operate by word or document boundary. F10 and a bare Alt tap request menu-bar activation; the Menu key and Shift+F10 request a context menu at the focused widget. The application decides whether to act on these requests.

## src/gpu/text_stage.zig

Colour glyphs use RGBA atlas pages and mode 2; their own colour is sampled instead of tinting coverage. Resolved atlas entries are reused across frames only while page generation and subpixel bin match. Fallback clusters use bin zero. The shaped-run cache uses open addressing and is cleared wholesale when its pools fill; without cross-frame caching a run is shaped into a pool reused by the next draw. SDF instance flags encode mode in bits 0–1 and quad scale in bits 16–31.

## src/core/text_field.zig

Each `TextField(N)` capacity has a distinct message type with the same shape. Key-dispatch helpers use compile-time field types and union construction to wrap local messages in an application's composed message.

## src/core/data_table.zig

Sorting is stable for equal rows in either direction. The header stays fixed outside the body scroll region. The table exposes one Tab stop on the cursor row's first cell, or the first displayed row when needed; application key routing then moves the table cursor.

## src/text/measure.zig

Cache entries compare text and every font field; the hash selects a slot but is not identity. The cache is cleared when the face table changes, and runs longer than `max_text` bypass it. Native builds use a larger two-way table; wasm uses a small table and an all-zero initial representation to avoid occupying the data section. Short ASCII runs bypass hashing and cache lookup.

## src/platform/host.zig

Optional Host surfaces are validated only when declared. A missing scale factor defaults to 1.0; effect submission and result polling are paired. The Host clock supplies subscriptions and other time-dependent services without reading time in `view`. Accessibility actions are polled before input routing. See HARDLINE §2 hatch 4 and §3.

## src/gpu/scene_pass.zig

The grid fades before its far plane. Gizmo rotation is recovered by normalizing the view-projection rows after removing projection scale; the perspective w row is the negative third view row.

## src/platform/native_effects.zig

Hosts with native clipboards intercept clipboard effects before the shared service. Windows UTC offsets combine the base bias with the active standard or daylight adjustment; current rules are used for the queried instant. Completed effects are delivered asynchronously by the Host.

## src/core/unicode.zig

Backward grapheme scanning can restart without prior context between adjacent ASCII bytes other than CR followed by LF. Kana and half-width kana count as letters even when their UAX #14 line-break class is NS or CJ.

## src/core/debug_overlay.zig

Overlay lines are formatted before commands are appended: callers can pass the command buffer's own slice, and appending first could reallocate it while it is being read.

## src/core/numeric_field.zig

`NumericField(config)` exposes the component Model, Msg, update and view plus value, validity, content and formatting accessors.

## src/platform/control_socket.zig

An overlong input line is discarded through its newline. Replies are single lines and the server sends no unsolicited messages, so a received chunk cannot contain another reply.

## src/platform/file_picker.zig

The dialog subprocess needs an allocating `Io` and inherits the environment, including display, session-bus and XDG variables needed by the desktop toolkit. Zenity and kdialog return status 1 for cancellation and 0 with the selected path on stdout.

## src/core/widgets/split.zig

Focused-divider arrow keys adjust by `key_step`; Home and End request the minimum and maximum first-pane sizes, clamped by update.

## src/core/widgets/tooltip.zig

The tooltip prefers the widget's lower-left side, flipping above or right-aligned near the lower or right edge of the window.

## build.zig

Consumer helpers resolve lazy wgpu and zunk dependencies on Teak's builder, where the dependencies are declared. Host text measurement and GPU rasterization share the same stb module so metrics agree. X11 loads libX11 through `std.DynLib` and therefore needs libc's dlopen path; the executable itself must link libc. Wasm uses a libc shim for stb. Native GPU libraries are installed beside the executable and found through the platform runtime search path. The Windows ARM64 native-target workaround adds i8mm because Zig's detection misses it. Web applications with registered faces omit the built-in default; embedded faces are used for shaping while page font preloads do not block startup.

## examples/counter_greeter/src/app.zig

The composed application keeps focus in its app-level Model; the Host translates keyboard input into the focused component's messages. The greeter's focus click routes through app-level state rather than its component update. The help overlay is modal with a backdrop message and uses a fixed 900×500 backdrop; a real window-sized backdrop should use Host dimensions. Clipboard chords are serviced by the Host's clipboard path rather than ordinary key dispatch. The stats window is app intent consumed by the Host.

## examples/todo/src/app.zig

Row messages carry the current Model index. Deletion shifts items to preserve order; drag insertion accounts for the source removal shifting later indices. The count is a polite accessibility live region. Its text is allocated in the frame arena because a stack slice would outlive its buffer before layout.

## examples/tree/src/app.zig

Tree nodes are stored in preorder; a collapsed ancestor hides following deeper nodes until its subtree ends. View iterates by pointer because commands borrow label slices from Model storage. Without content height from layout, scroll state clamps only at zero and may temporarily overscroll the bottom. A fixed-size empty scroll is used as a spacer.

## examples/kerf_viewer/src/app.zig

A URL request already in flight owns the request state, so only plain queries are chained. In the focused chat text area, Enter sends and Shift+Enter inserts a newline. Gizmo-cap clicks select a camera axis; other viewport clicks pick a part. Open shells use outline-only section rendering to avoid stencil-parity streaks. See `kerf/spec/DESIGN.md` §1 for the palette and header treatment.

## examples/chrome/src/app.zig

The popover intentionally overlaps the parts table so its opaque backdrop exercises occlusion of underlying text. Retro table rows use one pixel of padding because borders do not take layout space. The popover opens over 400 ms and closes faster.

## examples/vector_canvas/src/app.zig

Moment diagrams use the parabola of a uniformly loaded simple span. When a diagram changes sign, zero crossings split it into one filled polygon per lobe. Drawing order is braces, members, overlays, then node dots; view reuses slices owned by the Model.

## examples/scene_layers/src/app.zig

Sheet frame vectors use world units per sheet unit; a factor of 0.8 displays a 120×80 page at 96×64 inches. See `kerf/spec/DESIGN.md` for the palette.

## examples/tables/src/app.zig

The large Model arrays are heap allocated because the Runtime may otherwise exceed the Windows 1 MiB stack. One frame-time message advances whichever scroller is moving.

## examples/viewport/src/app.zig

Zoom keeps the world point under the cursor fixed. Grid labels are world-space scalable text, so one distance-field glyph set serves zoom levels from 0.2× to 8× without rerasterizing.

## examples/fonts/src/app.zig

Unsupported script glyphs fall back to browser canvas text on web and the missing-glyph box on native. Web colour emoji use RGBA atlas pages; native currently lacks a colour-font strike decoder.

## examples/counter_greeter/src/rich_zig_adapter.zig

The parsed text owns its plain buffer in the frame arena. It must not be deinitialized before the emitted slices are consumed; arena reset frees it in bulk.

## examples/kerf_viewer/src/draw/pick.zig

Picking considers text, fills, linework and interiors in that order. Linework chooses the nearest path with topmost ties; interiors choose the smallest enclosing region.
