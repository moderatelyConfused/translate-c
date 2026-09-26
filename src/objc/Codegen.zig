//! Generates Zig bindings for the Objective-C declarations in an `objc.Model`.
//!
//! The generated code depends on the `objc` module provided by
//! https://github.com/mitchellh/zig-objc. Every class and protocol becomes an
//! `opaque` wrapper type; instances are `*NSString`-style pointers whose
//! nullability follows the header's annotations. Methods are generated once
//! per declaring type as a generic "mixin" (`__objc_methods_<Name>(Self)`) and
//! re-exported from every wrapper that inherits them, so `instancetype` and
//! class methods keep referring to the concrete receiver type.
const Codegen = @This();

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const aro = @import("aro");
const QualType = aro.QualType;
const Node = aro.Tree.Node;
const Nullability = aro.TypeStore.Type.Pointer.Nullability;

const ast = @import("../ast.zig");
const ZigNode = ast.Node;
const ZigTag = ZigNode.Tag;
const Translator = @import("../Translator.zig");
const Scope = @import("../Scope.zig");
const Model = @import("Model.zig");

pub const Error = error{OutOfMemory};

/// A wrapper file produced in split mode, see `Split`.
pub const File = struct {
    /// File name inside the wrapper directory.
    name: []const u8,
    text: []const u8,
};

/// Writes every class and protocol wrapper (together with its mixin) to a file
/// of its own instead of the root file. Editors and language servers then only
/// have to analyse the wrappers that are actually used, which matters for
/// frameworks like Cocoa whose single-file bindings run to hundreds of
/// thousands of lines. The root file re-exports every wrapper, so the module
/// looks the same to users.
pub const Split = struct {
    /// Path of the wrapper directory relative to the directory of the root
    /// file, using `/` separators. Empty when both are the same directory.
    import_prefix: []const u8,
    /// File name of the root file; every wrapper file imports it for the C
    /// declarations and the `__objc` support code.
    root_basename: []const u8,
    /// Receives one entry per wrapper file. Names and contents are allocated
    /// with the gpa given to `generate`.
    files: *std.ArrayList(File),
};

t: *Translator,
model: *const Model,
gpa: Allocator,
arena: Allocator,
/// The root file.
out: std.Io.Writer.Allocating,
/// Where `print`/`write` go: the root file, or the wrapper file being
/// generated in split mode.
cur: *std.Io.Writer.Allocating = undefined,
split: ?Split,
/// Zig wrapper name -> wrapper file name (split mode).
file_names: std.StringHashMapUnmanaged([]const u8) = .empty,
/// Mixin name -> wrapper file name defining it (split mode).
mixin_files: std.StringHashMapUnmanaged([]const u8) = .empty,

/// Synthetic prototype name -> declaration node.
protos: std.StringHashMapUnmanaged(Node.Index) = .empty,
/// Names that are taken at file scope in the generated file.
reserved: std.StringHashMapUnmanaged(void) = .empty,
/// Names of types at file scope (wrapper types, C typedefs and records) that
/// method signatures may refer to. A method with such a name would make the
/// type an ambiguous reference inside its mixin, so method names avoid them.
type_names: std.StringHashMapUnmanaged(void) = .empty,
/// Objective-C class name -> Zig wrapper name.
class_names: std.StringHashMapUnmanaged([]const u8) = .empty,
/// Objective-C protocol name -> Zig wrapper name.
protocol_names: std.StringHashMapUnmanaged([]const u8) = .empty,
/// Synthetic prototype name -> translated signature, or null when the method
/// cannot be translated. Filled by `prepareMethods`.
specs: std.StringHashMapUnmanaged(?MethodSpecs) = .empty,

const ParamSpec = struct {
    name: []const u8,
    spec: TypeSpec,
};

const MethodSpecs = struct {
    ret: TypeSpec,
    params: []const ParamSpec,
};

/// Names of the helper declarations every wrapper defines.
const helper_names = [_][]const u8{
    "Super",        "objc_class_name", "objc_protocol_name", "objcClass", "objcProtocol",
    "as",           "object",          "fromObject",         "fromId",    "msgSend",
    "msgSendSuper",
};

const Owner = union(enum) {
    class: *const Model.Class,
    protocol: *const Model.Protocol,

    fn name(o: Owner) []const u8 {
        return switch (o) {
            .class => |c| c.name,
            .protocol => |p| p.name,
        };
    }
};

const Entry = struct {
    method: *const Model.Method,
    /// The type whose mixin defines the method.
    owner: Owner,
    /// The name of the function in the mixin.
    mixin_name: []const u8 = "",
    /// The name of the alias in the wrapper.
    name: []const u8 = "",
    unavailable: bool = false,
};

/// Renders the Objective-C bindings for `model` and returns the text appended
/// to the root file, owned by `t.arena`. In split mode (`split != null`) the
/// wrappers go to `split.files` instead and the root file only re-exports
/// them.
pub fn generate(t: *Translator, model: *const Model, split: ?Split) Error![]const u8 {
    var cg: Codegen = .{
        .t = t,
        .model = model,
        .gpa = t.gpa,
        .arena = t.arena,
        .out = .init(t.gpa),
        .split = split,
    };
    defer cg.deinit();
    cg.cur = &cg.out;

    try cg.collectProtos();
    try cg.collectReserved();
    try cg.assignWrapperNames();
    if (split != null) try cg.assignFileNames();
    try cg.prepareMethods();

    try cg.emitPrelude();
    try cg.emitDiagnostics();
    for (model.aliases.items) |alias| {
        try cg.print("pub const {f} = {f};\n", .{ fmtId(alias.name), fmtId(cg.classZigName(alias.target)) });
    }
    if (split != null) {
        for (model.classes.values()) |class| try cg.emitSplitFile(cg.classZigName(class.name), .{ .class = class });
        for (model.protocols.values()) |protocol| try cg.emitSplitFile(cg.protocol_names.get(protocol.name).?, .{ .protocol = protocol });
    } else {
        for (model.classes.values()) |class| try cg.emitClass(class);
        for (model.protocols.values()) |protocol| try cg.emitProtocol(protocol);
    }

    return cg.format();
}

fn deinit(cg: *Codegen) void {
    cg.out.deinit();
    cg.protos.deinit(cg.gpa);
    cg.reserved.deinit(cg.gpa);
    cg.class_names.deinit(cg.gpa);
    cg.protocol_names.deinit(cg.gpa);
    cg.type_names.deinit(cg.gpa);
    cg.specs.deinit(cg.gpa);
    cg.file_names.deinit(cg.gpa);
    cg.mixin_files.deinit(cg.gpa);
}

fn print(cg: *Codegen, comptime fmt: []const u8, args: anytype) Error!void {
    cg.cur.writer.print(fmt, args) catch return error.OutOfMemory;
}

fn write(cg: *Codegen, text: []const u8) Error!void {
    cg.cur.writer.writeAll(text) catch return error.OutOfMemory;
}

fn fmtId(name: []const u8) std.zig.FormatId {
    return std.zig.fmtId(name);
}

/// Runs the generated root text through the Zig parser and formatter.
fn format(cg: *Codegen) Error![]const u8 {
    const raw = try cg.out.toOwnedSliceSentinel(0);
    defer cg.gpa.free(raw);
    return cg.formatRaw(cg.arena, raw);
}

