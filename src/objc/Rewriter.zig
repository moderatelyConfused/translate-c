//! Rewrites Objective-C syntax in Aro's preprocessed token stream into plain C.
//!
//! Aro's parser only understands C. This pass runs between preprocessing and
//! parsing, walks the token stream, and:
//!
//! - records every `@interface`, `@protocol`, `@class`, `@property` and method
//!   declaration in an `objc.Model`,
//! - replaces each of them with synthetic C declarations that carry the same
//!   type information (`typedef struct objc_object Foo;` for classes and
//!   `RET __objc_m_<n>(PARAMS);` prototypes for methods and property accessors),
//! - rewrites block declarators (`RET (^)(ARGS)`) anywhere, including in plain
//!   C, into `struct __objc_block_<n> *` plus a hoisted
//!   `typedef RET (*__objc_blocksig_<n>)(ARGS);` that records the signature,
//! - strips Objective-C only type syntax (generics, `__kindof`, ownership
//!   qualifiers, nullability keywords) so that Aro can parse what remains.
//!
//! Function definitions whose bodies use Objective-C expressions are dropped
//! and reported through the model so that a `@compileError` can be emitted for
//! them.
const Rewriter = @This();

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const aro = @import("aro");
const Model = @import("Model.zig");

const Token = aro.Tree.Token;
const TokenId = aro.Tokenizer.Token.Id;
const TokenIndex = aro.Tree.TokenIndex;
const Source = aro.Source;

gpa: Allocator,
pp: *aro.Preprocessor,
comp: *aro.Compilation,
model: *Model,

/// The original token stream.
ids: []const TokenId,
locs: []const Source.Location,
/// Read cursor into the original token stream.
i: u32 = 0,

/// Output items for completed top-level declarations.
out: std.ArrayList(Item) = .empty,
/// Items of the top-level C declaration currently being scanned.
cur: std.ArrayList(Item) = .empty,
/// Synthetic declarations that must precede the current declaration.
hoisted: std.ArrayList(Item) = .empty,
/// Synthetic C source text; `Item.synth` ranges index into it.
synth: std.ArrayList(u8) = .empty,
/// Set when the current top-level declaration must be dropped.
cur_failed: ?[]const u8 = null,
/// Set by `endDecl`; used to detect the end of a declaration.
decl_boundary: bool = false,
/// Whether anything other than a plain copy happened.
changed: bool = false,
/// Whether the stream is Objective-C (language option or `@` tokens present),
/// in which case Objective-C only qualifiers are stripped from C code too.
objc_syntax: bool = false,

/// Brace nesting depth in C code.
depth: u32 = 0,
/// Whether the `{` that opened the outermost brace group followed a `)`,
/// i.e. whether it is a function body.
body_brace: bool = false,
/// Inside a `clang assume_nonnull` region.
assume_nonnull: bool = false,
/// Print timing information to stderr.
timing: bool = false,
/// Type context of the `@interface`/`@protocol` whose members are being
/// parsed, so that C declarations inside it can use its generic parameters.
member_type_ctx: ?TypeCtx = null,
/// Protocols for which a `__objc_proto_<name>` typedef was emitted.
proto_typedefs: std.StringHashMapUnmanaged(void) = .empty,

const Item = struct {
    tag: enum(u8) { orig, synth },
    /// Token index for `orig`, start byte offset into `synth` for `synth`.
    start: u32,
    /// End byte offset into `synth` for `synth`.
    end: u32 = 0,
};

/// Context for the members of an `@interface` or `@protocol`.
const MemberCtx = struct {
    owner: union(enum) {
        class: *Model.Class,
        protocol: *Model.Protocol,
    },
    /// The C type `instancetype` is rewritten to.
    self_type: []const []const u8,
    /// Generic type parameters and the C type they are rewritten to.
    generic_params: std.StringArrayHashMapUnmanaged(GenericBound) = .empty,
    optional: bool = false,
};

const GenericBound = struct {
    /// The C type the parameter is replaced with.
    pieces: []const []const u8 = &.{"id"},
    /// Protocols the bound was qualified with (`KeyType : id<NSCopying>`).
    protocols: []const []const u8 = &.{},
};

/// Context for rewriting a single type.
const TypeCtx = struct {
    self_type: []const []const u8 = &.{"id"},
    generic_params: ?*const std.StringArrayHashMapUnmanaged(GenericBound) = null,
};

const TypeResult = struct {
    /// C text pieces; joined with spaces they form the rewritten type.
    pieces: std.ArrayList([]const u8) = .empty,
    protocols: std.ArrayList([]const u8) = .empty,
    nullability: Model.Nullability = .default,
    is_instancetype: bool = false,

    fn info(res: *const TypeResult) Model.TypeInfo {
        return .{ .protocols = res.protocols.items, .nullability = res.nullability };
    }
};

pub const Error = error{OutOfMemory};

pub const Options = struct {
    /// Print timing information to stderr.
    timing: bool = false,
};

/// Rewrites `pp.tokens` in place. Does nothing if the stream contains no
/// Objective-C syntax and no block declarators.
pub fn run(gpa: Allocator, pp: *aro.Preprocessor, model: *Model, options: Options) Error!void {
    const io = pp.comp.io;
    const t0 = std.Io.Timestamp.now(io, .real);
    defer if (options.timing) {
        const elapsed = t0.durationTo(std.Io.Timestamp.now(io, .real)).nanoseconds;
        std.debug.print("objc rewriter: {d} ms ({d} tokens)\n", .{ @divTrunc(elapsed, std.time.ns_per_ms), pp.tokens.len });
    };
    const ids = pp.tokens.items(.id);
    var has_at = false;
    var has_caret = false;
    for (ids) |id| switch (id) {
        .at => has_at = true,
        .caret => has_caret = true,
        else => {},
    };
    const objc_syntax = has_at or pp.comp.langopts.objc;
    if (!has_at and !has_caret and !objc_syntax) return;

    var r: Rewriter = .{
        .gpa = gpa,
        .pp = pp,
        .comp = pp.comp,
        .model = model,
        .ids = try gpa.dupe(TokenId, ids),
        .locs = try gpa.dupe(Source.Location, pp.tokens.items(.loc)),
        .objc_syntax = objc_syntax,
    };
    defer r.deinit();

    try r.scanTopLevel();
    if (options.timing) {
        const elapsed = t0.durationTo(std.Io.Timestamp.now(io, .real)).nanoseconds;
        std.debug.print("objc rewriter: scan {d} ms\n", .{@divTrunc(elapsed, std.time.ns_per_ms)});
    }
    if (!r.changed) return;
    r.timing = options.timing;
    try r.commit();
}

fn phase(r: *const Rewriter, name: []const u8, start: std.Io.Timestamp) void {
    if (!r.timing) return;
    const elapsed = start.durationTo(std.Io.Timestamp.now(r.comp.io, .real)).nanoseconds;
    std.debug.print("objc rewriter: {s} {d} ms\n", .{ name, @divTrunc(elapsed, std.time.ns_per_ms) });
}

fn deinit(r: *Rewriter) void {
    r.gpa.free(r.ids);
    r.gpa.free(r.locs);
    r.out.deinit(r.gpa);
    r.cur.deinit(r.gpa);
    r.hoisted.deinit(r.gpa);
    r.synth.deinit(r.gpa);
    r.proto_typedefs.deinit(r.gpa);
}

/// `id<P>` is rewritten to `__objc_proto_P *`, a pointer to a synthetic typedef
/// that the translator maps to the protocol's wrapper type. Returns null for
/// protocols that are not declared (yet).
fn protocolTypedef(r: *Rewriter, protocol: []const u8) Error!?[]const u8 {
    if (!r.model.protocols.contains(protocol)) return null;
    const name = try std.fmt.allocPrint(r.model.arena, "__objc_proto_{s}", .{protocol});
    const gop = try r.proto_typedefs.getOrPut(r.gpa, name);
    if (!gop.found_existing) {
        const decl = try std.fmt.allocPrint(r.gpa, "typedef struct objc_object {s};", .{name});
        defer r.gpa.free(decl);
        try r.synthHoist(decl);
    }
    return name;
}

// =========================
// Token stream helpers
// =========================

fn at(r: *const Rewriter, idx: u32) TokenId {
    if (idx >= r.ids.len) return .eof;
    return r.ids[idx];
}

fn slice(r: *const Rewriter, idx: u32) []const u8 {
    if (idx >= r.ids.len) return "";
    if (r.ids[idx].lexeme()) |lexeme| return lexeme;
    return r.comp.locSlice(r.locs[idx]);
}

fn loc(r: *const Rewriter, idx: u32) Source.Location {
    if (idx >= r.locs.len) return r.locs[r.locs.len - 1];
    return r.locs[idx];
}

/// Identifier or keyword.
fn isIdentLike(id: TokenId) bool {
    return id.isMacroIdentifier();
}

fn isIdentifier(id: TokenId) bool {
    return id == .identifier or id == .extended_identifier;
}

fn isAttributeKeyword(id: TokenId) bool {
    return id == .keyword_attribute1 or id == .keyword_attribute2;
}

fn isNullabilityKeyword(id: TokenId) bool {
    return switch (id) {
        .keyword_nullable, .keyword_nonnull, .keyword_null_unspecified, .keyword_nullable_result => true,
        else => false,
    };
}

/// Returns the index of the token matching the opening bracket at `open`.
/// Returns the index of `eof` if there is no match.
fn matchBracket(r: *const Rewriter, open: u32) u32 {
    var j = open + 1;
    var nesting: u32 = 1;
    while (j < r.ids.len) : (j += 1) {
        switch (r.ids[j]) {
            .l_paren, .l_brace, .l_bracket => nesting += 1,
            .r_paren, .r_brace, .r_bracket => {
                nesting -= 1;
                if (nesting == 0) return j;
            },
            .eof => return j,
            else => {},
        }
    }
    return @intCast(r.ids.len - 1);
}

/// Returns the index of the token matching the `<` at `open`, or `null` if
/// the angle bracket does not look like a generic/protocol list.
fn matchAngle(r: *const Rewriter, open: u32) ?u32 {
    var j = open + 1;
    var nesting: u32 = 1;
    while (j < r.ids.len) : (j += 1) {
        switch (r.ids[j]) {
            .angle_bracket_left => nesting += 1,
            .angle_bracket_right => {
                nesting -= 1;
                if (nesting == 0) return j;
            },
            .angle_bracket_angle_bracket_right => {
                // `>>` closes two levels.
                if (nesting <= 2) return j;
                nesting -= 2;
            },
            .semicolon, .l_brace, .r_brace, .eof, .at => return null,
            else => {},
        }
    }
    return null;
}

/// Is the `(` at `idx` the start of a block declarator, i.e. `(` followed by
/// `^`, possibly with attributes in between?
fn isBlockDeclaratorStart(r: *const Rewriter, idx: u32) bool {
    if (r.at(idx) != .l_paren) return false;
    var j = idx + 1;
    while (isAttributeKeyword(r.at(j))) {
        if (r.at(j + 1) != .l_paren) return false;
        j = r.matchBracket(j + 1) + 1;
    }
    return r.at(j) == .caret;
}

/// Is the `^` at `idx` a block literal (`^{ ... }` or `^(args) { ... }`)?
fn isBlockLiteral(r: *const Rewriter, idx: u32) bool {
    if (r.at(idx) != .caret) return false;
    const next = r.at(idx + 1);
    if (next == .l_brace) return true;
    if (next == .l_paren) {
        const close = r.matchBracket(idx + 1);
        return r.at(close + 1) == .l_brace;
    }
    // `^ RetType (args) {` is also allowed.
    var j = idx + 1;
    while (isIdentLike(r.at(j)) or r.at(j) == .asterisk) j += 1;
    if (j != idx + 1 and r.at(j) == .l_paren) {
        const close = r.matchBracket(j);
        return r.at(close + 1) == .l_brace;
    }
    return false;
}

