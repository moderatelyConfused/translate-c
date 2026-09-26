# Vendored zig-objc sources (tests only)

This is an unmodified copy of the `src/` directory of
[mitchellh/zig-objc](https://github.com/mitchellh/zig-objc) at commit
`c8de82ff80281215ad92900866dab7103a8efa8b`, used by the `test-objc` build step to
compile-check the Objective-C bindings that translate-c generates.

zig-objc's own `build.zig` needs an Xcode installation to translate the
Objective-C runtime headers, which is not available on the hosts that run the
translate-c test suite. The test step therefore builds the `objc` module
directly from these files and provides the `objc-c` import from the stub
runtime headers in `../runtime`.

See `LICENSE` for zig-objc's license (MIT).
