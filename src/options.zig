const std = @import("std");
const Options = @import("run.zig").Options;

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

const environment_count_max: u32 = 65536;

pub fn from_environment(init: std.process.Init, defaults: Options) !Options {
    var options = defaults;
    const count = init.environ_map.count();
    if (count > environment_count_max) return error.EnvironmentTooLarge;
    const entries = try init.arena.allocator().alloc(Entry, count);
    var iterator = init.environ_map.iterator();
    var index: u32 = 0;
    for (entries) |*entry| {
        const pair = iterator.next() orelse @panic("environment count changed");
        assert(index < count);
        assert(index < entries.len);
        entry.* = .{ .name = pair.key_ptr.*, .value = pair.value_ptr.* };
        index += 1;
    }
    assert(index == count);
    assert(iterator.next() == null);
    options.environment = entries;
    inline for (.{
        .{ "TEAK_FONT", "font_path" },
        .{ "WINDIR", "windows_directory" },
        .{ "TEAK_FALLBACK_FONTS", "fallback_fonts" },
        .{ "TEAK_BACKEND", "backend" },
        .{ "WAYLAND_DISPLAY", "wayland_display" },
        .{ "TEAK_SCALE", "scale" },
        .{ "GDK_SCALE", "gdk_scale" },
        .{ "TEAK_PICKER", "picker" },
        .{ "TEAK_OPEN", "open_path" },
        .{ "TEAK_OUT", "output_directory" },
        .{ "XDG_CONFIG_HOME", "config_home" },
        .{ "HOME", "home" },
        .{ "APPDATA", "app_data" },
        .{ "TEAK_SNAPSHOT", "snapshot_path" },
        .{ "TEAK_CONTROL", "control_path" },
        .{ "TEAK_RECORD", "record_path" },
        .{ "TEAK_REPLAY", "replay_path" },
        .{ "TEAK_FRAME_STATS", "stats_path" },
    }) |setting| {
        if (init.environ_map.get(setting[0])) |value| {
            const preserves_empty = std.mem.eql(u8, setting[1], "backend") or
                std.mem.eql(u8, setting[1], "windows_directory");
            if (value.len > 0 or preserves_empty) @field(options, setting[1]) = value;
        }
    }
    inline for (.{
        .{ "TEAK_INSPECT", "inspect" }, .{ "TEAK_CONTINUOUS", "continuous" },
        .{ "TEAK_HUD", "hud" },
    }) |setting| {
        if (init.environ_map.get(setting[0])) |value| {
            if (value.len > 0) @field(options, setting[1]) = !std.mem.eql(u8, value, "0");
        }
    }
    if (init.environ_map.get("TEAK_COCOA_DEBUG") != null) options.cocoa_debug = true;
    if (init.environ_map.get("TEAK_WL_NO_VIEWPORT") != null) options.wayland_no_viewport = true;
    if (init.environ_map.get("TEAK_GPU_FALLBACK")) |value| {
        options.gpu_fallback = value.len > 0 and value[0] != '0';
    }
    if (init.environ_map.get("TEAK_EXIT_AFTER_FRAMES")) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        const parsed = std.fmt.parseInt(u64, trimmed, 10);
        options.exit_after_frames = parsed catch options.exit_after_frames;
    }
    return options;
}

fn assert(condition: bool) void {
    if (!condition) @panic("options invariant");
}