fn isObjcKeyword(r: *const Rewriter, idx: u32, name: []const u8) bool {
    return r.at(idx) == .at and isIdentLike(r.at(idx + 1)) and mem.eql(u8, r.slice(idx + 1), name);
}

/// Reconstructs the source text of the tokens `[start, end)` on a single line.
fn sourceText(r: *const Rewriter, start: u32, end: u32) Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    const arena = r.model.arena;
    var j = start;
    var prev: TokenId = .eof;
    // The `)` closing `@property (attributes)` is followed by a space.
    var attr_group_end: ?u32 = null;
    var prev_was_attr_group_end = false;
    while (j < end and j < r.ids.len) : (j += 1) {
        const id = r.ids[j];
        if (id == .nl or id == .whitespace) continue;
        const s = r.slice(j);
        const prev_prev: TokenId = if (j >= start + 2) r.ids[j - 2] else .eof;
        if (id == .l_paren and prev_prev == .at and isIdentLike(prev)) attr_group_end = r.matchBracket(j);
        const no_space_before = switch (id) {
            .r_paren, .comma, .colon, .semicolon, .r_bracket, .angle_bracket_right, .l_bracket => true,
            // `foo(`, `foo:(` but `@property (` and `void (^)(...)`.
            .l_paren => (isIdentifier(prev) and prev_prev != .at) or isAttributeKeyword(prev) or
                prev == .l_paren or prev == .r_paren or prev == .caret or prev == .colon,
            .angle_bracket_left => isIdentifier(prev),
            .asterisk => prev == .l_paren or prev == .asterisk,
            else => switch (prev) {
                .l_paren, .l_bracket, .at, .angle_bracket_left, .eof, .caret => true,
                .r_paren => !prev_was_attr_group_end,
                .colon => id != .l_paren,
                else => false,
            },
        };
        if (!no_space_before and text.items.len != 0) try text.append(arena, ' ');
        try text.appendSlice(arena, s);
        prev = id;
        prev_was_attr_group_end = attr_group_end != null and attr_group_end.? == j;
    }
    return text.items;
}

// =========================
// Output helpers
// =========================

fn emitOrig(r: *Rewriter, idx: u32) Error!void {
    try r.cur.append(r.gpa, .{ .tag = .orig, .start = idx });
}

fn appendSynth(r: *Rewriter, list: *std.ArrayList(Item), text: []const u8) Error!void {
    const start: u32 = @intCast(r.synth.items.len);
    try r.synth.appendSlice(r.gpa, text);
    try r.synth.append(r.gpa, '\n');
    const end: u32 = @intCast(r.synth.items.len);
    try list.append(r.gpa, .{ .tag = .synth, .start = start, .end = end });
    r.changed = true;
}

/// Emit synthetic text as part of the current declaration.
fn synthCur(r: *Rewriter, text: []const u8) Error!void {
    try r.appendSynth(&r.cur, text);
}

/// Emit synthetic text before the current declaration.
fn synthHoist(r: *Rewriter, text: []const u8) Error!void {
    try r.appendSynth(&r.hoisted, text);
}

/// Emit synthetic text as a completed top-level declaration.
fn synthOut(r: *Rewriter, text: []const u8) Error!void {
    try r.flushHoisted();
    try r.appendSynth(&r.out, text);
}

fn flushHoisted(r: *Rewriter) Error!void {
    try r.out.appendSlice(r.gpa, r.hoisted.items);
    r.hoisted.clearRetainingCapacity();
}

/// The current top-level declaration is complete.
fn endDecl(r: *Rewriter) Error!void {
    try r.flushHoisted();
    if (r.cur_failed) |reason| {
        try r.recordFailedDecl(reason);
        r.cur_failed = null;
        r.changed = true;
    } else {
        try r.out.appendSlice(r.gpa, r.cur.items);
    }
    r.cur.clearRetainingCapacity();
    r.body_brace = false;
    r.decl_boundary = true;
}

fn failCur(r: *Rewriter, reason: []const u8) void {
    if (r.cur_failed == null) r.cur_failed = reason;
}

/// Records a dropped declaration under its (best guess) name.
fn recordFailedDecl(r: *Rewriter, reason: []const u8) Error!void {
    // The name of a function definition is the identifier preceding the first
    // `(` at paren depth 0.
    var name: ?[]const u8 = null;
    var first_loc: ?Source.Location = null;
    var nesting: u32 = 0;
    var prev_ident: ?u32 = null;
    for (r.cur.items) |item| {
        if (item.tag != .orig) continue;
        const idx = item.start;
        if (first_loc == null) first_loc = r.loc(idx);
        switch (r.ids[idx]) {
            .l_paren => {
                if (nesting == 0 and prev_ident != null and name == null) name = r.slice(prev_ident.?);
                nesting += 1;
            },
            .r_paren => nesting -|= 1,
            .l_brace => break,
            else => {},
        }
        if (isIdentifier(r.ids[idx])) prev_ident = idx else prev_ident = null;
    }
    const first = first_loc orelse r.loc(r.i);
    if (name) |n| {
        try r.model.failed_decls.append(r.model.arena, .{
            .loc = first,
            .name = try r.model.arena.dupe(u8, n),
            .reason = reason,
        });
    } else {
        try r.model.warn(first, "dropped declaration: {s}", .{reason});
    }
}

// =========================
// Top-level scanning
// =========================

fn scanTopLevel(r: *Rewriter) Error!void {
    while (r.i < r.ids.len) {
        if (r.ids[r.i] == .eof) {
            try r.endDecl();
            try r.out.append(r.gpa, .{ .tag = .orig, .start = r.i });
            r.i += 1;
            break;
        }
        try r.scanToken();
    }
    try r.endDecl();
}

/// Scans one C declaration that appears inside an `@interface` or
/// `@protocol` (Apple's headers put `typedef NS_OPTIONS(...)` and the like
/// there). Stops at the end of the declaration, or before an `@` directive.
fn scanCDeclaration(r: *Rewriter) Error!void {
    while (r.i < r.ids.len) {
        const id = r.ids[r.i];
        if (id == .eof) return;
        if (id == .at and r.depth == 0) return;
        r.decl_boundary = false;
        try r.scanToken();
        if (r.decl_boundary and r.depth == 0) return;
    }
}

/// Processes the token at `r.i` as C code.
fn scanToken(r: *Rewriter) Error!void {
    const id = r.ids[r.i];
    {
        switch (id) {
            .eof => unreachable,
            .at => {
                if (r.depth == 0) {
                    try r.atTopLevel();
                } else {
                    r.failCur("function body uses Objective-C syntax");
                    r.i += 1;
                }
            },
            .keyword_pragma => try r.pragma(),
            .l_brace => {
                if (r.depth == 0) {
                    r.body_brace = r.lastOrigId() == .r_paren;
                }
                r.depth += 1;
                try r.emitOrig(r.i);
                r.i += 1;
            },
            .r_brace => {
                try r.emitOrig(r.i);
                r.i += 1;
                if (r.depth > 0) r.depth -= 1;
                if (r.depth == 0 and r.body_brace) try r.endDecl();
            },
            .semicolon => {
                try r.emitOrig(r.i);
                r.i += 1;
                if (r.depth == 0) try r.endDecl();
            },
            .l_paren => {
                if (r.isBlockDeclaratorStart(r.i)) {
                    try r.blockInC();
                } else {
                    try r.emitOrig(r.i);
                    r.i += 1;
                }
            },
            .caret => {
                if (r.depth > 0 and r.isBlockLiteral(r.i)) {
                    r.failCur("function body uses a block literal");
                }
                try r.emitOrig(r.i);
                r.i += 1;
            },
            .l_bracket => {
                // A `[` that does not follow an expression is a message send.
                if (r.objc_syntax and r.depth > 0 and !r.isPostfixContext()) {
                    r.failCur("function body uses Objective-C syntax");
                }
                try r.emitOrig(r.i);
                r.i += 1;
            },
            else => {
                if (r.objc_syntax and isIdentifier(id)) {
                    // Ownership qualifiers and `__kindof` are keywords in
                    // Objective-C that mean nothing to the C parser.
                    if (isStrippedTypeWord(r.slice(r.i))) {
                        r.i += 1;
                        r.changed = true;
                        return;
                    }
                    // Generic type parameters of the enclosing interface used
                    // by a C declaration inside it.
                    if (r.member_type_ctx) |ctx| {
                        if (ctx.generic_params) |gp| {
                            if (gp.get(r.slice(r.i))) |bound| {
                                const text = try r.joinPieces(r.gpa, bound.pieces);
                                defer r.gpa.free(text);
                                try r.synthCur(text);
                                r.i += 1;
                                if (r.at(r.i) == .angle_bracket_left) {
                                    if (r.matchAngle(r.i)) |close| r.i = close + 1;
                                }
                                return;
                            }
                        }
                    }
                    // `NSArray<NSString *> *` / `id<NSCopying>` in C declarations.
                    if (r.at(r.i + 1) == .angle_bracket_left and r.isObjcTypeName(r.slice(r.i))) {
                        if (r.matchAngle(r.i + 1)) |close| {
                            if (mem.eql(u8, r.slice(r.i), "id") and isIdentifier(r.at(r.i + 2))) {
                                if (try r.protocolTypedef(r.slice(r.i + 2))) |typedef_name| {
                                    // A qualifier written before `id` must follow the `*`.
                                    var qualifier: []const u8 = "";
                                    if (r.cur.items.len != 0) {
                                        const prev = r.cur.items[r.cur.items.len - 1];
                                        if (prev.tag == .orig and isNullabilityKeyword(r.ids[prev.start])) {
                                            qualifier = r.slice(prev.start);
                                            r.cur.items.len -= 1;
                                        }
                                    }
                                    const text = try std.fmt.allocPrint(r.gpa, "{s} * {s}", .{ typedef_name, qualifier });
                                    defer r.gpa.free(text);
                                    try r.synthCur(text);
                                    r.i = close + 1;
                                    return;
                                }
                            }
                            try r.emitOrig(r.i);
                            r.i = close + 1;
                            r.changed = true;
                            return;
                        }
                    }
                }
                try r.emitOrig(r.i);
                r.i += 1;
            },
        }
    }
}

/// Whether `name` can carry a generic argument or protocol list.
fn isObjcTypeName(r: *const Rewriter, name: []const u8) bool {
    if (mem.eql(u8, name, "id") or mem.eql(u8, name, "Class")) return true;
    return r.model.classes.contains(name);
}

/// Whether the last token of the current declaration ends an expression, so
/// that a following `[` is an array subscript rather than a message send.
fn isPostfixContext(r: *const Rewriter) bool {
    var k = r.cur.items.len;
    while (k > 0) {
        k -= 1;
        const item = r.cur.items[k];
        if (item.tag != .orig) return true;
        const id = r.ids[item.start];
        if (id == .nl or id == .whitespace) continue;
        return switch (id) {
            .r_paren, .r_bracket, .string_literal, .string_literal_utf_8, .string_literal_utf_16, .string_literal_utf_32, .string_literal_wide, .pp_num, .char_literal => true,
            else => isIdentLike(id) and !isCKeywordEndingStatement(id),
        };
    }
    return false;
}

fn isCKeywordEndingStatement(id: TokenId) bool {
    return switch (id) {
        .keyword_return, .keyword_case, .keyword_else, .keyword_do, .keyword_goto => true,
        else => false,
    };
}

/// The id of the last original token emitted into the current declaration.
fn lastOrigId(r: *const Rewriter) TokenId {
    var k = r.cur.items.len;
    while (k > 0) {
        k -= 1;
        const item = r.cur.items[k];
        if (item.tag == .orig) return r.ids[item.start];
        return .invalid;
    }
    return .eof;
}

