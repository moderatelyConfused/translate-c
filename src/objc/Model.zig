//! The Objective-C declarations found in a translation unit.
//!
//! The model is produced by `Rewriter` while it turns Objective-C syntax into
//! plain C for Aro, and consumed by `Codegen` which turns it into Zig bindings
//! that use zig-objc. Type information is *not* stored here: every method and
//! property is mirrored by a synthetic C prototype (`__objc_m_<n>`) that Aro
//! parses like any other declaration, and `Codegen` looks the types up in the
//! resulting AST.
const Model = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const aro = @import("aro");
const Source = aro.Source;

/// All strings and slices in the model are allocated in this arena, which is
/// owned by the caller.
arena: Allocator,

/// Whether any Objective-C construct was found. When this is false the token
/// stream was left untouched (apart from block declarators).
enabled: bool = false,
/// Whether any block declarator (`^`) was rewritten.
has_blocks: bool = false,

/// Classes in the order they were first mentioned, keyed by name.
classes: std.StringArrayHashMapUnmanaged(*Class) = .empty,
/// Protocols in the order they were first mentioned, keyed by name.
protocols: std.StringArrayHashMapUnmanaged(*Protocol) = .empty,
/// `@compatibility_alias` declarations.
aliases: std.ArrayList(Alias) = .empty,
/// Typedef names (in C or Objective-C code) whose type is a block pointer.
block_typedefs: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Number of synthetic block types (`struct __objc_block_<n>`) created so far.
block_count: u32 = 0,
/// Number of synthetic method prototypes (`__objc_m_<n>`) created so far.
method_count: u32 = 0,

/// Diagnostics produced while rewriting; rendered as comments in the output.
warnings: std.ArrayList(Warning) = .empty,
/// Function definitions that were dropped because their body uses
/// Objective-C syntax that cannot be translated.
failed_decls: std.ArrayList(FailedDecl) = .empty,

pub const Warning = struct {
    loc: Source.Location,
    msg: []const u8,
};

pub const FailedDecl = struct {
    loc: Source.Location,
    name: []const u8,
    reason: []const u8,
};

pub const Alias = struct {
    loc: Source.Location,
    /// The new name introduced by the alias.
    name: []const u8,
    /// The class being aliased.
    target: []const u8,
};

pub const Nullability = enum {
    /// No explicit annotation; depends on `assume_nonnull`.
    default,
    nonnull,
    nullable,
};

/// A parsed `availability(...)` attribute.
pub const Availability = struct {
    platform: []const u8,
    introduced: ?[]const u8 = null,
    deprecated: ?[]const u8 = null,
    obsoleted: ?[]const u8 = null,
    unavailable: bool = false,
    message: ?[]const u8 = null,
};

/// The attributes of a declaration that matter for the bindings.
pub const Attributes = struct {
    /// `__attribute__((unavailable))`, with its optional message.
    unavailable: ?[]const u8 = null,
    /// `__attribute__((deprecated))`, with its optional message.
    deprecated: ?[]const u8 = null,
    availability: []const Availability = &.{},

    pub fn isUnavailable(a: Attributes) bool {
        return a.unavailable != null;
    }
};

pub const Method = struct {
    /// The Objective-C selector, e.g. `initWithBytes:length:`.
    selector: []const u8,
    /// Whether this is a class method (`+`) rather than an instance method (`-`).
    is_class: bool,
    /// Name of the synthetic C prototype that carries the types.
    proto_name: []const u8,
    /// Where the prototype's parameters came from. Same length as the
    /// prototype's parameter list.
    params: []const Param,
    /// Whether the return type was written as `instancetype`.
    returns_instancetype: bool,
    /// Extra Objective-C information about the return type.
    return_info: TypeInfo,
    /// The method takes variable arguments.
    variadic: bool,
    /// Declared in an `@optional` section of a protocol.
    optional: bool,
    /// The declaration appeared inside `NS_ASSUME_NONNULL_BEGIN/END`.
    assume_nonnull: bool,
    /// How the method was declared.
    kind: Kind,
    attributes: Attributes = .{},
    /// The original declaration, single line, for documentation.
    source: []const u8,
    loc: Source.Location,

    pub const Kind = enum { method, getter, setter };
};

