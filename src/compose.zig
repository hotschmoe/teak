const std = @import("std");

// ── Comptime Component Composition ─────────────────────────────────
//
// A component is any type with public decls:
//   pub const Model = struct { ... };           (default-initialisable)
//   pub const Msg   = union(enum) { ... };
//   pub fn update(model: *Model, msg: Msg) void;
//   pub fn view(model: *const Model, cb: anytype, msgs: anytype) void;
//
// view() takes *const Model (not Model by value) so slices the view constructs
// into Model — e.g. a text buffer as []const u8 — stay valid for the caller's
// arena lifetime. A by-value parameter would make such slices dangle the
// moment view returned.

pub fn validateComponent(comptime T: type) void {
    const name = @typeName(T);
    if (!@hasDecl(T, "Model"))
        @compileError("Component '" ++ name ++ "' is missing a 'Model' type");
    if (!@hasDecl(T, "Msg"))
        @compileError("Component '" ++ name ++ "' is missing a 'Msg' type");
    if (@typeInfo(T.Msg) != .@"union")
        @compileError("Component '" ++ name ++ "'.Msg must be a union(enum)");
    const msg_info = @typeInfo(T.Msg).@"union";
    if (msg_info.tag_type == null)
        @compileError("Component '" ++ name ++ "'.Msg must be a TAGGED union, i.e. union(enum)");
    if (!@hasDecl(T, "update"))
        @compileError("Component '" ++ name ++ "' is missing an 'update' function");
    if (!@hasDecl(T, "view"))
        @compileError("Component '" ++ name ++ "' is missing a 'view' function");

    const update_info = @typeInfo(@TypeOf(T.update));
    if (update_info != .@"fn")
        @compileError("Component '" ++ name ++ "'.update must be a function");
    if (update_info.@"fn".params.len != 2)
        @compileError("Component '" ++ name ++ "'.update must take (*Model, Msg)");

    const view_info = @typeInfo(@TypeOf(T.view));
    if (view_info != .@"fn")
        @compileError("Component '" ++ name ++ "'.view must be a function");
    if (view_info.@"fn".params.len != 3)
        @compileError("Component '" ++ name ++ "'.view must take (*const Model, cb: anytype, msgs: anytype)");
}

/// Build an anonymous struct type with one field per payloadless variant
/// of `Comp.Msg`. Each field's type is `AppMsg`; when the composed view
/// runs, we populate each field with a pre-wrapped AppMsg value.
fn MsgsStructFor(comptime Comp: type, comptime AppMsg: type) type {
    const msg_info = @typeInfo(Comp.Msg).@"union";
    comptime var fields: []const std.builtin.Type.StructField = &.{};
    inline for (msg_info.fields) |f| {
        if (f.type == void) {
            fields = fields ++ &[_]std.builtin.Type.StructField{.{
                .name = f.name,
                .type = AppMsg,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(AppMsg),
            }};
        }
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    }});
}

/// Fill in a MsgsStruct with pre-wrapped AppMsg values. Runs once per
/// component per frame; the inline for unrolls to a handful of assignments.
/// Exposed publicly so apps can hand-call it when composing views outside
/// the generated `view` (e.g. to override a single field with an app-level
/// Msg while keeping the rest of the wiring automatic).
pub fn buildMsgs(
    comptime Comp: type,
    comptime variant_name: []const u8,
    comptime AppMsg: type,
) MsgsStructFor(Comp, AppMsg) {
    var msgs: MsgsStructFor(Comp, AppMsg) = undefined;
    const msg_info = @typeInfo(Comp.Msg).@"union";
    inline for (msg_info.fields) |f| {
        if (f.type == void) {
            const local: Comp.Msg = @unionInit(Comp.Msg, f.name, {});
            @field(msgs, f.name) = @unionInit(AppMsg, variant_name, local);
        }
    }
    return msgs;
}