/// Handles `#pragma` tokens (`keyword_pragma` up to and including the `nl`).
fn pragma(r: *Rewriter) Error!void {
    const start = r.i;
    var end = start + 1;
    while (end < r.ids.len and r.ids[end] != .nl and r.ids[end] != .eof) end += 1;
    // `#pragma clang assume_nonnull begin|end`
    if (end == start + 4 and
        isIdentLike(r.at(start + 1)) and mem.eql(u8, r.slice(start + 1), "clang") and
        isIdentLike(r.at(start + 2)) and mem.eql(u8, r.slice(start + 2), "assume_nonnull") and
        isIdentLike(r.at(start + 3)))
    {
        const which = r.slice(start + 3);
        if (mem.eql(u8, which, "begin")) {
            r.assume_nonnull = true;
        } else if (mem.eql(u8, which, "end")) {
            r.assume_nonnull = false;
        }
        r.i = end + 1;
        r.changed = true;
        return;
    }
    var j = start;
    while (j <= end and j < r.ids.len) : (j += 1) try r.emitOrig(j);
    r.i = end + 1;
}

/// Handles an `@` directive at file scope.
fn atTopLevel(r: *Rewriter) Error!void {
    assert(r.ids[r.i] == .at);
    const directive_loc = r.loc(r.i);
    if (!isIdentLike(r.at(r.i + 1))) {
        try r.model.warn(directive_loc, "unexpected '@' at file scope", .{});
        r.failCur("unexpected '@' at file scope");
        r.i += 1;
        return;
    }
    const name = r.slice(r.i + 1);

    // Attributes (or leftovers) before the directive belong to it; drop them.
    if (r.cur.items.len != 0) {
        if (!r.curIsOnlyAttributes()) {
            var ignored: std.ArrayList(u8) = .empty;
            defer ignored.deinit(r.gpa);
            var count: usize = 0;
            for (r.cur.items) |item| {
                if (item.tag != .orig) continue;
                if (count == 8) {
                    try ignored.appendSlice(r.gpa, " ...");
                    break;
                }
                if (count != 0) try ignored.append(r.gpa, ' ');
                try ignored.appendSlice(r.gpa, r.slice(item.start));
                count += 1;
            }
            try r.model.warn(directive_loc, "unexpected tokens before '@{s}' were ignored: {s}", .{ name, ignored.items });
        }
        r.cur.clearRetainingCapacity();
        r.changed = true;
    }
    try r.flushHoisted();

    if (mem.eql(u8, name, "interface")) {
        try r.parseInterface();
    } else if (mem.eql(u8, name, "protocol")) {
        try r.parseProtocol();
    } else if (mem.eql(u8, name, "class")) {
        try r.parseClassForward();
    } else if (mem.eql(u8, name, "compatibility_alias")) {
        try r.parseCompatibilityAlias();
    } else if (mem.eql(u8, name, "import")) {
        try r.model.warn(directive_loc, "'@import' is not supported, use '#import' instead", .{});
        r.skipPastSemicolon();
    } else if (mem.eql(u8, name, "implementation")) {
        try r.model.warn(directive_loc, "'@implementation' was skipped", .{});
        r.skipPastEnd();
    } else if (mem.eql(u8, name, "end")) {
        try r.model.warn(directive_loc, "stray '@end'", .{});
        r.i += 2;
    } else {
        try r.model.warn(directive_loc, "unsupported directive '@{s}' was skipped", .{name});
        r.skipPastSemicolon();
    }
    r.changed = true;
    r.model.enabled = true;
}

/// Whether the current declaration consists solely of attribute specifiers,
/// storage class specifiers (`OBJC_EXPORT @interface`) and pragmas.
fn curIsOnlyAttributes(r: *const Rewriter) bool {
    var nesting: u32 = 0;
    var in_pragma = false;
    for (r.cur.items) |item| {
        if (item.tag != .orig) return false;
        const id = r.ids[item.start];
        if (in_pragma) {
            if (id == .nl) in_pragma = false;
            continue;
        }
        switch (id) {
            .l_paren, .l_bracket => nesting += 1,
            .r_paren, .r_bracket => nesting -|= 1,
            .keyword_attribute1, .keyword_attribute2, .keyword_extension, .keyword_extern, .keyword_static, .keyword_inline, .nl => {},
            .keyword_pragma => in_pragma = true,
            else => if (nesting == 0) return false,
        }
    }
    return true;
}

fn skipPastSemicolon(r: *Rewriter) void {
    while (r.i < r.ids.len) {
        const id = r.ids[r.i];
        r.i += 1;
        if (id == .semicolon or id == .eof) return;
    }
}

fn skipPastEnd(r: *Rewriter) void {
    while (r.i < r.ids.len) {
        if (r.ids[r.i] == .eof) return;
        if (r.isObjcKeyword(r.i, "end")) {
            r.i += 2;
            return;
        }
        r.i += 1;
    }
}

/// Emits the C typedef that stands in for a class.
fn declareClassTypedef(r: *Rewriter, name: []const u8) Error!void {
    const text = try std.fmt.allocPrint(r.gpa, "typedef struct objc_object {s};", .{name});
    defer r.gpa.free(text);
    try r.synthOut(text);
}

// =========================
// @class, @protocol, @compatibility_alias
// =========================

fn parseClassForward(r: *Rewriter) Error!void {
    const start_loc = r.loc(r.i);
    r.i += 2; // `@class`
    while (true) {
        if (!isIdentifier(r.at(r.i))) {
            try r.model.warn(start_loc, "malformed '@class' declaration", .{});
            r.skipPastSemicolon();
            return;
        }
        const name = r.slice(r.i);
        _ = try r.model.getOrCreateClass(name, r.loc(r.i));
        try r.declareClassTypedef(name);
        r.i += 1;
        if (r.at(r.i) == .angle_bracket_left) {
            if (r.matchAngle(r.i)) |close| r.i = close + 1;
        }
        if (r.at(r.i) == .comma) {
            r.i += 1;
            continue;
        }
        break;
    }
    if (r.at(r.i) == .semicolon) r.i += 1;
}

fn parseCompatibilityAlias(r: *Rewriter) Error!void {
    const start_loc = r.loc(r.i);
    r.i += 2;
    if (!isIdentifier(r.at(r.i)) or !isIdentifier(r.at(r.i + 1))) {
        try r.model.warn(start_loc, "malformed '@compatibility_alias' declaration", .{});
        r.skipPastSemicolon();
        return;
    }
    const alias = r.slice(r.i);
    const target = r.slice(r.i + 1);
    r.i += 2;
    if (r.at(r.i) == .semicolon) r.i += 1;
    try r.declareClassTypedef(alias);
    try r.model.aliases.append(r.model.arena, .{
        .loc = start_loc,
        .name = try r.model.arena.dupe(u8, alias),
        .target = try r.model.arena.dupe(u8, target),
    });
    r.model.enabled = true;
}

fn parseProtocol(r: *Rewriter) Error!void {
    const start_loc = r.loc(r.i);
    r.i += 2; // `@protocol`
    if (!isIdentifier(r.at(r.i))) {
        try r.model.warn(start_loc, "malformed '@protocol' declaration", .{});
        r.skipPastSemicolon();
        return;
    }

    // Forward declaration: `@protocol A, B;`
    if (r.at(r.i + 1) == .semicolon or r.at(r.i + 1) == .comma) {
        while (isIdentifier(r.at(r.i))) {
            _ = try r.model.getOrCreateProtocol(r.slice(r.i), r.loc(r.i));
            r.i += 1;
            if (r.at(r.i) != .comma) break;
            r.i += 1;
        }
        if (r.at(r.i) == .semicolon) r.i += 1;
        return;
    }

    const protocol = try r.model.getOrCreateProtocol(r.slice(r.i), r.loc(r.i));
    protocol.defined = true;
    r.i += 1;
    if (r.at(r.i) == .angle_bracket_left) {
        try r.parseProtocolList(&protocol.parents);
    }
    var ctx: MemberCtx = .{
        .owner = .{ .protocol = protocol },
        .self_type = &.{"id"},
    };
    defer ctx.generic_params.deinit(r.gpa);
    try r.parseMembers(&ctx);
}

/// Parses `<A, B, C>` into `list`, skipping any generic arguments.
fn parseProtocolList(r: *Rewriter, list: *std.ArrayList([]const u8)) Error!void {
    assert(r.at(r.i) == .angle_bracket_left);
    const close = r.matchAngle(r.i) orelse {
        try r.model.warn(r.loc(r.i), "unterminated protocol list", .{});
        r.i += 1;
        return;
    };
    var j = r.i + 1;
    var nesting: u32 = 0;
    while (j < close) : (j += 1) {
        switch (r.ids[j]) {
            .angle_bracket_left => nesting += 1,
            .angle_bracket_right => nesting -|= 1,
            else => if (nesting == 0 and isIdentifier(r.ids[j])) {
                try r.model.appendList(list, r.slice(j));
            },
        }
    }
    r.i = close + 1;
}

// =========================
// @interface
// =========================

fn parseInterface(r: *Rewriter) Error!void {
    const start_loc = r.loc(r.i);
    r.i += 2; // `@interface`
    if (!isIdentifier(r.at(r.i))) {
        try r.model.warn(start_loc, "malformed '@interface' declaration", .{});
        r.skipPastEnd();
        return;
    }
    const class_name = r.slice(r.i);
    const class = try r.model.getOrCreateClass(class_name, r.loc(r.i));
    r.i += 1;

    var ctx: MemberCtx = .{
        .owner = .{ .class = class },
        .self_type = try r.model.arena.dupe([]const u8, &.{ class.name, "*" }),
    };
    defer ctx.generic_params.deinit(r.gpa);

    // Generic parameters or, for a root class, the protocol list.
    if (r.at(r.i) == .angle_bracket_left) {
        if (r.angleIsGenericParams(r.i)) {
            try r.parseGenericParams(&ctx, class);
        }
    }

    var is_category = false;
    if (r.at(r.i) == .l_paren) {
        // Category or class extension.
        is_category = true;
        const close = r.matchBracket(r.i);
        if (isIdentifier(r.at(r.i + 1))) {
            try r.model.appendList(&class.categories, r.slice(r.i + 1));
        }
        r.i = close + 1;
    } else if (r.at(r.i) == .colon) {
        r.i += 1;
        if (isIdentifier(r.at(r.i))) {
            class.superclass = try r.model.arena.dupe(u8, r.slice(r.i));
            r.i += 1;
            // `: NSDictionary<KeyType, ObjectType>` (generic arguments of the
            // superclass) versus `: NSObject <NSCopying>` (protocol list).
            if (r.at(r.i) == .angle_bracket_left and r.angleIsTypeArgs(r.i, &ctx)) {
                if (r.matchAngle(r.i)) |close| r.i = close + 1;
            }
        } else {
            try r.model.warn(start_loc, "expected superclass name", .{});
        }
    }
    if (!is_category) class.defined = true;

    if (r.at(r.i) == .angle_bracket_left) {
        try r.parseProtocolList(&class.protocols);
    }

    try r.declareClassTypedef(class.name);

    // Instance variables.
    if (r.at(r.i) == .l_brace) {
        r.i = r.matchBracket(r.i) + 1;
    }

    try r.parseMembers(&ctx);
}

/// Decides whether the `<` at `idx` (right after a class name) starts a
/// generic parameter list rather than a protocol list.
fn angleIsGenericParams(r: *const Rewriter, idx: u32) bool {
    const close = r.matchAngle(idx) orelse return false;
    var j = idx + 1;
    while (j < close) : (j += 1) {
        if (r.ids[j] == .colon) return true;
        if (isIdentifier(r.ids[j])) {
            const s = r.slice(j);
            if (mem.eql(u8, s, "__covariant") or mem.eql(u8, s, "__contravariant")) return true;
        }
    }
    // `@interface Foo<T> : Super` or `@interface Foo<T> (Category)`.
    return r.at(close + 1) == .colon or r.at(close + 1) == .l_paren;
}

