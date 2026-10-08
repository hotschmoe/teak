//! HARDLINE drift audit. Walks `src/` and flags the greppable rules
//! from `docs/HARDLINE.md` §5. Wired as `zig build audit` in the root
//! build.zig; the step also depends on `test-wasm`, so one command
//! gates the full automated half of the checklist.
//!
//! Not every §5 rule is greppable — validator coverage and feature-doc
//! completeness still need human review. What's here is the fast
//! automated half.

const std = @import("std");
const gen_api = @import("gen_api.zig");
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
    .name = "Cmd union and resource/scene data types carry data, not callbacks",
    .reason = "HARDLINE §3 — msgs are values, not fn pointers; §2 hatch 8 — resources are data.",
    .files = &.{ "src/core/cmd.zig", "src/core/resources.zig", "src/core/scene.zig" },
    .forbid_any = &.{
        "*const fn",
        ": fn(",
    },
};

const RULE_NO_HASDECL_EXTERNS = Rule{
    .name = "no @hasDecl gate on the private `externs` namespace",
    .reason = "@hasDecl is false for non-pub decls, so the guarded call was silently dead (file dialog, a11y mirror).",
    .dirs = &.{ "src/platform", "src/gpu" },
    .forbid_any = &.{"@hasDecl(externs"},
};

const RULE_NO_CHAR_WIDTH = Rule{
    .name = "no CHAR_WIDTH constant anywhere in src/",
    .reason = "WS3 — real text measurement goes through TextMeasurer; the 10-px-per-byte placeholder must not return.",
    .dirs = &.{"src"},
    .forbid_any = &.{"CHAR_WIDTH"},
};

const RULE_NO_DEPRECATED_POINTER_HOOKS = Rule{
    .name = "examples declare no deprecated pointer hook (pointerMsg is the one)",
    .reason = "HARDLINE §5 -- pointer input has one hook; canvasMsg/textMsg/sliderMsg/scrollMsg/hoverMsg/contextMsg are adapters slated for removal.",
    .dirs = &.{"examples"},
    .forbid_any = &.{
        "pub fn canvasMsg(",
        "pub fn textMsg(",
        "pub fn sliderMsg(",
        "pub fn scrollMsg(",
        "pub fn hoverMsg(",
        "pub fn contextMsg(",
    },
};

