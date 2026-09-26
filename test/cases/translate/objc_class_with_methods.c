typedef unsigned long NSUInteger;
@class NSString;

#pragma mark - The root class
__attribute__((objc_root_class)) extern __attribute__((visibility("default")))
@interface NSObject
+ (instancetype)alloc;
- (instancetype)init;
- (void)dealloc;
+ (NSString *)description;
- (NSString *)description;
@end

@interface NSString : NSObject
- (NSUInteger)length;
- (unsigned short)characterAtIndex:(NSUInteger)index;
+ (instancetype)stringWithUTF8String:(const char *)nullTerminatedCString;
- (NSString *)stringByAppendingString:(NSString *)aString;
- (void)getCharacters:(unsigned short *)buffer range:(NSUInteger)range;
- (BOOL)isEqualToString:(NSString *)aString;
+ (instancetype)stringWithFormat:(NSString *)format, ...;
- (void)doThing:(int)x for:(int)y;
@end

extern void NSLog(NSString *format, ...);

// translate
// args=-fobjc
// target=aarch64-macos
//
// pub extern fn NSLog(format: ?*NSString, ...) void;
//
// pub const objc = @import("objc");
//
// pub const NSString = opaque {
//     pub const objc_class_name = "NSString";
//     pub const Super = NSObject;
//     pub const objcClass = __objc.ClassHelpers(@This(), objc_class_name).objcClass;
//     pub const msgSendSuper = __objc.ClassHelpers(@This(), objc_class_name).msgSendSuper;
//     pub const as = __objc.Helpers(@This()).as;
//     pub const object = __objc.Helpers(@This()).object;
//     pub const fromObject = __objc.Helpers(@This()).fromObject;
//     pub const fromId = __objc.Helpers(@This()).fromId;
//     pub const msgSend = __objc.Helpers(@This()).msgSend;
//
//     // Methods of class `NSString`
//     pub const length = __objc_methods_NSString(@This()).length;
//     pub const characterAtIndex = __objc_methods_NSString(@This()).characterAtIndex;
//     pub const stringWithUTF8String = __objc_methods_NSString(@This()).stringWithUTF8String;
//     pub const stringByAppendingString = __objc_methods_NSString(@This()).stringByAppendingString;
//     pub const getCharacters_range = __objc_methods_NSString(@This()).getCharacters_range;
//     pub const isEqualToString = __objc_methods_NSString(@This()).isEqualToString;
//     pub const stringWithFormat = __objc_methods_NSString(@This()).stringWithFormat;
//     pub const doThing_for = __objc_methods_NSString(@This()).doThing_for;
//
//     // Methods of class `NSObject`
//     pub const alloc = __objc_methods_NSObject(@This()).alloc;
//     pub const init = __objc_methods_NSObject(@This()).init;
//     pub const dealloc = __objc_methods_NSObject(@This()).dealloc;
//     pub const description_class = __objc_methods_NSObject(@This()).description_class;
//     pub const description = __objc_methods_NSObject(@This()).description;
// };
//
// pub fn __objc_methods_NSString(comptime Self: type) type {
//     return struct {
//         /// `- (NSUInteger)length`
//         pub fn length(self: *Self) NSUInteger {
//             return __objc.msgSend(self, NSUInteger, "length", .{});
//         }
//         /// `- (unsigned short)characterAtIndex:(NSUInteger)index`
//         pub fn characterAtIndex(self: *Self, index: NSUInteger) c_ushort {
//             return __objc.msgSend(self, c_ushort, "characterAtIndex:", .{index});
//         }
//         /// `+ (instancetype)stringWithUTF8String:(const char *)nullTerminatedCString`
//         pub fn stringWithUTF8String(nullTerminatedCString: [*c]const u8) ?*Self {
//             return __objc.msgSendClass(Self, ?*Self, "stringWithUTF8String:", .{nullTerminatedCString});
//         }
//         /// `- (NSString *)stringByAppendingString:(NSString *)aString`
//         pub fn stringByAppendingString(self: *Self, aString: ?*NSString) ?*NSString {
//             return __objc.msgSend(self, ?*NSString, "stringByAppendingString:", .{aString});
//         }
//         /// `- (void)getCharacters:(unsigned short *)buffer range:(NSUInteger)range`
//         pub fn getCharacters_range(self: *Self, buffer: [*c]c_ushort, range: NSUInteger) void {
//             __objc.msgSend(self, void, "getCharacters:range:", .{ buffer, range });
//         }
//         /// `- (BOOL)isEqualToString:(NSString *)aString`
//         pub fn isEqualToString(self: *Self, aString: ?*NSString) bool {
//             return __objc.fromBOOL(__objc.msgSend(self, objc.c.BOOL, "isEqualToString:", .{aString}));
//         }
//         /// `+ (instancetype)stringWithFormat:(NSString *)format, ...`
//         /// Variadic: only the fixed arguments are supported.
//         pub fn stringWithFormat(format: ?*NSString) ?*Self {
//             return __objc.msgSendClass(Self, ?*Self, "stringWithFormat:", .{format});
//         }
//         /// `- (void)doThing:(int)x for:(int)y`
//         pub fn doThing_for(self: *Self, x: c_int, y: c_int) void {
//             __objc.msgSend(self, void, "doThing:for:", .{ x, y });
//         }
//     };
// }
//
// pub fn __objc_methods_NSObject(comptime Self: type) type {
//     return struct {
//         /// `+ (instancetype)alloc`
//         pub fn alloc() ?*Self {
//             return __objc.msgSendClass(Self, ?*Self, "alloc", .{});
//         }
//         /// `- (instancetype)init`
//         pub fn init(self: *Self) ?*Self {
//             return __objc.msgSend(self, ?*Self, "init", .{});
//         }
//         /// `- (void)dealloc`
//         pub fn dealloc(self: *Self) void {
//             __objc.msgSend(self, void, "dealloc", .{});
//         }
//         /// `+ (NSString *)description`
//         pub fn description_class() ?*NSString {
//             return __objc.msgSendClass(Self, ?*NSString, "description", .{});
//         }
//         /// `- (NSString *)description`
//         pub fn description(self: *Self) ?*NSString {
//             return __objc.msgSend(self, ?*NSString, "description", .{});
//         }
//     };
// }
