const std = @import("std");

// Component composition constraints: HARDLINE §2 hatch 1 and SRC.md.

pub fn validateComponent(comptime T: type) void {
    const name = @typeName(T);

    if (!@hasDecl(T, "Model"))
        @compileError("Component '" ++ name ++ "' is missing a 'Model' type " ++
            "(expected `pub const Model = struct { ... }`)");
    if (@typeInfo(T.Model) != .@"struct")
        @compileError("Component '" ++ name ++ "'.Model must be a struct " ++
            "(default-initialisable via `.{}`)");
    const model_info = @typeInfo(T.Model).@"struct";
    inline for (model_info.field_names, model_info.field_attrs) |field_name, attrs| {
        if (attrs.default_value_ptr == null)
            @compileError("Component '" ++ name ++ "'.Model field '" ++ field_name ++
                "' has no default value; Model must be default-initialisable " ++
                "(every field defaulted) so composition can build `.{}`");
    }

    if (!@hasDecl(T, "Msg"))
        @compileError("Component '" ++ name ++ "' is missing a 'Msg' type " ++
            "(expected `pub const Msg = union(enum) { ... }`)");
    if (@typeInfo(T.Msg) != .@"union")
        @compileError("Component '" ++ name ++ "'.Msg must be a union(enum)");
    const msg_info = @typeInfo(T.Msg).@"union";
    if (msg_info.tag_type == null)
        @compileError("Component '" ++ name ++ "'.Msg must be a TAGGED union, i.e. union(enum)");

    if (!@hasDecl(T, "update"))
        @compileError("Component '" ++ name ++ "' is missing an 'update' function " ++
            "(expected `pub fn update(model: *Model, msg: Msg) void`)");
    const update_info = @typeInfo(@TypeOf(T.update));
    if (update_info != .@"fn")
        @compileError("Component '" ++ name ++ "'.update must be a function " ++
            "with signature `fn(*Model, Msg) void`");
    const update_fn = update_info.@"fn";
    const expected_update = "Component '" ++ name ++ "'.update must be `fn(*Model, Msg) void`";
    if (update_fn.param_types.len != 2)
        @compileError(expected_update ++ " — it takes " ++ paramCountStr(update_fn.param_types.len) ++
            ", expected 2 (*Model, Msg)");
    if (update_fn.param_types[0] != *T.Model)
        @compileError(expected_update ++ " — first parameter must be *Model");
    if (update_fn.param_types[1] != T.Msg)
        @compileError(expected_update ++ " — second parameter must be Msg");
    if (update_fn.return_type == null or update_fn.return_type.? != void)
        @compileError(expected_update ++ " — it must return void");

    if (!@hasDecl(T, "view"))
        @compileError("Component '" ++ name ++ "' is missing a 'view' function " ++
            "(expected `pub fn view(model: *const Model, cb: anytype, msgs: anytype) void`)");
    const view_info = @typeInfo(@TypeOf(T.view));
    if (view_info != .@"fn")
        @compileError("Component '" ++ name ++ "'.view must be a function " ++
            "with signature `fn(*const Model, cb: anytype, msgs: anytype) void`");
    const view_fn = view_info.@"fn";
    const expected_view = "Component '" ++ name ++
        "'.view must be `fn(*const Model, cb: anytype, msgs: anytype) void`";
    if (view_fn.param_types.len != 3)
        @compileError(expected_view ++ " — it takes " ++ paramCountStr(view_fn.param_types.len) ++
            ", expected 3 (*const Model, cb, msgs)");
    if (view_fn.param_types[0] != *const T.Model)
        @compileError(expected_view ++ " — first parameter must be *const Model");
    if (view_fn.return_type) |rt| {
        if (rt != void)
            @compileError(expected_view ++ " — it must return void");
    }
}

/// Small comptime helper: render a parameter count as English for the
/// arity-mismatch messages ("1 parameter" vs "3 parameters").
fn paramCountStr(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d} parameter{s}", .{ n, if (n == 1) "" else "s" });
}