fn GenerateModel(comptime components: anytype, comptime AppLevel: ?type) type {
    comptime var fields: []const std.builtin.Type.StructField = &.{};
    inline for (std.meta.fields(@TypeOf(components))) |field| {
        const T = @field(components, field.name);
        fields = fields ++ &[_]std.builtin.Type.StructField{.{
            .name = field.name,
            .type = T.Model,
            .default_value_ptr = default_ptr: {
                const default: T.Model = .{};
                break :default_ptr @ptrCast(&default);
            },
            .is_comptime = false,
            .alignment = @alignOf(T.Model),
        }};
    }
    if (AppLevel) |AL| {
        inline for (std.meta.fields(AL)) |field| {
            fields = fields ++ &[_]std.builtin.Type.StructField{field};
        }
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    }});
}

fn GenerateMsg(comptime components: anytype, comptime AppLevel: ?type) type {
    comptime var union_fields: []const std.builtin.Type.UnionField = &.{};
    comptime var enum_fields: []const std.builtin.Type.EnumField = &.{};
    comptime var idx: u16 = 0;

    inline for (std.meta.fields(@TypeOf(components))) |field| {
        const T = @field(components, field.name);
        union_fields = union_fields ++ &[_]std.builtin.Type.UnionField{.{
            .name = field.name,
            .type = T.Msg,
            .alignment = @alignOf(T.Msg),
        }};
        enum_fields = enum_fields ++ &[_]std.builtin.Type.EnumField{.{
            .name = field.name,
            .value = idx,
        }};
        idx += 1;
    }

    if (AppLevel) |AL| {
        if (@hasDecl(AL, "Msg")) {
            const AL_Msg_info = @typeInfo(AL.Msg).@"union";
            inline for (AL_Msg_info.fields) |uf| {
                union_fields = union_fields ++ &[_]std.builtin.Type.UnionField{uf};
                enum_fields = enum_fields ++ &[_]std.builtin.Type.EnumField{.{
                    .name = uf.name,
                    .value = idx,
                }};
                idx += 1;
            }
        }
    }

    const TagT = @Type(.{ .@"enum" = .{
        .tag_type = u16,
        .fields = enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    }});

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = TagT,
        .fields = union_fields,
        .decls = &.{},
    }});
}

pub fn Components(comptime components: anytype, comptime AppLevel: ?type) type {
    inline for (std.meta.fields(@TypeOf(components))) |field| {
        validateComponent(@field(components, field.name));
    }

    const Model_ = GenerateModel(components, AppLevel);
    const Msg_ = GenerateMsg(components, AppLevel);
    const comp_fields = std.meta.fields(@TypeOf(components));

    return struct {
        pub const Model = Model_;
        pub const Msg = Msg_;

        /// Switch on the composed Msg tag. If it names a component, dispatch
        /// to that component's update. Otherwise reconstruct the AppLevel
        /// Msg (same variant name, same payload) and hand to AppLevel.update.
        pub fn update(model: *Model, msg: Msg) void {
            switch (msg) {
                inline else => |payload, tag| {
                    const tag_name = @tagName(tag);
                    inline for (comp_fields) |field| {
                        if (comptime std.mem.eql(u8, tag_name, field.name)) {
                            const Comp = @field(components, field.name);
                            Comp.update(&@field(model, field.name), payload);
                            return;
                        }
                    }
                    if (AppLevel) |AL| {
                        if (@hasDecl(AL, "Msg") and @hasDecl(AL, "update")) {
                            const al_msg = @unionInit(AL.Msg, tag_name, payload);
                            AL.update(model, al_msg);
                            return;
                        }
                    }
                },
            }
        }

        /// Call every component's view in declaration order, handing each a
        /// pre-wrapped msgs struct so the component can write its own local
        /// Msg values verbatim (cb.button(msgs.increment, "+")) and the
        /// stored command carries the already-composed AppMsg.
        pub fn view(model: *const Model, cb: anytype) void {
            inline for (comp_fields) |field| {
                const Comp = @field(components, field.name);
                const msgs = buildMsgs(Comp, field.name, Msg);
                Comp.view(&@field(model.*, field.name), cb, msgs);
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd = @import("cmd.zig");

const TestCounter = struct {
    pub const Model = struct { count: i32 = 0 };
    pub const Msg = union(enum) { inc, dec, reset };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .inc => m.count += 1,
            .dec => m.count -= 1,
            .reset => m.count = 0,
        }
    }

    pub fn view(m: *const Model, cb: anytype, msgs: anytype) void {
        _ = m;
        cb.button(msgs.inc, "+");
        cb.button(msgs.dec, "-");
        cb.button(msgs.reset, "Reset");
    }
};

const TestGreeter = struct {
    pub const Model = struct {
        name: [32]u8 = [_]u8{0} ** 32,
        name_len: u8 = 0,
    };
    pub const Msg = union(enum) { focus, append: u8, clear };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .focus => {},
            .append => |c| {
                if (m.name_len < 31) {
                    m.name[m.name_len] = c;
                    m.name_len += 1;
                }
            },
            .clear => m.name_len = 0,
        }
    }

    pub fn view(m: *const Model, cb: anytype, msgs: anytype) void {
        cb.textInput(msgs.focus, m.name[0..m.name_len], m.name_len);
        cb.button(msgs.clear, "Clear");
    }
};