/// Runs `raw` through the Zig parser and formatter; the result is allocated
/// with `allocator`.
fn formatRaw(cg: *Codegen, allocator: Allocator, raw: [:0]const u8) Error![]u8 {
    var tree = try std.zig.Ast.parse(cg.gpa, raw, .zig);
    defer tree.deinit(cg.gpa);
    if (tree.errors.len != 0) {
        // This is a bug in the generator; keep the output readable so that
        // the problem can be diagnosed.
        var text: std.Io.Writer.Allocating = .init(cg.gpa);
        defer text.deinit();
        const w = &text.writer;
        w.writeAll("// translate-c: internal error: the generated Objective-C bindings do not parse:\n") catch return error.OutOfMemory;
        for (tree.errors) |err| {
            const loc = tree.tokenLocation(0, err.token);
            w.print("//   line {d}: ", .{loc.line + 1}) catch return error.OutOfMemory;
            tree.renderError(err, w) catch return error.OutOfMemory;
            w.writeByte('\n') catch return error.OutOfMemory;
        }
        w.writeAll(raw) catch return error.OutOfMemory;
        return allocator.dupe(u8, text.written());
    }
    var formatted: std.Io.Writer.Allocating = .init(cg.gpa);
    defer formatted.deinit();
    tree.render(cg.gpa, &formatted.writer, .{}) catch return error.OutOfMemory;
    return allocator.dupe(u8, formatted.written());
}

// =========================
// Setup
// =========================

fn collectProtos(cg: *Codegen) Error!void {
    const tree = cg.t.tree;
    for (tree.root_decls.items) |decl| {
        switch (decl.get(tree)) {
            .function => |function| {
                const name = tree.tokSlice(function.name_tok);
                if (mem.startsWith(u8, name, "__objc_m_")) {
                    try cg.protos.put(cg.gpa, name, decl);
                }
            },
            else => {},
        }
    }
}

fn collectReserved(cg: *Codegen) Error!void {
    const t = cg.t;
    for (t.global_names.keys()) |name| try cg.reserved.put(cg.gpa, name, {});
    for (t.weak_global_names.keys()) |name| try cg.reserved.put(cg.gpa, name, {});
    for (t.global_scope.sym_table.keys()) |name| try cg.reserved.put(cg.gpa, name, {});
    for ([_][]const u8{ "objc", "__objc", "__root", "__builtin", "__helpers", "std" }) |name| {
        try cg.reserved.put(cg.gpa, name, {});
        try cg.type_names.put(cg.gpa, name, {});
    }
    for (t.typedefs.keys()) |name| try cg.type_names.put(cg.gpa, name, {});
    for (t.container_types.values()) |name| try cg.type_names.put(cg.gpa, name, {});
    try cg.type_names.put(cg.gpa, "Self", {});
}

/// Picks collision free Zig names for the class and protocol wrappers.
fn assignWrapperNames(cg: *Codegen) Error!void {
    for (cg.model.classes.values()) |class| {
        // The C typedef standing in for the class already reserved its name.
        try cg.class_names.put(cg.gpa, class.name, class.name);
        try cg.reserved.put(cg.gpa, class.name, {});
        try cg.type_names.put(cg.gpa, class.name, {});
    }
    for (cg.model.protocols.values()) |protocol| {
        // Chosen by the translator, which needs the names while translating
        // C declarations that mention `id<P>`.
        const name = cg.t.objc_protocol_names.get(protocol.name) orelse protocol.name;
        try cg.protocol_names.put(cg.gpa, protocol.name, name);
        try cg.reserved.put(cg.gpa, name, {});
        try cg.type_names.put(cg.gpa, name, {});
    }
    for (cg.model.classes.values()) |class| {
        const mixin = try mixinName(cg.arena, .{ .class = class });
        try cg.reserved.put(cg.gpa, mixin, {});
    }
    for (cg.model.protocols.values()) |protocol| {
        const mixin = try mixinName(cg.arena, .{ .protocol = protocol });
        try cg.reserved.put(cg.gpa, mixin, {});
    }
}

/// Split mode: picks a file name for every wrapper. File names are the Zig
/// wrapper names, kept unique case-insensitively for the benefit of
/// case-insensitive file systems.
fn assignFileNames(cg: *Codegen) Error!void {
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(cg.gpa);
    for (cg.model.classes.values()) |class| {
        try cg.assignFileName(&used, cg.classZigName(class.name), try mixinName(cg.arena, .{ .class = class }));
    }
    for (cg.model.protocols.values()) |protocol| {
        try cg.assignFileName(&used, cg.protocol_names.get(protocol.name).?, try mixinName(cg.arena, .{ .protocol = protocol }));
    }
}

fn assignFileName(cg: *Codegen, used: *std.StringHashMapUnmanaged(void), zig_name: []const u8, mixin: []const u8) Error!void {
    var stem = zig_name;
    var n: usize = 2;
    while (true) : (n += 1) {
        const lower = try std.ascii.allocLowerString(cg.arena, stem);
        const gop = try used.getOrPut(cg.gpa, lower);
        if (!gop.found_existing) break;
        stem = try std.fmt.allocPrint(cg.arena, "{s}_{d}", .{ zig_name, n });
    }
    const file = try std.fmt.allocPrint(cg.arena, "{s}.zig", .{stem});
    try cg.file_names.put(cg.gpa, zig_name, file);
    try cg.mixin_files.put(cg.gpa, mixin, file);
}

/// Translates the signature of every method once, so that wrappers and mixins
/// agree on which methods exist.
fn prepareMethods(cg: *Codegen) Error!void {
    for (cg.model.classes.values()) |class| try cg.prepareOwner(.{ .class = class }, class.methods.items);
    for (cg.model.protocols.values()) |protocol| try cg.prepareOwner(.{ .protocol = protocol }, protocol.methods.items);
}

fn prepareOwner(cg: *Codegen, owner: Owner, methods: []const *Model.Method) Error!void {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(cg.gpa);
    for (methods) |method| try entries.append(cg.gpa, .{ .method = method, .owner = owner });
    try cg.assignNames(entries.items, "mixin_name", false);

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(cg.gpa);
    for (entries.items) |entry| try names.put(cg.gpa, entry.mixin_name, {});

    for (entries.items) |entry| {
        if (cg.isUnavailable(entry.method)) continue;
        const specs = cg.computeSpecs(entry.method, &names) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedType => null,
        };
        try cg.specs.put(cg.gpa, entry.method.proto_name, specs);
    }
}

fn classZigName(cg: *const Codegen, name: []const u8) []const u8 {
    return cg.class_names.get(name) orelse name;
}

fn mixinName(arena: Allocator, owner: Owner) Error![]const u8 {
    return switch (owner) {
        .class => |c| std.fmt.allocPrint(arena, "__objc_methods_{s}", .{c.name}),
        .protocol => |p| std.fmt.allocPrint(arena, "__objc_protocol_methods_{s}", .{p.name}),
    };
}

// =========================
// Prelude
// =========================