pub const Param = struct {
    /// The parameter name as written in Objective-C.
    name: []const u8,
    info: TypeInfo,
};

/// Objective-C information about a type that is lost in the C rewrite.
pub const TypeInfo = struct {
    /// Protocols a `id<...>` or `Class<...>` type was qualified with.
    protocols: []const []const u8 = &.{},
    /// Explicit Objective-C nullability keyword (`nullable`, `nonnull`, ...)
    /// or `_Nullable`-style qualifier at the outermost level.
    nullability: Nullability = .default,
};

pub const Property = struct {
    name: []const u8,
    getter: *Method,
    /// `null` for read-only properties.
    setter: ?*Method,
    is_class: bool,
    /// Raw attribute list, e.g. `nonatomic, copy`, for documentation.
    attributes: []const u8,
    loc: Source.Location,
};

pub const Class = struct {
    name: []const u8,
    /// `null` for root classes and classes that were only forward-declared.
    superclass: ?[]const u8 = null,
    /// Adopted protocols, from the interface and all categories.
    protocols: std.ArrayList([]const u8) = .empty,
    /// Generic type parameters, for documentation.
    generic_params: std.ArrayList([]const u8) = .empty,
    /// Category names, for documentation.
    categories: std.ArrayList([]const u8) = .empty,
    /// Whether an `@interface` (not just `@class`) was seen.
    defined: bool = false,
    /// All methods, including property accessors, in declaration order.
    methods: std.ArrayList(*Method) = .empty,
    properties: std.ArrayList(*Property) = .empty,
    loc: Source.Location,
};

pub const Protocol = struct {
    name: []const u8,
    /// Protocols this protocol conforms to.
    parents: std.ArrayList([]const u8) = .empty,
    /// Whether a full `@protocol ... @end` was seen.
    defined: bool = false,
    methods: std.ArrayList(*Method) = .empty,
    properties: std.ArrayList(*Property) = .empty,
    loc: Source.Location,
};

pub fn init(arena: Allocator) Model {
    return .{ .arena = arena };
}

pub fn getOrCreateClass(m: *Model, name: []const u8, loc: Source.Location) !*Class {
    const gop = try m.classes.getOrPut(m.arena, name);
    if (gop.found_existing) return gop.value_ptr.*;
    const owned_name = try m.arena.dupe(u8, name);
    gop.key_ptr.* = owned_name;
    const class = try m.arena.create(Class);
    class.* = .{ .name = owned_name, .loc = loc };
    gop.value_ptr.* = class;
    m.enabled = true;
    return class;
}

pub fn getOrCreateProtocol(m: *Model, name: []const u8, loc: Source.Location) !*Protocol {
    const gop = try m.protocols.getOrPut(m.arena, name);
    if (gop.found_existing) return gop.value_ptr.*;
    const owned_name = try m.arena.dupe(u8, name);
    gop.key_ptr.* = owned_name;
    const protocol = try m.arena.create(Protocol);
    protocol.* = .{ .name = owned_name, .loc = loc };
    gop.value_ptr.* = protocol;
    m.enabled = true;
    return protocol;
}

pub fn warn(m: *Model, loc: Source.Location, comptime fmt: []const u8, args: anytype) !void {
    try m.warnings.append(m.arena, .{
        .loc = loc,
        .msg = try std.fmt.allocPrint(m.arena, fmt, args),
    });
}

/// Returns the name of a fresh synthetic method prototype.
pub fn nextProtoName(m: *Model) ![]const u8 {
    const name = try std.fmt.allocPrint(m.arena, "__objc_m_{d}", .{m.method_count});
    m.method_count += 1;
    return name;
}

/// Returns the index of a fresh synthetic block type.
pub fn nextBlockIndex(m: *Model) u32 {
    const index = m.block_count;
    m.block_count += 1;
    m.has_blocks = true;
    return index;
}

pub fn appendList(m: *Model, list: *std.ArrayList([]const u8), item: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, item)) return;
    }
    try list.append(m.arena, try m.arena.dupe(u8, item));
}
