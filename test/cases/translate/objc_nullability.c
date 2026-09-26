@class NSString, NSError;

@interface NSObject
@end

_Pragma("clang assume_nonnull begin")

@interface NSFoo : NSObject
- (NSString *)implicitNonnull:(NSString *)arg;
- (nullable NSString *)explicitNullable:(nullable NSString *)arg;
- (NSString * _Nullable)qualifierNullable:(id _Nullable)arg;
- (id)implicitId:(Class)cls sel:(SEL)sel;
- (nullable id)nullableId:(nullable Class)cls sel:(nullable SEL)sel;
- (BOOL)tryWithError:(NSError * _Nullable * _Nullable)error;
- (nonnull NSString *)stillNonnull;
@end

_Pragma("clang assume_nonnull end")

@interface NSBar : NSObject
- (NSString *)implicitNullable:(NSString *)arg;
- (nonnull NSString *)explicitNonnull:(nonnull NSString *)arg;
- (id)implicitNullableId;
@end

// translate
// args=-fobjc
// target=aarch64-macos
//
//         pub fn implicitNonnull(self: *Self, arg: *NSString) *NSString {
//             return __objc.msgSend(self, *NSString, "implicitNonnull:", .{arg});
//
//         pub fn explicitNullable(self: *Self, arg: ?*NSString) ?*NSString {
//             return __objc.msgSend(self, ?*NSString, "explicitNullable:", .{arg});
//
//         pub fn qualifierNullable(self: *Self, arg: ?objc.Object) ?*NSString {
//             return __objc.msgSend(self, ?*NSString, "qualifierNullable:", .{__objc.idOf(arg)});
//
//         pub fn implicitId_sel(self: *Self, cls: objc.Class, sel: objc.Sel) objc.Object {
//             return __objc.msgSend(self, objc.Object, "implicitId:sel:", .{ cls, sel });
//
//         pub fn nullableId_sel(self: *Self, cls: ?objc.Class, sel: ?objc.Sel) ?objc.Object {
//             return __objc.objectFromId(__objc.msgSend(self, objc.c.id, "nullableId:sel:", .{ __objc.rawClass(cls), __objc.rawSel(sel) }));
//
//         pub fn tryWithError(self: *Self, @"error": [*c]?*NSError) bool {
//             return __objc.fromBOOL(__objc.msgSend(self, objc.c.BOOL, "tryWithError:", .{@"error"}));
//
//         pub fn stillNonnull(self: *Self) *NSString {
//
//         pub fn implicitNullable(self: *Self, arg: ?*NSString) ?*NSString {
//
//         pub fn explicitNonnull(self: *Self, arg: *NSString) *NSString {
//
//         pub fn implicitNullableId(self: *Self) ?objc.Object {
