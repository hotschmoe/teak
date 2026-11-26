//! Background gates for every example: idle, input latency, idle memory and
//! binary size. `zig build gates [-- --examples a,b --only idle,latency,memory,size --update-budgets]`.
//! Policy and budgets: SRC.md and tools/ci_gates_budgets.json.

const std = @import("std");
const builtin = @import("builtin");

pub const default_out = "zig-out/gates/ci-gates.json";
pub const default_budgets = "tools/ci_gates_budgets.json";
pub const default_idle_frames: u32 = 125;
pub const default_latency_budget: u32 = 1;
pub const default_alert_pct: u64 = 10;

pub fn overBudget(measured: u64, budget: u64, pct: u64) bool {
    if (budget == 0) return false;
    return measured * 100 > budget * (100 + pct);
}

pub fn hostTriple() []const u8 {
    return @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
}

pub const LatencyCfg = struct {
    state: []const u8,
    x: f32,
    y: f32,
};

pub const ExampleCfg = struct {
    /// False: `initial` (or the first state) is the strict set.
    strict_explicit: bool = false,
    strict: []const []const u8 = &.{},
    expect_busy: []const []const u8 = &.{},
    expect_all_busy: bool = false,
    latency: ?LatencyCfg = null,
    wasm_brotli: u64 = 0,
    native_exe: u64 = 0,
    rss: u64 = 0,
    committed: u64 = 0,
    /// The budgets file has a `platforms` entry for this host triple.
    host_budgeted: bool = false,
};

pub fn listed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name) or std.mem.eql(u8, n, "*")) return true;
    return false;
}

pub fn idleOk(cfg: ExampleCfg, name: []const u8, ended_quiet: bool, fully_quiet: bool, strict_fallback: ?[]const u8) bool {
    if (cfg.expect_all_busy or listed(cfg.expect_busy, name)) return true;
    if (!ended_quiet) return false;
    const strict = if (cfg.strict_explicit)
        listed(cfg.strict, name)
    else if (strict_fallback) |fb|
        std.mem.eql(u8, fb, name)
    else
        false;
    if (strict) return fully_quiet;
    return true;
}

const Options = struct {
    zig: []const u8 = "zig",
    node: []const u8 = "node",
    out: []const u8 = default_out,
    budgets: []const u8 = default_budgets,
    examples: ?[]const u8 = null,
    only: ?[]const u8 = null,
    update: bool = false,
    idle_frames: ?u32 = null,
};

const Which = struct {
    idle: bool = true,
    latency: bool = true,
    memory: bool = true,
    size: bool = true,

    fn wantShot(self: Which) bool {
        return self.idle or self.latency or self.memory;
    }
};

const StateRow = struct {
    name: []const u8,
    frames: u32 = 0,
    busy: u32 = 0,
    presented: u32 = 0,
    blinks: u32 = 0,
    settled: bool = false,
    fully_quiet: bool = false,
    rewoke: bool = false,
    busy_at_end: bool = false,
    first_busy: ?u32 = null,
    ok: bool = true,
};

const ExResult = struct {
    name: []const u8,
    ok: bool = true,
    err: []const u8 = "",
    ran_shot: bool = false,
    ran_size: bool = false,
    states: []StateRow = &.{},
    idle_ok: bool = true,
    latency_skipped: bool = true,
    latency_ok: bool = true,
    latency_frames: u32 = 0,
    latency_unstable: bool = false,
    latency_unchanged: bool = false,
    latency_state: []const u8 = "",
    latency_x: f32 = 0,
    latency_y: f32 = 0,
    host_budgeted: bool = false,
    mem_unbudgeted: bool = true,
    mem_ok: bool = true,
    rss: u64 = 0,
    committed: u64 = 0,
    rss_budget: u64 = 0,
    committed_budget: u64 = 0,
    native_unbudgeted: bool = true,
    brotli_unbudgeted: bool = true,
    bin_ok: bool = true,
    native_ok: bool = true,
    brotli_ok: bool = true,
    native_bytes: u64 = 0,
    wasm_bytes: u64 = 0,
    brotli_bytes: u64 = 0,
    native_budget: u64 = 0,
    brotli_budget: u64 = 0,
};

