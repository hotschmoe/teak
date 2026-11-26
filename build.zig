const std = @import("std");

/// Single source of truth: build.zig.zon `.version` (docs/VERSIONING.md). `-Dversion-meta=<str>` appends "+<str>".
fn versionString(b: *std.Build) []const u8 {
    const base: []const u8 = @import("build.zig.zon").version;
    _ = std.SemanticVersion.parse(base) catch @panic("build.zig.zon .version is not valid semver");
    const meta = b.option([]const u8, "version-meta", "Semver build metadata appended as +<meta>") orelse return base;
    return b.fmt("{s}+{s}", .{ base, meta });
}

const BuildZig = @This();

pub fn build(b: *std.Build) void {
    const target = resolvedTarget(b);
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("teak", .{
        .root_source_file = b.path("src/teak.zig"),
        .target = target,
        .optimize = optimize,
    });
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", versionString(b));
    version_options.addOption([]const u8, "manifest_version", @import("build.zig.zon").version);
    mod.addOptions("build_options", version_options);

    const blocking = b.step("test", "Run the blocking end-to-end checks");
    const blocking_run = b.addSystemCommand(&.{ "bash", "tools/test-e2e.sh", "blocking" });
    blocking_run.setCwd(b.path("."));
    blocking.dependOn(&blocking_run.step);
    const tidy_exe = b.addExecutable(.{
        .name = "teak-tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "assert", .module = b.createModule(.{
                .root_source_file = b.path("src/assert.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }) }},
        }),
    });
    const tidy_run = b.addRunArtifact(tidy_exe);
    tidy_run.setCwd(b.path("."));
    tidy_run.has_side_effects = true;
    tidy_run.stdio = .inherit;
    tidy_run.addPassthruArgs();
    b.step("tidy", "Measure TigerStyle ratchets (-- --table or -- --update)")
        .dependOn(&tidy_run.step);
    blocking_run.step.dependOn(&tidy_run.step);
    const heavy = b.step("test-heavy", "Run background end-to-end checks");
    const heavy_run = if (b.graph.host.result.os.tag == .windows)
        b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-File", "tools/test-heavy-win32.ps1" })
    else
        b.addSystemCommand(&.{ "bash", "tools/test-e2e.sh", "heavy" });
    heavy_run.setCwd(b.path("."));
    heavy.dependOn(&heavy_run.step);

    const drive_mod = b.createModule(.{
        .root_source_file = b.path("tools/teak_drive.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "control_socket", .module = b.createModule(.{
            .root_source_file = b.path("src/platform/control_socket.zig"),
            .target = target,
            .optimize = optimize,
        }) }},
    });
    const drive_exe = b.addExecutable(.{ .name = "teak-drive", .root_module = drive_mod });
    drive_mod.addImport("teak", mod);
    b.step("drive", "Build zig-out/bin/teak-drive (agent driver CLI + MCP server)")
        .dependOn(&b.addInstallArtifact(drive_exe, .{}).step);

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
    blocking_run.step.dependOn(wasm_step);

    {
        const bench_teak = b.createModule(.{
            .root_source_file = b.path("src/teak.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        const bench_text = b.createModule(.{
            .root_source_file = b.path("src/text/text.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "teak", .module = bench_teak }},
        });
        configureTextShaper(b, b, bench_text, false, target, .ReleaseFast);
        bench_text.addImport("stb-c", translateC(b, b.path("src/gpu/vendor/stb_truetype.h"), null, target, .ReleaseFast));
        bench_text.addIncludePath(b.path("src/gpu/vendor"));
        bench_text.addCSourceFile(.{ .file = b.path("src/gpu/vendor/stb_truetype_impl.c"), .flags = &.{"-std=c99"} });
        const bench_exe = b.addExecutable(.{
            .name = "teak-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/bench/main.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .strip = false, // keep symbols so `perf report` works on the binary
                .imports = &.{
                    .{ .name = "teak", .module = bench_teak },
                    .{ .name = "teak-text", .module = bench_text },
                },
            }),
        });
        const bench_run = b.addRunArtifact(bench_exe);
        bench_run.has_side_effects = true;
        b.step("bench", "CPU pipeline benchmark (view/layout/hit/render/cmdsEqual + text)").dependOn(&bench_run.step);
    }

    // HARDLINE drift audit: docs/HARDLINE.md §5.
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

    const api_exe = b.addExecutable(.{
        .name = "teak-gen-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_api.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const api_run = b.addRunArtifact(api_exe);
    api_run.setCwd(b.path("."));
    api_run.has_side_effects = true;
    api_run.stdio = .inherit;
    b.step("api", "Regenerate docs/api.md and llms-full.txt from src/teak.zig").dependOn(&api_run.step);

    const audit_step = b.step("audit", "Run HARDLINE drift audit (greppable rules from HARDLINE §5)");
    audit_step.dependOn(&audit_run.step);
    audit_step.dependOn(wasm_step);

    const gates_exe = b.addExecutable(.{
        .name = "ci-gates",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ci_gates.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const gates_run = b.addRunArtifact(gates_exe);
    gates_run.setCwd(b.path("."));
    gates_run.has_side_effects = true;
    gates_run.stdio = .inherit;
    gates_run.addArgs(&.{ "--zig", b.graph.zig_exe });
    gates_run.addPassthruArgs();
    b.step("gates", "Background gates: idle, latency, idle memory, binary size (JSON in zig-out/gates/)")
        .dependOn(&gates_run.step);
}

fn resolvedTarget(b: *std.Build) std.Build.ResolvedTarget {
    var t = b.standardTargetOptions(.{});
    // Zig's Windows ARM64 CPU detection misses i8mm.
    if (t.result.cpu.arch == .aarch64) {
        t.query.cpu_features_add.addFeature(@backingInt(std.Target.aarch64.Feature.i8mm));
        t.result.cpu.features.addFeature(@backingInt(std.Target.aarch64.Feature.i8mm));
    }
    return t;
}

pub const NativeWgpuOptions = struct {
    /// Shape complex scripts with HarfBuzz (lazy package, C++ build). Default
    /// off: the build then has no extra dependency. See docs/features/harfbuzz.md.
    harfbuzz: bool = false,
};

/// True if teak ships a native (windowed) backend for `os`. Examples gate
/// their `ui` step on this so a `zig build` configures on *any* target —
/// the step is simply absent where there is no native backend. Today:
/// Windows (Win32 + GDI) and Linux (X11 + stb_truetype).
pub fn hasNativeBackend(os: std.Target.Os.Tag) bool {
    return os == .windows or os == .linux or os == .macos;
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
    opts: NativeWgpuOptions,
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
        .windows => linkWindows(b, exe, teak_dep, teak_mod, target, optimize, opts.harfbuzz),
        .linux => linkLinux(b, exe, teak_dep, teak_mod, target, optimize, opts.harfbuzz),
        .macos => linkMacos(b, exe, teak_dep, teak_mod, target, optimize, opts.harfbuzz),
        else => @panic("teak.linkNativeWgpu: no native backend for this OS (Windows, Linux or macOS)"),
    }
}

fn linkWindows(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    teak_dep: *std.Build.Dependency,
    teak_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    harfbuzz: bool,
) void {
    const wgpu_dep_name: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "wgpu-native-windows-aarch64",
        .x86_64 => "wgpu-native-windows-x86_64",
        else => @panic("teak.linkNativeWgpu: unsupported Windows arch (aarch64 or x86_64 only)"),
    };
    // Lazy dependencies must be resolved on their declaring builder.
    const wgpu_dep = teak_dep.builder.lazyDependency(wgpu_dep_name, .{}) orelse return;

    const shaders_mod = b.createModule(.{
        .root_source_file = teak_dep.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared text metrics keep Host layout and GPU rendering aligned.
    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize, harfbuzz);

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
        .link_libc = true,
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

    // The executable requires wgpu_native.dll beside it at runtime.
    const install_dll = b.addInstallBinFile(wgpu_dep.path("lib/wgpu_native.dll"), "wgpu_native.dll");
    exe.step.dependOn(&install_dll.step);
}

/// macOS: the Cocoa host (`platform/cocoa.zig`) + Metal via wgpu-native.
/// AppKit, QuartzCore and libobjc are `dlopen`ed by path at run time, so the
/// build needs no SDK and no `-framework` flags (cross-compiling from any
/// OS works); only `libwgpu_native.dylib` is linked, installed beside the
/// executable and found through an `@executable_path` rpath.
fn linkMacos(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    teak_dep: *std.Build.Dependency,
    teak_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    harfbuzz: bool,
) void {
    const wgpu_dep_name: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "wgpu-native-macos-aarch64",
        .x86_64 => "wgpu-native-macos-x86_64",
        else => @panic("teak.linkNativeWgpu: unsupported macOS arch (aarch64 or x86_64 only)"),
    };
    const wgpu_dep = teak_dep.builder.lazyDependency(wgpu_dep_name, .{}) orelse return;

    const shaders_mod = b.createModule(.{
        .root_source_file = teak_dep.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });
    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize, harfbuzz);

    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/cocoa.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "teak", .module = teak_mod },
            .{ .name = "teak-text", .module = text_mod },
        },
    });

    const gpu_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/gpu/native_macos.zig"),
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
    gpu_mod.linkSystemLibrary("wgpu_native", .{}); // libwgpu_native.dylib

    const root = exe.root_module;
    root.link_libc = true;
    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-native", platform_mod);
    root.addImport("teak-gpu-native", gpu_mod);
    root.addRPathSpecial("@executable_path");

    const install_dylib = b.addInstallBinFile(wgpu_dep.path("lib/libwgpu_native.dylib"), "libwgpu_native.dylib");
    exe.step.dependOn(&install_dylib.step);
}

