@class NSString;

@protocol NSCopying
- (id)copyWithZone:(void *)zone;
@end

@protocol NSMutableCopying <NSCopying>
- (id)mutableCopyWithZone:(void *)zone;
@optional
- (void)optionalThing;
@required
+ (int)classThing;
@end

@protocol NSObject
- (BOOL)isEqual:(id)object;
@end

@interface NSObject <NSObject>
- (instancetype)init;
@end

@interface NSString : NSObject <NSMutableCopying>
- (unsigned long)length;
@end

@interface NSString (Extensions)
- (NSString *)uppercaseString;
@end

@interface NSString ()
- (void)privateThing;
@end

@compatibility_alias MyString NSString;

// translate
// args=-fobjc
// target=aarch64-macos
//
// pub const MyString = NSString;
//
//     // Methods of class `NSString`
//     pub const length = __objc_methods_NSString(@This()).length;
//     pub const uppercaseString = __objc_methods_NSString(@This()).uppercaseString;
//     pub const privateThing = __objc_methods_NSString(@This()).privateThing;
//
//     // Methods of protocol `NSMutableCopying`
//     pub const mutableCopyWithZone = __objc_protocol_methods_NSMutableCopying(@This()).mutableCopyWithZone;
//     pub const optionalThing = __objc_protocol_methods_NSMutableCopying(@This()).optionalThing;
//     pub const classThing = __objc_protocol_methods_NSMutableCopying(@This()).classThing;
//
//     // Methods of protocol `NSCopying`
//     pub const copyWithZone = __objc_protocol_methods_NSCopying(@This()).copyWithZone;
//
//     // Methods of class `NSObject`
//     pub const init = __objc_methods_NSObject(@This()).init;
//
//     // Methods of protocol `NSObject`
//     pub const isEqual = __objc_protocol_methods_NSObject(@This()).isEqual;
// };
//
// pub const NSMutableCopying = opaque {
//     pub const objc_protocol_name = "NSMutableCopying";
//     pub const objcProtocol = __objc.ProtocolHelpers(objc_protocol_name).objcProtocol;
//
//     // Methods of protocol `NSMutableCopying`
//     pub const mutableCopyWithZone = __objc_protocol_methods_NSMutableCopying(@This()).mutableCopyWithZone;
//     pub const optionalThing = __objc_protocol_methods_NSMutableCopying(@This()).optionalThing;
//
//     // Methods of protocol `NSCopying`
//     pub const copyWithZone = __objc_protocol_methods_NSCopying(@This()).copyWithZone;
// };
//
//         /// `- (void)optionalThing`
//         /// Optional protocol method.
//         pub fn optionalThing(self: *Self) void {
//
// pub const NSObjectProtocol = opaque {
//     pub const objc_protocol_name = "NSObject";
