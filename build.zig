const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = blk: {
        var t = b.standardTargetOptions(.{});
        // Zig's native CPU detection on Windows ARM64 misses i8mm (FEAT_I8MM).
        // The Snapdragon X Elite (Oryon) supports it -- enable for native aarch64 builds.
        if (t.result.cpu.arch == .aarch64) {
            t.query.cpu_features_add.addFeature(@intFromEnum(std.Target.aarch64.Feature.i8mm));
            t.result.cpu.features.addFeature(@intFromEnum(std.Target.aarch64.Feature.i8mm));
        }
        break :blk t;
    };
    const optimize = b.standardOptimizeOption(.{});

    // --- Library module (importable as "teak") ---

    const mod = b.addModule("teak", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // --- CLI executable ---

    const exe = b.addExecutable(.{
        .name = "teak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "teak", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // --- Tests ---

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // --- wgpu UI executable ---

    // Pick the wgpu-native prebuilt for the resolved target architecture.
    // Keeps `zig build ui` working on both aarch64-windows (native on
    // Snapdragon) and x86_64-windows (native or Prism-emulated host).
    const wgpu_dep_name: []const u8 = if (target.result.os.tag != .windows)
        @panic("wgpu-native: only Windows targets are wired up; add the release to build.zig.zon")
    else switch (target.result.cpu.arch) {
        .aarch64 => "wgpu-native-aarch64",
        .x86_64 => "wgpu-native-x86_64",
        else => @panic("wgpu-native: unsupported Windows arch (need aarch64 or x86_64)"),
    };
    const wgpu_dep = b.dependency(wgpu_dep_name, .{});

    const ui_mod = b.createModule(.{
        .root_source_file = b.path("src/ui_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = mod },
        },
    });
    ui_mod.addIncludePath(wgpu_dep.path("include/webgpu"));
    ui_mod.addLibraryPath(wgpu_dep.path("lib"));
    ui_mod.linkSystemLibrary("wgpu_native.dll", .{});

    const ui_exe = b.addExecutable(.{ .name = "teak-ui", .root_module = ui_mod });

    const install_ui = b.addInstallArtifact(ui_exe, .{});
    const install_dll = b.addInstallBinFile(wgpu_dep.path("lib/wgpu_native.dll"), "wgpu_native.dll");

    const ui_run = b.addRunArtifact(ui_exe);
    ui_run.step.dependOn(&install_ui.step);
    ui_run.step.dependOn(&install_dll.step);
    if (b.args) |args| ui_run.addArgs(args);

    const ui_step = b.step("ui", "Run Teak UI (wgpu + Win32)");
    ui_step.dependOn(&ui_run.step);
}
