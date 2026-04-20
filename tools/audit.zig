//! HARDLINE drift audit. Walks `src/` and flags the greppable rules
//! from `docs/HARDLINE.md` §5. Wired as `zig build audit` in the root
//! build.zig; the step also depends on `test-wasm`, so one command
//! gates the full automated half of the checklist.
//!
//! Not every §5 rule is greppable — validator coverage and feature-doc
//! completeness still need human review. What's here is the fast
//! automated half.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

// ── Rules ──────────────────────────────────────────────────────────

const FRAMEWORK_CORE_DIRS = [_][]const u8{
    "src/core",
    "src/layout",
    "src/input",
    "src/render",
};

const Rule = struct {
    name: []const u8,
    reason: []const u8,
    dirs: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    forbid_any: []const []const u8,
};

const RULE_NO_PLATFORM_IMPORTS = Rule{
    .name = "framework core imports no platform or gpu modules",
    .reason = "HARDLINE escape hatch 4(c) — dependency arrow points inward.",
    .dirs = &FRAMEWORK_CORE_DIRS,
    .forbid_any = &.{
        "@import(\"../platform/",
        "@import(\"../gpu/",
        "@import(\"platform/",
        "@import(\"gpu/",
    },
};

const RULE_NO_COND_COMP = Rule{
    .name = "framework core has no conditional compilation",
    .reason = "HARDLINE §3 — platform branching happens in platform/ and gpu/, not core.",
    .dirs = &FRAMEWORK_CORE_DIRS,
    .forbid_any = &.{
        "@import(\"builtin\")",
        "builtin.os.tag",
        "builtin.target",
    },
};

const RULE_CMD_HAS_NO_FN_PTRS = Rule{
    .name = "Cmd union carries data, not callbacks",
    .reason = "HARDLINE §3 — msgs are values, not fn pointers.",
    .files = &.{"src/core/cmd.zig"},
    .forbid_any = &.{
        "*const fn",
        ": fn(",
    },
};

const RULE_NO_CHAR_WIDTH = Rule{
    .name = "no CHAR_WIDTH constant anywhere in src/",
    .reason = "WS3 — real text measurement goes through TextMeasurer; the 10-px-per-byte placeholder must not return.",
    .dirs = &.{"src"},
    .forbid_any = &.{"CHAR_WIDTH"},
};

const simple_rules = [_]Rule{
    RULE_NO_PLATFORM_IMPORTS,
    RULE_NO_COND_COMP,
    RULE_CMD_HAS_NO_FN_PTRS,
    RULE_NO_CHAR_WIDTH,
};

const NO_MODULE_VARS_RULE = Rule{
    .name = "framework core has no module-scope var statics",
    .reason = "HARDLINE §5 — mutable module-level state lives in platform/ and gpu/ only.",
    .dirs = &FRAMEWORK_CORE_DIRS,
    .forbid_any = &.{},
};

const VIEW_SIG_RULE = Rule{
    .name = "view() takes no std.mem.Allocator parameter",
    .reason = "HARDLINE §3 — the per-frame arena reaches view() via CmdBuffer; a second allocator path defeats bulk-free.",
    .dirs = &FRAMEWORK_CORE_DIRS,
    .forbid_any = &.{},
};

// ── Main ───────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var total_violations: usize = 0;

    for (simple_rules) |rule| {
        const hits = try runRule(gpa, io, rule);
        defer freeHits(gpa, hits);
        total_violations += reportRule(rule, hits);
    }

    const view_hits = try auditViewSignatures(gpa, io, VIEW_SIG_RULE.dirs);
    defer freeHits(gpa, view_hits);
    total_violations += reportRule(VIEW_SIG_RULE, view_hits);

    const var_hits = try auditModuleVars(gpa, io, NO_MODULE_VARS_RULE.dirs);
    defer freeHits(gpa, var_hits);
    total_violations += reportRule(NO_MODULE_VARS_RULE, var_hits);

    if (total_violations > 0) {
        std.debug.print("\nHARDLINE audit FAILED with {d} violation(s).\n", .{total_violations});
        std.debug.print("See docs/HARDLINE.md §5 for the rules.\n", .{});
        std.process.exit(1);
    }
    std.debug.print("\nHARDLINE audit PASSED. Automated half of §5 is clean.\n", .{});
    std.debug.print("Manual review still required: validator coverage + feature-doc completeness.\n", .{});
}

// ── Rule engine ────────────────────────────────────────────────────

const Hit = struct {
    path: []const u8,
    line: usize,
    pattern: []const u8,
    text: []const u8,
};

fn freeHits(gpa: std.mem.Allocator, hits: []Hit) void {
    for (hits) |h| {
        gpa.free(h.path);
        gpa.free(h.text);
    }
    gpa.free(hits);
}

fn runRule(gpa: std.mem.Allocator, io: Io, rule: Rule) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |h| {
            gpa.free(h.path);
            gpa.free(h.text);
        }
        hits.deinit(gpa);
    }

    for (rule.dirs) |dir_path| {
        try scanDir(gpa, io, &hits, dir_path, rule.forbid_any);
    }
    for (rule.files) |file_path| {
        try scanFile(gpa, io, &hits, file_path, rule.forbid_any);
    }

    return hits.toOwnedSlice(gpa);
}

fn reportRule(rule: Rule, hits: []const Hit) usize {
    if (hits.len == 0) {
        std.debug.print("  PASS  {s}\n", .{rule.name});
        return 0;
    }
    std.debug.print("  FAIL  {s}\n", .{rule.name});
    std.debug.print("        ({s})\n", .{rule.reason});
    for (hits) |h| {
        std.debug.print("        {s}:{d}: matched \"{s}\" — {s}\n", .{ h.path, h.line, h.pattern, h.text });
    }
    return hits.len;
}