const RunCfg = struct {
    alert_pct: u64 = default_alert_pct,
    idle_frames: u32 = default_idle_frames,
    latency_budget: u32 = default_latency_budget,
    root: std.json.Value = .null,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var o: Options = .{};
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--update-budgets")) {
            o.update = true;
        } else if (std.mem.eql(u8, a, "--zig")) {
            i += 1;
            o.zig = if (i < args.len) args[i] else return usage();
        } else if (std.mem.eql(u8, a, "--node")) {
            i += 1;
            o.node = if (i < args.len) args[i] else return usage();
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            o.out = if (i < args.len) args[i] else return usage();
        } else if (std.mem.eql(u8, a, "--budgets")) {
            i += 1;
            o.budgets = if (i < args.len) args[i] else return usage();
        } else if (std.mem.eql(u8, a, "--examples")) {
            i += 1;
            o.examples = if (i < args.len) args[i] else return usage();
        } else if (std.mem.eql(u8, a, "--only")) {
            i += 1;
            o.only = if (i < args.len) args[i] else return usage();
        } else if (std.mem.eql(u8, a, "--idle-frames")) {
            i += 1;
            if (i >= args.len) return usage();
            o.idle_frames = std.fmt.parseInt(u32, args[i], 10) catch return usage();
        } else return usage();
    }
    const which = parseWhich(o.only);

    var cfg = try loadRunCfg(arena, io, o.budgets);
    if (o.idle_frames) |n| cfg.idle_frames = n;

    const zig_ver = try zigVersion(arena, io, o.zig);
    const triple = hostTriple();
    const examples = try listExamples(arena, io, o);

    if (std.mem.lastIndexOfScalar(u8, o.out, '/')) |slash| {
        try std.Io.Dir.cwd().createDirPath(io, o.out[0..slash]);
    }

    var results: std.ArrayList(ExResult) = .empty;
    defer results.deinit(arena);
    var all_ok = true;
    for (examples) |ex| {
        const r = runExample(arena, io, o, cfg, which, triple, ex) catch |e| blk: {
            std.debug.print("[gates] {s}: {s}\n", .{ ex, @errorName(e) });
            break :blk ExResult{ .name = ex, .ok = false, .err = @errorName(e) };
        };
        if (!r.ok) all_ok = false;
        try results.append(arena, r);
        printRow(r);
    }
    printUnbudgeted(triple, o.budgets, results.items);

    if (o.update) {
        try updateBudgets(arena, io, o.budgets, triple, results.items);
        std.debug.print("[gates] updated {s} for {s}\n", .{ o.budgets, triple });
    }

    const body = try renderReport(arena, triple, zig_ver, cfg, results.items, all_ok);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = o.out, .data = body });
    std.debug.print("[gates] wrote {s} ({s})\n", .{ o.out, if (all_ok) "ok" else "FAILED" });
    if (!all_ok) return error.GateFailed;
}

fn usage() error{BadArgs} {
    std.debug.print("usage: ci-gates [--examples a,b] [--only idle,latency,memory,size] [--out path] [--budgets path] [--idle-frames N] [--update-budgets] [--zig path] [--node path]\n", .{});
    return error.BadArgs;
}

fn parseWhich(only: ?[]const u8) Which {
    const spec = only orelse return .{};
    return .{
        .idle = hasToken(spec, "idle"),
        .latency = hasToken(spec, "latency"),
        .memory = hasToken(spec, "memory"),
        .size = hasToken(spec, "size"),
    };
}