/// Decides whether the `<` at `idx` (right after a superclass name) holds
/// generic type arguments rather than the protocol list of the class being
/// declared. Type arguments contain pointers, generic parameters or classes.
fn angleIsTypeArgs(r: *const Rewriter, idx: u32, ctx: *const MemberCtx) bool {
    const close = r.matchAngle(idx) orelse return false;
    var j = idx + 1;
    while (j < close) : (j += 1) {
        const id = r.ids[j];
        if (id == .asterisk or id == .caret) return true;
        if (isIdentifier(id)) {
            const s = r.slice(j);
            if (ctx.generic_params.contains(s)) return true;
            if (r.isObjcTypeName(s)) return true;
            if (isStrippedTypeWord(s)) return true;
        } else if (id != .comma) {
            // Keywords such as `const` or `int` only occur in types.
            return true;
        }
    }
    return false;
}

fn parseGenericParams(r: *Rewriter, ctx: *MemberCtx, class: *Model.Class) Error!void {
    const close = r.matchAngle(r.i).?;
    var j = r.i + 1;
    while (j < close) {
        // [__covariant|__contravariant] Name [: Bound]
        if (isIdentifier(r.ids[j])) {
            const s = r.slice(j);
            if (mem.eql(u8, s, "__covariant") or mem.eql(u8, s, "__contravariant")) {
                j += 1;
                continue;
            }
        }
        if (!isIdentifier(r.ids[j])) {
            j += 1;
            continue;
        }
        const name = try r.model.arena.dupe(u8, r.slice(j));
        try r.model.appendList(&class.generic_params, name);
        j += 1;
        var bound: GenericBound = .{};
        if (r.at(j) == .colon) {
            j += 1;
            const bound_start = j;
            var nesting: u32 = 0;
            while (j < close) : (j += 1) {
                switch (r.ids[j]) {
                    .angle_bracket_left => nesting += 1,
                    .angle_bracket_right => nesting -|= 1,
                    .comma => if (nesting == 0) break,
                    else => {},
                }
            }
            var res = try r.rewriteType(bound_start, j, .{});
            defer res.pieces.deinit(r.gpa);
            defer res.protocols.deinit(r.gpa);
            bound = .{
                .pieces = try r.model.arena.dupe([]const u8, res.pieces.items),
                .protocols = try r.model.arena.dupe([]const u8, res.protocols.items),
            };
        }
        try ctx.generic_params.put(r.gpa, name, bound);
        if (r.at(j) == .comma) j += 1;
    }
    r.i = close + 1;
}

// =========================
// Members
// =========================

fn parseMembers(r: *Rewriter, ctx: *MemberCtx) Error!void {
    const saved_type_ctx = r.member_type_ctx;
    r.member_type_ctx = typeCtx(ctx);
    defer r.member_type_ctx = saved_type_ctx;
    while (r.i < r.ids.len) {
        const id = r.ids[r.i];
        switch (id) {
            .eof => {
                try r.model.warn(r.loc(r.i), "missing '@end'", .{});
                return;
            },
            .at => {
                const name = if (isIdentLike(r.at(r.i + 1))) r.slice(r.i + 1) else "";
                if (mem.eql(u8, name, "end")) {
                    r.i += 2;
                    return;
                } else if (mem.eql(u8, name, "property")) {
                    try r.parseProperty(ctx);
                } else if (mem.eql(u8, name, "optional")) {
                    ctx.optional = true;
                    r.i += 2;
                } else if (mem.eql(u8, name, "required")) {
                    ctx.optional = false;
                    r.i += 2;
                } else {
                    try r.model.warn(r.loc(r.i), "unexpected '@{s}' inside interface", .{name});
                    r.i += 2;
                    r.skipMember();
                }
            },
            .minus, .plus => try r.parseMethod(ctx, id == .plus),
            .keyword_pragma => try r.pragma(),
            .semicolon => r.i += 1,
            else => {
                // A C declaration (typedef, enum, ...) inside the interface.
                try r.scanCDeclaration();
                try r.endDecl();
            },
        }
    }
}

/// Skips to just past the next `;` or to the next `@`.
fn skipMember(r: *Rewriter) void {
    while (r.i < r.ids.len) {
        switch (r.ids[r.i]) {
            .semicolon => {
                r.i += 1;
                return;
            },
            .at, .eof => return,
            .l_paren, .l_brace, .l_bracket => r.i = r.matchBracket(r.i) + 1,
            else => r.i += 1,
        }
    }
}

fn typeCtx(ctx: *const MemberCtx) TypeCtx {
    return .{ .self_type = ctx.self_type, .generic_params = &ctx.generic_params };
}

fn addMethod(r: *Rewriter, ctx: *MemberCtx, method: *Model.Method) Error!void {
    switch (ctx.owner) {
        .class => |class| try class.methods.append(r.model.arena, method),
        .protocol => |protocol| try protocol.methods.append(r.model.arena, method),
    }
}

const ParamRec = struct {
    name: []const u8,
    type: TypeResult,
    attrs: []const u8,
};

fn parseMethod(r: *Rewriter, ctx: *MemberCtx, is_class: bool) Error!void {
    const start = r.i;
    const method_loc = r.loc(r.i);
    r.i += 1;

    var ret: TypeResult = .{};
    defer ret.pieces.deinit(r.gpa);
    defer ret.protocols.deinit(r.gpa);
    if (r.at(r.i) == .l_paren) {
        const close = r.matchBracket(r.i);
        ret = try r.rewriteType(r.i + 1, close, typeCtx(ctx));
        r.i = close + 1;
    } else {
        try ret.pieces.append(r.gpa, "id");
    }

    var selector: std.ArrayList(u8) = .empty;
    defer selector.deinit(r.gpa);
    var params: std.ArrayList(ParamRec) = .empty;
    defer {
        for (params.items) |*p| {
            p.type.pieces.deinit(r.gpa);
            p.type.protocols.deinit(r.gpa);
            r.gpa.free(p.attrs);
        }
        params.deinit(r.gpa);
    }
    var method_attrs: std.ArrayList(u8) = .empty;
    defer method_attrs.deinit(r.gpa);
    var attributes: Model.Attributes = .{};

    while (true) {
        const id = r.at(r.i);
        if (isIdentLike(id) and r.at(r.i + 1) == .colon) {
            try selector.appendSlice(r.gpa, r.slice(r.i));
            try selector.append(r.gpa, ':');
            r.i += 2;
            try r.parseMethodParam(ctx, &params, &method_attrs, &attributes);
        } else if (id == .colon) {
            try selector.append(r.gpa, ':');
            r.i += 1;
            try r.parseMethodParam(ctx, &params, &method_attrs, &attributes);
        } else if (isIdentLike(id) and selector.items.len == 0) {
            try selector.appendSlice(r.gpa, r.slice(r.i));
            r.i += 1;
            break;
        } else break;
    }
    if (selector.items.len == 0) {
        try r.model.warn(method_loc, "malformed method declaration", .{});
        r.skipMember();
        return;
    }

    var variadic = false;
    if (r.at(r.i) == .comma and r.at(r.i + 1) == .ellipsis) {
        variadic = true;
        r.i += 2;
    }

    {
        const attrs = try r.parseTrailingAttributes(&attributes);
        defer r.gpa.free(attrs);
        try method_attrs.appendSlice(r.gpa, attrs);
    }
    const attrs = method_attrs.items;
    const end = r.i;
    if (r.at(r.i) == .semicolon) r.i += 1;

    // Synthetic prototype.
    const proto_name = try r.model.nextProtoName();
    var decl: std.ArrayList(u8) = .empty;
    defer decl.deinit(r.gpa);
    try decl.appendSlice(r.gpa, proto_name);
    try decl.append(r.gpa, '(');
    if (params.items.len == 0 and !variadic) try decl.appendSlice(r.gpa, "void");
    for (params.items, 0..) |*p, idx| {
        if (idx != 0) try decl.appendSlice(r.gpa, ", ");
        const arg_name = try std.fmt.allocPrint(r.gpa, "a{d}", .{idx});
        defer r.gpa.free(arg_name);
        try r.writeDeclaration(&decl, p.type.pieces.items, arg_name);
        try decl.appendSlice(r.gpa, p.attrs);
    }
    if (variadic) try decl.appendSlice(r.gpa, if (params.items.len == 0) "..." else ", ...");
    try decl.append(r.gpa, ')');

    var proto: std.ArrayList(u8) = .empty;
    defer proto.deinit(r.gpa);
    try r.writeDeclaration(&proto, ret.pieces.items, decl.items);
    try proto.appendSlice(r.gpa, attrs);
    try proto.append(r.gpa, ';');
    try r.synthOut(proto.items);

    // Model entry.
    const model_params = try r.model.arena.alloc(Model.Param, params.items.len);
    for (params.items, model_params) |*p, *mp| {
        mp.* = .{
            .name = try r.model.arena.dupe(u8, p.name),
            .info = .{
                .protocols = try r.model.arena.dupe([]const u8, p.type.protocols.items),
                .nullability = p.type.nullability,
            },
        };
    }
    const method = try r.model.arena.create(Model.Method);
    method.* = .{
        .selector = try r.model.arena.dupe(u8, selector.items),
        .is_class = is_class,
        .proto_name = proto_name,
        .params = model_params,
        .returns_instancetype = ret.is_instancetype,
        .return_info = .{
            .protocols = try r.model.arena.dupe([]const u8, ret.protocols.items),
            .nullability = ret.nullability,
        },
        .variadic = variadic,
        .optional = ctx.optional,
        .assume_nonnull = r.assume_nonnull,
        .kind = .method,
        .attributes = attributes,
        .source = try r.sourceText(start, end),
        .loc = method_loc,
    };
    try r.addMethod(ctx, method);
}

fn parseMethodParam(r: *Rewriter, ctx: *MemberCtx, params: *std.ArrayList(ParamRec), method_attrs: *std.ArrayList(u8), method_attributes: *Model.Attributes) Error!void {
    var ty: TypeResult = .{};
    errdefer ty.pieces.deinit(r.gpa);
    errdefer ty.protocols.deinit(r.gpa);
    if (r.at(r.i) == .l_paren) {
        const close = r.matchBracket(r.i);
        ty = try r.rewriteType(r.i + 1, close, typeCtx(ctx));
        r.i = close + 1;
    } else {
        try ty.pieces.append(r.gpa, "id");
    }
    var name: []const u8 = "";
    if (isIdentLike(r.at(r.i))) {
        name = r.slice(r.i);
        r.i += 1;
    }
    var param_attributes: Model.Attributes = .{};
    var attrs = try r.parseTrailingAttributes(&param_attributes);
    errdefer r.gpa.free(attrs);
    // Attributes after the last parameter belong to the method, not to the
    // parameter (e.g. `- (void)foo:(id)x NS_UNAVAILABLE;`).
    const next_is_param = r.at(r.i) == .colon or (isIdentLike(r.at(r.i)) and r.at(r.i + 1) == .colon);
    if (!next_is_param and attrs.len != 0) {
        try method_attrs.appendSlice(r.gpa, attrs);
        r.gpa.free(attrs);
        attrs = try r.gpa.alloc(u8, 0);
        mergeAttributes(method_attributes, param_attributes);
    }
    try params.append(r.gpa, .{ .name = name, .type = ty, .attrs = attrs });
}

fn mergeAttributes(into: *Model.Attributes, from: Model.Attributes) void {
    if (from.unavailable) |m| into.unavailable = m;
    if (from.deprecated) |m| into.deprecated = m;
    if (from.availability.len != 0) into.availability = from.availability;
}

