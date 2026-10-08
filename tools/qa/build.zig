//! Visual QA: one headless-shot binary per example, driven by `scripts.zig`
//! (the states worth looking at: initial, hover, modals, themes, pages ...).
//! Not part of any example: it imports each example's `src/app.zig` as a module.
//!
//!   cd tools/qa && zig build -p out          # builds qa-<example> for every example present
//!   out/bin/qa-chrome <out-dir> [--scale 2] [--state name] [--list]
//!
//! See docs/qa-2026-10.md and tools/qa/run.sh (native + web, 1x and 2x).
const std = @import("std");
const teak = @import("teak");

const examples = [_][]const u8{
    "chrome",  "counter_greeter", "todo",    "tree",         "viewport",
    "effects", "fonts",           "scene3d", "scene_layers", "kerf_viewer",
    "gallery", "notes",           "tables",
};

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
    const rich_dep = b.dependency("rich_zig", .{ .target = target, .optimize = optimize });

    for (examples) |name| {
        const app_path = b.fmt("../../examples/{s}/src/app.zig", .{name});
        std.Io.Dir.cwd().access(b.graph.io, app_path, .{}) catch continue;
        const app_mod = b.createModule(.{
            .root_source_file = b.path(app_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "teak", .module = teak_mod }},
        });
        if (std.mem.eql(u8, name, "counter_greeter")) {
            app_mod.addImport("rich_zig", rich_dep.module("rich_zig"));
        }
        const opts = b.addOptions();
        opts.addOption([]const u8, "example", name);
        const exe = b.addExecutable(.{
            .name = b.fmt("qa-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("shot.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "app", .module = app_mod },
                    .{ .name = "qa_cfg", .module = opts.createModule() },
                },
            }),
        });
        teak.linkHeadless(b, exe, .{});
        b.installArtifact(exe);
    }
}
