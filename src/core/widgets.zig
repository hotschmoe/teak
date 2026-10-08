//! Widgets built purely from existing Cmd primitives (zero new Cmd
//! variants). Each is data + pure functions in the Dropdown / Combobox
//! mould: a `Model` and `Msg` the app embeds (HARDLINE §1: all state in the
//! Model), `update`, and view helpers that emit ordinary cmds. See
//! docs/features/widgets.md for the contract of each.

pub const toggle = @import("widgets/toggle.zig");
pub const progress = @import("widgets/progress.zig");
pub const tabs = @import("widgets/tabs.zig");
pub const split = @import("widgets/split.zig");
pub const tooltip = @import("widgets/tooltip.zig");
pub const menu = @import("widgets/menu.zig");
pub const toast = @import("widgets/toast.zig");
pub const dialog = @import("widgets/dialog.zig");
pub const spinner = @import("widgets/spinner.zig");
pub const color_picker = @import("widgets/color_picker.zig");
pub const util = @import("widgets/util.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