// ── File walking + scanning ────────────────────────────────────────

fn scanDir(
    gpa: std.mem.Allocator,
    io: Io,
    hits: *std.ArrayList(Hit),
    dir_path: []const u8,
    forbid_any: []const []const u8,
) !void {
    const cwd = Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
        defer gpa.free(full_path);

        try scanFile(gpa, io, hits, full_path, forbid_any);
    }
}

fn scanFile(
    gpa: std.mem.Allocator,
    io: Io,
    hits: *std.ArrayList(Hit),
    file_path: []const u8,
    forbid_any: []const []const u8,
) !void {
    const cwd = Dir.cwd();
    const contents = cwd.readFileAlloc(io, file_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(contents);

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const stripped = stripLineComment(line);
        for (forbid_any) |needle| {
            if (std.mem.indexOf(u8, stripped, needle) != null) {
                const path_copy = try gpa.dupe(u8, file_path);
                const text_copy = try gpa.dupe(u8, std.mem.trim(u8, line, " \t\r"));
                try hits.append(gpa, .{
                    .path = path_copy,
                    .line = line_no,
                    .pattern = needle,
                    .text = text_copy,
                });
                break;
            }
        }
    }
}

/// Strip `//`-to-EOL comments. Doesn't handle `//` inside string
/// literals — acceptable because our forbidden patterns don't
/// contain `//`, so false-positive suppression inside strings is rare.
fn stripLineComment(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "//")) |idx| return line[0..idx];
    return line;
}

// ── Dedicated: module-scope var statics ────────────────────────────
//
// A `var` declaration at column 0 (or after `pub ` at column 0) is
// module-scope. Function-local vars are indented. Test blocks use
// `test "..." { var ... }` which is also indented. So a simple
// column-zero check catches the real violations without false
// positives.

fn auditModuleVars(gpa: std.mem.Allocator, io: Io, dirs: []const []const u8) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |h| {
            gpa.free(h.path);
            gpa.free(h.text);
        }
        hits.deinit(gpa);
    }

    for (dirs) |dir_path| {
        try scanDirForModuleVars(gpa, io, &hits, dir_path);
    }

    return hits.toOwnedSlice(gpa);
}

fn scanDirForModuleVars(
    gpa: std.mem.Allocator,
    io: Io,
    hits: *std.ArrayList(Hit),
    dir_path: []const u8,
) !void {
    const cwd = Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
        defer gpa.free(full_path);

        try scanFileForModuleVars(gpa, io, hits, full_path);
    }
}

fn scanFileForModuleVars(
    gpa: std.mem.Allocator,
    io: Io,
    hits: *std.ArrayList(Hit),
    file_path: []const u8,
) !void {
    const cwd = Dir.cwd();
    const contents = cwd.readFileAlloc(io, file_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(contents);

    const prefixes = [_][]const u8{
        "var ",
        "pub var ",
        "threadlocal var ",
        "pub threadlocal var ",
        "export var ",
        "pub export var ",
        "extern var ",
        "pub extern var ",
    };

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const stripped = stripLineComment(line);
        var is_module_var = false;
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, stripped, p)) {
                is_module_var = true;
                break;
            }
        }
        if (!is_module_var) continue;

        const path_copy = try gpa.dupe(u8, file_path);
        const text_copy = try gpa.dupe(u8, std.mem.trim(u8, line, " \t\r"));
        try hits.append(gpa, .{
            .path = path_copy,
            .line = line_no,
            .pattern = "module-scope var",
            .text = text_copy,
        });
    }
}

// ── Dedicated: view() signatures ───────────────────────────────────

fn auditViewSignatures(gpa: std.mem.Allocator, io: Io, dirs: []const []const u8) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |h| {
            gpa.free(h.path);
            gpa.free(h.text);
        }
        hits.deinit(gpa);
    }

    for (dirs) |dir_path| {
        try scanDirForViewSig(gpa, io, &hits, dir_path);
    }

    return hits.toOwnedSlice(gpa);
}

fn scanDirForViewSig(
    gpa: std.mem.Allocator,
    io: Io,
    hits: *std.ArrayList(Hit),
    dir_path: []const u8,
) !void {
    const cwd = Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
        defer gpa.free(full_path);

        try scanFileForViewSig(gpa, io, hits, full_path);
    }
}

fn scanFileForViewSig(
    gpa: std.mem.Allocator,
    io: Io,
    hits: *std.ArrayList(Hit),
    file_path: []const u8,
) !void {
    const cwd = Dir.cwd();
    const contents = cwd.readFileAlloc(io, file_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(contents);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    for (lines.items, 0..) |line, idx| {
        const stripped = stripLineComment(line);
        if (std.mem.indexOf(u8, stripped, "fn view(") == null) continue;

        const end = @min(lines.items.len, idx + 4);
        var found = false;
        for (lines.items[idx..end]) |sig_line| {
            const sig_stripped = stripLineComment(sig_line);
            if (std.mem.indexOf(u8, sig_stripped, "Allocator") != null) {
                found = true;
                break;
            }
            if (std.mem.indexOf(u8, sig_stripped, ") void") != null or
                std.mem.indexOf(u8, sig_stripped, ") !") != null) break;
        }
        if (found) {
            const path_copy = try gpa.dupe(u8, file_path);
            const text_copy = try gpa.dupe(u8, std.mem.trim(u8, line, " \t\r"));
            try hits.append(gpa, .{
                .path = path_copy,
                .line = idx + 1,
                .pattern = "Allocator in view() signature",
                .text = text_copy,
            });
        }
    }
}