/// Collects `__attribute__((...))` groups up to the end of the declaration
/// (or up to the next selector part). Other tokens are skipped (typically
/// undefined attribute macros). The returned text is owned by the caller;
/// attributes relevant to the bindings are also recorded in `attributes`.
fn parseTrailingAttributes(r: *Rewriter, attributes: *Model.Attributes) Error![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(r.gpa);
    while (true) {
        const id = r.at(r.i);
        if (isAttributeKeyword(id) and r.at(r.i + 1) == .l_paren) {
            const close = r.matchBracket(r.i + 1);
            try text.append(r.gpa, ' ');
            try r.appendTokensText(&text, r.i, close + 1);
            try r.recordAttributes(r.i + 1, close, attributes);
            r.i = close + 1;
            continue;
        }
        switch (id) {
            .semicolon, .eof, .at, .minus, .plus, .comma, .ellipsis => break,
            .l_paren, .l_brace, .l_bracket => r.i = r.matchBracket(r.i) + 1,
            .colon => {
                // Next selector part; a parameter attribute list ends here.
                break;
            },
            else => {
                if (isIdentLike(id) and r.at(r.i + 1) == .colon) break;
                r.i += 1;
            },
        }
    }
    return text.toOwnedSlice(r.gpa);
}

/// Records the attributes in `__attribute__` `(` `(` ... `)` `)`, where `open`
/// is the outer `(` and `close` the outer `)`.
fn recordAttributes(r: *Rewriter, open: u32, close: u32, attributes: *Model.Attributes) Error!void {
    if (r.at(open + 1) != .l_paren) return;
    const inner_close = r.matchBracket(open + 1);
    if (inner_close >= close) return;
    var j = open + 2;
    while (j < inner_close) {
        if (!isIdentLike(r.ids[j])) {
            j += 1;
            continue;
        }
        var name = r.slice(j);
        name = mem.trim(u8, name, "_");
        j += 1;
        var args_start = j;
        var args_end = j;
        if (r.at(j) == .l_paren) {
            args_start = j + 1;
            args_end = r.matchBracket(j);
            j = args_end + 1;
        }
        if (mem.eql(u8, name, "unavailable")) {
            attributes.unavailable = try r.attributeMessage(args_start, args_end);
        } else if (mem.eql(u8, name, "deprecated")) {
            attributes.deprecated = try r.attributeMessage(args_start, args_end);
        } else if (mem.eql(u8, name, "availability")) {
            try r.recordAvailability(args_start, args_end, attributes);
        }
        if (r.at(j) == .comma) j += 1;
    }
}

/// The string literal argument of an attribute, or "" if there is none.
fn attributeMessage(r: *Rewriter, start: u32, end: u32) Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var j = start;
    while (j < end) : (j += 1) {
        if (r.ids[j] == .string_literal) {
            const s = r.slice(j);
            if (s.len >= 2) try text.appendSlice(r.model.arena, s[1 .. s.len - 1]);
        }
    }
    return text.items;
}

fn recordAvailability(r: *Rewriter, start: u32, end: u32, attributes: *Model.Attributes) Error!void {
    if (!isIdentLike(r.at(start))) return;
    var availability: Model.Availability = .{ .platform = try r.model.arena.dupe(u8, r.slice(start)) };
    var j = start + 1;
    while (j < end) {
        if (r.ids[j] == .comma) {
            j += 1;
            continue;
        }
        if (!isIdentLike(r.ids[j])) {
            j += 1;
            continue;
        }
        const key = r.slice(j);
        j += 1;
        var value_start = j;
        if (r.at(j) == .equal) {
            j += 1;
            value_start = j;
        }
        while (j < end and r.ids[j] != .comma) j += 1;
        const value = try r.sourceText(value_start, j);
        if (mem.eql(u8, key, "unavailable")) {
            availability.unavailable = true;
        } else if (mem.eql(u8, key, "introduced")) {
            availability.introduced = value;
        } else if (mem.eql(u8, key, "deprecated")) {
            availability.deprecated = value;
        } else if (mem.eql(u8, key, "obsoleted")) {
            availability.obsoleted = value;
        } else if (mem.eql(u8, key, "message")) {
            availability.message = try r.attributeMessage(value_start, j);
        }
    }
    var list: std.ArrayList(Model.Availability) = .empty;
    try list.appendSlice(r.model.arena, attributes.availability);
    try list.append(r.model.arena, availability);
    attributes.availability = list.items;
}

fn appendTokensText(r: *const Rewriter, text: *std.ArrayList(u8), start: u32, end: u32) Error!void {
    var j = start;
    while (j < end and j < r.ids.len) : (j += 1) {
        if (r.ids[j] == .nl or r.ids[j] == .whitespace) continue;
        try text.append(r.gpa, ' ');
        try text.appendSlice(r.gpa, r.slice(j));
    }
}

const PropertyAttrs = struct {
    readonly: bool = false,
    is_class: bool = false,
    getter: ?[]const u8 = null,
    setter: ?[]const u8 = null,
    nullability: enum { default, nullable, nonnull, null_unspecified, null_resettable } = .default,
};

fn parseProperty(r: *Rewriter, ctx: *MemberCtx) Error!void {
    const start = r.i;
    const prop_loc = r.loc(r.i);
    r.i += 2; // `@property`

    var attrs: PropertyAttrs = .{};
    var attr_text: []const u8 = "";
    if (r.at(r.i) == .l_paren) {
        const close = r.matchBracket(r.i);
        attr_text = try r.sourceText(r.i + 1, close);
        var j = r.i + 1;
        while (j < close) {
            if (!isIdentLike(r.ids[j])) {
                j += 1;
                continue;
            }
            const key = r.slice(j);
            j += 1;
            if (r.at(j) == .equal) {
                j += 1;
                var value: std.ArrayList(u8) = .empty;
                defer value.deinit(r.gpa);
                while (j < close and r.ids[j] != .comma) : (j += 1) {
                    try value.appendSlice(r.gpa, r.slice(j));
                }
                if (mem.eql(u8, key, "getter")) {
                    attrs.getter = try r.model.arena.dupe(u8, value.items);
                } else if (mem.eql(u8, key, "setter")) {
                    attrs.setter = try r.model.arena.dupe(u8, value.items);
                }
            } else if (mem.eql(u8, key, "readonly")) {
                attrs.readonly = true;
            } else if (mem.eql(u8, key, "readwrite")) {
                attrs.readonly = false;
            } else if (mem.eql(u8, key, "class")) {
                attrs.is_class = true;
            } else if (mem.eql(u8, key, "nullable")) {
                attrs.nullability = .nullable;
            } else if (mem.eql(u8, key, "nonnull")) {
                attrs.nullability = .nonnull;
            } else if (mem.eql(u8, key, "null_unspecified")) {
                attrs.nullability = .null_unspecified;
            } else if (mem.eql(u8, key, "null_resettable")) {
                attrs.nullability = .null_resettable;
            }
            if (r.at(j) == .comma) j += 1;
        }
        r.i = close + 1;
    }

    // The declaration runs up to the `;`. Trailing `__attribute__` groups are
    // declaration attributes rather than part of the type.
    const decl_start = r.i;
    var end = r.i;
    while (end < r.ids.len) {
        switch (r.ids[end]) {
            .semicolon, .eof, .at => break,
            .l_paren, .l_brace, .l_bracket => end = r.matchBracket(end) + 1,
            else => end += 1,
        }
    }
    var type_end = end;
    while (type_end > decl_start and r.ids[type_end - 1] == .r_paren) {
        // Find the `(` matching the `)` at `type_end - 1`.
        var k = type_end - 1;
        var nesting: u32 = 0;
        while (k > decl_start) : (k -= 1) {
            switch (r.ids[k]) {
                .r_paren => nesting += 1,
                .l_paren => {
                    nesting -= 1;
                    if (nesting == 0) break;
                },
                else => {},
            }
        }
        if (k > decl_start and isAttributeKeyword(r.ids[k - 1])) {
            type_end = k - 1;
        } else break;
    }
    var decl_attrs: std.ArrayList(u8) = .empty;
    defer decl_attrs.deinit(r.gpa);
    try r.appendTokensText(&decl_attrs, type_end, end);
    var attributes: Model.Attributes = .{};
    {
        var k = type_end;
        while (k < end) : (k += 1) {
            if (isAttributeKeyword(r.ids[k]) and r.at(k + 1) == .l_paren) {
                const close = r.matchBracket(k + 1);
                try r.recordAttributes(k + 1, close, &attributes);
                k = close;
            }
        }
    }

    // `@property T a, *b;` declares several properties sharing the specifiers.
    var segments: std.ArrayList([2]u32) = .empty;
    defer segments.deinit(r.gpa);
    {
        var seg_start = decl_start;
        var k = decl_start;
        while (k < type_end) : (k += 1) {
            switch (r.ids[k]) {
                .l_paren, .l_brace, .l_bracket => k = r.matchBracket(k),
                .angle_bracket_left => if (r.matchAngle(k)) |close| {
                    k = close;
                },
                .comma => {
                    try segments.append(r.gpa, .{ seg_start, k });
                    seg_start = k + 1;
                },
                else => {},
            }
        }
        try segments.append(r.gpa, .{ seg_start, type_end });
    }

    const source = try r.sourceText(start, end);
    r.i = end;
    if (r.at(r.i) == .semicolon) r.i += 1;

    var first = try r.rewriteType(segments.items[0][0], segments.items[0][1], typeCtx(ctx));
    defer first.pieces.deinit(r.gpa);
    defer first.protocols.deinit(r.gpa);
    const first_name_index = findDeclaratorName(first.pieces.items) orelse {
        try r.model.warn(prop_loc, "unable to determine property name", .{});
        return;
    };
    // The specifiers shared by all declarators end where the first declarator begins.
    var specifiers_end = first_name_index;
    for (first.pieces.items[0..first_name_index], 0..) |piece, k| {
        if (mem.eql(u8, piece, "*") or mem.eql(u8, piece, "(") or mem.eql(u8, piece, "[")) {
            specifiers_end = k;
            break;
        }
    }
    try r.emitProperty(ctx, &attrs, attr_text, decl_attrs.items, attributes, source, prop_loc, first.pieces.items, &first.protocols, first.nullability, first_name_index);

    for (segments.items[1..]) |seg| {
        var extra = try r.rewriteType(seg[0], seg[1], typeCtx(ctx));
        defer extra.pieces.deinit(r.gpa);
        defer extra.protocols.deinit(r.gpa);
        var pieces: std.ArrayList([]const u8) = .empty;
        defer pieces.deinit(r.gpa);
        try pieces.appendSlice(r.gpa, first.pieces.items[0..specifiers_end]);
        try pieces.appendSlice(r.gpa, extra.pieces.items);
        const name_index = findDeclaratorName(pieces.items) orelse {
            try r.model.warn(prop_loc, "unable to determine property name", .{});
            continue;
        };
        try r.emitProperty(ctx, &attrs, attr_text, decl_attrs.items, attributes, source, prop_loc, pieces.items, &first.protocols, extra.nullability, name_index);
    }
}

