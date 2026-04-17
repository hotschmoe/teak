const std = @import("std");

const BuildZig = @This();

pub fn build(b: *std.Build) void {
    const target = resolvedTarget(b);
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("teak", .{
        .root_source_file = b.path("src/teak.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // Integration tests: full-pipeline round trip + wasm-canary.
    const integ_mod = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "teak", .module = mod }},
    });
    const integ_tests = b.addTest(.{ .root_module = integ_mod });
    test_step.dependOn(&b.addRunArtifact(integ_tests).step);

    // wasm32-freestanding compile canary. Run `zig build test-wasm` to
    // assert the framework core stays posix-dep-free. The artifact isn't
    // executed — successful compile is the signal.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_mod = b.addModule("teak-wasm-canary", .{
        .root_source_file = b.path("src/teak.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_integ_mod = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "teak", .module = wasm_mod }},
    });
    const wasm_canary = b.addExecutable(.{
        .name = "teak-wasm-canary",
        .root_module = wasm_integ_mod,
    });
    wasm_canary.entry = .disabled;
    wasm_canary.rdynamic = true;

    const wasm_step = b.step("test-wasm", "Compile framework core for wasm32-freestanding (posix-dep canary)");
    wasm_step.dependOn(&wasm_canary.step);
}

fn resolvedTarget(b: *std.Build) std.Build.ResolvedTarget {
    var t = b.standardTargetOptions(.{});
    // Zig's native CPU detection on Windows ARM64 misses i8mm (FEAT_I8MM).
    // The Snapdragon X Elite (Oryon) supports it -- enable for native aarch64 builds.
    if (t.result.cpu.arch == .aarch64) {
        t.query.cpu_features_add.addFeature(@intFromEnum(std.Target.aarch64.Feature.i8mm));
        t.result.cpu.features.addFeature(@intFromEnum(std.Target.aarch64.Feature.i8mm));
    }
    return t;
}

// ════════════════════════════════════════════════════════════════════
// Convenience helpers for consumer build.zig files.
// ════════════════════════════════════════════════════════════════════
//
// Consumer pattern:
//
//     const teak = @import("teak");
//     ...
//     teak.linkWin32Wgpu(b, exe, .{});
//
// One call wires: `teak` module, platform+gpu modules, wgpu-native
// link, and the DLL install. Internals stay decoupled — power users
// who want to skip the convenience path can still import the source
// files directly and assemble modules by hand.

pub const Win32WgpuOptions = struct {};

/// Wire the Win32 + wgpu-native backend onto `exe`. Adds `teak`,
/// `teak-platform-win32`, and `teak-gpu-native` imports; links the
/// wgpu-native prebuilt for the resolved target arch; installs
/// `wgpu_native.dll` alongside the binary.
pub fn linkWin32Wgpu(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    _: Win32WgpuOptions,
) void {
    const root = exe.root_module;
    const target = root.resolved_target.?;
    const optimize = root.optimize.?;

    const teak_dep = b.dependencyFromBuildZig(BuildZig, .{
        .target = target,
        .optimize = optimize,
    });
    const teak_mod = teak_dep.module("teak");

    if (target.result.os.tag != .windows) {
        @panic("teak.linkWin32Wgpu: target must be Windows");
    }
    const wgpu_dep_name: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "wgpu-native-aarch64",
        .x86_64 => "wgpu-native-x86_64",
        else => @panic("teak.linkWin32Wgpu: unsupported Windows arch (aarch64 or x86_64 only)"),
    };
    // Look up the lazy dep on teak's builder (where it's declared), not
    // the consumer's. Otherwise Zig panics that the consumer never
    // declared wgpu-native in its own zon.
    const wgpu_dep = teak_dep.builder.lazyDependency(wgpu_dep_name, .{}) orelse return;

    const shaders_mod = b.createModule(.{
        .root_source_file = teak_dep.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/win32.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
        },
    });

    const gpu_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/gpu/native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-shaders", .module = shaders_mod },
        },
    });
    gpu_mod.addIncludePath(wgpu_dep.path("include/webgpu"));
    gpu_mod.addLibraryPath(wgpu_dep.path("lib"));
    gpu_mod.linkSystemLibrary("wgpu_native.dll", .{});

    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-win32", platform_mod);
    root.addImport("teak-gpu-native", gpu_mod);

    // The exe needs wgpu_native.dll next to it at runtime. Tying the
    // DLL install to exe.step ensures any build that compiles exe also
    // places the DLL in zig-out/bin.
    const install_dll = b.addInstallBinFile(wgpu_dep.path("lib/wgpu_native.dll"), "wgpu_native.dll");
    exe.step.dependOn(&install_dll.step);
}

pub const WebWgpuOptions = struct {};

/// Wire the WASM + WebGPU backend onto `exe`. Adds `teak`,
/// `teak-platform-wasm`, and `teak-gpu-web` imports. No native
/// dependencies — the web backend targets `wasm32-freestanding` plus a
/// JS shim (not fetched here; consumers wire the shim into their page).
pub fn linkWebWgpu(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    _: WebWgpuOptions,
) void {
    const root = exe.root_module;
    const target = root.resolved_target.?;
    const optimize = root.optimize.?;

    const teak_dep = b.dependencyFromBuildZig(BuildZig, .{
        .target = target,
        .optimize = optimize,
    });
    const teak_mod = teak_dep.module("teak");

    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/wasm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
        },
    });

    const gpu_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/gpu/web.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
        },
    });

    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-wasm", platform_mod);
    root.addImport("teak-gpu-web", gpu_mod);
}