fn emitPrelude(cg: *Codegen) Error!void {
    try cg.write(
        \\
        \\// ==========================================================================
        \\// Objective-C bindings. These require the `objc` module from zig-objc
        \\// (https://github.com/mitchellh/zig-objc) to be added as an import of the
        \\// translated module.
        \\// ==========================================================================
        \\
        \\pub const objc = @import("objc");
        \\
        \\/// Support code for the generated Objective-C bindings.
        \\pub const __objc = struct {
        \\    pub inline fn fromBOOL(value: objc.c.BOOL) bool {
        \\        return switch (objc.c.BOOL) {
        \\            bool => value,
        \\            else => value != 0,
        \\        };
        \\    }
        \\
        \\    pub inline fn toBOOL(value: bool) objc.c.BOOL {
        \\        return switch (objc.c.BOOL) {
        \\            bool => value,
        \\            else => @intFromBool(value),
        \\        };
        \\    }
        \\
        \\    pub inline fn idOf(obj: ?objc.Object) objc.c.id {
        \\        return if (obj) |o| o.value else null;
        \\    }
        \\
        \\    pub inline fn objectFromId(raw: objc.c.id) ?objc.Object {
        \\        return if (raw) |ptr| .{ .value = ptr } else null;
        \\    }
        \\
        \\    pub inline fn classFromRaw(cls: objc.c.Class) ?objc.Class {
        \\        return if (cls) |ptr| .{ .value = ptr } else null;
        \\    }
        \\
        \\    pub inline fn classFromRawNonnull(cls: objc.c.Class) objc.Class {
        \\        return .{ .value = cls };
        \\    }
        \\
        \\    pub inline fn rawClass(cls: ?objc.Class) objc.c.Class {
        \\        return if (cls) |v| v.value else null;
        \\    }
        \\
        \\    pub inline fn selFromRaw(sel: objc.c.SEL) ?objc.Sel {
        \\        return if (sel) |ptr| .{ .value = ptr } else null;
        \\    }
        \\
        \\    pub inline fn selFromRawNonnull(sel: objc.c.SEL) objc.Sel {
        \\        return .{ .value = sel };
        \\    }
        \\
        \\    pub inline fn rawSel(sel: ?objc.Sel) objc.c.SEL {
        \\        return if (sel) |v| v.value else null;
        \\    }
        \\
        \\    /// Sends a message to an instance of a generated wrapper type.
        \\    pub fn msgSend(target: anytype, comptime Return: type, comptime sel: [:0]const u8, args: anytype) Return {
        \\        return objc.Object.fromId(target).msgSend(Return, sel, args);
        \\    }
        \\
        \\    /// Sends a message to the class object of a generated wrapper type.
        \\    pub fn msgSendClass(comptime T: type, comptime Return: type, comptime sel: [:0]const u8, args: anytype) Return {
        \\        return T.objcClass().msgSend(Return, sel, args);
        \\    }
        \\
        \\    pub fn classNamed(comptime name: [:0]const u8) objc.Class {
        \\        return objc.getClass(name) orelse @panic("Objective-C class not found: " ++ name);
        \\    }
        \\
        \\    pub fn protocolNamed(comptime name: [:0]const u8) objc.Protocol {
        \\        return objc.getProtocol(name) orelse @panic("Objective-C protocol not found: " ++ name);
        \\    }
        \\
        \\    /// Helpers shared by all wrapper types.
        \\    pub fn Helpers(comptime Self: type) type {
        \\        return struct {
        \\            /// Reinterprets the object as another wrapper type (unchecked).
        \\            pub inline fn as(self: *Self, comptime T: type) *T {
        \\                return @ptrCast(self);
        \\            }
        \\
        \\            /// The object as a zig-objc `Object`.
        \\            pub inline fn object(self: *Self) objc.Object {
        \\                return objc.Object.fromId(self);
        \\            }
        \\
        \\            pub inline fn fromObject(obj: objc.Object) ?*Self {
        \\                return @ptrCast(obj.value);
        \\            }
        \\
        \\            pub inline fn fromId(raw: objc.c.id) ?*Self {
        \\                return @ptrCast(raw);
        \\            }
        \\
        \\            /// Sends an arbitrary message; see `objc.Object.msgSend`.
        \\            pub fn msgSend(self: *Self, comptime Return: type, sel: anytype, args: anytype) Return {
        \\                return object(self).msgSend(Return, sel, args);
        \\            }
        \\        };
        \\    }
        \\
        \\    /// Helpers shared by all class wrapper types.
        \\    pub fn ClassHelpers(comptime Self: type, comptime name: [:0]const u8) type {
        \\        return struct {
        \\            // The cache must live in this struct, which is distinct for every
        \\            // `Self`/`name`; a struct declared inside `objcClass` would capture
        \\            // nothing and be shared by all wrapper types.
        \\            var cached_class: objc.c.Class = null;
        \\
        \\            /// The Objective-C class object, looked up once and cached.
        \\            pub fn objcClass() objc.Class {
        \\                if (cached_class) |ptr| return .{ .value = ptr };
        \\                const cls = classNamed(name);
        \\                cached_class = cls.value;
        \\                return cls;
        \\            }
        \\
        \\            /// Sends a message to the superclass implementation; see `objc.Object.msgSendSuper`.
        \\            pub fn msgSendSuper(self: *Self, comptime Return: type, sel: anytype, args: anytype) Return {
        \\                return objc.Object.fromId(self).msgSendSuper(Self.Super.objcClass(), Return, sel, args);
        \\            }
        \\        };
        \\    }
        \\
        \\    /// Helpers shared by all protocol wrapper types.
        \\    pub fn ProtocolHelpers(comptime name: [:0]const u8) type {
        \\        return struct {
        \\            /// The Objective-C protocol object.
        \\            pub fn objcProtocol() objc.Protocol {
        \\                return protocolNamed(name);
        \\            }
        \\        };
        \\    }
        \\
        \\    /// A pointer to an Objective-C block whose invocation signature is `Fn`
        \\    /// (without the implicit block pointer argument). Use `Type` to
        \\    /// declare a zig-objc block that can be passed where this type is
        \\    /// expected, and `init` to wrap a pointer to its context.
        \\    pub fn Block(comptime Fn: type) type {
        \\        const fn_info = @typeInfo(Fn).@"fn";
        \\        return extern struct {
        \\            value: ?*const anyopaque = null,
        \\
        \\            const Self = @This();
        \\            /// The signature as translated from C.
        \\            pub const Signature = Fn;
        \\            /// The return type, with C pointers turned into optional single-item pointers.
        \\            pub const Return = normalizedType(fn_info.return_type.?);
        \\            /// The argument types, with C pointers turned into optional single-item pointers.
        \\            pub const Args = blk: {
        \\                var types: [fn_info.params.len]type = undefined;
        \\                for (fn_info.params, 0..) |param, i| types[i] = normalizedType(param.type.?);
        \\                const result = types;
        \\                break :blk result;
        \\            };
        \\            const InvokeFn = blk: {
        \\                var params: [fn_info.params.len + 1]type = undefined;
        \\                params[0] = *const anyopaque;
        \\                for (Args, 1..) |Arg, i| params[i] = Arg;
        \\                break :blk @Fn(&params, &@splat(.{}), Return, .{ .@"callconv" = .c });
        \\            };
        \\            const Literal = extern struct {
        \\                isa: ?*anyopaque,
        \\                flags: c_int,
        \\                reserved: c_int,
        \\                invoke: *const InvokeFn,
        \\            };
        \\
        \\            pub const nil: Self = .{ .value = null };
        \\
        \\            /// A zig-objc block type with the given captures whose
        \\            /// invocation signature matches this block type.
        \\            pub fn Type(comptime Captures: type) type {
        \\                return objc.Block(Captures, Args, Return);
        \\            }
        \\
        \\            /// Wraps a pointer to a block context created with `Type(...).init`.
        \\            pub fn init(context: anytype) Self {
        \\                return .{ .value = @ptrCast(context) };
        \\            }
        \\
        \\            pub fn isNull(self: Self) bool {
        \\                return self.value == null;
        \\            }
        \\
        \\            /// Invokes the block. The block must not be null.
        \\            pub fn invoke(self: Self, args: anytype) Return {
        \\                const literal: *const Literal = @ptrCast(@alignCast(self.value.?));
        \\                return @call(.auto, literal.invoke, .{@as(*const anyopaque, @ptrCast(literal))} ++ args);
        \\            }
        \\        };
        \\    }
        \\
        \\    /// zig-objc cannot encode C pointers in block signatures, so they are
        \\    /// replaced by the ABI-compatible optional single-item pointer.
        \\    fn normalizedType(comptime T: type) type {
        \\        switch (@typeInfo(T)) {
        \\            .pointer => |p| {
        \\                if (p.size != .c) return T;
        \\                if (T == objc.c.id or T == [*c]u8 or T == [*c]const u8) return T;
        \\                return ?@Pointer(.one, .{
        \\                    .@"const" = p.is_const,
        \\                    .@"volatile" = p.is_volatile,
        \\                    .@"align" = p.alignment,
        \\                    .@"addrspace" = p.address_space,
        \\                }, p.child, null);
        \\            },
        \\            else => return T,
        \\        }
        \\    }
        \\};
        \\
        \\
    );
}

