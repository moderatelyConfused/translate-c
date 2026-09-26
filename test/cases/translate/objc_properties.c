typedef unsigned long NSUInteger;
@class NSString;

@interface NSObject
@end

@interface NSTask : NSObject
@property (readonly) NSUInteger processIdentifier;
@property (copy) NSString *launchPath;
@property (nonatomic, getter=isRunning, readonly) BOOL running;
@property (nonatomic, getter=isHidden, setter=setIsHidden:) BOOL hidden;
@property (class, readonly) NSTask *currentTask;
@property (nullable, copy) NSString *comment;
@property (null_resettable, copy) NSString *title;
@property void (*callback)(int);
@property NSUInteger a, b;
@property (nullable, readonly, copy) NSString *error;
@end

// translate
// args=-fobjc
// target=aarch64-macos
//
//     // Methods of class `NSTask`
//     pub const processIdentifier = __objc_methods_NSTask(@This()).processIdentifier;
//     pub const launchPath = __objc_methods_NSTask(@This()).launchPath;
//     pub const setLaunchPath = __objc_methods_NSTask(@This()).setLaunchPath;
//     pub const isRunning = __objc_methods_NSTask(@This()).isRunning;
//     pub const isHidden = __objc_methods_NSTask(@This()).isHidden;
//     pub const setIsHidden = __objc_methods_NSTask(@This()).setIsHidden;
//     pub const currentTask = __objc_methods_NSTask(@This()).currentTask;
//     pub const comment = __objc_methods_NSTask(@This()).comment;
//     pub const setComment = __objc_methods_NSTask(@This()).setComment;
//     pub const title = __objc_methods_NSTask(@This()).title;
//     pub const setTitle = __objc_methods_NSTask(@This()).setTitle;
//     pub const callback = __objc_methods_NSTask(@This()).callback;
//     pub const setCallback = __objc_methods_NSTask(@This()).setCallback;
//     pub const a = __objc_methods_NSTask(@This()).a;
//     pub const setA = __objc_methods_NSTask(@This()).setA;
//     pub const b = __objc_methods_NSTask(@This()).b;
//     pub const setB = __objc_methods_NSTask(@This()).setB;
//     pub const @"error" = __objc_methods_NSTask(@This()).@"error";
//
//         pub fn processIdentifier(self: *Self) NSUInteger {
//             return __objc.msgSend(self, NSUInteger, "processIdentifier", .{});
//
//         pub fn setLaunchPath(self: *Self, value: ?*NSString) void {
//             __objc.msgSend(self, void, "setLaunchPath:", .{value});
//
//         pub fn isRunning(self: *Self) bool {
//             return __objc.fromBOOL(__objc.msgSend(self, objc.c.BOOL, "isRunning", .{}));
//
//         pub fn setIsHidden(self: *Self, value: bool) void {
//             __objc.msgSend(self, void, "setIsHidden:", .{__objc.toBOOL(value)});
//
//         pub fn currentTask() ?*NSTask {
//             return __objc.msgSendClass(Self, ?*NSTask, "currentTask", .{});
//
//         pub fn comment(self: *Self) ?*NSString {
//
//         pub fn title(self: *Self) *NSString {
//
//         pub fn setTitle(self: *Self, value: ?*NSString) void {
//
//         pub fn callback(self: *Self) ?*const fn (c_int) callconv(.c) void {
//             return __objc.msgSend(self, ?*const fn (c_int) callconv(.c) void, "callback", .{});
//
//         pub fn setCallback(self: *Self, value: ?*const fn (c_int) callconv(.c) void) void {
