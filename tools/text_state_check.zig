//! See SRC.md, tools/text_state_check.zig.
const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");
const assert = teak.assert;

const fonts = [_][]const u8{
    @embedFile("font-plex-sub"),
    @embedFile("font-plex-accents"),
    @embedFile("font-plex-marks"),
    @embedFile("font-quicksand"),
    @embedFile("font-quicksand-nolig"),
};
const family_count: u8 = std.enums.values(teak.FontFamily).len;
const weight_count: u8 = std.enums.values(teak.FontWeight).len;
const ops_max: u32 = 360;
const text_bytes_max: u32 = 160;
const glyphs_max: u32 = 64;
const explicit_max: u8 = 4;
const recent_max: u32 = 16;
const states_max: u32 = 2;

const sizes = [_]f32{ 9, 11.5, 12, 14, 16.25, 24, 31 };
const spacings = [_]f32{ 0, 0, 0, 0, 0.5, -0.25, 1 };
const words = [_][]const u8{
    "office",                "affluent",                     "waffle",
    "fifty",                 "flow",                         "The",
    "quick",                 "brown",                        "Typography",
    "AVAWAY",                "Te",                           "To.",
    "1234567890",            "x",                            "-",
    "caf\u{e9}",             "cafe\u{301}",                  "na\u{ef}ve",
    "\u{391}\u{3b2}\u{3b3}", "\u{41f}\u{440}\u{438}\u{432}", "\u{5e9}\u{5dc}\u{5d5}\u{5dd}",
    "\u{4e2d}\u{6587}",      "\u{1f600}",                    "\u{200b}",
    "a\u{300}\u{301}",       "\xff\xfe",                     "\xe4\xb8",
};

pub const std_options: std.Options = .{ .log_level = .err };

const Query = struct {
    bytes: [text_bytes_max]u8,
    len: u8,
    family: u8,
    weight: u8,
    snap: u8,
    rtl: bool,
    size_px: f32,
    letter_spacing: f32,
    out_len: u8,

    fn spec(self: *const Query) teak.FontSpec {
        assert(self.family < family_count and self.weight < weight_count);
        assert(self.size_px > 0);
        const snap: ?bool = if (self.snap == 0) null else self.snap == 2;
        return .{
            .size_px = self.size_px,
            .family = @fromBackingInt(self.family),
            .weight = @fromBackingInt(self.weight),
            .letter_spacing = self.letter_spacing,
            .snap_advance = snap,
            .rtl = self.rtl,
        };
    }

    fn slice(self: *const Query) []const u8 {
        assert(self.len <= text_bytes_max);
        assert(self.len > 0);
        return self.bytes[0..self.len];
    }
};

const Register = struct { family: u8, weight: u8, font: u8 };
const Op = union(enum) {
    register: Register,
    release,
    fallback_bytes: u8,
    fallback_face: u8,
    measure: Query,
    shape: Query,
};

fn word_number(rng: std.Random, out: *[8]u8) []const u8 {
    var value: u32 = rng.int(u16);
    out[0] = 'n';
    var len: u32 = 1;
    for (0..6) |_| {
        const digit: u8 = @intCast(value % 10);
        out[len] = '0' + digit;
        len += 1;
        value /= 10;
        if (value == 0) break;
    }
    assert(len >= 2 and len <= out.len);
    assert(out[0] == 'n');
    return out[0..len];
}

fn compose(rng: std.Random, buf: *[text_bytes_max]u8) u8 {
    var len: u32 = 0;
    var number: [8]u8 = undefined;
    const count = 1 + rng.uintLessThan(u32, 14);
    assert(count >= 1 and count <= 14);
    for (0..count) |_| {
        const word = if (rng.uintLessThan(u32, 8) == 0)
            word_number(rng, &number)
        else
            words[rng.uintLessThan(u32, words.len)];
        const gap: u32 = if (len > 0) 1 else 0;
        if (len + gap + word.len > text_bytes_max) break;
        if (gap == 1) buf[len] = ' ';
        @memcpy(buf[len + gap ..][0..word.len], word);
        len += gap + @as(u32, @intCast(word.len));
    }
    assert(len > 0 and len <= text_bytes_max);
    return @intCast(len);
}

