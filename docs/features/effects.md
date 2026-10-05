# Declarative effects (`teak.Effect` / `effects` / `effectMsg`)

**Status**: `pub` in `src/teak.zig` as `Effect`, `EffectResult`, `HttpRequest`, `HttpResult`, `HttpMethod`, `Header`, `Drop`, `DropKind`, `EffectSubmit` (the rest of the data types under `teak.effects`).
**Source**: `src/core/effects.zig` (contract types + issued-id table), `src/run.zig` (servicing), `src/platform/host.zig` (the optional Host pair).
**Tests**: `src/core/effects.zig` (table + helpers), `src/run_effects_test.zig` (whole loop against the scripted Host), `src/platform/wasm.zig` / `src/platform/native_effects.zig` (host-side pure parts).

HARDLINE §2 escape hatch 7 — the sibling of [subscriptions](subscriptions.md).

## Why

`update` is a pure `(*Model, Msg) void` switch; `view` cannot do I/O. Yet an
app has to call an HTTP API, save a file, remember a setting, read the
clock. Teak does not give `update` a way to *do* these. The app **declares**
what it currently wants; the runtime does it and the answer comes back as a
`Msg`. Like `Sub`, an `Effect` is plain data: no callbacks, no promises, no
platform types.

## The hooks

```zig
pub fn effects(m: *const Model) []const teak.Effect;               // pure, like `subscribe`
pub fn effectMsg(m: *const Model, r: teak.EffectResult) ?Msg;     // required with `effects`
```

`effects` returns a slice borrowing from `Model` (or the frame arena), so
keep the request in `Model`:

```zig
const Model = struct {
    next_id: u32 = 1,
    in_flight: bool = false,
    req: [1]teak.Effect = undefined, // what effects() returns while in_flight
    reply: [256]u8 = undefined,
    reply_len: usize = 0,
};
pub fn effects(m: *const Model) []const teak.Effect {
    return if (m.in_flight) &m.req else &.{};
}
```

`update` builds the effect (`m.req[0] = .{ .http = .{ .id = m.next_id, ... } }`),
bumps `next_id`, sets `in_flight`; the answer arrives in `effectMsg`, whose
`update` copies what it needs and clears `in_flight`. The effect is gone
from the list on the next frame, so its id is forgotten.

An app that only wants unsolicited input (images dropped on the window,
pasted text) declares `effectMsg` alone.

## Effects

| Effect | Fields | Answer |
|---|---|---|
| `http` | `id, method, url, headers: []Header, body, timeout_ms` | `.http{ id, status, body, err }` — `status == 0` is a transport failure (network, CORS, timeout, TLS) and `err` says which |
| `download` | `id, name, mime, bytes` | `.downloaded{ id, ok }` — browser download / file under `$TEAK_OUT` or the cwd |
| `open_file` | `id, accept` | `.file_opened{ id, name, mime, bytes }` or `.file_cancelled{ id }` |
| `write_clipboard` | `id, text` | none (fire and forget) |
| `storage_set` | `id, key, value` | none; an empty `value` deletes the key |
| `storage_get` | `id, key` | `.storage_value{ id, value: ?[]const u8 }`; `null` = absent |
| `clock` | `id` | `.clock{ id, unix_ms, utc_offset_min }` |
| `query_param` | `id, name` | `.query_value{ id, value: ?[]const u8 }` — web: `?name=value`; native: `--name=value` argv, else env `TEAK_<NAME_UPPER>` |

Unsolicited results (no id, never filtered):

| Result | Meaning |
|---|---|
| `.dropped: Drop` | a file or image dropped on / pasted into the window. `Drop{ kind (file/image/text), name, mime, bytes, width, height, thumb_rgba, thumb_w, thumb_h }`. Web images are already decoded, limited to a 1568 px long side and re-encoded (PNG, or JPEG when the source was a JPEG that needed no downscale); `thumb_rgba` is a tightly packed RGBA8 preview with a 64 px long side, ready for `uploadImage`. |
| `.pasted_text: { text }` | text pasted with Ctrl/Cmd+V that no `handleClipboard` claimed |

`Effect.id()`, `Effect.wantsResult()`, `teak.effects.resultId`,
`teak.effects.unsupportedResult` are small pure helpers.

## What `teak.run` does

Per frame: input is routed; then **results** are fetched from the Host
(`pollEffectResults`) and dispatched through `effectMsg` -> `update`;
subscriptions fire; then **`effects()`** is serviced:

1. Every listed id is marked; ids no longer listed are **forgotten** (their
   table slot frees immediately).
2. Every listed id the table does not know is **issued** once: `Host.submit(effect)`.
   `accepted` records the id; `busy` retries next frame; `unsupported`
   records the id and answers with the effect's failed result (HTTP status 0,
   `file_cancelled`, absent key, ...) so the app never waits forever.
