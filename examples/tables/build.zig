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

    // --- CLI ---

    const exe = b.addExecutable(.{
        .name = "tables",
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

    const run_step = b.step("run", "Run the tables CLI canary");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // --- Tests ---

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tables tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // --- Native UI (wgpu native: Win32 / X11) ---
    //
    // Gated on `hasNativeBackend` so non-native targets still configure
    // `run`/`test`/`web`; `linkNativeWgpu` picks the backend per OS.

    if (teak.hasNativeBackend(target.result.os.tag)) {
        const ui_exe = b.addExecutable(.{
            .name = "tables-ui",
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

        const ui_step = b.step("ui", "Run Teak tables UI (wgpu native: Win32 / X11)");
        ui_step.dependOn(&ui_run.step);
    }

    // --- Headless screenshot + frame-time bench (no display; needs a Vulkan device) ---
    //
    //   zig build shot -- out.png [--tab table|list|tree] [--bench]

    if (target.result.os.tag == .linux) {
        const shot_exe = b.addExecutable(.{
            .name = "tables-shot",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/shot_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        teak.linkHeadless(b, shot_exe, .{});
        const shot_run = b.addRunArtifact(shot_exe);
        shot_run.addPassthruArgs();
        const shot_step = b.step("shot", "Render a headless PNG screenshot: zig build shot -- out.png");
        shot_step.dependOn(&shot_run.step);
    }

    // --- Web (wasm + zunk) ---

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const web_optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "web-optimize",
        "Optimize mode for the wasm build (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const web_exe = b.addExecutable(.{
        .name = "tables-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = wasm_target,
            .optimize = web_optimize,
        }),
    });
    teak.linkWebWgpu(b, web_exe, .{});
}