fn random_query(rng: std.Random) Query {
    var query: Query = undefined;
    query.len = compose(rng, &query.bytes);
    assert(query.len > 0);
    query.family = rng.uintLessThan(u8, family_count);
    query.weight = rng.uintLessThan(u8, weight_count);
    query.snap = rng.uintLessThan(u8, 3);
    query.rtl = rng.uintLessThan(u32, 8) == 0;
    query.size_px = sizes[rng.uintLessThan(u32, sizes.len)];
    query.letter_spacing = spacings[rng.uintLessThan(u32, spacings.len)];
    query.out_len = 1 + rng.uintLessThan(u8, glyphs_max);
    assert(query.out_len >= 1 and query.out_len <= glyphs_max);
    assert(query.family < family_count and query.weight < weight_count);
    return query;
}

fn random_op(rng: std.Random, recent: *[recent_max]Query, recent_len: *u32) Op {
    assert(recent_len.* <= recent_max);
    const pick = rng.uintLessThan(u32, 100);
    if (pick < 14) return .{ .register = .{
        .family = rng.uintLessThan(u8, family_count),
        .weight = rng.uintLessThan(u8, weight_count),
        .font = rng.uintLessThan(u8, fonts.len),
    } };
    if (pick < 16) return .release;
    if (pick < 19) return .{ .fallback_face = rng.uintLessThan(u8, fonts.len) };
    var query = random_query(rng);
    if (recent_len.* > 0 and rng.uintLessThan(u32, 100) < 35) {
        query = recent[rng.uintLessThan(u32, recent_len.*)];
    }
    recent[recent_len.* % recent_max] = query;
    recent_len.* = @min(recent_len.* + 1, recent_max);
    assert(recent_len.* >= 1 and recent_len.* <= recent_max);
    return if (pick < 60) .{ .measure = query } else .{ .shape = query };
}

fn generate(seed: u64, ops: []Op) void {
    assert(ops.len > family_count + 2);
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var recent: [recent_max]Query = undefined;
    var recent_len: u32 = 0;
    for (ops, 0..) |*op, index| {
        if (index < family_count) {
            const font = rng.uintLessThan(u8, fonts.len);
            op.* = .{ .register = .{ .family = @intCast(index), .weight = 0, .font = font } };
        } else if (index == family_count and rng.boolean()) {
            op.* = .{ .fallback_bytes = rng.uintLessThan(u8, fonts.len) };
        } else {
            op.* = random_op(rng, &recent, &recent_len);
        }
    }
    assert(ops[0] == .register);
}

const Failure = struct { state: u8, op: u32, what: []const u8 };
const Verdict = struct { schedule: []const u8, failure: Failure };

const Model = struct {
    faces: [family_count][weight_count]i8 = @splat(@splat(-1)),
    fallback_font: i8 = -1,
    explicit: u8 = 0,

    fn expect(self: *const Model, family: u8, weight: u8) i8 {
        assert(family < family_count and weight < weight_count);
        var best: i8 = -1;
        var best_distance: u8 = 255;
        for (self.faces[family], 0..) |font, index| {
            if (font < 0) continue;
            const slot: u8 = @intCast(index);
            const distance = if (slot > weight) slot - weight else weight - slot;
            if (distance < best_distance) {
                best = font;
                best_distance = distance;
            }
        }
        if (best >= 0) return best;
        assert(best == -1);
        if (self.fallback_font >= 0) return self.fallback_font;
        for (self.faces) |row| {
            for (row) |font| if (font >= 0) return font;
        }
        return -1;
    }
};

fn bits(value: f32) u64 {
    return @as(u32, @bitCast(value));
}

fn digest(values: []const u64) u64 {
    assert(values.len > 0);
    assert(values.len <= 8);
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(values));
}

fn oracle_width(state: *text.TextState, bytes: []const u8, font: teak.FontSpec) f32 {
    assert(bytes.len <= text_bytes_max);
    assert(state.measure.slots.len >= 2);
    return text.width(state, bytes, font);
}

