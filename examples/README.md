# Examples

You can test that all of the examples work by running `zig build all` in this directory.

Within a specific example's directory, run `zig build test` to test that example. Most also have a step
called `run` or similar which you can use to run the compiled program without hiding stdout.

- [import header](import_header/build.zig)
- [compile c](compile_c/build.zig)
- [use static library](use_static_lib/build.zig)
- [Objective-C Foundation bindings](objc_foundation/build.zig) (macOS only)
