# Migration: `handleClipboard` -> `clipboardMsg` / `clipboardText`

`handleClipboard(*Model, SpecialKey, Clipboard) void` changed the Model outside
`update` (HARDLINE §1) and did clipboard I/O inside app code. Replace the pair
`keyNeedsClipboard` + `handleClipboard` with two pure hooks:

```zig
// Before
pub const keyNeedsClipboard = teak.keyNeedsClipboard;
pub fn handleClipboard(m: *Model, key: teak.SpecialKey, clip: teak.Clipboard) void {
    switch (key) {
        .ctrl_c => clip.write(selection(m)),
        .ctrl_x => { clip.write(selection(m)); update(m, .delete_selection); },
        .ctrl_v => update(m, .{ .paste = clip.read() }),
        else => {},
    }
}

// After
pub fn clipboardText(m: *const Model, key: teak.SpecialKey) ?[]const u8 {
    if (key != .ctrl_c and key != .ctrl_x) return null;
    const sel = selection(m);
    return if (sel.len > 0) sel else null;       // the loop writes it to the clipboard
}
pub fn clipboardMsg(_: *const Model, key: teak.SpecialKey, paste: []const u8) ?Msg {
    return switch (key) {
        .ctrl_x => .delete_selection,             // runs AFTER the text above was copied
        .ctrl_v => .{ .paste = paste },           // empty pastes are not delivered
        else => null,
    };
}
```

For a `TextField` use `teak.textFieldCopyText(&model.field, key)` and
`teak.textFieldClipboardMsg(Msg, "field", key, paste)`. `teak.run` calls
`clipboardText` first (Ctrl+C / Ctrl+X), then `clipboardMsg` (all three keys).
If an app declares neither new hook, the old pair keeps working for one release.
