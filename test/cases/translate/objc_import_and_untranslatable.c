@import Foundation;
@class NSBundle;
#define NSLocalizedString(key, comment) [NSBundle localizedStringForKey:(key) value:@"" table:nil]
#define kNSFoo @"foo"
#define PLAIN_MACRO 42
static inline int uses_objc(void) { return [NSBundle mainBundle] != 0; }
static inline void uses_literal(void) { void (^b)(void) = ^{ }; b(); }
static inline int plain(int x) { return x + PLAIN_MACRO; }

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