fn hasToken(spec: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

fn printRow(r: ExResult) void {
    if (r.err.len > 0) {
        std.debug.print("[gates] {s}: ERROR {s}\n", .{ r.name, r.err });
        return;
    }
    std.debug.print("[gates] {s}: idle {s}, latency {s}, memory {s}, native size {s}, wasm size {s}\n", .{
        r.name,
        if (!r.ran_shot) "not run" else if (r.idle_ok) "ok" else "FAIL",
        if (r.latency_skipped) "not run" else if (r.latency_ok) "ok" else "FAIL",
        verdict(r.ran_shot, r.mem_unbudgeted, r.mem_ok),
        verdict(r.ran_size, r.native_unbudgeted, r.native_ok),
        verdict(r.ran_size, r.brotli_unbudgeted, r.brotli_ok),
    });
}

fn verdict(ran: bool, unbudgeted: bool, ok: bool) []const u8 {
    if (!ran) return "not run";
    if (unbudgeted) return "SKIPPED (no budget)";
    return if (ok) "ok" else "FAIL";
}

fn printUnbudgeted(triple: []const u8, budgets: []const u8, results: []const ExResult) void {
    var missing: usize = 0;
    for (results) |r| {
        if (r.err.len == 0 and !r.host_budgeted) missing += 1;
    }
    if (missing == 0) return;
    std.debug.print("[gates] {s} has no {s} budgets for {d} of {d} examples: their native exe size and idle memory were measured and SKIPPED, not gated\n", .{ budgets, triple, missing, results.len });
}

fn runExample(
    arena: std.mem.Allocator,
    io: std.Io,
    o: Options,
    cfg: RunCfg,
    which: Which,
    triple: []const u8,
    ex: []const u8,
) !ExResult {
    var r: ExResult = .{ .name = ex };
    const ecfg = try exampleCfg(arena, cfg.root, ex, triple);
    r.rss_budget = ecfg.rss;
    r.committed_budget = ecfg.committed;
    r.native_budget = ecfg.native_exe;
    r.brotli_budget = ecfg.wasm_brotli;
    r.host_budgeted = ecfg.host_budgeted;
    const dir = try std.fmt.allocPrint(arena, "examples/{s}", .{ex});

    if (which.wantShot()) {
        std.debug.print("[gates] {s}: shot (idle / latency / memory)\n", .{ex});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, o.zig);
        try argv.append(arena, "build");
        try argv.append(arena, "shot");
        try argv.append(arena, "-Doptimize=ReleaseSmall");
        try argv.append(arena, "--");
        try argv.append(arena, "--gates-json");
        try argv.append(arena, "--idle-frames");
        try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{cfg.idle_frames}));
        try argv.append(arena, "--state");
        try argv.append(arena, "*");
        if (which.latency) {
            if (ecfg.latency) |lat| {
                try argv.append(arena, "--latency-check");
                try argv.append(arena, try std.fmt.allocPrint(arena, "{d},{d}", .{ lat.x, lat.y }));
                try argv.append(arena, "--latency-state");
                try argv.append(arena, lat.state);
            }
        }
        const res = try std.process.run(arena, io, .{ .argv = argv.items, .cwd = .{ .path = dir } });
        if (!exitedOk(res.term)) {
            r.ok = false;
            r.err = try std.fmt.allocPrint(arena, "shot failed: {s}", .{clip(res.stderr)});
            return r;
        }
        const slice = jsonObject(res.stdout) orelse {
            r.ok = false;
            r.err = "shot stdout had no JSON object";
            return r;
        };
        try fillShot(arena, &r, slice, ecfg, cfg, which);
        r.ran_shot = true;
    }

    if (which.size) {
        std.debug.print("[gates] {s}: ui-install + web\n", .{ex});
        const ui = try std.process.run(arena, io, .{
            .argv = &.{ o.zig, "build", "ui-install", "-Doptimize=ReleaseSmall" },
            .cwd = .{ .path = dir },
        });
        if (!exitedOk(ui.term)) {
            r.ok = false;
            r.bin_ok = false;
            r.err = try std.fmt.allocPrint(arena, "ui-install failed: {s}", .{clip(ui.stderr)});
            return r;
        }
        const native = try std.fmt.allocPrint(arena, "{s}/zig-out/bin/{s}-ui", .{ dir, ex });
        r.native_bytes = fileSize(io, native) catch fileSize(io, try std.fmt.allocPrint(arena, "{s}.exe", .{native})) catch 0;
        if (r.native_bytes == 0) {
            r.ok = false;
            r.bin_ok = false;
            r.err = "native ui exe missing after ui-install";
            return r;
        }

        const web_main = try std.fmt.allocPrint(arena, "{s}/src/web_main.zig", .{dir});
        if (std.Io.Dir.cwd().access(io, web_main, .{})) |_| {
            const web = try std.process.run(arena, io, .{
                .argv = &.{ o.zig, "build", "-Dweb-optimize=ReleaseSmall", "web" },
                .cwd = .{ .path = dir },
            });
            if (!exitedOk(web.term)) {
                r.ok = false;
                r.bin_ok = false;
                r.err = try std.fmt.allocPrint(arena, "web build failed: {s}", .{clip(web.stderr)});
                return r;
            }
            const wasm = try wasmPath(arena, io, dir, ex);
            r.wasm_bytes = try fileSize(io, wasm);
            r.brotli_bytes = try brotliLen(arena, io, o.node, wasm);
        } else |_| {
            std.debug.print("[gates] {s}: no web target, wasm size not measured\n", .{ex});
        }
        r.ran_size = true;

        r.native_unbudgeted = ecfg.native_exe == 0;
        r.brotli_unbudgeted = ecfg.wasm_brotli == 0;
        r.native_ok = !overBudget(r.native_bytes, ecfg.native_exe, cfg.alert_pct);
        r.brotli_ok = !overBudget(r.brotli_bytes, ecfg.wasm_brotli, cfg.alert_pct);
        r.bin_ok = r.native_ok and r.brotli_ok;
        if (!r.bin_ok) r.ok = false;
    }
    return r;
}

