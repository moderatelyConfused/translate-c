#define NS_UNAVAILABLE __attribute__((unavailable))
extern int index;
@class NSError, CIImage;
typedef struct _NSRange { unsigned long location; unsigned long length; } NSRange;

@interface NSObject
+ (instancetype)alloc;
+ (instancetype)new;
- (instancetype)init;
+ (Class)class;
- (Class)class;
- (instancetype)self;
- (int)error;
@end

@interface NSFoo : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new __attribute__((availability(macos,unavailable)));
- (instancetype)initWithIndex:(int)index;
- (void)setValue:(int)value forKey:(int)key;
- (int)value;
- (int)foo;
- (int)foo:(int)x;
- (void)aloneOnIos __attribute__((availability(ios,unavailable)));
- (CIImage *)CIImage;
- (NSRange)NSRange;
@end

// translate
// args=-fobjc
// target=aarch64-macos
//
// pub const NSFoo = opaque {
//     pub const objc_class_name = "NSFoo";
//     pub const Super = NSObject;
//
//     // Methods of class `NSFoo`
//     pub const initWithIndex = __objc_methods_NSFoo(@This()).initWithIndex;
//     pub const setValue_forKey = __objc_methods_NSFoo(@This()).setValue_forKey;
//     pub const value = __objc_methods_NSFoo(@This()).value;
//     pub const foo = __objc_methods_NSFoo(@This()).foo;
//     pub const foo_ = __objc_methods_NSFoo(@This()).foo_;
//     pub const aloneOnIos = __objc_methods_NSFoo(@This()).aloneOnIos;
//     pub const CIImage_ = __objc_methods_NSFoo(@This()).CIImage_;
//     pub const NSRange_ = __objc_methods_NSFoo(@This()).NSRange_;
//
//     // Methods of class `NSObject`
//     pub const alloc = __objc_methods_NSObject(@This()).alloc;
//     pub const class_class = __objc_methods_NSObject(@This()).class_class;
//     pub const class = __objc_methods_NSObject(@This()).class;
//     pub const self_ = __objc_methods_NSObject(@This()).self_;
//     pub const @"error" = __objc_methods_NSObject(@This()).@"error";
// };
//
//         pub fn initWithIndex(self: *Self, index_: c_int) ?*Self {
//             return __objc.msgSend(self, ?*Self, "initWithIndex:", .{index_});
//
//         pub fn setValue_forKey(self: *Self, value_: c_int, key: c_int) void {
//             __objc.msgSend(self, void, "setValue:forKey:", .{ value_, key });
//
//         pub fn foo(self: *Self) c_int {
//             return __objc.msgSend(self, c_int, "foo", .{});
//
//         pub fn foo_(self: *Self, x: c_int) c_int {
//             return __objc.msgSend(self, c_int, "foo:", .{x});
//
//         /// Availability (ios): unavailable
//         pub fn aloneOnIos(self: *Self) void {
//
//         pub fn CIImage_(self: *Self) ?*CIImage {
//             return __objc.msgSend(self, ?*CIImage, "CIImage", .{});
//
//         pub fn NSRange_(self: *Self) NSRange {
//             return __objc.msgSend(self, NSRange, "NSRange", .{});
//
//         pub fn class_class() ?objc.Class {
//             return __objc.classFromRaw(__objc.msgSendClass(Self, objc.c.Class, "class", .{}));
//
//         pub fn class(self: *Self) ?objc.Class {
//
//         pub fn self_(self: *Self) ?*Self {
//
//         pub fn @"error"(self: *Self) c_int {