const simple_rules = [_]Rule{
    RULE_NO_DEPRECATED_POINTER_HOOKS,
    RULE_NO_PLATFORM_IMPORTS,
    RULE_NO_COND_COMP,
    RULE_CMD_HAS_NO_FN_PTRS,
    RULE_NO_CHAR_WIDTH,
    RULE_NO_HASDECL_EXTERNS,
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

// llms.txt sync: every `pub const NAME` re-export in src/teak.zig must be
// mentioned somewhere in the hand-curated llms.txt, so the one-read context
// pack can't silently fall behind the public API.
const LLMS_TXT_RULE = Rule{
    .name = "llms.txt lists every src/teak.zig re-export",
    .reason = "llms.txt is hand-curated + audit-enforced — a new/renamed pub const must be documented there.",
    .forbid_any = &.{},
};

// Doc-drift rules (HARDLINE §5, "docs match the code"): each is a named
// check with a list of (source, needle-extractor, doc) triples.
const DOC_DRIFT_RULE = Rule{
    .name = "docs name every escape hatch, App hook, Host/Gpu surface and example",
    .reason = "llms.txt hatch list, docs/features/{run,host,gpu}.md and README must not fall behind the code (HARDLINE §5).",
    .forbid_any = &.{},
};

const TEAK_ROOT_FILE = "src/teak.zig";
const LLMS_TXT_FILE = "llms.txt";

// Generated API reference: docs/api.md and llms-full.txt must equal what
// tools/gen_api.zig produces from the current sources + llms.txt.
const API_RULE_NAME = "docs/api.md and llms-full.txt are up to date (tools/gen_api.zig)";

fn auditApiReference(gpa: std.mem.Allocator, io: Io) usize {
    const fresh = gen_api.generate(gpa, io) catch |e| {
        std.debug.print("  FAIL  {s}\n        generator error: {s}\n", .{ API_RULE_NAME, @errorName(e) });
        return 1;
    };
    defer fresh.deinit(gpa);
    var stale: usize = 0;
    const pairs = [_]struct { path: []const u8, want: []const u8 }{
        .{ .path = gen_api.API_FILE, .want = fresh.api },
        .{ .path = gen_api.FULL_FILE, .want = fresh.full },
    };
    for (pairs) |p| {
        const have = std.Io.Dir.cwd().readFileAlloc(io, p.path, gpa, .unlimited) catch {
            std.debug.print("  FAIL  {s}\n        {s} is missing\n", .{ API_RULE_NAME, p.path });
            stale += 1;
            continue;
        };
        defer gpa.free(have);
        if (!std.mem.eql(u8, have, p.want)) {
            std.debug.print("  FAIL  {s}\n        {s} is stale\n", .{ API_RULE_NAME, p.path });
            stale += 1;
        }
    }
    if (stale == 0) {
        std.debug.print("  PASS  {s}\n", .{API_RULE_NAME});
    } else {
        std.debug.print("        Regenerate with `zig build api` and commit the result.\n", .{});
    }
    return stale;
}

/// Every docs/migration-*.md must be linked from llms.txt.
fn auditMigrationLinks(gpa: std.mem.Allocator, io: Io) usize {
    const name = "every docs/migration-*.md is linked from llms.txt";
    const llms = std.Io.Dir.cwd().readFileAlloc(io, LLMS_TXT_FILE, gpa, .unlimited) catch return 1;
    defer gpa.free(llms);
    var dir = std.Io.Dir.cwd().openDir(io, "docs", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var bad: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, "migration-") or !std.mem.endsWith(u8, e.name, ".md")) continue;
        var buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "docs/{s}", .{e.name}) catch continue;
        if (std.mem.indexOf(u8, llms, needle) == null) {
            std.debug.print("  FAIL  {s}\n        not linked: {s}\n", .{ name, needle });
            bad += 1;
        }
    }
    if (bad == 0) std.debug.print("  PASS  {s}\n", .{name});
    return bad;
}

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

    const llms_hits = try auditLlmsTxt(gpa, io);
    defer freeHits(gpa, llms_hits);
    total_violations += reportLlmsTxt(llms_hits);

    const doc_hits = try auditDocDrift(gpa, io);
    defer freeHits(gpa, doc_hits);
    total_violations += reportRule(DOC_DRIFT_RULE, doc_hits);
    total_violations += auditApiReference(gpa, io);
    total_violations += auditMigrationLinks(gpa, io);

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

// ── Dedicated: llms.txt ↔ src/teak.zig re-export sync ──────────────
//
// Extract every column-zero `pub const NAME` from src/teak.zig (the file
// that defines what "public" means) and flag any NAME that is absent from
// llms.txt. Substring match is deliberately lenient: the goal is to catch a
// brand-new export that was never documented, not to police phrasing. A
// missing llms.txt is itself a single violation.

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Identifier following `pub const ` at the start of `line`, or null if the
/// line is not a column-zero `pub const` declaration.
fn reExportName(line: []const u8) ?[]const u8 {
    const prefix = "pub const ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    var end: usize = 0;
    while (end < rest.len and isIdentChar(rest[end])) : (end += 1) {}
    if (end == 0) return null;
    return rest[0..end];
}

fn addHit(gpa: std.mem.Allocator, hits: *std.ArrayList(Hit), path: []const u8, pattern: []const u8, text: []const u8) !void {
    try hits.append(gpa, .{
        .path = try gpa.dupe(u8, path),
        .line = 0,
        .pattern = pattern,
        .text = try gpa.dupe(u8, text),
    });
}

/// Every quoted name that follows `prefix` in `src` (e.g. `@hasDecl(App, "`
/// yields the hook names `run.zig` looks for). Deduplicated, order kept.
fn namesAfter(gpa: std.mem.Allocator, src: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, prefix)) |at| {
        const start = at + prefix.len;
        from = start;
        const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse break;
        const name = src[start..end];
        if (name.len == 0 or name.len > 48) continue;
        var seen = false;
        for (out.items) |n| {
            if (std.mem.eql(u8, n, name)) seen = true;
        }
        if (!seen) try out.append(gpa, name);
    }
}