fn linkLinux(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    teak_dep: *std.Build.Dependency,
    teak_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    harfbuzz: bool,
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

    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize, harfbuzz);

    // X11 needs libc so DynLib uses dlopen to load libX11.
    const platform_mod = b.createModule(.{
        .root_source_file = teak_dep.path("src/platform/linux.zig"),
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
    // The executable must also link libc for DynLib's dlopen backend.
    root.link_libc = true;
    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-native", platform_mod);
    root.addImport("teak-gpu-native", gpu_mod);
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
    harfbuzz: bool,
) *std.Build.Module {
    // stb's wasm libc substitutes: src/text/stb_wasm_shim.zig.
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
        .flags = if (wasm) &.{ "-std=c99", "-Oz" } else &.{"-std=c99"},
    });
    configureTextShaper(b, teak_dep.builder, text_mod, harfbuzz, target, optimize);
    return text_mod;
}

/// Give a `teak-text` module its `text_options` import and, when `harfbuzz`,
/// compile HarfBuzz's single-source amalgamation (`src/harfbuzz.cc`) into it.
/// `owner` is the builder that declares the lazy `harfbuzz` dependency (teak's).
/// Native targets only: HarfBuzz is C++ and needs libc++, which wasm32-freestanding lacks.
fn configureTextShaper(
    b: *std.Build,
    owner: *std.Build,
    text_mod: *std.Build.Module,
    harfbuzz: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const opts = b.addOptions();
    opts.addOption(bool, "harfbuzz", harfbuzz);
    text_mod.addOptions("text_options", opts);
    if (!harfbuzz) return;
    if (target.result.os.tag == .freestanding) @panic("teak: -Dharfbuzz / .harfbuzz is native-only (HarfBuzz needs libc++)");
    const hb = owner.lazyDependency("harfbuzz", .{}) orelse return;
    text_mod.link_libcpp = true;
    text_mod.addIncludePath(hb.path("src"));
    text_mod.addCSourceFile(.{
        .file = hb.path("src/harfbuzz.cc"),
        .flags = &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti",
            "-fno-sanitize=undefined",
            "-DHAVE_OT",
            "-DHB_NO_PRAGMA_GCC_DIAGNOSTIC",
            "-DHB_NO_MT",
            "-DHB_NO_BUFFER_SERIALIZE",
            "-DHB_NO_BUFFER_VERIFY",
            "-DHB_NO_PAINT",
            "-DHB_NO_DRAW",
            "-DHB_NO_SUBSET_CFF",
        },
    });
    _ = optimize;
}