fn emitDiagnostics(cg: *Codegen) Error!void {
    for (cg.model.warnings.items) |warning| {
        try cg.print("// {s}: warning: {s}\n", .{ try cg.t.locStr(warning.loc), warning.msg });
    }
    for (cg.model.failed_decls.items) |failed| {
        const loc = try cg.t.locStr(failed.loc);
        if (cg.reserved.contains(failed.name)) {
            try cg.print("// {s}: warning: unable to translate function '{s}': {s}\n", .{ loc, failed.name, failed.reason });
        } else {
            try cg.print("pub const {f} = @compileError(\"unable to translate function: {s}\");\n// {s}\n", .{
                fmtId(failed.name), failed.reason, loc,
            });
            try cg.reserved.put(cg.gpa, failed.name, {});
        }
    }
    if (cg.model.warnings.items.len != 0 or cg.model.failed_decls.items.len != 0) try cg.write("\n");
}

// =========================
// Wrappers
// =========================

/// Collects the methods visible on `class`, own methods first, then adopted
/// protocols, then the superclass chain. Later duplicates of a selector are
/// dropped.
fn collectClassMethods(cg: *Codegen, class: *const Model.Class, entries: *std.ArrayList(Entry), seen: *std.StringHashMapUnmanaged(void)) Error!void {
    var cur: ?*const Model.Class = class;
    var visited: u32 = 0;
    while (cur) |c| : (visited += 1) {
        if (visited > 256) break; // cyclic superclass chain
        try cg.addOwnMethods(.{ .class = c }, c.methods.items, entries, seen);
        for (c.protocols.items) |proto_name| {
            if (cg.model.protocols.get(proto_name)) |p| try cg.collectProtocolMethods(p, entries, seen, 0);
        }
        cur = if (c.superclass) |super_name| cg.model.classes.get(super_name) else null;
        if (cur == c) break;
    }
}

fn collectProtocolMethods(cg: *Codegen, protocol: *const Model.Protocol, entries: *std.ArrayList(Entry), seen: *std.StringHashMapUnmanaged(void), depth: u32) Error!void {
    if (depth > 64) return;
    try cg.addOwnMethods(.{ .protocol = protocol }, protocol.methods.items, entries, seen);
    for (protocol.parents.items) |parent_name| {
        if (cg.model.protocols.get(parent_name)) |p| try cg.collectProtocolMethods(p, entries, seen, depth + 1);
    }
}

fn addOwnMethods(cg: *Codegen, owner: Owner, methods: []const *Model.Method, entries: *std.ArrayList(Entry), seen: *std.StringHashMapUnmanaged(void)) Error!void {
    for (methods) |method| {
        const key = try std.fmt.allocPrint(cg.arena, "{c}{s}", .{ @as(u8, if (method.is_class) '+' else '-'), method.selector });
        const gop = try seen.getOrPut(cg.gpa, key);
        if (gop.found_existing) continue;
        try entries.append(cg.gpa, .{
            .method = method,
            .owner = owner,
            .unavailable = cg.isUnavailable(method),
        });
    }
}

/// Converts a selector into a Zig identifier: `initWithBytes:length:` becomes
/// `initWithBytes_length`.
fn selectorToName(cg: *Codegen, selector: []const u8) Error![]const u8 {
    const buf = try cg.arena.dupe(u8, selector);
    for (buf) |*ch| if (ch.* == ':') {
        ch.* = '_';
    };
    var name: []const u8 = mem.trimEnd(u8, buf, "_");
    if (name.len == 0) name = "method";
    if (mem.eql(u8, name, "self")) name = "self_";
    return name;
}

/// Assigns unique names to `entries`. Instance methods get the plain name,
/// class methods that collide with them get a `_class` suffix, and names that
/// collide with a type get a trailing `_`.
fn assignNames(cg: *Codegen, entries: []Entry, comptime field: []const u8, reserve_helpers: bool) Error!void {
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    defer taken.deinit(cg.gpa);
    if (reserve_helpers) {
        for (helper_names) |h| try taken.put(cg.gpa, h, {});
    }
    for ([_]bool{ false, true }) |class_pass| {
        for (entries) |*entry| {
            if (entry.method.is_class != class_pass) continue;
            var name = try cg.selectorToName(entry.method.selector);
            if (class_pass and taken.contains(name)) {
                name = try std.fmt.allocPrint(cg.arena, "{s}_class", .{name});
            }
            while (taken.contains(name) or cg.type_names.contains(name)) {
                name = try std.fmt.allocPrint(cg.arena, "{s}_", .{name});
            }
            try taken.put(cg.gpa, name, {});
            @field(entry, field) = name;
        }
    }
}

fn emitClass(cg: *Codegen, class: *const Model.Class) Error!void {
    const zig_name = cg.classZigName(class.name);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(cg.gpa);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(cg.gpa);
    try cg.collectClassMethods(class, &entries, &seen);
    try cg.assignNames(entries.items, "name", true);

    // Documentation.
    try cg.print("/// Objective-C class `{s}`", .{class.name});
    if (class.superclass) |super| try cg.print(" (superclass `{s}`)", .{super});
    if (!class.defined) try cg.write(" (forward declaration only)");
    try cg.write("\n");
    if (class.generic_params.items.len != 0) {
        try cg.write("/// Generic parameters: ");
        for (class.generic_params.items, 0..) |param, i| {
            if (i != 0) try cg.write(", ");
            try cg.print("`{s}`", .{param});
        }
        try cg.write(" (erased to `objc.Object`)\n");
    }
    if (class.protocols.items.len != 0) {
        try cg.write("/// Adopted protocols: ");
        for (class.protocols.items, 0..) |name, i| {
            if (i != 0) try cg.write(", ");
            try cg.print("`{s}`", .{name});
        }
        try cg.write("\n");
    }
    try cg.print("pub const {f} = opaque {{\n", .{fmtId(zig_name)});
    try cg.print("    pub const objc_class_name = \"{s}\";\n", .{class.name});
    const super_known = if (class.superclass) |super| cg.model.classes.contains(super) else false;
    if (class.superclass) |super| {
        if (super_known) {
            try cg.print("    pub const Super = {f};\n", .{fmtId(cg.classZigName(super))});
        } else {
            try cg.print("    // The superclass `{s}` is not declared in this translation unit.\n", .{super});
        }
    }
    try cg.write("    pub const objcClass = __objc.ClassHelpers(@This(), objc_class_name).objcClass;\n");
    if (super_known) {
        try cg.write("    pub const msgSendSuper = __objc.ClassHelpers(@This(), objc_class_name).msgSendSuper;\n");
    }
    try cg.emitCommonHelpers();
    try cg.emitAliases(entries.items);
    try cg.write("};\n\n");

    try cg.emitMixin(.{ .class = class }, class.methods.items);
}

