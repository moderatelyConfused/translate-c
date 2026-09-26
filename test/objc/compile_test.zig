//! Exercises the Objective-C bindings generated from `Foundation.h`. This is
//! only compiled (for Apple targets), never run, so it can be checked on any
//! host.
const std = @import("std");
const objc = @import("objc");
const F = @import("foundation");

pub export fn objc_bindings_smoke_test() void {
    const str = F.NSString.stringWithUTF8String("hello");
    const len = str.length();
    _ = str.characterAtIndex(0);
    _ = str.uppercaseString();
    _ = str.lowercaseString();
    _ = str.compare(str);
    const eq: bool = str.isEqualToString(str);
    _ = eq;
    const r: F.NSRange = str.rangeOfString(str);
    _ = r.location;
    var err: ?*F.NSError = null;
    const s2 = F.NSString.stringWithContentsOfFile_error(str, &err);
    if (s2) |s| _ = s.length();
    if (err) |e| _ = e.code();
    const utf8: [*c]const u8 = str.UTF8String();
    _ = utf8;
    str.doThing_for(1, 2);

    const arr = F.NSArray.alloc().init();
    _ = arr.count();
    const first: ?objc.Object = arr.firstObject();
    _ = first;
    const obj: objc.Object = arr.objectAtIndex(0);
    _ = arr.arrayByAddingObject(obj);
    arr.setDelegate(null);
    const delegate: *F.NSCopying = arr.delegate();
    _ = delegate.copyWithZone(null);

    const BlockPtr = @typeInfo(@TypeOf(F.NSArray.enumerateObjectsUsingBlock)).@"fn".params[1].type.?;
    const Blk = BlockPtr.Type(struct { total: usize });
    var block = Blk.init(.{ .total = 0 }, &struct {
        fn f(ctx: *const Blk.Context, o: F.id, idx: F.NSUInteger, stop: ?*F.BOOL) callconv(.c) void {
            _ = ctx;
            _ = o;
            _ = idx;
            _ = stop;
        }
    }.f);
    arr.enumerateObjectsUsingBlock(.init(&block));
    const completion = arr.completion();
    if (!completion.isNull()) completion.invoke(.{});
    arr.setHandler(.nil);
    arr.setCompletion(.nil);

    const cls: objc.Class = F.NSString.objcClass();
    _ = cls;
    _ = str.object().msgSend(F.NSUInteger, "length", .{});
    _ = str.msgSend(F.NSUInteger, "length", .{});
    _ = str.retain();
    str.release();

    const ms = F.NSMutableString.alloc().initWithCapacity(10);
    ms.appendString(str);
    _ = ms.as(F.NSString).length();
    _ = ms.length();
    _ = ms.msgSendSuper(F.NSUInteger, "length", .{});
    _ = F.NSObject.description_class();
    _ = F.NSObject.class_class();
    _ = str.class();
    _ = str.hash();
    _ = str.self_();
    _ = str.isKindOfClass(F.NSObject.objcClass());
    _ = str.respondsToSelector(objc.sel("length"));
    _ = F.NSString.emptyString();
    _ = F.NSObject.new();
    _ = F.NSObject.instancesRespondToSelector(objc.sel("init"));
    const d: *F.NSString = str.description();
    _ = d;
    _ = F.NSString.stringWithFormat(str);
    str.performSelector_withObject_afterDelay(objc.sel("length"), null, 1.0);
    _ = F.NSCopying.objcProtocol();
    _ = F.NSObjectProtocol.objcProtocol();
    _ = F.NSString.objc_class_name;
    _ = F.NSString.Super;
    _ = F.NSString.fromObject(obj);
    _ = F.NSString.fromId(obj.value);
    std.mem.doNotOptimizeAway(len);
}
