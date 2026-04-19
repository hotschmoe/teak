const std = @import("std");
const teak = @import("teak");

pub fn build(b: *std.Build) void {
    const target = blk: {
        var t = b.standardTargetOptions(.{});
        if (t.result.cpu.arch == .aarch64) {
            t.query.cpu_features_add.addFeature(@intFromEnum(std.Target.aarch64.Feature.i8mm));
            t.result.cpu.features.addFeature(@intFromEnum(std.Target.aarch64.Feature.i8mm));
        }
        break :blk t;
    };
    const optimize = b.standardOptimizeOption(.{});

    const teak_dep = b.dependency("teak", .{ .target = target, .optimize = optimize });
    const teak_mod = teak_dep.module("teak");

    const exe = b.addExecutable(.{
        .name = "tree",
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

    const run_step = b.step("run", "Run the tree CLI canary");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tree tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const ui_exe = b.addExecutable(.{
        .name = "tree-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    teak.linkWin32Wgpu(b, ui_exe, .{});

    const install_ui = b.addInstallArtifact(ui_exe, .{});
    const ui_run = b.addRunArtifact(ui_exe);
    ui_run.step.dependOn(&install_ui.step);
    if (b.args) |args| ui_run.addArgs(args);

    const ui_step = b.step("ui", "Run Teak tree UI (wgpu + Win32)");
    ui_step.dependOn(&ui_run.step);

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
        .name = "tree-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = wasm_target,
            .optimize = web_optimize,
        }),
    });
    teak.linkWebWgpu(b, web_exe, .{});
}