fn fillShot(arena: std.mem.Allocator, r: *ExResult, text: []const u8, ecfg: ExampleCfg, cfg: RunCfg, which: Which) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    const root = parsed.value;
    if (root != .object) return error.BadShotJson;
    const mem = root.object.get("memory") orelse return error.BadShotJson;
    r.rss = intOf(mem.object.get("rss_bytes"));
    r.committed = intOf(mem.object.get("committed_bytes"));
    r.mem_unbudgeted = ecfg.rss == 0 and ecfg.committed == 0;
    const rss_over = overBudget(r.rss, ecfg.rss, cfg.alert_pct);
    const com_over = overBudget(r.committed, ecfg.committed, cfg.alert_pct);
    r.mem_ok = !rss_over and !com_over;
    if (which.memory and !r.mem_ok) r.ok = false;

    const states_v = root.object.get("states") orelse return error.BadShotJson;
    if (states_v != .array) return error.BadShotJson;
    const rows = try arena.alloc(StateRow, states_v.array.items.len);
    for (states_v.array.items, 0..) |item, n| {
        if (item != .object) return error.BadShotJson;
        const name_v = item.object.get("name") orelse return error.BadShotJson;
        if (name_v != .string) return error.BadShotJson;
        var row: StateRow = .{ .name = try arena.dupe(u8, name_v.string) };
        row.frames = u32Of(item.object.get("frames"));
        row.busy = u32Of(item.object.get("busy"));
        row.presented = u32Of(item.object.get("presented"));
        row.blinks = u32Of(item.object.get("blinks"));
        row.settled = boolOf(item.object.get("settled"));
        row.fully_quiet = boolOf(item.object.get("fully_quiet"));
        row.rewoke = boolOf(item.object.get("rewoke"));
        row.busy_at_end = boolOf(item.object.get("busy_at_end"));
        if (item.object.get("first_busy")) |fb| if (fb == .integer) {
            row.first_busy = u32Of(fb);
        };
        rows[n] = row;
    }
    const fallback: ?[]const u8 = if (ecfg.strict_explicit) null else blk: {
        for (rows) |row| if (std.mem.eql(u8, row.name, "initial")) break :blk row.name;
        break :blk if (rows.len > 0) rows[0].name else null;
    };
    r.idle_ok = true;
    for (rows) |*row| {
        row.ok = idleOk(ecfg, row.name, !row.busy_at_end, row.fully_quiet, fallback);
        if (!row.ok) r.idle_ok = false;
    }
    r.states = rows;
    if (which.idle and !r.idle_ok) r.ok = false;

    r.latency_skipped = true;
    r.latency_ok = true;
    if (which.latency) {
        if (ecfg.latency) |lat| {
            r.latency_skipped = false;
            r.latency_state = lat.state;
            r.latency_x = lat.x;
            r.latency_y = lat.y;
            const lv = root.object.get("latency") orelse return error.BadShotJson;
            if (lv != .object) {
                r.latency_ok = false;
                r.ok = false;
            } else {
                r.latency_frames = u32Of(lv.object.get("frames"));
                r.latency_unstable = boolOf(lv.object.get("unstable"));
                r.latency_unchanged = boolOf(lv.object.get("unchanged"));
                const pass = !r.latency_unstable and !r.latency_unchanged and r.latency_frames == cfg.latency_budget;
                r.latency_ok = pass;
                if (!pass) r.ok = false;
            }
        }
    }
}

