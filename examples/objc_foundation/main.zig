const std = @import("std");
const objc = @import("objc");
const F = @import("foundation");

test "NSString round trip" {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // `+ (nullable instancetype)stringWithUTF8String:(const char *)nullTerminatedCString;`
    const hello = F.NSString.stringWithUTF8String("hello").?;
    try std.testing.expectEqual(@as(F.NSUInteger, 5), hello.length());

    // `- (NSString *)stringByAppendingString:(NSString *)aString;`
    const world = F.NSString.stringWithUTF8String(" world").?;
    const joined = hello.stringByAppendingString(world);
    try std.testing.expectEqualStrings("hello world", std.mem.span(joined.UTF8String().?));

    // `- (BOOL)isEqualToString:(NSString *)aString;` translates to a Zig `bool`.
    try std.testing.expect(!hello.isEqualToString(world));
    try std.testing.expect(hello.isEqualToString(hello.uppercaseString().lowercaseString()));
}

test "inherited methods and instancetype" {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // `+alloc` / `-init` are declared by NSObject but return the receiver type.
    // `objc/NSObject.h` is not nullability-audited, so both return optionals.
    const string: *F.NSMutableString = F.NSMutableString.alloc().?.init().?;
    defer string.release();
    string.appendString(F.NSString.stringWithUTF8String("abc").?);
    try std.testing.expectEqual(@as(F.NSUInteger, 3), string.length());

    // Any wrapper can be viewed as a zig-objc `Object` for dynamic dispatch.
    try std.testing.expectEqual(@as(F.NSUInteger, 3), string.object().msgSend(F.NSUInteger, "length", .{}));
}

test "class properties and process info" {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const info = F.NSProcessInfo.processInfo();
    try std.testing.expect(info.processIdentifier() > 0);
    const name = info.processName();
    try std.testing.expect(name.length() > 0);
}
