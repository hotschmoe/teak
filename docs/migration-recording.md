# Input recording version 2

Record old sessions again. Files without the exact `teak-recording 2` version line fail
at Runtime initialization with `RecordingVersion` and the message
`recording was made by an older teak; record it again`. Unknown versions fail the same way.
There is no conversion: the missing Host facts cannot be recovered from an old recording.

Keep using `TEAK_RECORD=<path>` and `TEAK_REPLAY=<path>`, or `Options.record_path` and
`Options.replay_path`. Replay requires the Host file capability, and ends at the last complete
frame. Use the same app, initial Model, options and code; this is reproduction data, not a
cross-commit or cross-platform compatibility promise. Outside `Runtime.frame`, application
`post` messages, startup resources and custom loop I/O remain the loop owner's responsibility.

Every frame, including quiet frames, has one binary record after the ASCII version line.
Its header is a little-endian u32 frame index and u32 payload length. The payload is the
ordered transcript of consumed Host results. Call tags are explicit u8 values. Integers
and float bits are little-endian; enums use validated u32 tags; booleans use 0 or 1;
slices have u32 lengths; structs follow declaration order, tagged unions include their tag,
and optionals include presence. Padding, pointers and unused buffer capacity are never written.
Unknown calls, invalid tags, missing or extra data, skipped frames and reordered calls are
errors. `teak.input_record` now exposes `Frame`, `Call`, `validate_version`, `next_frame`,
`write_frame` and `check_input`; the old sparse text parser and tracker are removed.

Runtime supplies the complete delivered input snapshot, repeated logical/statistics clock
reads, scale, IME, accessibility actions, clipboard reads, effect submission outcomes and
effect answer bytes, text measurements, in-frame sink-write outcomes and secondary-window
outcomes/polls during replay.
Effects are not submitted to the outside world during replay. File-dialog answers delivered
as effects are replayed from their result bytes. The standalone dialog methods are not called
by Runtime. InputQueue's aggregation is preserved exactly, including held buttons and both
edge flags; it has no separate raw-event chronology for Runtime to consume.

Secondary windows need a local render surface. Recorded creation failures are reproduced
without opening a window. Recorded success requires successful local window/handle/surface
creation; otherwise replay returns `ReplayWindowUnavailable`. Native handles are never
serialized. Poll results and closure are supplied by the recording.

Limits are 1 MiB encoded payload per frame, 1 MiB decoded slice storage, 64 MiB per recording,
100,032 frames, 256 text bytes, 64 special keys and 16 chords per input snapshot. Traversal has
a 1,024-job stack and one million visits per value. Buffers are reserved at startup. At a limit
recording stops, increments `Runtime.ctl.session.limits` (included in simulation `limits`),
and warns once; it retains only complete preceding frames. It never shortens text or queues.

The file is written every 32 complete frame records, on control `quit`, and at shutdown. The
cadence is unchanged; every frame is now nonempty because it contains Host facts. The first
write replaces the file and each later write appends only the frames since the last one, so
the cost of a flush does not grow with the recording. This is not an fsync guarantee. A crash
can lose up to 31 unflushed frames or leave a partial last frame; replay then runs every
complete frame and ends with `BadRecording` at the partial one. The in-memory publication of
a frame is all-or-nothing. A write failure disables recording with one warning and counter.
Recorder persistence stays outside its own transcript. Other in-frame file-write failures
are replayed without writing; successful snapshot/statistics outputs may be written locally.
Local replay-output errors are logged without changing the recorded sink outcome.

Simulation `--record-check 1` replays through the ordinary Runtime path. SimHost's optional
`replay_value` only mirrors supplied input, time and scale for checker observations. The
blocking fixed seeds and all `sim-heavy` apps enable this check.
Simulation consumers also supply `Config.file_bytes`, sized to `sim.files.storage_bytes_max`;
the memory-file table borrows this startup reservation and reuses it between passes.