fn loadRunCfg(arena: std.mem.Allocator, io: std.Io, path: []const u8) !RunCfg {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20)) catch |e| {
        std.debug.print("ci-gates: cannot read budgets {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    var cfg: RunCfg = .{ .root = root };
    if (root == .object) {
        const pct = intOf(root.object.get("alert_over_pct"));
        if (pct != 0) cfg.alert_pct = pct;
        const frames = u32Of(root.object.get("idle_frames"));
        if (frames != 0) cfg.idle_frames = frames;
        const lat = u32Of(root.object.get("latency_budget_frames"));
        if (lat != 0) cfg.latency_budget = lat;
    }
    return cfg;
}

fn exampleCfg(arena: std.mem.Allocator, root: std.json.Value, name: []const u8, triple: []const u8) !ExampleCfg {
    if (root != .object) return .{};
    const examples = root.object.get("examples") orelse return .{};
    if (examples != .object) return .{};
    const ex = examples.object.get(name) orelse return .{};
    if (ex != .object) return .{};
    var cfg: ExampleCfg = .{};
    if (ex.object.get("strict_states")) |v| {
        cfg.strict_explicit = true;
        cfg.strict = try stringsOf(arena, v);
    }
    if (ex.object.get("expect_busy")) |v| {
        cfg.expect_busy = try stringsOf(arena, v);
        cfg.expect_all_busy = listed(cfg.expect_busy, "*");
    }
    if (ex.object.get("latency")) |v| switch (v) {
        .null => {},
        .object => {
            const state_v = v.object.get("state") orelse return error.BadBudgets;
            if (state_v != .string) return error.BadBudgets;
            cfg.latency = .{
                .state = try arena.dupe(u8, state_v.string),
                .x = floatOf(v.object.get("x") orelse return error.BadBudgets),
                .y = floatOf(v.object.get("y") orelse return error.BadBudgets),
            };
        },
        else => return error.BadBudgets,
    };
    cfg.wasm_brotli = intOf(ex.object.get("wasm_brotli_bytes"));
    if (ex.object.get("platforms")) |p| if (p == .object) {
        if (p.object.get(triple)) |plat| if (plat == .object) {
            cfg.host_budgeted = true;
            cfg.native_exe = intOf(plat.object.get("native_exe_bytes"));
            cfg.rss = intOf(plat.object.get("rss_bytes"));
            cfg.committed = intOf(plat.object.get("committed_bytes"));
        };
    };
    return cfg;
}

fn stringsOf(arena: std.mem.Allocator, v: std.json.Value) ![]const []const u8 {
    if (v != .array) return error.BadBudgets;
    const out = try arena.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, n| {
        if (item != .string) return error.BadBudgets;
        out[n] = try arena.dupe(u8, item.string);
    }
    return out;
}

fn intOf(v: ?std.json.Value) u64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |n| if (n > 0) @intCast(n) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn u32Of(v: ?std.json.Value) u32 {
    return std.math.cast(u32, intOf(v)) orelse 0;
}

fn floatOf(v: std.json.Value) f32 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| @floatCast(f),
        else => 0,
    };
}

fn boolOf(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return switch (x) {
        .bool => |b| b,
        else => false,
    };
}

fn jsonObject(s: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, s, '{') orelse return null;
    const b = std.mem.lastIndexOfScalar(u8, s, '}') orelse return null;
    if (b < a) return null;
    return s[a .. b + 1];
}

fn exitedOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn clip(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \r\n\t");
    if (t.len <= 400) return t;
    return t[t.len - 400 ..];
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    return st.size;
}

