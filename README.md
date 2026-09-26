# Translate-C (with Objective-C support)

A Zig package for translating C code into Zig code, intended to replace
`@cImport` and `zig translate-c`.

This is a fork of [ziglang/translate-c](https://codeberg.org/ziglang/translate-c)
(via [vancluever/translate-c](https://codeberg.org/vancluever/translate-c)) that
additionally understands Objective-C headers and generates Zig bindings for
them on top of [zig-objc](https://github.com/mitchellh/zig-objc). The C
translation is unchanged; see [Objective-C support](#objective-c-support) for
the additions.

This branch tracks Zig 0.16.x. Other branches track other versions of Zig.

## Usage

Add `translate-c` to your `build.zig.zon` with this command:

```
$ zig fetch --save git+https://codeberg.org/ziglang/translate-c
```

Then, within your `build.zig`, write something like this:

```zig
// An abstraction to make using translate-c as simple as possible.
const Translator = @import("translate_c").Translator;

const translate_c = b.dependency("translate_c", .{});

const t: Translator = .init(translate_c, .{
    .c_source_file = b.path("to_translate.h"),
    .target = target,
    // This is the optimization mode of the C code being translated and
    // the resulting Zig code.
    .optimize = optimize,
    // more options go here (see below)
});
// If you want, you can now call methods on `Translator` to add include paths (etc).

// Depend on the translated C code as a Zig module.
some_module.addImport("translated", t.mod);
// ...or, if you want to, just use the output file directly.
const translated_to_zig: LazyPath = t.output_file;
```

For a more complete usage, take a look at the `examples/` directory.

## Options

The options for the [`build/Translator.zig`](build/Translator.zig) abstraction
are in heavy development. Please see the file directly for more details.

## Objective-C support

Passing `.objc = true` (or `-fobjc` on the command line) translates the input
as Objective-C: `#import`, `@interface`, `@protocol`, `@class`, `@property`,
method declarations, categories, class extensions, lightweight generics,
`__kindof`, nullability annotations (including `NS_ASSUME_NONNULL_BEGIN`
regions) and block types (`^`) are understood. Bindings are also generated
automatically when a header contains Objective-C declarations even without the
flag, but `-fobjc` additionally predefines `__OBJC__` and friends and enables
`__has_feature(objc_*)`, which real Apple headers rely on.

The generated code depends on zig-objc's `objc` module, which must be added to
the translated module as the import named `"objc"`:

```zig
const zig_objc = b.dependency("zig_objc", .{ .target = target, .optimize = optimize });

const foundation: Translator = .init(translate_c, .{
    .c_source_file = b.addWriteFiles().add("foundation.h",
        \\#import <Foundation/Foundation.h>
        \\
    ),
    .target = target,
    .optimize = optimize,
    .objc = true,
    .objc_module = zig_objc.module("objc"),
});
foundation.addSystemFrameworkPath(.{ .cwd_relative = "/path/to/SDK/System/Library/Frameworks" });
exe.root_module.addImport("foundation", foundation.mod);
exe.root_module.linkFramework("Foundation", .{});
```

### What the bindings look like

Every class and protocol becomes an `opaque` wrapper type. Objects are plain
pointers to it, so nullability maps onto Zig optionals: a method declared as
returning `nullable NSString *` (or any object pointer outside of a
`NS_ASSUME_NONNULL` region) returns `?*NSString`, otherwise `*NSString`.
Methods are exposed as functions on the wrapper:

```zig
const F = @import("foundation");

const str = F.NSString.stringWithUTF8String("hello");   // + (instancetype)stringWithUTF8String:
const len = str.length();                              // @property (readonly) NSUInteger length
const upper = str.uppercaseString();                   // - (NSString *)uppercaseString
if (str.isEqualToString(upper)) {}                     // BOOL becomes bool
const mutable = F.NSMutableString.alloc().?.initWithCapacity(16); // inherited class method
mutable.appendString(str);
mutable.release();                                     // - (oneway void)release
```

- Selectors are turned into identifiers by joining their parts with `_`:
  `initWithBytes:length:` becomes `initWithBytes_length`. Names that collide
  with a Zig keyword are quoted (`@"error"`); a class method whose name
  collides with an instance method gets a `_class` suffix (`description` and
  `description_class`), a selector with arguments that collides with one
  without gets a trailing `_` (`foo` and `foo_`), and so does a method named
  like a type (`- (CIImage *)CIImage` becomes `CIImage_`).
- Inherited methods, category methods and the methods of adopted protocols are
  all available on the wrapper. Class methods are called on the wrapper type
  (`NSString.stringWithUTF8String(...)`), instance methods on the object.
  `instancetype` follows the receiver: `NSMutableString.alloc()` returns a
  `?*NSMutableString` (`alloc`, `init` and `new` come from the unaudited
  `objc/NSObject.h`, hence the optional).
- Properties produce a getter and, unless `readonly`, a `setXxx` setter,
  honouring `getter=`/`setter=`.
- `id` is `objc.Object` (or `?objc.Object`); `id<Protocol>` is a pointer to
  the protocol's wrapper type; `Class` and `SEL` are `objc.Class` and
  `objc.Sel`; structs, enums and other C types translate as usual.
- Blocks are `__objc.Block(fn (Args...) callconv(.c) Ret)`, an `extern struct`
  holding the block pointer. `Block.Type(Captures)` is the matching
  `objc.Block(...)` type from zig-objc, `Block.init(&context)` wraps a block
  context to pass it to a method, and `Block.invoke(.{...})` calls a block
  received from Objective-C. C pointers in block signatures are converted to
  optional single-item pointers because zig-objc cannot encode `[*c]` pointers.
- Every wrapper also offers `objcClass()`/`objcProtocol()`, `object()` (the
  zig-objc `Object`), `msgSend`, `msgSendSuper`, `as(T)` (an unchecked cast to
  another wrapper), `fromObject` and `fromId`.
- Methods marked `unavailable` (`NS_UNAVAILABLE`, `API_UNAVAILABLE` for the
  target platform) are omitted; deprecations are noted in the doc comments,
  together with the original Objective-C declaration.
- Variadic methods only accept their fixed arguments. Function bodies and macros
  that use Objective-C expressions (message sends, `@selector`, block literals,
  ...) become `@compileError` declarations, like other untranslatable C.

Plain C headers that use blocks (for example `dispatch/dispatch.h` on Apple
targets, where `__BLOCKS__` is predefined) are translated too: without
Objective-C bindings a block type is an opaque `?*const anyopaque`.

### Implementation notes

Aro, the C frontend, only parses C. This fork depends on a lightly patched
fork of it, [moderatelyConfused/aro](https://github.com/moderatelyConfused/aro)
(`#import`, an `@` token, `-x objective-c`; see its `PATCHES.md`), and rewrites
the Objective-C declarations of the preprocessed token stream into plain C
before parsing ([`src/objc/Rewriter.zig`](src/objc/Rewriter.zig)):
classes become typedefs, methods and properties become prototypes that carry
their types, and blocks become pointers to synthetic structs. The recorded
declarations ([`src/objc/Model.zig`](src/objc/Model.zig)) are then turned into
Zig by [`src/objc/Codegen.zig`](src/objc/Codegen.zig), using the types Aro
resolved for the prototypes.

The `test-objc` build step compile-checks the bindings generated from
[`test/objc/Foundation.h`](test/objc/Foundation.h) together with a vendored copy
of zig-objc for `aarch64-macos` and `x86_64-macos`; it runs on any host. The
real `<Foundation/Foundation.h>` and `<Cocoa/Cocoa.h>` of the macOS 11.3 SDK
translate without errors (about 145k and 360k lines of Zig), and a program using
those bindings compiles against zig-objc; see
[`examples/objc_foundation`](examples/objc_foundation/build.zig) for a build
script that does this with a local SDK.
