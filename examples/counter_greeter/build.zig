const std = @import("std");
const teak = @import("teak");

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

    const teak_dep = b.dependency("teak", .{ .target = target, .optimize = optimize });
    const teak_mod = teak_dep.module("teak");

    const rich_zig_dep = b.dependency("rich_zig", .{ .target = target, .optimize = optimize });
    const rich_zig_mod = rich_zig_dep.module("rich_zig");

    // --- CLI executable (run) ---

    const exe = b.addExecutable(.{
        .name = "counter_greeter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "teak", .module = teak_mod },
                .{ .name = "rich_zig", .module = rich_zig_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the CLI demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // --- Tests ---

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run example tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // --- wgpu UI executable ---
    //
    // One helper call wires teak + platform + gpu modules, links
    // wgpu-native, and installs wgpu_native.dll alongside the binary.

    const ui_exe = b.addExecutable(.{
        .name = "counter_greeter-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    teak.linkWin32Wgpu(b, ui_exe, .{});
    ui_exe.root_module.addImport("rich_zig", rich_zig_mod);

    const install_ui = b.addInstallArtifact(ui_exe, .{});

    const ui_run = b.addRunArtifact(ui_exe);
    ui_run.step.dependOn(&install_ui.step);
    if (b.args) |args| ui_run.addArgs(args);

    const ui_step = b.step("ui", "Run Teak UI demo (wgpu + Win32)");
    ui_step.dependOn(&ui_run.step);

    // --- web executable (wasm + zunk) ---
    //
    // `teak.linkWebWgpu` registers the `web` and `web-run` steps; zunk's
    // CLI generates dist/index.html + app.js + app.wasm.

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });
    // Default ReleaseFast — Debug wasm is too large to usefully ship.
    const web_optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "web-optimize",
        "Optimize mode for the wasm build (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const web_exe = b.addExecutable(.{
        .name = "counter_greeter-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = wasm_target,
            .optimize = web_optimize,
        }),
    });
    teak.linkWebWgpu(b, web_exe, .{});

    // rich_zig adapter for wasm: same rich_zig source compiled for
    // wasm. The adapter uses only the Text + markup parser path, so
    // pure-Zig std + WebAssembly is sufficient.
    const rich_zig_dep_wasm = b.dependency("rich_zig", .{ .target = wasm_target, .optimize = web_optimize });
    const rich_zig_mod_wasm = rich_zig_dep_wasm.module("rich_zig");
    web_exe.root_module.addImport("rich_zig", rich_zig_mod_wasm);
}
