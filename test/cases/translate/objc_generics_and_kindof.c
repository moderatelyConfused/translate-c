typedef unsigned long NSUInteger;
@class NSString;
@protocol NSCopying;

@interface NSObject
@end

@interface NSArray<__covariant ObjectType> : NSObject
- (ObjectType)objectAtIndex:(NSUInteger)index;
- (NSArray<ObjectType> *)arrayByAddingObject:(ObjectType)anObject;
+ (instancetype)arrayWithObjects:(const ObjectType _Nonnull [])objects count:(NSUInteger)cnt;
@end

@interface NSDictionary<KeyType : id<NSCopying>, ObjectType> : NSObject
- (ObjectType)objectForKey:(KeyType)aKey;
- (NSArray<KeyType> *)allKeys;
@end

@interface NSMutableDictionary<KeyType, ObjectType> : NSDictionary<KeyType, ObjectType>
- (void)setObject:(ObjectType)anObject forKey:(KeyType <NSCopying>)aKey;
@end

@interface NSArray<ObjectType> (NSExtendedArray)
- (ObjectType)firstObject;
@end

@interface NSView : NSObject
- (__kindof NSView *)superview;
- (NSArray<__kindof NSView *> *)subviews;
- (void)addSubview:(NSView * __strong)view;
@end

@interface NSMeasurement<UnitType : NSView *> : NSObject
@property (readonly, copy) UnitType unit;
@end

@interface NSDiffableDataSource<SectionIdentifierType, ItemIdentifierType> : NSObject
typedef NSView * _Nullable (^NSDiffableItemProvider)(NSView * _Nonnull, ItemIdentifierType _Nonnull);
typedef ItemIdentifierType NSDiffableItem;
- (instancetype)initWithItemProvider:(NSDiffableItemProvider)itemProvider;
@end

extern NSArray<NSString *> *global_strings;

// translate
// args=-fobjc
// target=aarch64-macos
//
// pub extern var global_strings: ?*NSArray;
//
// /// Objective-C class `NSArray` (superclass `NSObject`)
// /// Generic parameters: `ObjectType` (erased to `objc.Object`)
// pub const NSArray = opaque {
//
//         pub fn objectAtIndex(self: *Self, index: NSUInteger) ?objc.Object {
//             return __objc.objectFromId(__objc.msgSend(self, objc.c.id, "objectAtIndex:", .{index}));
//
//         pub fn arrayByAddingObject(self: *Self, anObject: ?objc.Object) ?*NSArray {
//             return __objc.msgSend(self, ?*NSArray, "arrayByAddingObject:", .{__objc.idOf(anObject)});
//
//         pub fn arrayWithObjects_count(objects: [*c]objc.c.id, cnt: NSUInteger) ?*Self {
//
//         pub fn firstObject(self: *Self) ?objc.Object {
//
//         pub fn objectForKey(self: *Self, aKey: ?*NSCopying) ?objc.Object {
//             return __objc.objectFromId(__objc.msgSend(self, objc.c.id, "objectForKey:", .{aKey}));
//
//         pub fn allKeys(self: *Self) ?*NSArray {
//
//         pub fn setObject_forKey(self: *Self, anObject: ?objc.Object, aKey: ?*NSCopying) void {
//
//         pub fn unit(self: *Self) ?*NSView {
//
// pub const NSDiffableItemProvider = __objc.Block(fn (*NSView, objc.c.id) callconv(.c) ?*NSView);
// pub const NSDiffableItem = id;
//
//         pub fn initWithItemProvider(self: *Self, itemProvider: __objc.Block(fn (*NSView, objc.c.id) callconv(.c) ?*NSView)) ?*Self {
//
//         pub fn superview(self: *Self) ?*NSView {
//
//         pub fn subviews(self: *Self) ?*NSArray {
//
//         pub fn addSubview(self: *Self, view: ?*NSView) void {
