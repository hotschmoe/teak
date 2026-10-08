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

    // Pure GPU-side helpers (slot table, scene uniform packing / target
    // sizing / change signature). Not reachable from src/teak.zig for the
    // same reason as the other gpu helpers; each is a root file with its own tests.
    for ([_][]const u8{ "src/gpu/slot_table.zig", "src/gpu/scene_common.zig", "src/gpu/overlay.zig", "src/gpu/glyph_atlas.zig", "src/gpu/text_stage.zig" }) |path| {
        const m = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "teak", .module = mod }},
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

    // stb_truetype text backend (src/text/text.zig) — the Linux
    // rasterizer + measurer. It is gpu-adjacent and not
    // reachable from src/teak.zig, so it gets its own test module. Links
    // the vendored stb impl TU + libc; its tests rasterize/measure a real
    // system font and skip cleanly when none is installed (headless CI).
    const stbtt_mod = b.createModule(.{
        .root_source_file = b.path("src/text/text.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "teak", .module = mod }},
    });
    stbtt_mod.addImport("stb-c", translateC(b, b.path("src/gpu/vendor/stb_truetype.h"), null, target, optimize));
    stbtt_mod.addIncludePath(b.path("src/gpu/vendor"));
    stbtt_mod.addCSourceFile(.{
        .file = b.path("src/gpu/vendor/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });
    // Platform-wasm serialization tests. wasm.zig is the host backend
    // for the web target, but `serializeA11yTree` is a pure helper —
    // testable on the build host as long as zunk's `extern "env"`
    // declarations don't get linked. Tests reference only the helper,
    // so the externs stay un-instantiated and `zig build test` covers
    // the wire-format contract without needing a wasm runtime.
    const zunk_host_dep = b.dependency("zunk", .{
        .target = target,
        .optimize = optimize,
    });
    // The web font helper is tested with a registered mono family so the
    // `"<family>", monospace` form is exercised.
    const test_fonts = [_]WebFont{.{ .family = "Test Mono", .weight = 400, .path = b.path("build.zig") }};
    const web_font_mod = webFontModule(b, mod, webFontsModule(b, &test_fonts), b.path("src/gpu/web_font.zig"), target, optimize);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = web_font_mod })).step);
    const platform_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/wasm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = mod },
            .{ .name = "zunk", .module = zunk_host_dep.module("zunk") },
            .{ .name = "teak-web-font", .module = web_font_mod },
            .{ .name = "teak-text", .module = stbtt_mod },
            .{ .name = "teak-web-fontdata", .module = webFontDataModule(b, &.{}, b.path("src/text/fonts/IBMPlexMonoDefault.ttf"), target, optimize) },
        },
    });
    const platform_wasm_tests = b.addTest(.{ .root_module = platform_wasm_mod });
    test_step.dependOn(&b.addRunArtifact(platform_wasm_tests).step);

    // Win32 platform smoke tests (src/platform/win32.zig). Only
    // wired when the host target is Windows because the file imports
    // user32/oleaut32/kernel32/uiautomationcore. Covers the UIA
    // per-node fragment provider wiring among other host helpers.
    if (target.result.os.tag == .windows) {
        const platform_win32_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/win32.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "teak", .module = mod },
                .{ .name = "teak-text", .module = stbtt_mod },
            },
        });
        const platform_win32_tests = b.addTest(.{ .root_module = platform_win32_mod });
        test_step.dependOn(&b.addRunArtifact(platform_win32_tests).step);
    }
    const stbtt_tests = b.addTest(.{ .root_module = stbtt_mod });
    test_step.dependOn(&b.addRunArtifact(stbtt_tests).step);

    // Face-table tests against the real IBM Plex Mono files shipped with
    // examples/fonts (no system font needed).
    const stbtt_face_mod = b.createModule(.{
        .root_source_file = b.path("src/text/face_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = mod },
            .{ .name = "teak-text", .module = stbtt_mod },
        },
    });
    for ([_][]const u8{ "regular", "medium", "bold" }) |weight| {
        const file = b.fmt("IBMPlexMono-{c}{s}.ttf", .{ std.ascii.toUpper(weight[0]), weight[1..] });
        stbtt_face_mod.addAnonymousImport(b.fmt("plex-{s}", .{weight}), .{
            .root_source_file = b.path(b.fmt("examples/fonts/assets/{s}", .{file})),
        });
    }
    for ([_][]const u8{ "IBMPlexMonoSub-Regular", "QuicksandSub-Regular", "QuicksandSub-NoLig", "IBMPlexMonoMarks" }) |name| {
        stbtt_face_mod.addAnonymousImport(b.fmt("test-font-{s}", .{name}), .{
            .root_source_file = b.path(b.fmt("tests/fonts/{s}.ttf", .{name})),
        });
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = stbtt_face_mod })).step);

    // Headless host (src/platform/headless.zig): scripted input, fake
    // clock, effect capture. Needs the stb text module for its font.
    const headless_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/headless.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = mod },
            .{ .name = "teak-text", .module = stbtt_mod },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = headless_mod })).step);

    // X11 host (src/platform/x11.zig) — its keysym→SpecialKey mapping is
    // the one piece of host logic worth unit-testing headlessly (no
    // libX11 / display needed; the test calls only pure mapping fns).
    // Imports the stb text module under `teak-text`, same as the build's
    // linkLinux wiring. Built unconditionally on the host target; harmless
    // on non-Linux since it never opens a display in tests.
    const x11_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/x11.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = mod },
            .{ .name = "teak-text", .module = stbtt_mod },
        },
    });
    const x11_tests = b.addTest(.{ .root_module = x11_mod });
    test_step.dependOn(&b.addRunArtifact(x11_tests).step);

    // Display-backed X11 host tests (src/platform/x11_test.zig): clipboard
    // via xclip, XDND via a second in-process source, key/IME fallback via
    // xdotool. Opt-in (`zig build test-x11`, run under Xvfb or any X
    // session); each test skips when DISPLAY is unset or a tool is missing.
    if (target.result.os.tag == .linux) {
        const x11_live_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/x11_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "teak", .module = mod },
                .{ .name = "teak-text", .module = stbtt_mod },
            },
        });
        const test_x11_step = b.step("test-x11", "Run X11 host tests against a live display (skip without DISPLAY)");
        const run_x11 = b.addRunArtifact(b.addTest(.{ .root_module = x11_live_mod }));
        run_x11.has_side_effects = true; // depends on $DISPLAY: never cache
        test_x11_step.dependOn(&run_x11.step);
    }

    // Headless native GPU tests (wgpu-native scene renderer: render offscreen,
    // read pixels back). Needs the wgpu-native prebuilt (fetched lazily) and a
    // Vulkan driver; the tests skip when no adapter opens. Linux only (the
    // Windows stitch has no headless path).
    if (target.result.os.tag == .linux) {
        const wgpu_dep_name: ?[]const u8 = switch (target.result.cpu.arch) {
            .aarch64 => "wgpu-native-linux-aarch64",
            .x86_64 => "wgpu-native-linux-x86_64",
            else => null,
        };
        const gpu_step = b.step("test-gpu", "Headless native GPU tests (needs wgpu-native + Vulkan)");
        if (wgpu_dep_name) |name| if (b.lazyDependency(name, .{})) |wgpu_dep| {
            const shaders_mod = b.createModule(.{
                .root_source_file = b.path("shaders/shaders.zig"),
                .target = target,
                .optimize = optimize,
            });
            for ([_][]const u8{ "src/gpu/wgpu_scene_test.zig", "src/gpu/wgpu_core_test.zig" }) |path| {
                const gpu_test_mod = b.createModule(.{
                    .root_source_file = b.path(path),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "teak", .module = mod },
                        .{ .name = "teak-shaders", .module = shaders_mod },
                    },
                });
                gpu_test_mod.addImport("wgpu-c", translateC(b, b.path("src/gpu/vendor/wgpu_c.h"), wgpu_dep.path("include/webgpu"), target, optimize));
                gpu_test_mod.addLibraryPath(wgpu_dep.path("lib"));
                gpu_test_mod.addRPath(wgpu_dep.path("lib"));
                gpu_test_mod.linkSystemLibrary("wgpu_native", .{});
                gpu_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = gpu_test_mod })).step);
            }
        };
    }

    // Native effects service (HTTP worker threads, storage files, ...): runs
    // against a local libc-socket server. Linux only, like its host.
    if (target.result.os.tag == .linux) {
        const native_fx_mod = b.createModule(.{
            .root_source_file = b.path("src/platform/native_effects.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "teak", .module = mod }},
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = native_fx_mod })).step);
    }

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

    // HARDLINE drift audit — greppable half of docs/HARDLINE.md §5.
    // Depends on the wasm canary so one command gates both.
    const audit_exe = b.addExecutable(.{
        .name = "teak-audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audit.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const audit_run = b.addRunArtifact(audit_exe);
    audit_run.setCwd(b.path("."));
    audit_run.has_side_effects = true;
    audit_run.stdio = .inherit;

    const audit_step = b.step("audit", "Run HARDLINE drift audit (greppable rules from HARDLINE §5)");
    audit_step.dependOn(&audit_run.step);
    audit_step.dependOn(wasm_step);
}

fn resolvedTarget(b: *std.Build) std.Build.ResolvedTarget {
    var t = b.standardTargetOptions(.{});
    // Zig's native CPU detection on Windows ARM64 misses i8mm (FEAT_I8MM).
    // The Snapdragon X Elite (Oryon) supports it -- enable for native aarch64 builds.
    if (t.result.cpu.arch == .aarch64) {
        t.query.cpu_features_add.addFeature(@backingInt(std.Target.aarch64.Feature.i8mm));
        t.result.cpu.features.addFeature(@backingInt(std.Target.aarch64.Feature.i8mm));
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

pub const NativeWgpuOptions = struct {};

/// True if teak ships a native (windowed) backend for `os`. Examples gate
/// their `ui` step on this so a `zig build` configures on *any* target —
/// the step is simply absent where there is no native backend. Today:
/// Windows (Win32 + GDI) and Linux (X11 + stb_truetype).
pub fn hasNativeBackend(os: std.Target.Os.Tag) bool {
    return os == .windows or os == .linux;
}

/// Wire teak's native backend onto `exe`, dispatching on the resolved
/// target OS. Adds `teak`, `teak-platform-native`, `teak-gpu-native`
/// imports and the matching wgpu-native prebuilt:
///   * Windows → Win32 host + GDI text + `wgpu_native.dll`.
///   * Linux   → X11 host (libX11 dlopened, not linked) + stb_truetype
///               text + `libwgpu_native.so` (installed beside the exe,
///               rpath `$ORIGIN`); links libc.
/// The platform/gpu source picked per OS lives behind the stable import
/// names above, so a single `ui_main.zig` compiles on both.
pub fn linkNativeWgpu(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    _: NativeWgpuOptions,
) void {
    const root = exe.root_module;
    const target = root.resolved_target.?;
    const optimize = root.optimize.?;

    const teak_dep = b.dependencyFromBuildZig(BuildZig, .{
        .target = target,
        .optimize = optimize,
    });
    const teak_mod = teak_dep.module("teak");

    switch (target.result.os.tag) {
        .windows => linkWindows(b, exe, teak_dep, teak_mod, target, optimize),
        .linux => linkLinux(b, exe, teak_dep, teak_mod, target, optimize),
        else => @panic("teak.linkNativeWgpu: no native backend for this OS (Windows or Linux)"),
    }
}

pub const Win32WgpuOptions = struct {};

/// Deprecated alias for `linkNativeWgpu`, kept for consumers still calling
/// the Windows-specific name. Asserts a Windows target — cross-OS
/// consumers should switch to `linkNativeWgpu`.
pub fn linkWin32Wgpu(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    _: Win32WgpuOptions,
) void {
    if (exe.root_module.resolved_target.?.result.os.tag != .windows) {
        @panic("teak.linkWin32Wgpu: target must be Windows (use teak.linkNativeWgpu for cross-OS)");
    }
    linkNativeWgpu(b, exe, .{});
}

fn linkWindows(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    teak_dep: *std.Build.Dependency,
    teak_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const wgpu_dep_name: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "wgpu-native-windows-aarch64",
        .x86_64 => "wgpu-native-windows-x86_64",
        else => @panic("teak.linkNativeWgpu: unsupported Windows arch (aarch64 or x86_64 only)"),
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

    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize);

    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/win32.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });

    const gpu_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/gpu/native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-shaders", .module = shaders_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });
    gpu_mod.addImport("wgpu-c", translateC(b, teak_dep.path("src/gpu/vendor/wgpu_c.h"), wgpu_dep.path("include/webgpu"), target, optimize));
    gpu_mod.addLibraryPath(wgpu_dep.path("lib"));
    gpu_mod.linkSystemLibrary("wgpu_native.dll", .{});

    const root = exe.root_module;
    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-native", platform_mod);
    root.addImport("teak-gpu-native", gpu_mod);

    // The exe needs wgpu_native.dll next to it at runtime. Tying the
    // DLL install to exe.step ensures any build that compiles exe also
    // places the DLL in zig-out/bin.
    const install_dll = b.addInstallBinFile(wgpu_dep.path("lib/wgpu_native.dll"), "wgpu_native.dll");
    exe.step.dependOn(&install_dll.step);
}

