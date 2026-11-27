//! See SRC.md, src/sim/probe.zig.
const assert = @import("../assert.zig").assert;
const effects_mod = @import("../core/effects.zig");
const Resource = @import("../core/resources.zig").Resource;
const hashing = @import("hash.zig");

const generation_max = 1000000;
const initial_requests = [_]effects_mod.Effect{
    .{ .http = .{ .id = 1, .url = "sim://a", .headers = &.{
        .{ .name = "simulation", .value = "owned" },
    } } },
    .{ .download = .{ .id = 2, .name = "sim.txt", .bytes = "payload" } },
    .{ .open_file = .{ .id = 3, .accept = ".txt", .title = "simulation" } },
    .{ .write_clipboard = .{ .id = 4, .text = "captured" } },
    .{ .write_clipboard_image = .{ .id = 5, .png = "uninterpreted" } },
    .{ .storage_set = .{ .id = 6, .key = "simulation", .value = "owned" } },
    .{ .storage_get = .{ .id = 7, .key = "simulation" } },
    .{ .clock = .{ .id = 8 } },
    .{ .query_param = .{ .id = 9, .name = "simulation" } },
};
const assets = [_]Resource{
    .{ .image = .{ .key = 1, .rev = 1, .width = 1, .height = 1, .rgba = &.{ 24, 80, 160, 255 } } },
    .{ .mesh = .{ .key = 2, .rev = 1, .data = .{} } },
};

pub const Model = struct {
    generation: u32 = 0,
    shown: bool = false,
    text: [7]u8 = "sim://a".*,
    requests: [initial_requests.len]effects_mod.Effect = initial_requests,
    replies: u32 = 0,
    reply_digest: u64 = 0,
    reply_limits: u32 = 0,
};
pub const Msg = union(enum) { advance, answer: u64, answer_limit };

pub fn update(model: *Model, message: Msg) void {
    assert(model.generation < generation_max);
    assert(model.requests[0] == .http);
    switch (message) {
        .advance => {
            model.generation += 1;
            model.shown = !model.shown;
            model.text[6] = 'a' + @as(u8, @intCast(model.generation % 26));
            for (&model.requests, 0..) |*request, index| switch (request.*) {
                inline else => |*payload| {
                    const offset: u32 = @intCast(index);
                    payload.id = model.generation * 9 + offset + 1;
                },
            };
            model.requests[0].http.url = &model.text;
            model.requests[3].write_clipboard.text = &model.text;
        },
        .answer => |digest| {
            model.replies += 1;
            model.reply_digest = (model.reply_digest *% 31) +% digest;
        },
        .answer_limit => model.reply_limits += 1,
    }
}

pub fn view(model: *const Model, buffer: anytype) void {
    assert(model.generation <= generation_max);
    assert(model.requests[0] == .http);
    buffer.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });
    buffer.button(.advance, "Change requests and resources");
    if (model.shown) buffer.image(1, .{ .width = 24, .height = 24 });
    buffer.popGroup();
}

pub fn effects(model: *const Model) []const effects_mod.Effect {
    assert(model.generation <= generation_max);
    assert(model.requests[0].http.id == model.generation * 9 + 1);
    return &model.requests;
}

pub fn effectMsg(model: *const Model, result: effects_mod.EffectResult) ?Msg {
    assert(model.generation <= generation_max);
    assert(model.requests[0] == .http);
    const digest = hashing.hash(result) catch return .answer_limit;
    return .{ .answer = digest };
}

pub fn resources(model: *const Model) []const Resource {
    assert(model.generation <= generation_max);
    assert(model.requests[0] == .http);
    return if (model.shown) &assets else &.{};
}

pub fn windowMsg(model: *const Model, width: f32, height: f32) ?Msg {
    assert(model.generation <= generation_max);
    assert(width >= 0 and height >= 0);
    return .advance;
}