fn oracle_metrics(state: *text.TextState, bytes: []const u8, font: teak.FontSpec) teak.TextMetrics {
    const size = font.size_px;
    assert(size > 0);
    const resolved = text.face.resolveFace(state, font.family, font.weight) orelse
        return .{ .width = 0, .height = size, .ascent = size * 0.75, .descent = size * 0.25 };
    const vertical = resolved.face.vMetrics(size);
    assert(resolved.id <= text.face.fallback_face_id);
    return .{
        .width = oracle_width(state, bytes, font),
        .height = vertical.ascent + vertical.descent,
        .ascent = vertical.ascent,
        .descent = vertical.descent,
    };
}

fn same_metrics(a: teak.TextMetrics, b: teak.TextMetrics) bool {
    return bits(a.width) == bits(b.width) and bits(a.height) == bits(b.height) and
        bits(a.ascent) == bits(b.ascent) and bits(a.descent) == bits(b.descent);
}

const Player = struct {
    state: *text.TextState,
    model: Model = .{},
    what: []const u8 = "",

    fn fail(self: *Player, what: []const u8) error{CheckFailed} {
        assert(what.len > 0);
        assert(self.what.len == 0);
        self.what = what;
        return error.CheckFailed;
    }

    fn step(self: *Player, op: *const Op) error{CheckFailed}!u64 {
        return switch (op.*) {
            .register => |r| self.do_register(r),
            .release => self.do_release(),
            .fallback_bytes => |font| self.do_fallback_bytes(font),
            .fallback_face => |font| self.do_fallback_face(font),
            .measure => |*query| self.do_measure(query),
            .shape => |*query| self.do_shape(query),
        };
    }

    fn check_face(self: *Player, family: u8, weight: u8) error{CheckFailed}!void {
        assert(family < family_count and weight < weight_count);
        const want = self.model.expect(family, weight);
        assert(want < @as(i8, fonts.len));
        const got = text.faceFor(self.state, @fromBackingInt(family), @fromBackingInt(weight));
        if (want < 0) {
            if (got != null) return self.fail("a face exists that nothing registered");
            return;
        }
        const face = got orelse return self.fail("no face for a registered request");
        const bytes = fonts[@intCast(want)];
        if (face.data.ptr != bytes.ptr) return self.fail("face is not the one registered");
    }

    fn do_register(self: *Player, r: Register) error{CheckFailed}!u64 {
        assert(r.font < fonts.len);
        const family: teak.FontFamily = @fromBackingInt(r.family);
        const weight: teak.FontWeight = @fromBackingInt(r.weight);
        text.registerFace(self.state, family, weight, fonts[r.font]) catch
            return self.fail("registerFace refused a valid font");
        self.model.faces[r.family][r.weight] = @intCast(r.font);
        assert(self.model.faces[r.family][r.weight] >= 0);
        try self.check_face(r.family, r.weight);
        return digest(&.{ 1, self.state.faces.epoch });
    }

    fn do_release(self: *Player) error{CheckFailed}!u64 {
        const before = self.state.faces.epoch;
        text.releaseFaces(self.state);
        assert(self.state.faces.epoch > before);
        self.model.faces = @splat(@splat(-1));
        self.model.explicit = 0;
        try self.check_face(0, 0);
        return digest(&.{ 2, self.state.faces.epoch });
    }

    fn do_fallback_bytes(self: *Player, font: u8) error{CheckFailed}!u64 {
        assert(font < fonts.len);
        text.face.setFallbackBytes(self.state, fonts[font]);
        self.model.fallback_font = @intCast(font);
        assert(self.model.fallback_font >= 0);
        return digest(&.{ 3, self.state.faces.epoch });
    }

    fn do_fallback_face(self: *Player, font: u8) error{CheckFailed}!u64 {
        assert(font < fonts.len);
        const room = self.model.explicit < explicit_max;
        const result = text.registerFallbackFace(self.state, fonts[font]);
        const accepted = if (result) |_| true else |err| blk: {
            if (room or err != error.ChainFull) return self.fail("fallback chain refused early");
            break :blk false;
        };
        if (accepted != room) return self.fail("fallback chain accepted past its limit");
        if (accepted) self.model.explicit += 1;
        assert(self.model.explicit <= explicit_max);
        return digest(&.{ 4, @intFromBool(accepted), self.state.faces.epoch });
    }

    fn do_measure(self: *Player, query: *const Query) error{CheckFailed}!u64 {
        assert(query.len > 0);
        try self.check_face(query.family, query.weight);
        const font = query.spec();
        const got = text.measure(self.state, query.slice(), font);
        const want = oracle_metrics(self.state, query.slice(), font);
        if (!same_metrics(got, want)) return self.fail("measure differs from an uncached run");
        assert(got.height > 0);
        return digest(&.{
            5, bits(got.width), bits(got.height), bits(got.ascent), bits(got.descent),
        });
    }

    fn do_shape(self: *Player, query: *const Query) error{CheckFailed}!u64 {
        assert(query.out_len >= 1 and query.out_len <= glyphs_max);
        try self.check_face(query.family, query.weight);
        var glyphs: [glyphs_max]teak.ShapedGlyph = undefined;
        const out = glyphs[0..query.out_len];
        const result = text.shaper.shape(self.state, query.slice(), query.spec(), out);
        if (result.count > out.len or result.consumed > query.len) {
            return self.fail("shape overran");
        }
        var hash = std.hash.Wyhash.init(6);
        var sum: f32 = 0;
        for (out[0..result.count]) |glyph| {
            sum += glyph.advance;
            hash.update(std.mem.asBytes(&glyph));
        }
        if (bits(sum) != bits(result.width)) return self.fail("advances do not sum to width");
        const tail = [_]u64{ result.count, bits(result.width), result.consumed };
        hash.update(std.mem.sliceAsBytes(&tail));
        assert(tail[0] == result.count);
        return hash.final();
    }
};

