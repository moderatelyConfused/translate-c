@class NSString, NSArray;
@protocol NSCoding;
typedef NSString *NSNotificationName;
extern NSString *const NSFooKey;
extern NSNotificationName const NSDidThing;
void NSLog(NSString *format, ...);
NSArray *make_array(id<NSCoding> obj, NSString * _Nonnull nonnull_string);
struct wrapper { NSString *name; id object; };

// translate
// args=-fobjc
// target=aarch64-macos
//
// pub const NSNotificationName = ?*NSString;
// pub extern const NSFooKey: ?*NSString;
// pub extern const NSDidThing: NSNotificationName;
// pub extern fn NSLog(format: ?*NSString, ...) void;
// pub extern fn make_array(obj: id, nonnull_string: *NSString) ?*NSArray;
// pub const struct_wrapper = extern struct {
//     name: ?*NSString,
//     object: id,
// };
//
// /// Objective-C class `NSString` (forward declaration only)
// pub const NSString = opaque {
//     pub const objc_class_name = "NSString";
//     pub const objcClass = __objc.ClassHelpers(@This(), objc_class_name).objcClass;
//
// /// Objective-C protocol `NSCoding` (forward declaration only)
// pub const NSCoding = opaque {