fn linkLinux(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    teak_dep: *std.Build.Dependency,
    teak_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const wgpu_dep_name: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "wgpu-native-linux-aarch64",
        .x86_64 => "wgpu-native-linux-x86_64",
        else => @panic("teak.linkNativeWgpu: unsupported Linux arch (aarch64 or x86_64 only)"),
    };
    const wgpu_dep = teak_dep.builder.lazyDependency(wgpu_dep_name, .{}) orelse return;

    const shaders_mod = b.createModule(.{
        .root_source_file = teak_dep.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize);

    // X11 host. libX11 is loaded at runtime via std.DynLib (no -lX11, no
    // X11 dev headers needed) — but std.DynLib must take its dlopen path,
    // which requires libc linked (without it the manual ELF loader can't
    // resolve libX11.so.6 and crashes on first call).
    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/x11.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });

    const gpu_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/gpu/native_linux.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-shaders", .module = shaders_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });
    gpu_mod.addImport("wgpu-c", translateC(b, teak_dep.path("src/gpu/vendor/wgpu_c.h"), wgpu_dep.path("include/webgpu"), target, optimize));
    gpu_mod.addLibraryPath(wgpu_dep.path("lib"));
    gpu_mod.linkSystemLibrary("wgpu_native", .{}); // libwgpu_native.so

    const root = exe.root_module;
    // The exe itself must link libc so `builtin.link_libc` is true (picks
    // std.DynLib's dlopen backend for the X11 host).
    root.link_libc = true;
    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-native", platform_mod);
    root.addImport("teak-gpu-native", gpu_mod);
    // Find libwgpu_native.so next to the exe at runtime (Linux analog of
    // the Windows DLL-copy).
    root.addRPathSpecial("$ORIGIN");

    const install_so = b.addInstallBinFile(wgpu_dep.path("lib/libwgpu_native.so"), "libwgpu_native.so");
    exe.step.dependOn(&install_so.step);
}