const Plan = struct {
    scripts: [states_max][]const Op,
    limits: [states_max]text.Limits,
    count: u32,
};

const Outcome = struct {
    digests: [states_max][]u64,
    reports: [states_max]text.Report = @splat(.{}),
};

fn play(gpa: std.mem.Allocator, plan: *const Plan, order: []const u8, out: *Outcome) !?Failure {
    assert(plan.count >= 1 and plan.count <= states_max);
    assert(order.len == plan.count * ops_max);
    var states: [states_max]*text.TextState = undefined;
    var players: [states_max]Player = undefined;
    var opened: u32 = 0;
    defer for (states[0..opened]) |state| state.close();
    for (0..plan.count) |index| {
        states[index] = try text.TextState.open(gpa, plan.limits[index]);
        opened += 1;
        players[index] = .{ .state = states[index] };
    }
    var cursor: [states_max]u32 = @splat(0);
    for (order) |which| {
        assert(which < plan.count);
        const op = &plan.scripts[which][cursor[which]];
        const value = players[which].step(op) catch {
            return .{ .state = which, .op = cursor[which], .what = players[which].what };
        };
        out.digests[which][cursor[which]] = value;
        cursor[which] += 1;
    }
    for (0..plan.count) |index| out.reports[index] = states[index].report();
    assert(cursor[0] == ops_max);
    return null;
}

const Schedule = enum { a_then_b, alternate, shuffled, b_then_a, same_script };

fn build_order(kind: Schedule, rng: std.Random, order: []u8) void {
    assert(order.len % 2 == 0);
    const half = order.len / 2;
    switch (kind) {
        .a_then_b => {
            @memset(order[0..half], 0);
            @memset(order[half..], 1);
        },
        .b_then_a => {
            @memset(order[0..half], 1);
            @memset(order[half..], 0);
        },
        .alternate => for (order, 0..) |*slot, index| {
            slot.* = @intCast(index % 2);
        },
        .shuffled, .same_script => {
            @memset(order[0..half], 0);
            @memset(order[half..], 1);
            rng.shuffle(u8, order);
        },
    }
    assert(std.mem.count(u8, order, &.{1}) == half);
}