test "compose: Model has one field per component" {
    const App = Components(.{
        .counter = TestCounter,
        .greeter = TestGreeter,
    }, null);

    const model: App.Model = .{};
    try std.testing.expectEqual(@as(i32, 0), model.counter.count);
    try std.testing.expectEqual(@as(u8, 0), model.greeter.name_len);
}

test "compose: Msg has one variant per component + routing works" {
    const App = Components(.{
        .counter = TestCounter,
        .greeter = TestGreeter,
    }, null);

    var model: App.Model = .{};

    App.update(&model, .{ .counter = .inc });
    App.update(&model, .{ .counter = .inc });
    try std.testing.expectEqual(@as(i32, 2), model.counter.count);

    App.update(&model, .{ .greeter = .{ .append = 'A' } });
    App.update(&model, .{ .greeter = .{ .append = 'B' } });
    try std.testing.expectEqual(@as(u8, 2), model.greeter.name_len);
    try std.testing.expectEqual(@as(u8, 'A'), model.greeter.name[0]);

    App.update(&model, .{ .counter = .reset });
    try std.testing.expectEqual(@as(i32, 0), model.counter.count);
}

test "compose: view wraps component msgs into AppMsg" {
    const testing = std.testing;
    const App = Components(.{
        .counter = TestCounter,
        .greeter = TestGreeter,
    }, null);

    var cb = cmd.CmdBuffer(App.Msg).init(testing.allocator);
    defer cb.deinit();

    const model: App.Model = .{};
    App.view(&model, &cb);

    // 3 counter buttons + 1 greeter text_input + 1 greeter "Clear" button = 5 cmds
    try testing.expectEqual(@as(usize, 5), cb.cmds.items.len);

    // First button is counter's "+" wrapped as .counter = .inc
    try testing.expectEqual(App.Msg{ .counter = .inc }, cb.cmds.items[0].button.msg);
    try testing.expectEqual(App.Msg{ .counter = .reset }, cb.cmds.items[2].button.msg);

    // Greeter text_input's focus_msg is .greeter = .focus
    try testing.expectEqual(App.Msg{ .greeter = .focus }, cb.cmds.items[3].text_input.focus_msg);
    try testing.expectEqual(App.Msg{ .greeter = .clear }, cb.cmds.items[4].button.msg);
}

test "compose: AppLevel adds state fields + msg variants + routes to AL.update" {
    const AppLevel = struct {
        focused: u32 = 0,

        pub const Msg = union(enum) {
            focus_set: u32,
            reset_all,
        };

        pub fn update(model: anytype, msg: Msg) void {
            switch (msg) {
                .focus_set => |f| model.focused = f,
                .reset_all => {
                    model.counter.count = 0;
                    model.focused = 0;
                },
            }
        }
    };

    const App = Components(.{ .counter = TestCounter }, AppLevel);

    var model: App.Model = .{};
    try std.testing.expectEqual(@as(u32, 0), model.focused);

    App.update(&model, .{ .counter = .inc });
    try std.testing.expectEqual(@as(i32, 1), model.counter.count);

    App.update(&model, .{ .focus_set = 7 });
    try std.testing.expectEqual(@as(u32, 7), model.focused);

    App.update(&model, .reset_all);
    try std.testing.expectEqual(@as(i32, 0), model.counter.count);
    try std.testing.expectEqual(@as(u32, 0), model.focused);
}