fn emitProtocol(cg: *Codegen, protocol: *const Model.Protocol) Error!void {
    const zig_name = cg.protocol_names.get(protocol.name).?;

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(cg.gpa);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(cg.gpa);
    try cg.collectProtocolMethods(protocol, &entries, &seen, 0);
    try cg.assignNames(entries.items, "name", true);

    try cg.print("/// Objective-C protocol `{s}`", .{protocol.name});
    if (!protocol.defined) try cg.write(" (forward declaration only)");
    try cg.write("\n");
    if (protocol.parents.items.len != 0) {
        try cg.write("/// Conforms to: ");
        for (protocol.parents.items, 0..) |name, i| {
            if (i != 0) try cg.write(", ");
            try cg.print("`{s}`", .{name});
        }
        try cg.write("\n");
    }
    try cg.print("pub const {f} = opaque {{\n", .{fmtId(zig_name)});
    try cg.print("    pub const objc_protocol_name = \"{s}\";\n", .{protocol.name});
    try cg.write("    pub const objcProtocol = __objc.ProtocolHelpers(objc_protocol_name).objcProtocol;\n");
    try cg.emitCommonHelpers();
    // Class methods cannot be called through a protocol wrapper.
    var instance_entries: std.ArrayList(Entry) = .empty;
    defer instance_entries.deinit(cg.gpa);
    for (entries.items) |entry| {
        if (!entry.method.is_class) try instance_entries.append(cg.gpa, entry);
    }
    try cg.emitAliases(instance_entries.items);
    try cg.write("};\n\n");

    try cg.emitMixin(.{ .protocol = protocol }, protocol.methods.items);
}

fn emitCommonHelpers(cg: *Codegen) Error!void {
    try cg.write(
        \\    pub const as = __objc.Helpers(@This()).as;
        \\    pub const object = __objc.Helpers(@This()).object;
        \\    pub const fromObject = __objc.Helpers(@This()).fromObject;
        \\    pub const fromId = __objc.Helpers(@This()).fromId;
        \\    pub const msgSend = __objc.Helpers(@This()).msgSend;
        \\
    );
}

/// Emits the `pub const name = mixin(@This()).name;` lines of a wrapper.
fn emitAliases(cg: *Codegen, entries: []const Entry) Error!void {
    // Group by owner for readability, preserving the first-seen order.
    var owners: std.ArrayList(Owner) = .empty;
    defer owners.deinit(cg.gpa);
    for (entries) |entry| {
        for (owners.items) |o| {
            if (ownerEql(o, entry.owner)) break;
        } else try owners.append(cg.gpa, entry.owner);
    }

    for (owners.items) |owner| {
        // The mixin's own naming must be reproduced to reference its functions.
        var own_entries: std.ArrayList(Entry) = .empty;
        defer own_entries.deinit(cg.gpa);
        const methods = switch (owner) {
            .class => |c| c.methods.items,
            .protocol => |p| p.methods.items,
        };
        for (methods) |method| try own_entries.append(cg.gpa, .{ .method = method, .owner = owner });
        try cg.assignNames(own_entries.items, "mixin_name", false);

        var header_written = false;
        for (entries) |entry| {
            if (!ownerEql(entry.owner, owner)) continue;
            if (entry.unavailable) continue;
            if ((cg.specs.get(entry.method.proto_name) orelse null) == null) continue;
            const mixin_name = for (own_entries.items) |own| {
                if (own.method == entry.method) break own.mixin_name;
            } else continue;
            if (!header_written) {
                header_written = true;
                switch (owner) {
                    .class => |c| try cg.print("\n    // Methods of class `{s}`\n", .{c.name}),
                    .protocol => |p| try cg.print("\n    // Methods of protocol `{s}`\n", .{p.name}),
                }
            }
            try cg.print("    pub const {f} = {s}(@This()).{f};\n", .{
                fmtId(entry.name), try mixinName(cg.arena, owner), fmtId(mixin_name),
            });
        }
    }
}

fn ownerEql(a: Owner, b: Owner) bool {
    return switch (a) {
        .class => |c| b == .class and b.class == c,
        .protocol => |p| b == .protocol and b.protocol == p,
    };
}

// =========================
// Split mode
// =========================

/// Generates the wrapper and the mixin of `owner` into a file of their own
/// and re-exports the wrapper from the root file.
fn emitSplitFile(cg: *Codegen, zig_name: []const u8, owner: Owner) Error!void {
    const split = cg.split.?;
    const file_name = cg.file_names.get(zig_name).?;

    var body_out: std.Io.Writer.Allocating = .init(cg.gpa);
    defer body_out.deinit();
    {
        cg.cur = &body_out;
        defer cg.cur = &cg.out;
        switch (owner) {
            .class => |class| try cg.emitClass(class),
            .protocol => |protocol| try cg.emitProtocol(protocol),
        }
    }
    const body = try body_out.toOwnedSliceSentinel(0);
    defer cg.gpa.free(body);

    var text: std.Io.Writer.Allocating = .init(cg.gpa);
    defer text.deinit();
    try cg.writeSplitHeader(&text.writer, file_name, body);
    text.writer.writeAll(body) catch return error.OutOfMemory;
    const raw = try text.toOwnedSliceSentinel(0);
    defer cg.gpa.free(raw);

    const formatted = try cg.formatRaw(cg.gpa, raw);
    errdefer cg.gpa.free(formatted);
    const name = try cg.gpa.dupe(u8, file_name);
    errdefer cg.gpa.free(name);
    try split.files.append(cg.gpa, .{ .name = name, .text = formatted });

    try cg.print("pub const {f} = @import(\"", .{fmtId(zig_name)});
    if (split.import_prefix.len != 0) {
        try cg.writeStringContents(split.import_prefix);
        try cg.write("/");
    }
    try cg.writeStringContents(file_name);
    try cg.print("\").{f};\n", .{fmtId(zig_name)});
}

