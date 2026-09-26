typedef unsigned long NSUInteger;
typedef void (^dispatch_block_t)(void);
typedef int (^int_block_t)(int a, int b);
void dispatch_async_f(void *queue, dispatch_block_t block);
void run_inline_block(void (^callback)(int status));
struct holder {
    void (^on_done)(void);
};
@class NSString, NSDictionary;
@protocol NSCopying;

@interface NSObject
@end

@interface NSArray : NSObject
- (void)enumerateObjectsUsingBlock:(void (__attribute__((noescape)) ^)(id obj, NSUInteger idx, BOOL *stop))block;
- (void)sortUsingComparator:(int (^ _Nullable)(id, id))cmp;
@property (nullable, copy) dispatch_block_t completion;
- (dispatch_block_t)makeBlock;
- (void)nested:(void (^)(void (^inner)(int)))outer;
- (void)enumerateAttributes:(void (^)(NSDictionary<NSString *, id> *attrs, NSUInteger idx, BOOL *stop))block;
- (void)withCopying:(void (^)(id<NSCopying> _Nullable item, id<NSCopying> _Nonnull other))block;
@end

// translate
// args=-fobjc
// target=aarch64-macos
//
// pub const dispatch_block_t = __objc.Block(fn () callconv(.c) void);
// pub const int_block_t = __objc.Block(fn (a: c_int, b: c_int) callconv(.c) c_int);
// pub extern fn dispatch_async_f(queue: ?*anyopaque, block: dispatch_block_t) void;
// pub extern fn run_inline_block(callback: __objc.Block(fn (status: c_int) callconv(.c) void)) void;
// pub const struct_holder = extern struct {
//     on_done: __objc.Block(fn () callconv(.c) void),
// };
//
//         pub fn enumerateObjectsUsingBlock(self: *Self, block: __objc.Block(fn (obj: id, idx: NSUInteger, stop: [*c]BOOL) callconv(.c) void)) void {
//             __objc.msgSend(self, void, "enumerateObjectsUsingBlock:", .{block});
//
//         pub fn sortUsingComparator(self: *Self, cmp: __objc.Block(fn (id, id) callconv(.c) c_int)) void {
//
//         pub fn completion(self: *Self) __objc.Block(fn () callconv(.c) void) {
//
//         pub fn makeBlock(self: *Self) __objc.Block(fn () callconv(.c) void) {
//
//         pub fn nested(self: *Self, outer: __objc.Block(fn (inner: __objc.Block(fn (c_int) callconv(.c) void)) callconv(.c) void)) void {
//
//         pub fn enumerateAttributes(self: *Self, block: __objc.Block(fn (attrs: ?*NSDictionary, idx: NSUInteger, stop: [*c]BOOL) callconv(.c) void)) void {
//
//         pub fn withCopying(self: *Self, block: __objc.Block(fn (item: ?*NSCopying, other: *NSCopying) callconv(.c) void)) void {