const Work = struct {
    scripts: [states_max][]Op,
    digests: [states_max][]u64,
    solo: [states_max][]u64,
    solo_reports: [states_max]text.Report = @splat(.{}),
    order: []u8,

    fn init(gpa: std.mem.Allocator) !Work {
        var work: Work = undefined;
        var made: u32 = 0;
        errdefer work.deinit(gpa, made);
        for (0..states_max) |index| {
            work.scripts[index] = try gpa.alloc(Op, ops_max);
            work.digests[index] = try gpa.alloc(u64, ops_max);
            work.solo[index] = try gpa.alloc(u64, ops_max);
            made += 1;
        }
        work.order = try gpa.alloc(u8, states_max * ops_max);
        assert(made == states_max);
        assert(work.order.len == states_max * ops_max);
        return work;
    }

    fn deinit(self: *Work, gpa: std.mem.Allocator, made: u32) void {
        assert(made <= states_max);
        assert(made == 0 or self.scripts[0].len == ops_max);
        for (0..made) |index| {
            gpa.free(self.scripts[index]);
            gpa.free(self.digests[index]);
            gpa.free(self.solo[index]);
        }
        if (made == states_max) gpa.free(self.order);
    }
};

fn mismatch(want: []const u64, got: []const u64) ?u32 {
    assert(want.len == got.len);
    assert(want.len == ops_max);
    for (want, got, 0..) |a, b, index| {
        if (a != b) return @intCast(index);
    }
    return null;
}

fn verdict(schedule: []const u8, state: u8, op: u32, what: []const u8) Verdict {
    assert(what.len > 0);
    assert(state < states_max and op <= ops_max);
    return .{ .schedule = schedule, .failure = .{ .state = state, .op = op, .what = what } };
}

const Solo = struct { failure: ?Failure, report: text.Report };

fn run_solo(
    gpa: std.mem.Allocator,
    work: *Work,
    which: u32,
    limits: text.Limits,
    dest: []u64,
) !Solo {
    assert(which < states_max and dest.len == ops_max);
    assert(limits.valid());
    const plan: Plan = .{
        .scripts = .{ work.scripts[which], work.scripts[which] },
        .limits = .{ limits, limits },
        .count = 1,
    };
    var out: Outcome = .{ .digests = .{ dest, dest } };
    const order = work.order[0..ops_max];
    @memset(order, 0);
    const failure = try play(gpa, &plan, order, &out);
    return .{ .failure = failure, .report = out.reports[0] };
}

fn check_solo(gpa: std.mem.Allocator, work: *Work) !?Verdict {
    assert(work.solo[0].len == ops_max and work.solo[1].len == ops_max);
    for (0..states_max) |index| {
        const which: u32 = @intCast(index);
        const first = try run_solo(gpa, work, which, .{}, work.solo[which]);
        if (first.failure) |failure| return .{ .schedule = "solo", .failure = failure };
        work.solo_reports[which] = first.report;
    }
    const again = try run_solo(gpa, work, 0, .{}, work.digests[0]);
    if (again.failure) |failure| return .{ .schedule = "solo again", .failure = failure };
    if (mismatch(work.solo[0], work.digests[0])) |op| {
        return verdict("a second run in the same process", 0, op, "results changed");
    }
    if (!std.meta.eql(again.report, work.solo_reports[0])) {
        return verdict("a second run in the same process", 0, ops_max, "report changed");
    }
    assert(!work.solo_reports[0].degraded() or work.solo_reports[0].fallback_refused > 0);
    return null;
}

fn check_tiny(gpa: std.mem.Allocator, work: *Work) !?Verdict {
    const tiny: text.Limits = .{ .kern_slots = 2, .measure_slots = 2 };
    assert(tiny.valid());
    const run = try run_solo(gpa, work, 0, tiny, work.digests[0]);
    if (run.failure) |failure| return .{ .schedule = "tiny limits", .failure = failure };
    if (mismatch(work.solo[0], work.digests[0])) |op| {
        return verdict("tiny limits", 0, op, "a full cache changed a result");
    }
    const evicted = run.report.kern_evicted + run.report.measure_evicted;
    if (evicted == 0) return verdict("tiny limits", 0, ops_max, "no eviction was counted");
    assert(run.report.kern_evicted > 0 or run.report.measure_evicted > 0);
    return null;
}