pub const HeadlessOptions = struct {
    /// See `NativeWgpuOptions.harfbuzz`.
    harfbuzz: bool = false,
};

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
    headless_opts: HeadlessOptions,
) void {
    const root = exe.root_module;
    const target = root.resolved_target.?;
    const optimize = root.optimize.?;
    const os = target.result.os.tag;
    if (os != .linux and os != .windows and os != .macos) @panic("teak.linkHeadless: Linux, Windows or macOS only");

    const teak_dep = b.dependencyFromBuildZig(BuildZig, .{
        .target = target,
        .optimize = optimize,
    });
    const teak_mod = teak_dep.module("teak");
    const wgpu_dep_name: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => if (os == .windows) "wgpu-native-windows-aarch64" else if (os == .macos) "wgpu-native-macos-aarch64" else "wgpu-native-linux-aarch64",
        .x86_64 => if (os == .windows) "wgpu-native-windows-x86_64" else if (os == .macos) "wgpu-native-macos-x86_64" else "wgpu-native-linux-x86_64",
        else => @panic("teak.linkHeadless: unsupported arch (aarch64 or x86_64 only)"),
    };
    const wgpu_dep = teak_dep.builder.lazyDependency(wgpu_dep_name, .{}) orelse return;

    const shaders_mod = b.createModule(.{
        .root_source_file = teak_dep.path("shaders/shaders.zig"),
        .target = target,
        .optimize = optimize,
    });
    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize, headless_opts.harfbuzz);

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
    gpu_mod.linkSystemLibrary(if (os == .windows) "wgpu_native.dll" else "wgpu_native", .{});

    root.link_libc = true;
    root.addImport("teak", teak_mod);
    root.addImport("teak-platform-headless", platform_mod);
    root.addImport("teak-gpu-headless", gpu_mod);
    if (os == .windows) {
        const install_dll = b.addInstallBinFile(wgpu_dep.path("lib/wgpu_native.dll"), "wgpu_native.dll");
        exe.step.dependOn(&install_dll.step);
    } else if (os == .macos) {
        root.addRPathSpecial("@executable_path");
        const install_dylib = b.addInstallBinFile(wgpu_dep.path("lib/libwgpu_native.dylib"), "libwgpu_native.dylib");
        exe.step.dependOn(&install_dylib.step);
    } else {
        root.addRPathSpecial("$ORIGIN");
        const install_so = b.addInstallBinFile(wgpu_dep.path("lib/libwgpu_native.so"), "libwgpu_native.so");
        exe.step.dependOn(&install_so.step);
    }
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
    /// The app's own JS glue, appended to zunk's generated bridge after the
    /// dependency chunks (zunk `--bridge-dep`), so it can implement extra
    /// `env` imports the app declares or call wasm exports from JS. Any
    /// path, e.g. `b.path("web/bridge.js")`. Null: zunk still picks up a
    /// `bridge.js` / `js/bridge.js` at the build root, as before.
    bridge_js: ?std.Build.LazyPath = null,
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
    mod.addAnonymousImport("teak-default-font", .{ .root_source_file = if (fonts.len > 0) wf.add("no-default-font", "") else default_font });
    for (fonts, 0..) |f, i| {
        mod.addAnonymousImport(b.fmt("font-{d}", .{i}), .{ .root_source_file = f.path });
    }
    return mod;
}

