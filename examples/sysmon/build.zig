const std = @import("std");
const teak = @import("teak");

pub fn build(b: *std.Build) void {
    const target = blk: {
        var t = b.standardTargetOptions(.{});
        if (t.result.cpu.arch == .aarch64) {
            t.query.cpu_features_add.addFeature(@backingInt(std.Target.aarch64.Feature.i8mm));
            t.result.cpu.features.addFeature(@backingInt(std.Target.aarch64.Feature.i8mm));
        }
        break :blk t;
    };
    const optimize = b.standardOptimizeOption(.{});

    const teak_dep = b.dependency("teak", .{ .target = target, .optimize = optimize });
    const teak_mod = teak_dep.module("teak");

    const exe = b.addExecutable(.{
        .name = "sysmon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "teak", .module = teak_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the sysmon CLI canary (prints a real sample)");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run the example canary");
    test_step.dependOn(&run_cmd.step);

    if (!teak.hasNativeBackend(target.result.os.tag)) return;

    const ui_exe = b.addExecutable(.{
        .name = "sysmon-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    teak.linkNativeWgpu(b, ui_exe, .{});
    const install_ui = b.addInstallArtifact(ui_exe, .{});
    const ui_run = b.addRunArtifact(ui_exe);
    ui_run.step.dependOn(&install_ui.step);
    ui_run.addPassthruArgs();
    b.step("ui-install", "Build and install the native UI exe (no run)").dependOn(&install_ui.step);
    b.step("ui", "Run the system monitor (wgpu native: Win32 / X11 / Wayland)").dependOn(&ui_run.step);

    const shot_exe = b.addExecutable(.{
        .name = "sysmon-shot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shot_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    teak.linkHeadless(b, shot_exe, .{});
    // Windows needs the installed executable beside wgpu_native.dll.
    const install_shot = b.addInstallArtifact(shot_exe, .{});
    const shot_run = b.addRunArtifact(shot_exe);
    shot_run.step.dependOn(&install_shot.step);
    shot_run.addPassthruArgs();
    b.step("shot-install", "Build and install the screenshot exe (no run)").dependOn(&install_shot.step);
    b.step("shot", "Render a headless PNG screenshot: zig build shot -- out.png").dependOn(&shot_run.step);
}