fn wasmPath(arena: std.mem.Allocator, io: std.Io, dir: []const u8, ex: []const u8) ![]const u8 {
    const candidates = [_][]const u8{
        try std.fmt.allocPrint(arena, "{s}/dist/app.wasm", .{dir}),
        try std.fmt.allocPrint(arena, "{s}/dist/{s}-web.wasm", .{ dir, ex }),
    };
    for (candidates) |p| {
        if (fileSize(io, p) catch null) |_| return p;
    }
    std.debug.print("[gates] {s}: no wasm under dist/\n", .{ex});
    return error.WasmMissing;
}

fn brotliLen(arena: std.mem.Allocator, io: std.Io, node: []const u8, path: []const u8) !u64 {
    const js =
        \\const fs = require("fs");
        \\const zlib = require("zlib");
        \\const b = fs.readFileSync(process.argv[1]);
        \\const c = zlib.brotliCompressSync(b, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } });
        \\process.stdout.write(c);
    ;
    const r = try std.process.run(arena, io, .{ .argv = &.{ node, "-e", js, "--", path } });
    if (!exitedOk(r.term)) {
        std.debug.print("brotli: {s}\n", .{clip(r.stderr)});
        return error.BrotliFailed;
    }
    return r.stdout.len;
}

fn zigVersion(arena: std.mem.Allocator, io: std.Io, zig: []const u8) ![]const u8 {
    const r = try std.process.run(arena, io, .{ .argv = &.{ zig, "version" } });
    if (!exitedOk(r.term)) return "unknown";
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \r\n\t"));
}

fn listExamples(arena: std.mem.Allocator, io: std.Io, o: Options) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const shot = try std.fmt.allocPrint(arena, "{s}/src/shot_main.zig", .{e.name});
        dir.access(io, shot, .{}) catch continue;
        if (o.examples) |want| if (!hasToken(want, e.name)) continue;
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

