const std = @import("std");

/// Import the `Translator` helper from the `translate_c` dependency.
const Translator = @import("translate_c").Translator;

/// Translates a Foundation header with Objective-C bindings and uses them from
/// Zig. This requires a macOS target and an Apple SDK (found via `xcrun`), so
/// on other hosts the example does nothing.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Build and run the test");
    b.default_step = test_step;

    if (target.result.os.tag != .macos) {
        std.log.info("objc_foundation example: skipped, it requires a macOS target", .{});
        return;
    }
    const sdk_path = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse {
        std.log.warn("objc_foundation example: skipped, no macOS SDK found (is Xcode installed?)", .{});
        return;
    };

    const translate_c = b.dependency("translate_c", .{});
    const zig_objc = b.dependency("zig_objc", .{ .target = target, .optimize = optimize });

    // Translate the header with Objective-C bindings enabled. The `objc`
    // module of zig-objc is what the generated bindings are built on.
    const foundation: Translator = .init(translate_c, .{
        .c_source_file = b.path("foundation.h"),
        .target = target,
        .optimize = optimize,
        .objc = true,
        .objc_module = zig_objc.module("objc"),
    });
    foundation.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "/System/Library/Frameworks" }) });
    foundation.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "/usr/include" }) });

    const test_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "foundation", .module = foundation.mod },
            .{ .name = "objc", .module = zig_objc.module("objc") },
        },
    });
    test_module.linkFramework("Foundation", .{});

    const test_exe = b.addTest(.{ .root_module = test_module });
    const run_test = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_test.step);
}