/// Emits the accessors of one property declarator.
fn emitProperty(
    r: *Rewriter,
    ctx: *MemberCtx,
    attrs: *const PropertyAttrs,
    attr_text: []const u8,
    decl_attrs: []const u8,
    attributes: Model.Attributes,
    source: []const u8,
    prop_loc: Source.Location,
    pieces: []const []const u8,
    protocols: *const std.ArrayList([]const u8),
    type_nullability: Model.Nullability,
    name_index: usize,
) Error!void {
    const name = try r.model.arena.dupe(u8, pieces[name_index]);

    // Property nullability keywords from the attribute list.
    var getter_pieces: std.ArrayList([]const u8) = .empty;
    defer getter_pieces.deinit(r.gpa);
    try getter_pieces.appendSlice(r.gpa, pieces);
    var setter_pieces: std.ArrayList([]const u8) = .empty;
    defer setter_pieces.deinit(r.gpa);
    try setter_pieces.appendSlice(r.gpa, pieces);
    var getter_null = type_nullability;
    var setter_null = type_nullability;
    var getter_name_index = name_index;
    var setter_name_index = name_index;
    switch (attrs.nullability) {
        .default => {},
        .nullable => {
            getter_name_index = try insertQualifier(r.gpa, &getter_pieces, "_Nullable", name_index);
            setter_name_index = try insertQualifier(r.gpa, &setter_pieces, "_Nullable", name_index);
            getter_null = .nullable;
            setter_null = .nullable;
        },
        .nonnull => {
            getter_name_index = try insertQualifier(r.gpa, &getter_pieces, "_Nonnull", name_index);
            setter_name_index = try insertQualifier(r.gpa, &setter_pieces, "_Nonnull", name_index);
            getter_null = .nonnull;
            setter_null = .nonnull;
        },
        .null_unspecified => {
            getter_name_index = try insertQualifier(r.gpa, &getter_pieces, "_Null_unspecified", name_index);
            setter_name_index = try insertQualifier(r.gpa, &setter_pieces, "_Null_unspecified", name_index);
            getter_null = .nullable;
            setter_null = .nullable;
        },
        .null_resettable => {
            getter_name_index = try insertQualifier(r.gpa, &getter_pieces, "_Nonnull", name_index);
            setter_name_index = try insertQualifier(r.gpa, &setter_pieces, "_Nullable", name_index);
            getter_null = .nonnull;
            setter_null = .nullable;
        },
    }

    const getter_sel = attrs.getter orelse name;
    const info: Model.TypeInfo = .{
        .protocols = try r.model.arena.dupe([]const u8, protocols.items),
        .nullability = getter_null,
    };

    // Getter prototype: the property type with the name replaced by `__objc_m_N(void)`.
    const getter_proto = try r.model.nextProtoName();
    {
        const with_params = try std.fmt.allocPrint(r.gpa, "{s}(void)", .{getter_proto});
        defer r.gpa.free(with_params);
        getter_pieces.items[getter_name_index] = with_params;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(r.gpa);
        try r.appendJoined(&text, getter_pieces.items);
        try text.appendSlice(r.gpa, decl_attrs);
        try text.append(r.gpa, ';');
        try r.synthOut(text.items);
    }
    const getter = try r.model.arena.create(Model.Method);
    getter.* = .{
        .selector = try r.model.arena.dupe(u8, getter_sel),
        .is_class = attrs.is_class,
        .proto_name = getter_proto,
        .params = &.{},
        .returns_instancetype = false,
        .return_info = info,
        .variadic = false,
        .optional = ctx.optional,
        .assume_nonnull = r.assume_nonnull,
        .kind = .getter,
        .attributes = attributes,
        .source = source,
        .loc = prop_loc,
    };
    try r.addMethod(ctx, getter);

    var setter: ?*Model.Method = null;
    if (!attrs.readonly) {
        const setter_sel = attrs.setter orelse try std.fmt.allocPrint(r.model.arena, "set{c}{s}:", .{
            std.ascii.toUpper(name[0]),
            name[1..],
        });
        const setter_proto = try r.model.nextProtoName();
        setter_pieces.items[setter_name_index] = "a0";
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(r.gpa);
        try text.appendSlice(r.gpa, "void ");
        try text.appendSlice(r.gpa, setter_proto);
        try text.append(r.gpa, '(');
        try r.appendJoined(&text, setter_pieces.items);
        try text.append(r.gpa, ')');
        try text.appendSlice(r.gpa, decl_attrs);
        try text.append(r.gpa, ';');
        try r.synthOut(text.items);

        const params = try r.model.arena.alloc(Model.Param, 1);
        params[0] = .{
            .name = "value",
            .info = .{ .protocols = info.protocols, .nullability = setter_null },
        };
        const m = try r.model.arena.create(Model.Method);
        m.* = .{
            .selector = setter_sel,
            .is_class = attrs.is_class,
            .proto_name = setter_proto,
            .params = params,
            .returns_instancetype = false,
            .return_info = .{},
            .variadic = false,
            .optional = ctx.optional,
            .assume_nonnull = r.assume_nonnull,
            .kind = .setter,
            .attributes = attributes,
            .source = source,
            .loc = prop_loc,
        };
        try r.addMethod(ctx, m);
        setter = m;
    }

    const property = try r.model.arena.create(Model.Property);
    property.* = .{
        .name = name,
        .getter = getter,
        .setter = setter,
        .is_class = attrs.is_class,
        .attributes = attr_text,
        .loc = prop_loc,
    };
    switch (ctx.owner) {
        .class => |class| try class.properties.append(r.model.arena, property),
        .protocol => |protocol| try protocol.properties.append(r.model.arena, property),
    }
}

// =========================
// Types
// =========================

/// Identifiers that are dropped from types.
fn isStrippedTypeWord(s: []const u8) bool {
    const words = [_][]const u8{
        "__kindof",        "__strong", "__weak",      "__unsafe_unretained",
        "__autoreleasing", "__block",  "__covariant", "__contravariant",
    };
    for (words) |w| if (mem.eql(u8, s, w)) return true;
    return false;
}

/// Objective-C method type qualifiers (distributed objects).
fn isMethodTypeQualifier(s: []const u8) bool {
    const words = [_][]const u8{ "oneway", "in", "out", "inout", "bycopy", "byref" };
    for (words) |w| if (mem.eql(u8, s, w)) return true;
    return false;
}

fn objcNullabilityKeyword(s: []const u8) ?[]const u8 {
    if (mem.eql(u8, s, "nullable")) return "_Nullable";
    if (mem.eql(u8, s, "nonnull")) return "_Nonnull";
    if (mem.eql(u8, s, "null_unspecified")) return "_Null_unspecified";
    return null;
}

fn nullabilityOfQualifier(s: []const u8) Model.Nullability {
    if (mem.eql(u8, s, "_Nonnull")) return .nonnull;
    return .nullable;
}

fn isNullabilityQualifierText(s: []const u8) bool {
    return mem.eql(u8, s, "_Nullable") or mem.eql(u8, s, "_Nonnull") or
        mem.eql(u8, s, "_Null_unspecified") or mem.eql(u8, s, "_Nullable_result");
}

/// `instancetype` and `id<P>` are typedef'd pointers that may carry a
/// nullability qualifier in front of them (`_Nonnull instancetype`). After
/// they are replaced by `Name *`, such a qualifier has to follow the `*`.
/// Call this after the replacement, with `type_start` the index of the first
/// piece of the replacement.
fn relocatePrefixQualifier(r: *Rewriter, pieces: *std.ArrayList([]const u8), type_start: usize) Error!void {
    if (type_start == 0) return;
    const qualifier = pieces.items[type_start - 1];
    if (!isNullabilityQualifierText(qualifier)) return;
    _ = pieces.orderedRemove(type_start - 1);
    try pieces.append(r.gpa, qualifier);
}

/// Rewrites the type spelled by the tokens `[start, end)` into C.
fn rewriteType(r: *Rewriter, start: u32, end: u32, ctx: TypeCtx) Error!TypeResult {
    var res: TypeResult = .{};
    errdefer res.pieces.deinit(r.gpa);
    errdefer res.protocols.deinit(r.gpa);

    var pending_qualifier: ?[]const u8 = null;
    var nesting: u32 = 0;
    var j = start;
    while (j < end) {
        const id = r.ids[j];
        switch (id) {
            .nl, .whitespace => j += 1,
            .l_paren => {
                if (r.isBlockDeclaratorStart(j)) {
                    j = try r.blockDeclarator(j, end, ctx, &res.pieces);
                    continue;
                }
                nesting += 1;
                try res.pieces.append(r.gpa, "(");
                j += 1;
            },
            .r_paren => {
                nesting -|= 1;
                try res.pieces.append(r.gpa, ")");
                j += 1;
            },
            .angle_bracket_left => {
                const close = r.matchAngle(j) orelse {
                    try res.pieces.append(r.gpa, "<");
                    j += 1;
                    continue;
                };
                const last = if (res.pieces.items.len != 0) res.pieces.items[res.pieces.items.len - 1] else "";
                if (mem.eql(u8, last, "id") or mem.eql(u8, last, "Class")) {
                    const first_protocol = res.protocols.items.len;
                    var k = j + 1;
                    var inner: u32 = 0;
                    while (k < close) : (k += 1) {
                        switch (r.ids[k]) {
                            .angle_bracket_left => inner += 1,
                            .angle_bracket_right => inner -|= 1,
                            else => if (inner == 0 and isIdentifier(r.ids[k])) {
                                try res.protocols.append(r.gpa, try r.model.arena.dupe(u8, r.slice(k)));
                            },
                        }
                    }
                    // `id<P>` becomes a pointer to the protocol's synthetic typedef.
                    if (mem.eql(u8, last, "id") and res.protocols.items.len > first_protocol) {
                        if (try r.protocolTypedef(res.protocols.items[first_protocol])) |typedef_name| {
                            const type_start = res.pieces.items.len - 1;
                            res.pieces.items[type_start] = typedef_name;
                            try res.pieces.append(r.gpa, "*");
                            try r.relocatePrefixQualifier(&res.pieces, type_start);
                        }
                    }
                }
                j = close + 1;
            },
            .keyword_nullable, .keyword_nonnull, .keyword_null_unspecified, .keyword_nullable_result => {
                if (nesting == 0) res.nullability = nullabilityOfQualifier(r.slice(j));
                try res.pieces.append(r.gpa, r.slice(j));
                j += 1;
            },
            .keyword_attribute1, .keyword_attribute2 => {
                if (r.at(j + 1) == .l_paren) {
                    const close = r.matchBracket(j + 1);
                    // Attributes inside a declarator group, such as
                    // `(NS_NOESCAPE *)`, cannot be parsed by Aro and carry
                    // nothing the bindings need.
                    if (nesting == 0) {
                        var k = j;
                        while (k <= close and k < r.ids.len) : (k += 1) {
                            try res.pieces.append(r.gpa, r.slice(k));
                        }
                    }
                    j = close + 1;
                } else {
                    j += 1;
                }
            },
            else => {
                if (isIdentifier(id)) {
                    const s = r.slice(j);
                    if (objcNullabilityKeyword(s)) |q| {
                        pending_qualifier = q;
                        j += 1;
                        continue;
                    }
                    if (isStrippedTypeWord(s)) {
                        j += 1;
                        continue;
                    }
                    if (res.pieces.items.len == 0 and isMethodTypeQualifier(s)) {
                        j += 1;
                        continue;
                    }
                    if (mem.eql(u8, s, "instancetype")) {
                        const type_start = res.pieces.items.len;
                        try res.pieces.appendSlice(r.gpa, ctx.self_type);
                        try r.relocatePrefixQualifier(&res.pieces, type_start);
                        res.is_instancetype = true;
                        j += 1;
                        continue;
                    }
                    if (ctx.generic_params) |gp| {
                        if (gp.get(s)) |bound| {
                            // A following `<...>` (`KeyType <NSCopying>`) is
                            // handled by the loop like `id<NSCopying>`.
                            try res.pieces.appendSlice(r.gpa, bound.pieces);
                            try res.protocols.appendSlice(r.gpa, bound.protocols);
                            j += 1;
                            continue;
                        }
                    }
                }
                try res.pieces.append(r.gpa, r.slice(j));
                j += 1;
            },
        }
    }
    if (pending_qualifier) |q| {
        _ = try insertQualifier(r.gpa, &res.pieces, q, null);
        res.nullability = nullabilityOfQualifier(q);
    }
    return res;
}