/// Which of teak's three `FontFamily` values a web font stands in for.
pub const WebFontSlot = enum { sans, serif, mono };

/// A web font file. Register one per weight: text in `slot` then uses
/// `"<family>", <generic>` with `FontSpec.weight` mapped to CSS
/// `font-weight` (regular 400, medium 500, bold 700).
pub const WebFont = struct {
    /// CSS family name, e.g. "IBM Plex Mono". No quotes or backslashes.
    family: []const u8,
    /// CSS `font-weight` of this file.
    weight: u16 = 400,
    path: std.Build.LazyPath,
    slot: WebFontSlot = .mono,
};

/// Shared stb_truetype text module — one font + scale math feeds both the
/// Host's measurer and the GPU's rasterizer so layout and rendering can't
/// drift. Owns the vendored stb impl TU (compiled once) and links libc
/// (stb's malloc/free + the X11 host's std.DynLib dlopen path).
fn stbTextModule(
    b: *std.Build,
    teak_dep: *std.Build.Dependency,
    teak_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    // wasm32-freestanding has no libc: stb is compiled against a small shim
    // (src/text/stb_wasm_shim.zig) instead.
    const wasm = target.result.os.tag == .freestanding;
    const text_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/text/text.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !wasm,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
        },
    });
    text_mod.addImport("stb-c", translateC(b, teak_dep.path("src/gpu/vendor/stb_truetype.h"), null, target, optimize));
    text_mod.addIncludePath(teak_dep.path("src/gpu/vendor"));
    text_mod.addCSourceFile(.{
        .file = if (wasm) teak_dep.path("src/text/stb_wasm_impl.c") else teak_dep.path("src/gpu/vendor/stb_truetype_impl.c"),
        // wasm: size matters more than the last few percent of rasterizer speed.
        .flags = if (wasm) &.{ "-std=c99", "-Oz" } else &.{"-std=c99"},
    });
    return text_mod;
}

