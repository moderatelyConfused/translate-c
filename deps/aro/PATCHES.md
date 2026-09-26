# Vendored Aro fork

This directory contains a vendored copy of
[vancluever/arocc](https://github.com/vancluever/arocc) at commit
`f97cdfc3779aec4b242299e2fc9a1c828c3547c6` (the revision translate-c depended on
before the fork), plus the patches below. They add just enough Objective-C
awareness to the preprocessor and tokenizer for translate-c's Objective-C
front-end (`src/objc/`), which rewrites Objective-C declarations into C before
Aro's parser runs.

## Patches

- `Tokenizer.zig`: `@` is tokenized as a new `.at` token instead of `.invalid`.
  The C parser still rejects it, but translate-c's Objective-C rewriter consumes
  every `.at` token before parsing.
- `Tokenizer.zig`, `Preprocessor.zig`: the `#import` directive is supported. It
  behaves like clang's: a file that is `#import`ed is never entered again, and
  `#import` skips files that were previously entered by any directive.
- `LangOpts.zig`, `Driver.zig`: `-x objective-c` / `-x objective-c-header` set
  the new `LangOpts.objc` flag and enable blocks.
- `Compilation.zig`: when `LangOpts.objc` is set, `__OBJC__`, `__OBJC2__`,
  `OBJC_NEW_PROPERTIES` and `__OBJC_BOOL_IS_BOOL` are predefined like clang does.
- `features.zig`: `__has_feature(blocks)` follows `LangOpts.blocks`, and the
  `objc_*` features are reported when `LangOpts.objc` is set (except ARC and
  `objc_bool`, which are reported as unavailable on purpose so that headers keep
  declaring manual reference counting APIs and define `YES`/`NO` as casts).
- `features.zig`, `Preprocessor.zig`: in Objective-C mode `__has_attribute`
  also reports the Objective-C, Swift and CoreFoundation attribute families
  (`objc_bridge`, `swift_name`, `ns_returns_retained`, ...) as available, since
  Apple's headers hide declarations behind those checks. The parser still
  ignores them as unknown attributes.

Everything else is unchanged. To update Aro, re-apply the patches above on top
of the new revision.