/// Rewrites the block declarator starting at the `(` at `idx`. The pieces
/// accumulated so far in `pieces` are the block's return type; they are
/// replaced by `struct __objc_block_N *` (plus qualifiers and the declared
/// name, if any). Returns the index just past the block's parameter list.
fn blockDeclarator(r: *Rewriter, idx: u32, limit: u32, ctx: TypeCtx, pieces: *std.ArrayList([]const u8)) Error!u32 {
    const ret_text = try r.joinPieces(r.gpa, pieces.items);
    defer r.gpa.free(ret_text);
    pieces.clearRetainingCapacity();

    const group_close = r.matchBracket(idx);
    // Inside the group: [attributes] ^ [qualifiers|attributes|nullability]* [name]
    var quals: std.ArrayList([]const u8) = .empty;
    defer quals.deinit(r.gpa);
    var name: ?[]const u8 = null;
    var k = idx + 1;
    while (k < group_close) {
        const id = r.ids[k];
        if (isAttributeKeyword(id) and r.at(k + 1) == .l_paren) {
            k = r.matchBracket(k + 1) + 1;
            continue;
        }
        switch (id) {
            .caret => {},
            .keyword_const, .keyword_volatile, .keyword_restrict, .keyword_restrict1, .keyword_restrict2 => try quals.append(r.gpa, r.slice(k)),
            .keyword_nullable, .keyword_nonnull, .keyword_null_unspecified, .keyword_nullable_result => {
                try quals.append(r.gpa, r.slice(k));
            },
            else => if (isIdentifier(id)) {
                const s = r.slice(k);
                if (objcNullabilityKeyword(s)) |q| {
                    try quals.append(r.gpa, q);
                } else if (!isStrippedTypeWord(s)) {
                    name = s;
                }
            },
        }
        k += 1;
    }

    // Parameter list.
    var args_text: std.ArrayList(u8) = .empty;
    defer args_text.deinit(r.gpa);
    var next = group_close + 1;
    if (r.at(next) == .l_paren and next < limit) {
        const args_close = r.matchBracket(next);
        var arg_start = next + 1;
        var first = true;
        var k2 = next + 1;
        while (k2 <= args_close) : (k2 += 1) {
            const id = r.at(k2);
            const is_sep = (id == .comma or k2 == args_close);
            if (id == .l_paren or id == .l_brace or id == .l_bracket) {
                k2 = r.matchBracket(k2);
                continue;
            }
            if (id == .angle_bracket_left) {
                // Commas inside `NSDictionary<KeyType, ObjectType> *` do not
                // separate parameters.
                if (r.matchAngle(k2)) |close| {
                    if (close < args_close) k2 = close;
                }
                continue;
            }
            if (!is_sep) continue;
            if (k2 > arg_start) {
                if (!first) try args_text.appendSlice(r.gpa, ", ");
                first = false;
                var arg = try r.rewriteType(arg_start, k2, ctx);
                defer arg.pieces.deinit(r.gpa);
                defer arg.protocols.deinit(r.gpa);
                try r.appendJoined(&args_text, arg.pieces.items);
            }
            arg_start = k2 + 1;
        }
        next = args_close + 1;
    }
    if (args_text.items.len == 0) try args_text.appendSlice(r.gpa, "void");

    const index = r.model.nextBlockIndex();
    const typedef = try std.fmt.allocPrint(r.gpa, "typedef {s} (*__objc_blocksig_{d})({s});", .{
        ret_text, index, args_text.items,
    });
    defer r.gpa.free(typedef);
    try r.synthHoist(typedef);

    try pieces.append(r.gpa, "struct");
    try pieces.append(r.gpa, try std.fmt.allocPrint(r.model.arena, "__objc_block_{d}", .{index}));
    try pieces.append(r.gpa, "*");
    try pieces.appendSlice(r.gpa, quals.items);
    if (name) |n| try pieces.append(r.gpa, n);
    return next;
}

/// A block declarator in plain C code (outside `@interface`).
fn blockInC(r: *Rewriter) Error!void {
    // The return type consists of the tokens of the current declaration since
    // the last boundary.
    var start_item = r.cur.items.len;
    var nesting: u32 = 0;
    while (start_item > 0) {
        const item = r.cur.items[start_item - 1];
        if (item.tag == .orig) {
            switch (r.ids[item.start]) {
                .r_paren => nesting += 1,
                .l_paren => {
                    if (nesting == 0) break;
                    nesting -= 1;
                },
                .semicolon, .comma, .l_brace, .r_brace, .r_bracket, .l_bracket, .equal, .colon, .keyword_typedef, .keyword_extern, .keyword_static, .keyword_inline, .keyword_return, .nl => if (nesting == 0) break,
                else => {},
            }
        }
        start_item -= 1;
    }
    // Attributes before the return type (`DISPATCH_NOESCAPE void (^block)(size_t)`)
    // stay in the declaration but are not part of the block's return type.
    while (start_item + 1 < r.cur.items.len) {
        const item = r.cur.items[start_item];
        const next = r.cur.items[start_item + 1];
        if (item.tag != .orig or next.tag != .orig) break;
        if (!isAttributeKeyword(r.ids[item.start]) or r.ids[next.start] != .l_paren) break;
        var group_depth: u32 = 0;
        var k = start_item + 1;
        while (k < r.cur.items.len) : (k += 1) {
            const it = r.cur.items[k];
            if (it.tag != .orig) continue;
            if (r.ids[it.start] == .l_paren) group_depth += 1;
            if (r.ids[it.start] == .r_paren) {
                group_depth -= 1;
                if (group_depth == 0) break;
            }
        }
        start_item = k + 1;
    }
    var pieces: std.ArrayList([]const u8) = .empty;
    defer pieces.deinit(r.gpa);
    for (r.cur.items[start_item..]) |item| {
        switch (item.tag) {
            .orig => try pieces.append(r.gpa, r.slice(item.start)),
            .synth => try pieces.append(r.gpa, r.synth.items[item.start..item.end]),
        }
    }
    r.cur.shrinkRetainingCapacity(start_item);

    const next = try r.blockDeclarator(r.i, @intCast(r.ids.len), r.member_type_ctx orelse .{}, &pieces);
    const text = try r.joinPieces(r.gpa, pieces.items);
    defer r.gpa.free(text);
    try r.synthCur(text);
    r.i = next;
    r.changed = true;

    // Remember typedef names whose type is a block.
    if (r.at(next) == .semicolon and start_item > 0) {
        const first = r.cur.items[0];
        if (first.tag == .orig and r.ids[first.start] == .keyword_typedef) {
            // `typedef RET (^name)(ARGS);` -> the name is the last identifier
            // of the block group, which is the last piece.
            if (pieces.items.len != 0) {
                const last = pieces.items[pieces.items.len - 1];
                if (isCIdentifier(last)) {
                    try r.model.block_typedefs.put(r.model.arena, try r.model.arena.dupe(u8, last), {});
                }
            }
        }
    }
}

fn joinPieces(r: *const Rewriter, allocator: Allocator, pieces: []const []const u8) Error![]u8 {
    _ = r;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (pieces, 0..) |p, idx| {
        if (idx != 0) try text.append(allocator, ' ');
        try text.appendSlice(allocator, p);
    }
    return text.toOwnedSlice(allocator);
}

fn appendJoined(r: *const Rewriter, text: *std.ArrayList(u8), pieces: []const []const u8) Error!void {
    for (pieces, 0..) |p, idx| {
        if (idx != 0) try text.append(r.gpa, ' ');
        try text.appendSlice(r.gpa, p);
    }
}

/// Writes the C declaration of `name` with the abstract type `pieces`.
fn writeDeclaration(r: *const Rewriter, text: *std.ArrayList(u8), pieces: []const []const u8, name: []const u8) Error!void {
    var copy: std.ArrayList([]const u8) = .empty;
    defer copy.deinit(r.gpa);
    try copy.appendSlice(r.gpa, pieces);
    try insertName(r.gpa, &copy, name);
    try r.appendJoined(text, copy.items);
}

/// Inserts a declarator name into an abstract declarator.
fn insertName(gpa: Allocator, pieces: *std.ArrayList([]const u8), name: []const u8) Error!void {
    // `RET ( * ) ( ARGS )` -> insert before the `)` closing the `( *` group.
    if (findPointerGroup(pieces.items)) |group_start| {
        var nesting: u32 = 0;
        var k = group_start;
        while (k < pieces.items.len) : (k += 1) {
            if (mem.eql(u8, pieces.items[k], "(")) nesting += 1;
            if (mem.eql(u8, pieces.items[k], ")")) {
                nesting -= 1;
                if (nesting == 0) {
                    try pieces.insert(gpa, k, name);
                    return;
                }
            }
        }
    }
    // `T [ N ]` -> insert before the `[`.
    var nesting: u32 = 0;
    for (pieces.items, 0..) |p, k| {
        if (mem.eql(u8, p, "(")) nesting += 1;
        if (mem.eql(u8, p, ")")) nesting -|= 1;
        if (nesting == 0 and mem.eql(u8, p, "[")) {
            try pieces.insert(gpa, k, name);
            return;
        }
    }
    try pieces.append(gpa, name);
}

/// Finds the index of a `(` that starts a `( *` declarator group at nesting
/// level 0.
fn findPointerGroup(pieces: []const []const u8) ?usize {
    var nesting: u32 = 0;
    for (pieces, 0..) |p, k| {
        if (mem.eql(u8, p, "(")) {
            if (nesting == 0 and k + 1 < pieces.len and mem.eql(u8, pieces[k + 1], "*")) return k;
            nesting += 1;
        } else if (mem.eql(u8, p, ")")) {
            nesting -|= 1;
        }
    }
    return null;
}

/// Inserts a pointer qualifier such as `_Nullable` so that it applies to the
/// outermost pointer of the type. `name_index` is the index of the declarator
/// name in `pieces`, if any; the qualifier is never placed after it. Returns
/// the new index of the name.
fn insertQualifier(gpa: Allocator, pieces: *std.ArrayList([]const u8), qualifier: []const u8, name_index: ?usize) Error!usize {
    const limit = name_index orelse pieces.items.len;
    // `( *` group: qualify that pointer.
    if (findPointerGroup(pieces.items[0..limit])) |group_start| {
        try pieces.insert(gpa, group_start + 2, qualifier);
        return (name_index orelse pieces.items.len - 1) + 1;
    }
    // Otherwise the last `*` before the name.
    var nesting: u32 = 0;
    var last_star: ?usize = null;
    for (pieces.items[0..limit], 0..) |p, k| {
        if (mem.eql(u8, p, "(")) nesting += 1;
        if (mem.eql(u8, p, ")")) nesting -|= 1;
        if (nesting == 0 and mem.eql(u8, p, "*")) last_star = k;
    }
    if (last_star) |k| {
        try pieces.insert(gpa, k + 1, qualifier);
        return (name_index orelse pieces.items.len - 1) + 1;
    }
    try pieces.insert(gpa, limit, qualifier);
    return limit + 1;
}

fn isCTypeKeyword(s: []const u8) bool {
    const words = [_][]const u8{
        "void",       "char",     "short",    "int",      "long",     "float",
        "double",     "signed",   "unsigned", "_Bool",    "bool",     "_Complex",
        "__int128",   "_Float16", "__fp16",   "_Float32", "_Float64", "_Float128",
        "__typeof__", "__typeof", "typeof",
    };
    for (words) |w| if (mem.eql(u8, s, w)) return true;
    return false;
}

fn isCQualifier(s: []const u8) bool {
    const words = [_][]const u8{
        "const",     "volatile",   "restrict",          "__restrict",       "__restrict__",
        "_Nullable", "_Nonnull",   "_Null_unspecified", "_Nullable_result", "_Atomic",
        "__const",   "__volatile",
    };
    for (words) |w| if (mem.eql(u8, s, w)) return true;
    return false;
}