pub const HeadlessOptions = struct {};

/// Wire the HEADLESS native backend onto `exe` — no window system needed,
/// only a Vulkan device (Linux for now). Adds the imports `teak`,
/// `teak-platform-headless` (scripted-input Host, `platform/headless.zig`)
/// and `teak-gpu-headless` (the wgpu core with no surface, for
/// `Gpu.initOffscreen`/`readFrame`), links wgpu-native and sets the rpath.
/// Typical `build.zig`:
///
///     const shot = b.addExecutable(.{ .name = "shot", .root_module = b.createModule(.{
///         .root_source_file = b.path("src/shot_main.zig"), .target = target, .optimize = optimize }) });
///     teak.linkHeadless(b, shot, .{});
///     const run = b.addRunArtifact(shot);
///     run.addPassthruArgs();
///     b.step("shot", "Render a headless screenshot").dependOn(&run.step);
///
/// See docs/features/headless.md.
pub fn linkHeadless(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    _: HeadlessOptions,
) void {
    const root = exe.root_module;
    const target = root.resolved_target.?;
    const optimize = root.optimize.?;
    if (target.result.os.tag != .linux) @panic("teak.linkHeadless: Linux only for now (Windows has no stb-text headless stitch yet)");

    const teak_dep = b.dependencyFromBuildZig(BuildZig, .{
        .target = target,
        .optimize = optimize,
    });
    const teak_mod = teak_dep.module("teak");
    const wgpu_dep_name: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "wgpu-native-linux-aarch64",
        .x86_64 => "wgpu-native-linux-x86_64",
        else => @panic("teak.linkHeadless: unsupported Linux arch (aarch64 or x86_64 only)"),
    };
    const wgpu_dep = teak_dep.builder.lazyDependency(wgpu_dep_name, .{}) orelse return;

    const shaders_mod = b.createModule(.{
        .root_source_file = teak_dep.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });
    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize);

    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/headless.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });
    const gpu_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/gpu/native_headless.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-shaders", .module = shaders_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });
    gpu_mod.addImport("wgpu-c", translateC(b, teak_dep.path("src/gpu/vendor/wgpu_c.h"), wgpu_dep.path("include/webgpu"), target, optimize));
    gpu_mod.addLibraryPath(wgpu_dep.path("lib"));
    gpu_mod.linkSystemLibrary("wgpu_native", .{});

    root.link_libc = true;
    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-headless", platform_mod);
    root.addImport("teak-gpu-headless", gpu_mod);
    root.addRPathSpecial("$ORIGIN");
    const install_so = b.addInstallBinFile(wgpu_dep.path("lib/libwgpu_native.so"), "libwgpu_native.so");
    exe.step.dependOn(&install_so.step);
}