/// Writes the imports a wrapper file needs: the file is scanned for
/// identifiers that name declarations of the root file, other wrappers or
/// other mixins. Declared names (`fn name`, `name =`, `name:`) and fields
/// (`.name`) are not references to file scope.
fn writeSplitHeader(cg: *Codegen, w: *std.Io.Writer, file_name: []const u8, body: [:0]const u8) Error!void {
    const split = cg.split.?;

    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer names.deinit(cg.gpa);
    var tokenizer: std.zig.Tokenizer = .init(body);
    var prev: std.zig.Token.Tag = .invalid;
    // An identifier is only known to be a reference once the next token is
    // seen: `name =` and `name:` declare rather than reference.
    var pending: ?std.zig.Token = null;
    while (true) {
        const tok = tokenizer.next();
        if (pending) |candidate| {
            pending = null;
            if (tok.tag != .equal and tok.tag != .colon) {
                const raw = body[candidate.loc.start..candidate.loc.end];
                const name = if (raw[0] == '@')
                    std.zig.string_literal.parseAlloc(cg.arena, raw[1..]) catch null
                else
                    raw;
                if (name) |n| try names.put(cg.gpa, n, {});
            }
        }
        if (tok.tag == .eof) break;
        defer prev = tok.tag;
        if (tok.tag != .identifier) continue;
        switch (prev) {
            .period, .keyword_fn => continue,
            else => {},
        }
        pending = tok;
    }
    const keys = names.keys();
    mem.sort([]const u8, keys, {}, stringLessThan);

    // The root file: `../` once per component of the import prefix.
    w.writeAll("const __root = @import(\"") catch return error.OutOfMemory;
    var components = mem.tokenizeScalar(u8, split.import_prefix, '/');
    while (components.next() != null) w.writeAll("../") catch return error.OutOfMemory;
    try writeStringContentsTo(w, split.root_basename);
    w.writeAll("\");\n") catch return error.OutOfMemory;

    for (keys) |name| {
        if (mem.eql(u8, name, "__root") or mem.eql(u8, name, "Self")) continue;
        if (mem.eql(u8, name, "objc")) {
            w.writeAll("const objc = @import(\"objc\");\n") catch return error.OutOfMemory;
        } else if (mem.eql(u8, name, "std")) {
            w.writeAll("const std = @import(\"std\");\n") catch return error.OutOfMemory;
        } else if (mem.eql(u8, name, "__objc")) {
            w.writeAll("const __objc = __root.__objc;\n") catch return error.OutOfMemory;
        } else if (cg.file_names.get(name) orelse cg.mixin_files.get(name)) |file| {
            if (mem.eql(u8, file, file_name)) continue;
            w.print("const {f} = @import(\"", .{fmtId(name)}) catch return error.OutOfMemory;
            try writeStringContentsTo(w, file);
            w.print("\").{f};\n", .{fmtId(name)}) catch return error.OutOfMemory;
        } else if (cg.isRootName(name)) {
            w.print("const {f} = __root.{f};\n", .{ fmtId(name), fmtId(name) }) catch return error.OutOfMemory;
        }
    }
    w.writeAll("\n") catch return error.OutOfMemory;
}

/// Whether `name` is declared at the top level of the root file. Besides the
/// names collected up front, this includes the C types that were translated
/// on demand while generating method signatures.
fn isRootName(cg: *const Codegen, name: []const u8) bool {
    if (cg.reserved.contains(name) or cg.type_names.contains(name)) return true;
    const t = cg.t;
    return t.global_scope.sym_table.contains(name) or t.global_names.contains(name) or
        t.weak_global_names.contains(name) or t.typedefs.contains(name);
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return mem.order(u8, a, b) == .lt;
}

/// Writes `text` as the contents of a Zig string literal.
fn writeStringContents(cg: *Codegen, text: []const u8) Error!void {
    try writeStringContentsTo(&cg.cur.writer, text);
}

fn writeStringContentsTo(w: *std.Io.Writer, text: []const u8) Error!void {
    for (text) |c| {
        switch (c) {
            '"', '\\' => w.print("\\{c}", .{c}) catch return error.OutOfMemory,
            else => w.writeByte(c) catch return error.OutOfMemory,
        }
    }
}

// =========================
// Mixins
// =========================

fn emitMixin(cg: *Codegen, owner: Owner, methods: []const *Model.Method) Error!void {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(cg.gpa);
    for (methods) |method| try entries.append(cg.gpa, .{ .method = method, .owner = owner });
    try cg.assignNames(entries.items, "mixin_name", false);

    var emitted: usize = 0;
    for (entries.items) |entry| {
        if ((cg.specs.get(entry.method.proto_name) orelse null) != null) emitted += 1;
    }
    // A generic function with an unused `Self` parameter does not compile.
    if (emitted == 0) return;

    switch (owner) {
        .class => |c| try cg.print("/// Methods declared by the Objective-C class `{s}`, generic over the receiver type.\n", .{c.name}),
        .protocol => |p| try cg.print("/// Methods declared by the Objective-C protocol `{s}`, generic over the receiver type.\n", .{p.name}),
    }
    try cg.print("pub fn {s}(comptime Self: type) type {{\n    return struct {{\n", .{try mixinName(cg.arena, owner)});
    for (entries.items) |entry| {
        if (cg.isUnavailable(entry.method)) continue;
        const specs = (cg.specs.get(entry.method.proto_name) orelse null) orelse {
            try cg.print("        // `{s}` was not translated: unsupported type\n", .{entry.method.source});
            continue;
        };
        try cg.emitMethod(entry, specs);
    }
    try cg.write("    };\n}\n\n");
}

const TypeKind = enum { plain, void_, bool_, object, id, class_ref, sel, block };

const TypeSpec = struct {
    /// The type used in the wrapper's signature.
    zig: []const u8,
    /// The type used with `msgSend`.
    abi: []const u8,
    kind: TypeKind,
    nullable: bool,
};

const MethodError = Error || error{UnsupportedType};

/// Translates the types of a method's signature.
fn computeSpecs(cg: *Codegen, method: *const Model.Method, mixin_names: *const std.StringHashMapUnmanaged(void)) MethodError!MethodSpecs {
    const decl = cg.protos.get(method.proto_name) orelse return error.UnsupportedType;
    const function = decl.get(cg.t.tree).function;
    const func_ty = function.qt.get(cg.t.comp, .func) orelse return error.UnsupportedType;

    // Return type.
    const ret: TypeSpec = if (method.returns_instancetype) blk: {
        const nullable = resolveNullability(pointerNullability(cg.t.comp, func_ty.return_type), method.return_info.nullability, method.assume_nonnull);
        break :blk .{
            .zig = if (nullable) "?*Self" else "*Self",
            .abi = if (nullable) "?*Self" else "*Self",
            .kind = .object,
            .nullable = nullable,
        };
    } else try cg.classify(func_ty.return_type, method.return_info, method.assume_nonnull, function.name_tok);

    // Parameters.
    var params: std.ArrayList(ParamSpec) = .empty;
    defer params.deinit(cg.gpa);
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    defer taken.deinit(cg.gpa);
    try taken.put(cg.gpa, "self", {});
    try taken.put(cg.gpa, "Self", {});
    for (func_ty.params, 0..) |param, i| {
        const info: Model.TypeInfo = if (i < method.params.len) method.params[i].info else .{};
        const spec = try cg.classify(param.qt, info, method.assume_nonnull, param.name_tok);
        const base_name = if (i < method.params.len and method.params[i].name.len != 0) method.params[i].name else try std.fmt.allocPrint(cg.arena, "arg{d}", .{i});
        var name = base_name;
        while (cg.reserved.contains(name) or mixin_names.contains(name) or taken.contains(name)) {
            name = try std.fmt.allocPrint(cg.arena, "{s}_", .{name});
        }
        try taken.put(cg.gpa, name, {});
        try params.append(cg.gpa, .{ .name = name, .spec = spec });
    }
    return .{ .ret = ret, .params = try cg.arena.dupe(ParamSpec, params.items) };
}