3. An id stays remembered while it stays listed — a still-listed effect is
   never re-issued, however many frames pass.

Rules that follow:

- **Ids are yours and must be unique per request** (a `Model` counter). Reusing
  an id while an older request of that id is still in flight mixes the answers.
- **Delisting cancels interest.** A result whose id is not currently listed
  is dropped. (The Host may still finish the work; the runtime ignores it.)
- **Table size**: 32 ids at once. More distinct ids than that wait for a free
  slot; the oldest keep running.
- **Results** are dispatched in the order the Host returned them; they land
  in the frame they arrive in, before that frame's view. `last_msg` in the
  snapshot names the Msg.
- **Slice lifetimes**: effect slices are valid for the duration of `submit`
  (the Host copies); result slices are valid until the `update` they trigger
  returns (the app copies).

## Host surface

An **optional pair** in `validateHost` (declare both or neither):

```zig
pub fn submit(self: *Host, e: teak.Effect) teak.EffectSubmit;          // accepted | busy | unsupported
pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize; // fills buf, returns the count
```

- `submit` starts the work and returns at once. Fire-and-forget effects are
  performed inside `submit`.
- `pollEffectResults` is called once per frame (after key routing) with a
  buffer of 16; leftover results stay queued for the next frame. Result slices
  stay valid until the Host's next `pollInputs`.
- A Host without the pair answers every effect as `unsupported`.

### Web (`src/platform/wasm.zig` over `zunk.web.fx`)

| Effect | Implementation |
|---|---|
| `http` | `fetch` with `AbortController` timeout; request body up to ~8 MB, response copied into wasm memory; failures give `status = 0` and `err` ("network error / CORS: ...", "timeout after N ms", "response too large") |
| `download` | `Blob` + temporary `<a download>` click |
| `open_file` | hidden `<input type=file accept=...>`. Browsers want a user activation: if one is live the picker opens at once, otherwise it is **armed and opens on the next pointer press or key press**; cancel resolves `file_cancelled` |
| `storage_*` | `localStorage` |
| `clock` | `Date.now()` + `-getTimezoneOffset()` |
| `write_clipboard` | `navigator.clipboard.writeText`, with an `execCommand('copy')` fallback. Ctrl/Cmd+C and Ctrl/Cmd+X also write through it (`Clipboard.write`) |
| `query_param` | `URLSearchParams` of `location.search` |
| paste / drop | `paste` and `drop` events on the page; images decoded with `createImageBitmap`, downscaled, re-encoded, thumbnailed (see `Drop`). Dropped `.json` / `.txt` and other files arrive as `Drop{kind = .file}`; pasted text as `.pasted_text`. Ctrl/Cmd+V is no longer swallowed by the page, and `Clipboard.read` returns the text of the paste that accompanied the key press, so a `keyNeedsClipboard` / `handleClipboard` text field pastes through the existing path; only unclaimed pastes surface as `.pasted_text` |

The lifecycle and the JS/wasm buffer protocol are written down once, in
zunk's `docs/ARCHITECTURE.md` ("Host services: `web.fx`").

### Native (Linux/X11; Win32 compiles but answers `unsupported`)

HTTP runs on a worker thread through `std.http.Client` (TLS), so a frame
never blocks; storage is files under `$XDG_CONFIG_HOME/teak/<app>/`
(default `~/.config`); downloads are written to `$TEAK_OUT` or the cwd;
`open_file` has no dialog: it answers `file_cancelled` unless the env var
`TEAK_OPEN=path` is set (the file is read once — lets agents and tests drive
it); `clock` and `query_param` read the OS clock and argv/env; `write_clipboard`
logs once and is ignored.

## HARDLINE bounds (§2 hatch 7)

See [HARDLINE.md](../HARDLINE.md): `effects` is pure and only declares; the
types are data (no callbacks); in-flight bookkeeping is a fixed table in the
runtime, request payloads live in `Model`; every answer is a `Msg` through
`update`; platform machinery sits behind the optional Host pair.

## Non-goals / known limits

- No streaming responses, no response headers, no request cancellation
  beyond delisting.
- No multi-file open, no save dialog (`download` is the save path).
- 32 distinct ids in flight at once.
- A Host that rejects an effect kind (`unsupported`) is not retried.

## Test coverage

`src/run_effects_test.zig` drives the whole loop with the scripted Host:
HTTP round trip, issued once while listed, forgotten and re-issuable after
delisting, cancellation drops late results, list/result ordering,
fire-and-forget, `busy` retry, `unsupported` failed results, table
overflow, unsolicited drops and pastes (an `effectMsg`-only app).
