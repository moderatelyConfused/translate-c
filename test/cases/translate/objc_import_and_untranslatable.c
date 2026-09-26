@import Foundation;
@class NSBundle;
#define NSLocalizedString(key, comment) [NSBundle localizedStringForKey:(key) value:@"" table:nil]
#define kNSFoo @"foo"
#define PLAIN_MACRO 42
static inline int uses_objc(void) { return [NSBundle mainBundle] != 0; }
static inline void uses_literal(void) { void (^b)(void) = ^{ }; b(); }
static inline int plain(int x) { return x + PLAIN_MACRO; }
static inline NSBundle *bundle_from_ref(const void *ref) { return (__bridge NSBundle *)ref; }
static inline const void *ref_from_bundle(NSBundle *bundle) { return (__bridge_retained const void *)bundle; }

@interface NSBundle
+ (NSBundle *)mainBundle;
@end

@implementation NSBundle
- (int)foo { return 1; }
@end

// translate
// args=-fobjc
// target=aarch64-macos
//
// pub fn plain(arg_x: c_int) callconv(.c) c_int {
//
// pub fn bundle_from_ref(arg_ref: ?*const anyopaque) callconv(.c) ?*NSBundle {
//
// pub fn ref_from_bundle(arg_bundle: ?*NSBundle) callconv(.c) ?*const anyopaque {
//
// pub const NSLocalizedString = @compileError("unable to translate macro: uses Objective-C syntax");
//
// pub const kNSFoo = @compileError("unable to translate macro: uses Objective-C syntax");
//
// pub const PLAIN_MACRO = @as(c_int, 42);
//
// warning: '@import' is not supported, use '#import' instead
//
// warning: '@implementation' was skipped
// pub const uses_objc = @compileError("unable to translate function: function body uses Objective-C syntax");
//
// pub const uses_literal = @compileError("unable to translate function: function body uses a block literal");
//
//         pub fn mainBundle() ?*NSBundle {
//             return __objc.msgSendClass(Self, ?*NSBundle, "mainBundle", .{});