fn readOpt(gpa: std.mem.Allocator, io: Io, path: []const u8) !?[]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// Require each of `names` to appear in backticks in `doc`.
fn requireNamed(gpa: std.mem.Allocator, hits: *std.ArrayList(Hit), what: []const u8, doc_path: []const u8, doc: []const u8, names: []const []const u8) !void {
    var buf: [64]u8 = undefined;
    for (names) |n| {
        const needle = std.fmt.bufPrint(&buf, "`{s}", .{n}) catch continue;
        if (std.mem.indexOf(u8, doc, needle) == null) {
            var msg: [160]u8 = undefined;
            const t = std.fmt.bufPrint(&msg, "{s} `{s}` is not documented in {s}", .{ what, n, doc_path }) catch n;
            try addHit(gpa, hits, doc_path, "undocumented", t);
        }
    }
}

fn auditDocDrift(gpa: std.mem.Allocator, io: Io) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |h| {
            gpa.free(h.path);
            gpa.free(h.text);
        }
        hits.deinit(gpa);
    }
    const cwd = Dir.cwd();

    // 1. Escape hatches: llms.txt's §2 list must carry every hatch HARDLINE defines.
    if (try readOpt(gpa, io, "docs/HARDLINE.md")) |hardline| {
        defer gpa.free(hardline);
        var n_hatches: usize = 0;
        var it = std.mem.splitScalar(u8, hardline, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "### Escape hatch ")) n_hatches += 1;
        }
        if (try readOpt(gpa, io, LLMS_TXT_FILE)) |llms| {
            defer gpa.free(llms);
            const sec_start = std.mem.indexOf(u8, llms, "### §2 Deliberate escape hatches") orelse 0;
            const sec_end = std.mem.indexOfPos(u8, llms, sec_start + 1, "\n## ") orelse llms.len;
            const sec = llms[sec_start..sec_end];
            var k: usize = 1;
            while (k <= n_hatches) : (k += 1) {
                var needle: [16]u8 = undefined;
                const nd = std.fmt.bufPrint(&needle, "\n{d}. ", .{k}) catch continue;
                if (std.mem.indexOf(u8, sec, nd) == null) {
                    var msg: [96]u8 = undefined;
                    const t = std.fmt.bufPrint(&msg, "HARDLINE defines {d} hatches; llms.txt §2 is missing #{d}", .{ n_hatches, k }) catch "hatch";
                    try addHit(gpa, &hits, LLMS_TXT_FILE, "hatch list", t);
                }
            }
        }
    }

    // 2. Examples: every examples/<dir> is listed in README.md.
    if (try readOpt(gpa, io, "README.md")) |readme| {
        defer gpa.free(readme);
        if (cwd.openDir(io, "examples", .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            defer dir.close(io);
            var di = dir.iterate();
            while (try di.next(io)) |e| {
                if (e.kind != .directory) continue;
                var buf: [96]u8 = undefined;
                const needle = std.fmt.bufPrint(&buf, "examples/{s}/", .{e.name}) catch continue;
                if (std.mem.indexOf(u8, readme, needle) == null) {
                    var msg: [128]u8 = undefined;
                    const t = std.fmt.bufPrint(&msg, "examples/{s} is not listed in README.md", .{e.name}) catch e.name;
                    try addHit(gpa, &hits, "README.md", "example list", t);
                }
            }
        } else |_| {}
    }

    // 2b. Orientation docs: every non-test src/**/*.zig is in CLAUDE.md's and
    // AGENTS.md's module tree (regenerate with tools/gen_tree.py).
    {
        const claude = try readOpt(gpa, io, "CLAUDE.md");
        defer if (claude) |b| gpa.free(b);
        const agents = try readOpt(gpa, io, "AGENTS.md");
        defer if (agents) |b| gpa.free(b);
        if (cwd.openDir(io, "src", .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                if (std.mem.endsWith(u8, entry.basename, "test.zig")) continue;
                if (std.mem.indexOf(u8, entry.path, "testdata") != null or std.mem.indexOf(u8, entry.path, "vendor") != null) continue;
                var needle_buf: [128]u8 = undefined;
                const needle = std.fmt.bufPrint(&needle_buf, "  {s} ", .{entry.basename}) catch continue;
                const docs = [_]struct { name: []const u8, text: ?[]u8 }{ .{ .name = "CLAUDE.md", .text = claude }, .{ .name = "AGENTS.md", .text = agents } };
                for (docs) |d| {
                    const t = d.text orelse continue;
                    if (std.mem.indexOf(u8, t, needle) == null) {
                        var msg: [200]u8 = undefined;
                        const txt = std.fmt.bufPrint(&msg, "src/{s} is missing from the {s} module tree (run python3 tools/gen_tree.py)", .{ entry.path, d.name }) catch entry.path;
                        try addHit(gpa, &hits, d.name, "module tree", txt);
                    }
                }
            }
        } else |_| {}
    }

    // 3. Optional surfaces the run loop probes: documented where readers look.
    const run_src = (try readOpt(gpa, io, "src/run.zig")) orelse return hits.toOwnedSlice(gpa);
    defer gpa.free(run_src);

    var hooks: std.ArrayList([]const u8) = .empty;
    defer hooks.deinit(gpa);
    try namesAfter(gpa, run_src, "@hasDecl(App, \"", &hooks);
    if (try readOpt(gpa, io, "docs/features/run.md")) |doc| {
        defer gpa.free(doc);
        try requireNamed(gpa, &hits, "App hook", "docs/features/run.md", doc, hooks.items);
    }

    var host_names: std.ArrayList([]const u8) = .empty;
    defer host_names.deinit(gpa);
    try namesAfter(gpa, run_src, "@hasDecl(Host, \"", &host_names);
    const host_src = try readOpt(gpa, io, "src/platform/host.zig");
    defer if (host_src) |b| gpa.free(b);
    if (host_src) |b| try namesAfter(gpa, b, ".name = \"", &host_names);
    if (try readOpt(gpa, io, "docs/features/host.md")) |doc| {
        defer gpa.free(doc);
        try requireNamed(gpa, &hits, "Host surface", "docs/features/host.md", doc, host_names.items);
    }

    var gpu_names: std.ArrayList([]const u8) = .empty;
    defer gpu_names.deinit(gpa);
    try namesAfter(gpa, run_src, "@hasDecl(Gpu, \"", &gpu_names);
    const gpu_src = try readOpt(gpa, io, "src/gpu/context.zig");
    defer if (gpu_src) |b| gpa.free(b);
    if (gpu_src) |b| try namesAfter(gpa, b, ".name = \"", &gpu_names);
    if (try readOpt(gpa, io, "docs/features/gpu.md")) |doc| {
        defer gpa.free(doc);
        try requireNamed(gpa, &hits, "Gpu surface", "docs/features/gpu.md", doc, gpu_names.items);
    }

    return hits.toOwnedSlice(gpa);
}