fn addFontArgs(run: *std.Build.Step.Run, fonts: []const WebFont) void {
    if (fonts.len > 0) run.addArg("--font-nowait");
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

    const text_mod = stbTextModule(b, teak_dep, teak_mod, target, optimize, false);
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

    const cli = zunk_dep.artifact("zunk");
    b.installArtifact(exe);

    const gen_cmd = b.addRunArtifact(cli);
    gen_cmd.addArg("build");
    gen_cmd.addArg("--wasm");
    gen_cmd.addArtifactArg(exe);
    gen_cmd.addArg("--output-dir");
    gen_cmd.addArg(opts.output_dir);
    addFontArgs(gen_cmd, opts.fonts);
    addBridgeArg(gen_cmd, opts.bridge_js);
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
    addBridgeArg(serve_cmd, opts.bridge_js);
    serve_cmd.setCwd(b.path("."));

    const web_run = b.step("web-run", "Build and serve wasm on localhost");
    web_run.dependOn(&serve_cmd.step);
}

/// `--bridge-dep <file>` for the app's own bridge.js (`WebWgpuOptions.bridge_js`).
fn addBridgeArg(cmd: *std.Build.Step.Run, bridge: ?std.Build.LazyPath) void {
    const p = bridge orelse return;
    cmd.addArg("--bridge-dep");
    cmd.addFileArg(p);
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
    // Hosted targets need libc's include paths for webgpu.h.
    const hosted = target.result.os.tag != .freestanding;
    const tc = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize, .link_libc = hosted });
    if (include_dir) |dir| tc.addIncludePath(dir);
    return tc.createModule();
}