fn isCIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// Finds the declarator name in a C declaration split into pieces.
fn findDeclaratorName(pieces: []const []const u8) ?usize {
    var specifier_seen = false;
    var expect_tag = false;
    var after_pointer = false;
    var k: usize = 0;
    while (k < pieces.len) : (k += 1) {
        const p = pieces[k];
        if (mem.eql(u8, p, "*")) {
            after_pointer = true;
            continue;
        }
        if (mem.eql(u8, p, "(")) {
            // Either a `( *` declarator group or a parameter list.
            if (k + 1 < pieces.len and mem.eql(u8, pieces[k + 1], "*")) continue;
            return null;
        }
        if (mem.eql(u8, p, ")") or mem.eql(u8, p, "[") or mem.eql(u8, p, ",")) return null;
        if (mem.eql(u8, p, "__attribute__") or mem.eql(u8, p, "__attribute")) {
            // Skip the attribute group.
            var nesting: u32 = 0;
            k += 1;
            while (k < pieces.len) : (k += 1) {
                if (mem.eql(u8, pieces[k], "(")) nesting += 1;
                if (mem.eql(u8, pieces[k], ")")) {
                    nesting -|= 1;
                    if (nesting == 0) break;
                }
            }
            continue;
        }
        if (isCQualifier(p)) continue;
        if (mem.eql(u8, p, "struct") or mem.eql(u8, p, "union") or mem.eql(u8, p, "enum")) {
            expect_tag = true;
            specifier_seen = true;
            continue;
        }
        if (isCTypeKeyword(p)) {
            specifier_seen = true;
            continue;
        }
        if (isCIdentifier(p)) {
            if (expect_tag) {
                expect_tag = false;
                continue;
            }
            if (after_pointer or specifier_seen) return k;
            specifier_seen = true;
            continue;
        }
    }
    return null;
}

// =========================
// Commit
// =========================

const SynthToken = struct {
    id: TokenId,
    start: u32,
    line: u32,
};

fn commit(r: *Rewriter) Error!void {
    const gpa = r.comp.gpa;

    // Basic Objective-C types that headers expect the compiler to provide.
    var final: std.ArrayList(Item) = .empty;
    defer final.deinit(r.gpa);
    if (r.model.enabled) {
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        defer declared.deinit(r.gpa);
        try r.collectTypedefNames(&declared);
        var prelude: std.ArrayList(u8) = .empty;
        defer prelude.deinit(r.gpa);
        if (!declared.contains("id")) try prelude.appendSlice(r.gpa, "typedef struct objc_object *id;\n");
        if (!declared.contains("Class")) try prelude.appendSlice(r.gpa, "typedef struct objc_class *Class;\n");
        if (!declared.contains("SEL")) try prelude.appendSlice(r.gpa, "typedef struct objc_selector *SEL;\n");
        if (!declared.contains("BOOL")) {
            const bool_is_bool = r.comp.target.os.tag.isDarwin() and r.comp.target.cpu.arch == .aarch64;
            try prelude.appendSlice(r.gpa, if (bool_is_bool) "typedef _Bool BOOL;\n" else "typedef signed char BOOL;\n");
        }
        // Like clang, predeclare the `Protocol` class. Headers may `@class`
        // it again later, which is harmless.
        if (!declared.contains("Protocol")) {
            _ = try r.model.getOrCreateClass("Protocol", r.locs[0]);
            try prelude.appendSlice(r.gpa, "typedef struct objc_object Protocol;\n");
        }
        if (prelude.items.len != 0) try r.appendSynth(&final, prelude.items);
    }
    try final.appendSlice(r.gpa, r.out.items);

    // Tokenize the synthetic source.
    var t = std.Io.Timestamp.now(r.comp.io, .real);
    const source = r.comp.addSourceFromBuffer("<objc>", r.synth.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.OutOfMemory, // FileTooBig etc.; cannot happen for in-memory buffers of sane size
    };
    var synth_tokens: std.ArrayList(SynthToken) = .empty;
    defer synth_tokens.deinit(r.gpa);
    {
        var tokenizer: aro.Tokenizer = .{
            .buf = source.buf,
            .langopts = r.comp.langopts,
            .source = source.id,
            .splice_locs = source.splice_locs,
        };
        while (true) {
            const tok = tokenizer.next();
            switch (tok.id) {
                .eof => break,
                .nl, .whitespace => continue,
                else => {
                    // Directive keywords such as `line` are plain identifiers
                    // outside of preprocessor directives.
                    var id = tok.id;
                    id.simplifyMacroKeywordExtra(true);
                    try synth_tokens.append(r.gpa, .{ .id = id, .start = tok.start, .line = tok.line });
                },
            }
        }
    }

    r.phase("addSource+tokenize", t);
    t = std.Io.Timestamp.now(r.comp.io, .real);

    // Build the new token list.
    var new_tokens: Token.List = .empty;
    errdefer new_tokens.deinit(gpa);
    try new_tokens.ensureTotalCapacity(gpa, r.ids.len + synth_tokens.items.len);
    const old_to_new = try r.gpa.alloc(u32, r.ids.len);
    defer r.gpa.free(old_to_new);
    @memset(old_to_new, std.math.maxInt(u32));

    for (final.items) |item| {
        switch (item.tag) {
            .orig => {
                old_to_new[item.start] = @intCast(new_tokens.len);
                try new_tokens.append(gpa, .{ .id = r.ids[item.start], .loc = r.locs[item.start] });
            },
            .synth => {
                var k = lowerBound(synth_tokens.items, item.start);
                while (k < synth_tokens.items.len and synth_tokens.items[k].start < item.end) : (k += 1) {
                    const st = synth_tokens.items[k];
                    try new_tokens.append(gpa, .{ .id = st.id, .loc = .{
                        .id = source.id,
                        .byte_offset = st.start,
                        .line = st.line,
                    } });
                }
            },
        }
    }

    r.phase("build tokens", t);
    t = std.Io.Timestamp.now(r.comp.io, .real);

    // Remap macro expansion locations to the new token indices. The entries
    // are sorted by token index and kept tokens keep their relative order, so
    // a stable partition keeps them sorted. Entries of dropped tokens are kept
    // (they own memory) but moved to the end.
    {
        const entries = &r.pp.expansion_entries;
        const Entry = @TypeOf(entries.get(0));
        var dropped: std.ArrayList(Entry) = .empty;
        defer dropped.deinit(r.gpa);
        var w: usize = 0;
        var k: usize = 0;
        while (k < entries.len) : (k += 1) {
            var entry = entries.get(k);
            entry.idx = if (entry.idx < old_to_new.len) old_to_new[entry.idx] else std.math.maxInt(u32);
            if (entry.idx == std.math.maxInt(u32)) {
                try dropped.append(r.gpa, entry);
                continue;
            }
            entries.set(w, entry);
            w += 1;
        }
        for (dropped.items) |entry| {
            entries.set(w, entry);
            w += 1;
        }
    }

    r.phase("remap+sort", t);

    r.pp.tokens.deinit(gpa);
    r.pp.tokens = new_tokens;
}

fn lowerBound(tokens: []const SynthToken, start: u32) usize {
    var lo: usize = 0;
    var hi: usize = tokens.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tokens[mid].start < start) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Collects the names declared by file-scope `typedef`s in the original
/// token stream.
fn collectTypedefNames(r: *const Rewriter, names: *std.StringHashMapUnmanaged(void)) Error!void {
    var j: u32 = 0;
    var depth: u32 = 0;
    while (j < r.ids.len) : (j += 1) {
        switch (r.ids[j]) {
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            .keyword_typedef => if (depth == 0) {
                var k = j + 1;
                var nesting: u32 = 0;
                while (k < r.ids.len) : (k += 1) {
                    switch (r.ids[k]) {
                        .l_paren, .l_brace, .l_bracket => nesting += 1,
                        .r_paren, .r_brace, .r_bracket => nesting -|= 1,
                        .semicolon => if (nesting == 0) break,
                        .eof => break,
                        else => {},
                    }
                    if (nesting == 0 and isIdentifier(r.ids[k])) {
                        switch (r.at(k + 1)) {
                            .semicolon, .comma, .l_bracket, .keyword_attribute1, .keyword_attribute2 => try names.put(r.gpa, r.slice(k), {}),
                            else => {},
                        }
                    } else if (nesting == 1 and isIdentifier(r.ids[k]) and r.at(k + 1) == .r_paren) {
                        // `typedef RET (*name)(ARGS);`
                        try names.put(r.gpa, r.slice(k), {});
                    }
                }
                j = k;
            },
            else => {},
        }
    }
}

// =========================
// Tests
// =========================

fn testPieces(gpa: Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var pieces: std.ArrayList([]const u8) = .empty;
    var it = mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |p| try pieces.append(gpa, p);
    return pieces;
}

fn testJoin(gpa: Allocator, pieces: []const []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    for (pieces, 0..) |p, i| {
        if (i != 0) try text.append(gpa, ' ');
        try text.appendSlice(gpa, p);
    }
    return text.toOwnedSlice(gpa);
}

test "insertName places the declarator name" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "NSString *", "NSString * a0" },
        .{ "id", "id a0" },
        .{ "void ( * ) ( int )", "void ( * a0 ) ( int )" },
        .{ "void ( * ) ( int ( * ) ( void ) )", "void ( * a0 ) ( int ( * ) ( void ) )" },
        .{ "int [ ]", "int a0 [ ]" },
        .{ "struct __objc_block_0 * _Nullable", "struct __objc_block_0 * _Nullable a0" },
    };
    for (cases) |case| {
        var pieces = try testPieces(gpa, case[0]);
        defer pieces.deinit(gpa);
        try insertName(gpa, &pieces, "a0");
        const joined = try testJoin(gpa, pieces.items);
        defer gpa.free(joined);
        try std.testing.expectEqualStrings(case[1], joined);
    }
}

test "insertQualifier qualifies the outermost pointer" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, name: ?usize, out: []const u8 }{
        .{ .in = "NSString *", .name = null, .out = "NSString * _Nullable" },
        .{ .in = "NSString * name", .name = 2, .out = "NSString * _Nullable name" },
        .{ .in = "id name", .name = 1, .out = "id _Nullable name" },
        .{ .in = "id", .name = null, .out = "id _Nullable" },
        .{ .in = "void ( * cb ) ( int )", .name = 3, .out = "void ( * _Nullable cb ) ( int )" },
        .{ .in = "NSError * _Nullable *", .name = null, .out = "NSError * _Nullable * _Nullable" },
    };
    for (cases) |case| {
        var pieces = try testPieces(gpa, case.in);
        defer pieces.deinit(gpa);
        const new_index = try insertQualifier(gpa, &pieces, "_Nullable", case.name);
        const joined = try testJoin(gpa, pieces.items);
        defer gpa.free(joined);
        try std.testing.expectEqualStrings(case.out, joined);
        if (case.name) |old| {
            try std.testing.expectEqualStrings(pieces.items[new_index], pieces.items[new_index]);
            try std.testing.expect(new_index == old + 1);
        }
    }
}

test "findDeclaratorName" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, name: ?[]const u8 }{
        .{ .in = "NSString * name", .name = "name" },
        .{ .in = "NSUInteger count", .name = "count" },
        .{ .in = "unsigned long long value", .name = "value" },
        .{ .in = "struct _NSRange range", .name = "range" },
        .{ .in = "const char * _Nullable UTF8String", .name = "UTF8String" },
        .{ .in = "void ( * callback ) ( int )", .name = "callback" },
        .{ .in = "struct __objc_block_0 * completion", .name = "completion" },
        .{ .in = "id _Nullable delegate", .name = "delegate" },
        .{ .in = "NSString * const __attribute__ ( ( foo ) ) name", .name = "name" },
        .{ .in = "int", .name = null },
    };
    for (cases) |case| {
        var pieces = try testPieces(gpa, case.in);
        defer pieces.deinit(gpa);
        const index = findDeclaratorName(pieces.items);
        if (case.name) |expected| {
            try std.testing.expect(index != null);
            try std.testing.expectEqualStrings(expected, pieces.items[index.?]);
        } else {
            try std.testing.expect(index == null);
        }
    }
}