fn check_schedule(gpa: std.mem.Allocator, work: *Work, kind: Schedule, rng: std.Random) !?Verdict {
    const same = kind == .same_script;
    assert(work.order.len == states_max * ops_max);
    const plan: Plan = .{
        .scripts = .{ work.scripts[0], work.scripts[if (same) 0 else 1] },
        .limits = .{ .{}, .{} },
        .count = 2,
    };
    var out: Outcome = .{ .digests = work.digests };
    build_order(kind, rng, work.order);
    if (try play(gpa, &plan, work.order, &out)) |failure| {
        return .{ .schedule = @tagName(kind), .failure = failure };
    }
    for (0..states_max) |index| {
        const want = if (same) 0 else index;
        if (mismatch(work.solo[want], work.digests[index])) |op| {
            return verdict(@tagName(kind), @intCast(index), op, "results differ from a solo run");
        }
        if (!std.meta.eql(out.reports[index], work.solo_reports[want])) {
            return verdict(@tagName(kind), @intCast(index), ops_max, "report differs from solo");
        }
    }
    assert(std.mem.count(u8, work.order, &.{0}) == ops_max);
    return null;
}

fn check_seed(gpa: std.mem.Allocator, seed: u64, work: *Work) !?Verdict {
    assert(work.scripts[0].len == ops_max and work.scripts[1].len == ops_max);
    generate(seed *% 2, work.scripts[0]);
    generate(seed *% 2 +% 1, work.scripts[1]);
    if (try check_solo(gpa, work)) |found| return found;
    if (try check_tiny(gpa, work)) |found| return found;
    var prng = std.Random.DefaultPrng.init(seed ^ 0x5eed);
    for (std.enums.values(Schedule)) |kind| {
        if (try check_schedule(gpa, work, kind, prng.random())) |found| return found;
    }
    assert(std.enums.values(Schedule).len == 5);
    return null;
}

const Arguments = struct { seed: u64 = 1, seeds: u32 = 24 };

fn parse_arguments(arguments: []const [:0]const u8) !Arguments {
    assert(arguments.len >= 1);
    var parsed: Arguments = .{};
    var index: usize = 1;
    for (0..arguments.len) |_| {
        if (index >= arguments.len) break;
        const name = arguments[index];
        if (index + 1 >= arguments.len) return error.MissingValue;
        const value = arguments[index + 1];
        if (std.mem.eql(u8, name, "--seed")) {
            parsed.seed = try std.fmt.parseInt(u64, value, 10);
            parsed.seeds = 1;
        } else if (std.mem.eql(u8, name, "--seeds")) {
            parsed.seeds = try std.fmt.parseInt(u32, value, 10);
        } else return error.UnknownArgument;
        index += 2;
    }
    assert(parsed.seeds >= 1);
    return parsed;
}

fn run_seeds(gpa: std.mem.Allocator, arguments: Arguments) !bool {
    assert(arguments.seeds >= 1);
    var work = try Work.init(gpa);
    defer work.deinit(gpa, states_max);
    var fingerprint: u64 = 0;
    for (0..arguments.seeds) |offset| {
        const seed = arguments.seed +% offset;
        if (try check_seed(gpa, seed, &work)) |found| {
            std.debug.print("FAIL text_state seed={d} schedule={s} state={d} op={d}: {s}\n", .{
                seed, found.schedule, found.failure.state, found.failure.op, found.failure.what,
            });
            std.debug.print("reproduce: zig build text-state -- --seed {d}\n", .{seed});
            return false;
        }
        fingerprint = std.hash.Wyhash.hash(fingerprint, std.mem.sliceAsBytes(work.solo[0]));
        fingerprint = std.hash.Wyhash.hash(fingerprint, std.mem.sliceAsBytes(work.solo[1]));
    }
    std.debug.print("PASS text_state seed={d} seeds={d} ops={d} fingerprint={x}\n", .{
        arguments.seed, arguments.seeds, ops_max, fingerprint,
    });
    assert(arguments.seeds >= 1);
    return true;
}

pub fn main(init: std.process.Init) !void {
    const arguments = try parse_arguments(try init.minimal.args.toSlice(init.arena.allocator()));
    assert(arguments.seeds >= 1);
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const passed = try run_seeds(debug.allocator(), arguments);
    if (debug.deinit() == .leak) {
        std.debug.print("FAIL text_state: memory leaked\n", .{});
        std.process.exit(1);
    }
    assert(passed or arguments.seeds >= 1);
    if (!passed) std.process.exit(1);
}
