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
        .root_source_file = b.path("src/teak.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Tests ---

    const mod_tests = b.addTest(.{ .root_module = mod });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
}
