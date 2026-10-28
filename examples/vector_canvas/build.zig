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
        .name = "vector_canvas",
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

    const run_step = b.step("run", "Run the vector_canvas CLI canary (prints the snapshot)");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run vector_canvas tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Native UI gated on `hasNativeBackend` so non-native targets still
    // configure `run`/`test`/`web`; `linkNativeWgpu` picks Win32 / X11.
    if (teak.hasNativeBackend(target.result.os.tag)) {
        const ui_exe = b.addExecutable(.{
            .name = "vector_canvas-ui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ui_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        teak.linkNativeWgpu(b, ui_exe, .{});

        const install_ui = b.addInstallArtifact(ui_exe, .{});
        b.getInstallStep().dependOn(&install_ui.step);
        const ui_run = b.addRunArtifact(ui_exe);
        ui_run.step.dependOn(&install_ui.step);
        ui_run.addPassthruArgs();

        const ui_step = b.step("ui", "Run Teak vector_canvas UI (wgpu native: Win32 / X11)");
        ui_step.dependOn(&ui_run.step);
    }

    // --- Headless screenshot (no display; needs a Vulkan device) ---
    //
    //   zig build shot -- out.png [--state <name>]   (-- --list prints the states)

    if (teak.hasNativeBackend(target.result.os.tag)) {
        const shot_exe = b.addExecutable(.{
            .name = "vector_canvas-shot",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/shot_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        teak.linkHeadless(b, shot_exe, .{});
        // Installed beside the wgpu-native runtime library (zig-out/bin).
        const install_shot = b.addInstallArtifact(shot_exe, .{});
        b.getInstallStep().dependOn(&install_shot.step);
        const shot_run = b.addRunArtifact(shot_exe);
        shot_run.step.dependOn(&install_shot.step);
        shot_run.addPassthruArgs();
        const shot_step = b.step("shot", "Render a headless PNG screenshot: zig build shot -- out.png [--state name]");
        shot_step.dependOn(&shot_run.step);
    }
}