pub const WebWgpuOptions = struct {
    port: u16 = 8080,
    output_dir: []const u8 = "dist",
    /// Fonts copied to `<output_dir>/fonts/` and loaded before the first frame.
    fonts: []const WebFont = &.{},
    /// Strip DWARF and the name section from the .wasm in any non-Debug
    /// build (the browser cannot use it without an extension, and it was
    /// ~90% of the shipped file: chrome 1.27 MB -> ~0.12 MB). Set false to
    /// keep symbols for wasm debugging / `wasm-objdump`.
    strip: bool = true,
};

/// The `teak-fonts` options module: the family registered for each slot ("" =
/// none, the CSS generic family is used alone). The last font of a slot wins
/// the name; all files of a slot should share one family.
fn webFontsModule(b: *std.Build, fonts: []const WebFont) *std.Build.Module {
    const opts = b.addOptions();
    const slots = @typeInfo(WebFontSlot).@"enum";
    inline for (slots.field_names, slots.field_values) |name, value| {
        var family: []const u8 = "";
        for (fonts) |font| {
            if (@backingInt(font.slot) == value) family = font.family;
        }
        opts.addOption([]const u8, name, family);
    }
    return opts.createModule();
}

/// The shared CSS font-string helper used by the web Host and Gpu.
fn webFontModule(b: *std.Build, teak_mod: *std.Build.Module, fonts_mod: *std.Build.Module, source: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-fonts", .module = fonts_mod },
        },
    });
}