/// Build an anonymous struct type with one field per payloadless variant
/// of `Comp.Msg`. Each field's type is `AppMsg`; when the composed view
/// runs, we populate each field with a pre-wrapped AppMsg value.
///
/// Public so `ComponentList` (and any future per-index msg generator)
/// can reuse the same shape — the msgs struct passed to a child view
/// is always `MsgsStructFor(Child, AppMsg)`, no matter who built it.
pub fn MsgsStructFor(comptime Comp: type, comptime AppMsg: type) type {
    const msg_info = @typeInfo(Comp.Msg).@"union";
    comptime var names: []const []const u8 = &.{};
    comptime var types: []const type = &.{};
    inline for (msg_info.field_names, msg_info.field_types) |field_name, field_type| {
        if (field_type == void) {
            names = names ++ &[_][]const u8{field_name};
            types = types ++ &[_]type{AppMsg};
        }
    }
    const n = names.len;
    const types_arr: [n]type = types[0..n].*;
    const attrs: [n]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.auto, null, names, &types_arr, &attrs);
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
    inline for (msg_info.field_names, msg_info.field_types) |field_name, field_type| {
        if (field_type == void) {
            const local: Comp.Msg = @unionInit(Comp.Msg, field_name, {});
            @field(msgs, field_name) = @unionInit(AppMsg, variant_name, local);
        }
    }
    return msgs;
}

/// Field names of the `.{ .name = Component, ... }` tuple handed to `Components`.
fn componentNames(comptime components: anytype) []const [:0]const u8 {
    return @typeInfo(@TypeOf(components)).@"struct".field_names;
}

fn GenerateModel(comptime components: anytype, comptime AppLevel: ?type) type {
    const Attrs = std.builtin.Type.Struct.FieldAttributes;
    comptime var names: []const []const u8 = &.{};
    comptime var types: []const type = &.{};
    comptime var attrs_list: []const Attrs = &.{};
    inline for (componentNames(components)) |comp_name| {
        const T = @field(components, comp_name);
        names = names ++ &[_][]const u8{comp_name};
        types = types ++ &[_]type{T.Model};
        const default: T.Model = .{};
        attrs_list = attrs_list ++ &[_]Attrs{.{ .default_value_ptr = @ptrCast(&default) }};
    }
    if (AppLevel) |AL| {
        const al_info = @typeInfo(AL).@"struct";
        names = names ++ al_info.field_names;
        types = types ++ al_info.field_types;
        attrs_list = attrs_list ++ al_info.field_attrs;
    }
    const n = names.len;
    const types_arr: [n]type = types[0..n].*;
    const attrs_arr: [n]Attrs = attrs_list[0..n].*;
    return @Struct(.auto, null, names, &types_arr, &attrs_arr);
}

fn GenerateMsg(comptime components: anytype, comptime AppLevel: ?type) type {
    const UAttrs = std.builtin.Type.Union.FieldAttributes;
    comptime var names: []const []const u8 = &.{};
    comptime var types: []const type = &.{};
    comptime var attrs_list: []const UAttrs = &.{};
    comptime var values: []const u16 = &.{};
    comptime var idx: u16 = 0;

    inline for (componentNames(components)) |comp_name| {
        const T = @field(components, comp_name);
        names = names ++ &[_][]const u8{comp_name};
        types = types ++ &[_]type{T.Msg};
        attrs_list = attrs_list ++ &[_]UAttrs{.{}};
        values = values ++ &[_]u16{idx};
        idx += 1;
    }

    if (AppLevel) |AL| {
        if (@hasDecl(AL, "Msg")) {
            const al_msg = @typeInfo(AL.Msg).@"union";
            names = names ++ al_msg.field_names;
            types = types ++ al_msg.field_types;
            attrs_list = attrs_list ++ al_msg.field_attrs;
            for (al_msg.field_names) |_| {
                values = values ++ &[_]u16{idx};
                idx += 1;
            }
        }
    }

    const n = names.len;
    const values_arr: [n]u16 = values[0..n].*;
    const TagT = @Enum(u16, .exhaustive, names, &values_arr);

    const types_arr: [n]type = types[0..n].*;
    const attrs_arr: [n]UAttrs = attrs_list[0..n].*;
    return @Union(.auto, TagT, names, &types_arr, &attrs_arr);
}

pub fn Components(comptime components: anytype, comptime AppLevel: ?type) type {
    inline for (componentNames(components)) |comp_name| {
        validateComponent(@field(components, comp_name));
    }

    const Model_ = GenerateModel(components, AppLevel);
    const Msg_ = GenerateMsg(components, AppLevel);
    const comp_names = componentNames(components);

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
                    inline for (comp_names) |comp_name| {
                        if (comptime std.mem.eql(u8, tag_name, comp_name)) {
                            const Comp = @field(components, comp_name);
                            Comp.update(&@field(model, comp_name), payload);
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
            inline for (comp_names) |comp_name| {
                const Comp = @field(components, comp_name);
                const msgs = buildMsgs(Comp, comp_name, Msg);
                Comp.view(&@field(model.*, comp_name), cb, msgs);
            }
        }
    };
}

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
        name: [32]u8 = @splat(0),
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