fn emitMethod(cg: *Codegen, entry: Entry, specs: MethodSpecs) Error!void {
    const method = entry.method;
    const ret = specs.ret;
    const params = specs.params;

    // Documentation.
    try cg.print("        /// `{s}`\n", .{method.source});
    switch (method.kind) {
        .method => {},
        .getter => try cg.write("        /// Property getter.\n"),
        .setter => try cg.write("        /// Property setter.\n"),
    }
    if (method.optional) try cg.write("        /// Optional protocol method.\n");
    if (method.variadic) try cg.write("        /// Variadic: only the fixed arguments are supported.\n");
    try cg.emitAvailabilityDocs(method);

    // Signature.
    try cg.print("        pub fn {f}(", .{fmtId(entry.mixin_name)});
    if (!method.is_class) try cg.write("self: *Self");
    for (params, 0..) |param, i| {
        if (i != 0 or !method.is_class) try cg.write(", ");
        try cg.print("{f}: {s}", .{ fmtId(param.name), param.spec.zig });
    }
    try cg.print(") {s} {{\n", .{ret.zig});

    // Body.
    var call_buf: std.Io.Writer.Allocating = .init(cg.gpa);
    defer call_buf.deinit();
    const call_w = &call_buf.writer;
    if (method.is_class) {
        call_w.print("__objc.msgSendClass(Self, {s}, \"{s}\", .{{", .{ ret.abi, method.selector }) catch return error.OutOfMemory;
    } else {
        call_w.print("__objc.msgSend(self, {s}, \"{s}\", .{{", .{ ret.abi, method.selector }) catch return error.OutOfMemory;
    }
    for (params, 0..) |param, i| {
        if (i != 0) call_w.writeAll(", ") catch return error.OutOfMemory;
        const ident = try std.fmt.allocPrint(cg.arena, "{f}", .{fmtId(param.name)});
        const conversion: []const u8 = switch (param.spec.kind) {
            .bool_ => "__objc.toBOOL",
            .id => if (param.spec.nullable) "__objc.idOf" else "",
            .class_ref => if (param.spec.nullable) "__objc.rawClass" else "",
            .sel => if (param.spec.nullable) "__objc.rawSel" else "",
            else => "",
        };
        if (conversion.len != 0) {
            call_w.print("{s}({s})", .{ conversion, ident }) catch return error.OutOfMemory;
        } else {
            call_w.writeAll(ident) catch return error.OutOfMemory;
        }
    }
    call_w.writeAll("})") catch return error.OutOfMemory;
    const call: struct { items: []const u8 } = .{ .items = call_buf.written() };

    switch (ret.kind) {
        .void_ => try cg.print("            {s};\n", .{call.items}),
        .bool_ => try cg.print("            return __objc.fromBOOL({s});\n", .{call.items}),
        .id => if (ret.nullable) {
            try cg.print("            return __objc.objectFromId({s});\n", .{call.items});
        } else try cg.print("            return {s};\n", .{call.items}),
        .class_ref => if (ret.nullable) {
            try cg.print("            return __objc.classFromRaw({s});\n", .{call.items});
        } else try cg.print("            return __objc.classFromRawNonnull({s});\n", .{call.items}),
        .sel => if (ret.nullable) {
            try cg.print("            return __objc.selFromRaw({s});\n", .{call.items});
        } else try cg.print("            return __objc.selFromRawNonnull({s});\n", .{call.items}),
        else => try cg.print("            return {s};\n", .{call.items}),
    }
    try cg.write("        }\n");
}

fn emitAvailabilityDocs(cg: *Codegen, method: *const Model.Method) Error!void {
    const attributes = method.attributes;
    if (attributes.deprecated) |msg| {
        try cg.write("        /// Deprecated");
        if (msg.len != 0) try cg.print(": {s}", .{msg});
        try cg.write("\n");
    }
    for (attributes.availability) |a| {
        if (a.deprecated == null and a.obsoleted == null and !a.unavailable) continue;
        try cg.print("        /// Availability ({s}):", .{a.platform});
        if (a.deprecated) |v| try cg.print(" deprecated in {s}", .{v});
        if (a.obsoleted) |v| try cg.print(" obsoleted in {s}", .{v});
        if (a.unavailable) try cg.write(" unavailable");
        if (a.message) |m| try cg.print(" ({s})", .{m});
        try cg.write("\n");
    }
}

/// Whether a method is marked unavailable for the target platform.
fn isUnavailable(cg: *Codegen, method: *const Method) bool {
    const attributes = method.attributes;
    if (attributes.unavailable != null) return true;
    const os = cg.t.comp.target.os.tag;
    for (attributes.availability) |a| {
        if (!a.unavailable) continue;
        const p = a.platform;
        const matches = if (mem.eql(u8, p, "macos") or mem.eql(u8, p, "macosx"))
            os == .macos
        else if (mem.eql(u8, p, "ios") or mem.eql(u8, p, "iphoneos"))
            os == .ios
        else if (mem.eql(u8, p, "tvos"))
            os == .tvos
        else if (mem.eql(u8, p, "watchos"))
            os == .watchos
        else if (mem.eql(u8, p, "driverkit"))
            os == .driverkit
        else if (mem.eql(u8, p, "visionos") or mem.eql(u8, p, "xros"))
            os == .visionos
        else
            false;
        if (matches) return true;
    }
    return false;
}

const Method = Model.Method;

fn pointerNullability(comp: *const aro.Compilation, qt: QualType) Nullability {
    return switch (qt.type(comp)) {
        .pointer => |p| p.nullability,
        else => .default,
    };
}

fn resolveNullability(pointer: Nullability, info: Model.Nullability, assume_nonnull: bool) bool {
    switch (pointer) {
        .nonnull => return false,
        .nullable, .nullable_result, .unspecified => return true,
        .default => {},
    }
    return switch (info) {
        .nonnull => false,
        .nullable => true,
        .default => !assume_nonnull,
    };
}