fn renderReport(
    arena: std.mem.Allocator,
    triple: []const u8,
    zig_ver: []const u8,
    cfg: RunCfg,
    results: []const ExResult,
    all_ok: bool,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var j: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try j.beginObject();
    try field(&j, "schema");
    try j.write(1);
    try field(&j, "host");
    try j.write(triple);
    try field(&j, "zig");
    try j.write(zig_ver);
    try field(&j, "alert_over_pct");
    try j.write(cfg.alert_pct);
    try field(&j, "idle_frames");
    try j.write(cfg.idle_frames);
    try field(&j, "latency_budget_frames");
    try j.write(cfg.latency_budget);
    try field(&j, "ok");
    try j.write(all_ok);
    try field(&j, "notes");
    try j.write("rss_bytes, committed_bytes and native_exe_bytes depend on the host triple and the GPU that loaded. wasm_brotli_bytes is wasm32 ReleaseSmall compressed with brotli quality 11 and should match across hosts on the same Zig. committed_bytes is RssAnon+VmSwap from /proc/self/status. The native exe is unstripped ReleaseSmall. A zero or missing budget is unbudgeted: the value is reported and its gate is skipped.");
    try field(&j, "examples");
    try j.beginArray();
    for (results) |r| {
        try j.beginObject();
        try field(&j, "name");
        try j.write(r.name);
        try field(&j, "ok");
        try j.write(r.ok);
        try field(&j, "error");
        if (r.err.len == 0) try j.write(null) else try j.write(r.err);
        try field(&j, "idle");
        try j.beginObject();
        try field(&j, "ok");
        try j.write(r.idle_ok);
        try field(&j, "states");
        try j.beginArray();
        for (r.states) |s| {
            try j.beginObject();
            try field(&j, "name");
            try j.write(s.name);
            try field(&j, "frames");
            try j.write(s.frames);
            try field(&j, "busy");
            try j.write(s.busy);
            try field(&j, "presented");
            try j.write(s.presented);
            try field(&j, "blinks");
            try j.write(s.blinks);
            try field(&j, "settled");
            try j.write(s.settled);
            try field(&j, "fully_quiet");
            try j.write(s.fully_quiet);
            try field(&j, "rewoke");
            try j.write(s.rewoke);
            try field(&j, "busy_at_end");
            try j.write(s.busy_at_end);
            try field(&j, "first_busy");
            if (s.first_busy) |b| try j.write(b) else try j.write(null);
            try field(&j, "ok");
            try j.write(s.ok);
            try j.endObject();
        }
        try j.endArray();
        try j.endObject();
        try field(&j, "latency");
        try j.beginObject();
        try field(&j, "skipped");
        try j.write(r.latency_skipped);
        try field(&j, "ok");
        try j.write(r.latency_ok);
        try field(&j, "frames");
        try j.write(r.latency_frames);
        try field(&j, "budget");
        try j.write(cfg.latency_budget);
        try field(&j, "unstable");
        try j.write(r.latency_unstable);
        try field(&j, "unchanged");
        try j.write(r.latency_unchanged);
        try field(&j, "state");
        try j.write(r.latency_state);
        try field(&j, "x");
        try j.write(r.latency_x);
        try field(&j, "y");
        try j.write(r.latency_y);
        try j.endObject();
        try field(&j, "memory");
        try j.beginObject();
        try field(&j, "ok");
        try j.write(r.mem_ok);
        try field(&j, "unbudgeted");
        try j.write(r.mem_unbudgeted);
        try field(&j, "host_budgeted");
        try j.write(r.host_budgeted);
        try field(&j, "rss_bytes");
        try j.write(r.rss);
        try field(&j, "committed_bytes");
        try j.write(r.committed);
        try field(&j, "rss_budget");
        try j.write(r.rss_budget);
        try field(&j, "committed_budget");
        try j.write(r.committed_budget);
        try j.endObject();
        try field(&j, "binary");
        try j.beginObject();
        try field(&j, "ok");
        try j.write(r.bin_ok);
        try field(&j, "native_exe_bytes");
        try j.write(r.native_bytes);
        try field(&j, "native_budget");
        try j.write(r.native_budget);
        try field(&j, "native_unbudgeted");
        try j.write(r.native_unbudgeted);
        try field(&j, "wasm_bytes");
        try j.write(r.wasm_bytes);
        try field(&j, "wasm_brotli_bytes");
        try j.write(r.brotli_bytes);
        try field(&j, "wasm_brotli_budget");
        try j.write(r.brotli_budget);
        try field(&j, "wasm_unbudgeted");
        try j.write(r.brotli_unbudgeted);
        try j.endObject();
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

fn field(j: *std.json.Stringify, name: []const u8) !void {
    try j.objectField(name);
}

fn updateBudgets(arena: std.mem.Allocator, io: std.Io, path: []const u8, triple: []const u8, results: []const ExResult) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20));
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadBudgets;
    const examples_v = parsed.value.object.getPtr("examples") orelse return error.BadBudgets;
    if (examples_v.* != .object) return error.BadBudgets;
    for (results) |r| {
        if (r.err.len > 0) continue;
        const ev = examples_v.object.getPtr(r.name) orelse continue;
        if (ev.* != .object) continue;
        if (r.ran_size and r.brotli_bytes != 0) try putInt(arena, &ev.object, "wasm_brotli_bytes", r.brotli_bytes);
        if (r.native_bytes == 0 and r.rss == 0 and r.committed == 0) continue;
        const plats = try ensureObj(arena, &ev.object, "platforms");
        const host = try ensureObj(arena, &plats.object, triple);
        if (r.native_bytes != 0) try putInt(arena, &host.object, "native_exe_bytes", r.native_bytes);
        if (r.rss != 0) try putInt(arena, &host.object, "rss_bytes", r.rss);
        if (r.committed != 0) try putInt(arena, &host.object, "committed_bytes", r.committed);
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

fn ensureObj(arena: std.mem.Allocator, map: *std.json.ObjectMap, key: []const u8) !*std.json.Value {
    if (map.getPtr(key)) |v| {
        if (v.* != .object) v.* = .{ .object = .empty };
        return v;
    }
    const owned = try arena.dupe(u8, key);
    try map.put(arena, owned, .{ .object = .empty });
    return map.getPtr(owned).?;
}

fn putInt(arena: std.mem.Allocator, map: *std.json.ObjectMap, key: []const u8, n: u64) !void {
    const v: std.json.Value = .{ .integer = @intCast(n) };
    if (map.getPtr(key)) |slot| {
        slot.* = v;
        return;
    }
    try map.put(arena, try arena.dupe(u8, key), v);
}