fn auditLlmsTxt(gpa: std.mem.Allocator, io: Io) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |h| {
            gpa.free(h.path);
            gpa.free(h.text);
        }
        hits.deinit(gpa);
    }

    const cwd = Dir.cwd();

    // A missing llms.txt is a single, loud violation.
    const llms = cwd.readFileAlloc(io, LLMS_TXT_FILE, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try hits.append(gpa, .{
                .path = try gpa.dupe(u8, LLMS_TXT_FILE),
                .line = 0,
                .pattern = "file missing",
                .text = try gpa.dupe(u8, "<llms.txt not found — create it per its header comment>"),
            });
            return hits.toOwnedSlice(gpa);
        },
        else => return err,
    };
    defer gpa.free(llms);

    const teak_src = cwd.readFileAlloc(io, TEAK_ROOT_FILE, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return hits.toOwnedSlice(gpa),
        else => return err,
    };
    defer gpa.free(teak_src);

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, teak_src, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const name = reExportName(line) orelse continue;
        if (std.mem.indexOf(u8, llms, name) == null) {
            try hits.append(gpa, .{
                .path = try gpa.dupe(u8, LLMS_TXT_FILE),
                .line = line_no,
                .pattern = "missing re-export",
                .text = try gpa.dupe(u8, name),
            });
        }
    }

    return hits.toOwnedSlice(gpa);
}

/// Custom reporter so a stale llms.txt fails with the missing names on one
/// line (matching llms.txt's own "regenerate per its header comment" note).
fn reportLlmsTxt(hits: []const Hit) usize {
    if (hits.len == 0) {
        std.debug.print("  PASS  {s}\n", .{LLMS_TXT_RULE.name});
        return 0;
    }
    std.debug.print("  FAIL  {s}\n", .{LLMS_TXT_RULE.name});
    std.debug.print("        ({s})\n", .{LLMS_TXT_RULE.reason});
    std.debug.print("        llms.txt is stale — missing: ", .{});
    for (hits, 0..) |h, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{h.text});
    }
    std.debug.print("\n        Regenerate per llms.txt's header comment " ++
        "(add each missing name to the \"Public API reference\" section).\n", .{});
    return hits.len;
}