/// Determines how a C type from a synthetic prototype maps to Zig.
fn classify(cg: *Codegen, qt: QualType, info: Model.TypeInfo, assume_nonnull: bool, tok: aro.Tree.TokenIndex) MethodError!TypeSpec {
    const comp = cg.t.comp;
    var cur = qt;
    var depth: u32 = 0;
    while (depth < 32) : (depth += 1) {
        switch (cur.type(comp)) {
            .typedef => |td| {
                const name = td.name.lookup(comp);
                if (mem.eql(u8, name, "BOOL")) {
                    return .{ .zig = "bool", .abi = "objc.c.BOOL", .kind = .bool_, .nullable = false };
                }
                if (mem.eql(u8, name, "id")) {
                    return cg.idSpec(info, resolveNullability(.default, info.nullability, assume_nonnull));
                }
                if (mem.eql(u8, name, "Class")) {
                    return classRefSpec(resolveNullability(.default, info.nullability, assume_nonnull));
                }
                if (mem.eql(u8, name, "SEL")) {
                    return selSpec(resolveNullability(.default, info.nullability, assume_nonnull));
                }
                if (cg.model.classes.contains(name)) break; // an object by value; not meaningful
                cur = td.base;
            },
            .pointer => |p| {
                const nullable = resolveNullability(p.nullability, info.nullability, assume_nonnull);
                switch (p.child.type(comp)) {
                    .typedef => |td| {
                        const name = td.name.lookup(comp);
                        if (mem.cutPrefix(u8, name, "__objc_proto_")) |protocol| {
                            if (cg.protocol_names.get(protocol)) |zig_name| {
                                const zig = try std.fmt.allocPrint(cg.arena, "{s}*{f}", .{ if (nullable) "?" else "", fmtId(zig_name) });
                                return .{ .zig = zig, .abi = zig, .kind = .object, .nullable = nullable };
                            }
                        }
                        if (cg.model.classes.contains(name)) {
                            const zig = try std.fmt.allocPrint(cg.arena, "{s}*{f}", .{ if (nullable) "?" else "", fmtId(cg.classZigName(name)) });
                            return .{ .zig = zig, .abi = zig, .kind = .object, .nullable = nullable };
                        }
                    },
                    .@"struct" => |record| {
                        const name = record.name.lookup(comp);
                        if (mem.eql(u8, name, "objc_object")) return cg.idSpec(info, nullable);
                        if (mem.eql(u8, name, "objc_class")) return classRefSpec(nullable);
                        if (mem.eql(u8, name, "objc_selector")) return selSpec(nullable);
                        if (mem.startsWith(u8, name, "__objc_block_")) {
                            const node = try cg.t.transObjcBlockType(name, tok);
                            const text = try cg.typeText(node);
                            return .{ .zig = text, .abi = text, .kind = .block, .nullable = true };
                        }
                    },
                    else => {},
                }
                break;
            },
            .void => return .{ .zig = "void", .abi = "void", .kind = .void_, .nullable = false },
            else => break,
        }
    }
    const node = cg.t.transType(&cg.t.global_scope.base, qt, tok) catch |err| switch (err) {
        error.UnsupportedType => return error.UnsupportedType,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // A struct that was demoted to an opaque type (bitfields, ...) cannot be
    // passed or returned by value.
    if (cg.t.typeIsOpaque(qt) or cg.t.typeWasDemotedToOpaque(qt)) return error.UnsupportedType;
    const text = try cg.typeText(node);
    return .{ .zig = text, .abi = text, .kind = .plain, .nullable = false };
}

fn idSpec(cg: *Codegen, info: Model.TypeInfo, nullable: bool) Error!TypeSpec {
    // `id<Protocol>` becomes a pointer to the protocol wrapper.
    if (info.protocols.len != 0) {
        if (cg.protocol_names.get(info.protocols[0])) |zig_name| {
            const zig = try std.fmt.allocPrint(cg.arena, "{s}*{f}", .{ if (nullable) "?" else "", fmtId(zig_name) });
            return .{ .zig = zig, .abi = zig, .kind = .object, .nullable = nullable };
        }
    }
    return .{
        .zig = if (nullable) "?objc.Object" else "objc.Object",
        .abi = if (nullable) "objc.c.id" else "objc.Object",
        .kind = .id,
        .nullable = nullable,
    };
}

fn classRefSpec(nullable: bool) TypeSpec {
    return .{
        .zig = if (nullable) "?objc.Class" else "objc.Class",
        .abi = "objc.c.Class",
        .kind = .class_ref,
        .nullable = nullable,
    };
}

fn selSpec(nullable: bool) TypeSpec {
    return .{
        .zig = if (nullable) "?objc.Sel" else "objc.Sel",
        .abi = "objc.c.SEL",
        .kind = .sel,
        .nullable = nullable,
    };
}

/// Renders a translated type node as Zig source text.
fn typeText(cg: *Codegen, node: ZigNode) Error![]const u8 {
    const decl = try ZigTag.var_simple.create(cg.arena, .{ .name = "__t", .init = node });
    var zig_ast = try ast.render(cg.gpa, &.{decl});
    defer {
        cg.gpa.free(zig_ast.source);
        zig_ast.deinit(cg.gpa);
    }
    var rendered: std.Io.Writer.Allocating = .init(cg.gpa);
    defer rendered.deinit();
    zig_ast.render(cg.gpa, &rendered.writer, .{}) catch return error.OutOfMemory;
    const text = mem.trim(u8, rendered.written(), " \n");
    const prefix = "const __t = ";
    assert(mem.startsWith(u8, text, prefix));
    var body = text[prefix.len..];
    if (mem.endsWith(u8, body, ";")) body = body[0 .. body.len - 1];
    return cg.arena.dupe(u8, body);
}

// The generated `__objc.ClassHelpers` caches the class object in a container
// level `var` of the struct it returns. That struct captures `Self` and `name`,
// so every wrapper type gets its own cache. A struct declared inside the
// function body would capture nothing and be shared by all instantiations.
test "per-instantiation class cache pattern" {
    const Helpers = struct {
        fn ClassHelpers(comptime Self: type, comptime name: []const u8) type {
            return struct {
                var cached: ?[]const u8 = null;
                fn class() []const u8 {
                    if (cached) |c| return c;
                    cached = name;
                    _ = Self;
                    return name;
                }
            };
        }
    };
    const A = opaque {};
    const B = opaque {};
    try std.testing.expectEqualStrings("A", Helpers.ClassHelpers(A, "A").class());
    try std.testing.expectEqualStrings("B", Helpers.ClassHelpers(B, "B").class());
    try std.testing.expectEqualStrings("A", Helpers.ClassHelpers(A, "A").class());
}

test "split file header imports what the wrapper references" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var files: std.ArrayList(File) = .empty;
    defer files.deinit(gpa);
    // Only the name tables of the translator are consulted.
    var translator: Translator = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .alias_list = .empty,
        .global_scope = try arena_state.allocator().create(Scope.Root),
        .comp = undefined,
        .pp = undefined,
        .tree = undefined,
        .pub_static = false,
        .func_bodies = false,
        .keep_macro_literals = false,
        .default_init = false,
        .strict_flex_arrays = .@"2",
        .objc_model = null,
        .objc_mode = false,
    };
    translator.global_scope.* = Scope.Root.init(&translator);
    defer translator.global_scope.deinit();
    defer translator.typedefs.deinit(gpa);
    try translator.typedefs.put(gpa, "CGFloat", {});
    try translator.global_scope.sym_table.put(gpa, "struct_CGPath", ZigTag.opaque_literal.init());
    var cg: Codegen = .{
        .t = &translator,
        .model = undefined,
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .out = .init(gpa),
        .split = .{ .import_prefix = "c.objc", .root_basename = "c.zig", .files = &files },
    };
    defer cg.deinit();
    cg.cur = &cg.out;
    try cg.file_names.put(gpa, "NSWindow", "NSWindow.zig");
    try cg.file_names.put(gpa, "NSString", "NSString.zig");
    try cg.mixin_files.put(gpa, "__objc_methods_NSWindow", "NSWindow.zig");
    try cg.mixin_files.put(gpa, "__objc_methods_NSObject", "NSObject.zig");
    for ([_][]const u8{ "objc", "__objc", "__root", "std", "NSRect", "frame", "error" }) |name| try cg.reserved.put(gpa, name, {});
    for ([_][]const u8{ "Self", "NSRect", "NSWindow", "NSString" }) |name| try cg.type_names.put(gpa, name, {});

    const body =
        \\pub const NSWindow = opaque {
        \\    pub const as = __objc.Helpers(@This()).as;
        \\    pub const hash = __objc_methods_NSObject(@This()).hash;
        \\    pub const frame = __objc_methods_NSWindow(@This()).frame;
        \\    pub const @"error" = __objc_methods_NSWindow(@This()).@"error";
        \\};
        \\pub fn __objc_methods_NSWindow(comptime Self: type) type {
        \\    return struct {
        \\        pub fn frame(self: *Self, title: ?*NSString, x: CGFloat, path: ?*const struct_CGPath) NSRect {
        \\            return __objc.msgSend(self, NSRect, "frame", .{ objc.Object.fromId(title), x, path });
        \\        }
        \\        pub fn @"error"(self: *Self, code: @"error") void {
        \\            _ = self;
        \\            _ = code;
        \\        }
        \\    };
        \\}
        \\
    ;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try cg.writeSplitHeader(&text.writer, "NSWindow.zig", body);
    try std.testing.expectEqualStrings(
        \\const __root = @import("../c.zig");
        \\const CGFloat = __root.CGFloat;
        \\const NSRect = __root.NSRect;
        \\const NSString = @import("NSString.zig").NSString;
        \\const __objc = __root.__objc;
        \\const __objc_methods_NSObject = @import("NSObject.zig").__objc_methods_NSObject;
        \\const @"error" = __root.@"error";
        \\const objc = @import("objc");
        \\const struct_CGPath = __root.struct_CGPath;
        \\
        \\
    , text.written());
}