/// The `teak-web-fontdata` module: every `.fonts` file and the default face
/// embedded as bytes (so stb_truetype in wasm shapes and rasterizes with exactly
/// the faces the app ships), plus each file's slot and weight. The default face
/// (a Plex Mono ASCII subset, ~5.5 KB gzip) is embedded only when `fonts` is empty.
fn webFontDataModule(
    b: *std.Build,
    fonts: []const WebFont,
    default_font: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    var src: std.Io.Writer.Allocating = .init(b.allocator);
    src.writer.writeAll(
        \\pub const Face = struct { slot: u8, weight: u16, bytes: []const u8 };
        \\pub const default_font = @embedFile("teak-default-font");
        \\pub const faces = [_]Face{
        \\
    ) catch @panic("OOM");
    for (fonts, 0..) |f, i| {
        src.writer.print("    .{{ .slot = {d}, .weight = {d}, .bytes = @embedFile(\"font-{d}\") }},\n", .{ @backingInt(f.slot), f.weight, i }) catch @panic("OOM");
    }
    src.writer.writeAll("};\n") catch @panic("OOM");
    const wf = b.addWriteFiles();
    const root = wf.add("webfontdata.zig", src.written());
    const mod = b.createModule(.{ .root_source_file = root, .target = target, .optimize = optimize });
    // An app that ships its own faces does not also pay for the built-in default
    // (any registered face serves families without one).
    mod.addAnonymousImport("teak-default-font", .{ .root_source_file = if (fonts.len > 0) wf.add("no-default-font", "") else default_font });
    for (fonts, 0..) |f, i| {
        mod.addAnonymousImport(b.fmt("font-{d}", .{i}), .{ .root_source_file = f.path });
    }
    return mod;
}

fn addFontArgs(run: *std.Build.Step.Run, fonts: []const WebFont) void {
    for (fonts) |f| {
        run.addArg("--font");
        run.addArg(f.family);
        run.addArg(run.step.owner.fmt("{d}", .{f.weight}));
        run.addFileArg(f.path);
    }
}

/// Wire the wasm + WebGPU (zunk) backend onto `exe`. Adds `teak`,
/// `teak-platform-wasm`, and `teak-gpu-web` imports; sets wasm linker
/// flags; registers `web` (build) and `web-run` (build + serve) steps
/// that drive zunk's CLI. Step names are `web` / `web-run` rather than
/// zunk's default `run` so the caller can keep a CLI `run` step.
pub fn linkWebWgpu(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    opts: WebWgpuOptions,
) void {
    const root = exe.root_module;
    const target = root.resolved_target.?;
    const optimize = root.optimize.?;

    if (target.result.cpu.arch != .wasm32 or target.result.os.tag != .freestanding) {
        @panic("teak.linkWebWgpu: target must be wasm32-freestanding");
    }
    exe.rdynamic = true;
    exe.entry = .disabled;
    exe.export_memory = true;
    if (opts.strip and optimize != .debug) root.strip = true;

    const teak_dep = b.dependencyFromBuildZig(BuildZig, .{
        .target = target,
        .optimize = optimize,
    });
    const teak_mod = teak_dep.module("teak");

    // Look up zunk on teak's builder (where `.zunk` is declared in
    // build.zig.zon). Consumers don't need zunk in their own zon.
    const zunk_dep = teak_dep.builder.dependency("zunk", .{
        .target = target,
        .optimize = optimize,
    });
    const zunk_mod = zunk_dep.module("zunk");

    const shaders_mod = b.createModule(.{
        .root_source_file = teak_dep.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    const web_font_mod = webFontModule(b, teak_mod, webFontsModule(b, opts.fonts), teak_dep.path("src/gpu/web_font.zig"), target, optimize);

    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize);
    const font_data_mod = webFontDataModule(b, opts.fonts, teak_dep.path("src/text/fonts/IBMPlexMonoDefault.ttf"), target, optimize);

    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/wasm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "zunk", .module = zunk_mod },
            .{ .name = "teak-web-font", .module = web_font_mod },
            .{ .name = "teak-text", .module = text_mod },
            .{ .name = "teak-web-fontdata", .module = font_data_mod },
        },
    });

    const gpu_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/gpu/web.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "zunk", .module = zunk_mod },
            .{ .name = "teak-web-font", .module = web_font_mod },
            .{ .name = "teak-shaders", .module = shaders_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });

    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-wasm", platform_mod);
    root.addImport("teak-gpu-web", gpu_mod);

    // Forked from zunk.installApp so the serve step is `web-run` rather
    // than `run`. Upstream candidate: `run_step_name` option on installApp.
    const cli = zunk_dep.artifact("zunk");
    b.installArtifact(exe);

    const gen_cmd = b.addRunArtifact(cli);
    gen_cmd.addArg("build");
    gen_cmd.addArg("--wasm");
    gen_cmd.addArtifactArg(exe);
    gen_cmd.addArg("--output-dir");
    gen_cmd.addArg(opts.output_dir);
    addFontArgs(gen_cmd, opts.fonts);
    gen_cmd.setCwd(b.path("."));

    const web_step = b.step("web", "Build wasm + dist/ via zunk");
    web_step.dependOn(&gen_cmd.step);

    const serve_cmd = b.addRunArtifact(cli);
    serve_cmd.addArg("run");
    serve_cmd.addArg("--wasm");
    serve_cmd.addArtifactArg(exe);
    serve_cmd.addArg("--output-dir");
    serve_cmd.addArg(opts.output_dir);
    serve_cmd.addArg("--port");
    serve_cmd.addArg(b.fmt("{d}", .{opts.port}));
    addFontArgs(serve_cmd, opts.fonts);
    serve_cmd.setCwd(b.path("."));

    const web_run = b.step("web-run", "Build and serve wasm on localhost");
    web_run.dependOn(&serve_cmd.step);
}

/// Translate a C header into a Zig module (`@cImport` is gone in 0.17).
/// `include_dir`, when given, is where the header's own `#include`s resolve.
/// Each call yields a distinct set of C types, so call it once per module
/// that must share them (every native GPU file reaches `c` through one).
fn translateC(
    b: *std.Build,
    header: std.Build.LazyPath,
    include_dir: ?std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    // Header-only declarations: no libc, so freestanding (wasm) targets work too.
    const tc = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize, .link_libc = false });
    if (include_dir) |dir| tc.addIncludePath(dir);
    return tc.createModule();
}
