#import <objc/objc.h>
#import <objc/objc.h>
#define NS_ASSUME_NONNULL_BEGIN _Pragma("clang assume_nonnull begin")
#define NS_ASSUME_NONNULL_END   _Pragma("clang assume_nonnull end")
#define NS_UNAVAILABLE __attribute__((unavailable))
#define NS_DESIGNATED_INITIALIZER __attribute__((objc_designated_initializer))
#define API_AVAILABLE(...) __attribute__((availability(macos,introduced=10.10)))
#define API_DEPRECATED(msg, ...) __attribute__((availability(macos,introduced=10.0,deprecated=10.12,message=msg)))
#define NS_SWIFT_NAME(x) __attribute__((swift_name(#x)))
#define NS_NOESCAPE __attribute__((noescape))
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef unsigned short unichar;
typedef struct _NSRange { NSUInteger location; NSUInteger length; } NSRange;
typedef struct _NSZone NSZone;
typedef enum NSComparisonResult : NSInteger { NSOrderedAscending = -1L, NSOrderedSame, NSOrderedDescending } NSComparisonResult;
typedef void (^dispatch_block_t)(void);

@class NSString, NSArray<ObjectType>, NSError;
@protocol NSCopying, NSFastEnumeration;

NS_ASSUME_NONNULL_BEGIN

@protocol NSObject
- (BOOL)isEqual:(id)object;
@property (readonly) NSUInteger hash;
@property (readonly) Class superclass;
- (Class)class NS_SWIFT_NAME(class());
- (instancetype)self;
- (BOOL)isKindOfClass:(Class)aClass;
- (BOOL)respondsToSelector:(SEL)aSelector;
- (instancetype)retain;
- (oneway void)release;
- (instancetype)autorelease;
@property (readonly, copy) NSString *description;
@optional
@property (readonly, copy) NSString *debugDescription;
@end

@protocol NSCopying
- (id)copyWithZone:(nullable NSZone *)zone;
@end

__attribute__((objc_root_class))
@interface NSObject <NSObject> {
    Class isa;
}
+ (void)load;
+ (instancetype)alloc;
+ (instancetype)new;
- (instancetype)init;
- (void)dealloc;
+ (Class)class;
+ (Class)superclass;
+ (NSString *)description;
- (id)copy;
+ (BOOL)instancesRespondToSelector:(SEL)aSelector;
- (void)performSelector:(SEL)aSelector withObject:(nullable id)object afterDelay:(double)delay;
@end

typedef NSString *NSNotificationName NS_SWIFT_NAME(NSNotification.Name);

@interface NSString : NSObject <NSCopying>
@property (readonly) NSUInteger length;
- (unichar)characterAtIndex:(NSUInteger)index;
+ (instancetype)stringWithUTF8String:(const char *)nullTerminatedCString;
+ (nullable instancetype)stringWithContentsOfFile:(NSString *)path error:(NSError * _Nullable * _Nullable)error;
- (NSString *)stringByAppendingString:(NSString *)aString;
- (BOOL)isEqualToString:(NSString *)aString;
- (NSComparisonResult)compare:(NSString *)string;
- (NSRange)rangeOfString:(NSString *)searchString;
@property (nullable, readonly) const char *UTF8String;
- (void)enumerateLinesUsingBlock:(void (NS_NOESCAPE ^)(NSString *line, BOOL *stop))block;
+ (instancetype)stringWithFormat:(NSString *)format, ...;
- (instancetype)init NS_UNAVAILABLE;
@property (class, readonly) NSString *emptyString;
- (void)doThing:(int)x for:(int)y;
- (void)deprecatedThing API_DEPRECATED("use doThing:for:", macos(10.0, 10.12));
@end

@interface NSString (NSStringExtensionMethods)
- (NSString *)uppercaseString;
@property (readonly, copy) NSString *lowercaseString API_AVAILABLE(macos(10.10));
@end

@interface NSMutableString : NSString
- (void)appendString:(NSString *)aString;
- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
@end

@interface NSArray<__covariant ObjectType> : NSObject <NSCopying, NSFastEnumeration>
@property (readonly) NSUInteger count;
- (ObjectType)objectAtIndex:(NSUInteger)index;
- (nullable ObjectType)firstObject;
- (void)enumerateObjectsUsingBlock:(void (NS_NOESCAPE ^)(ObjectType obj, NSUInteger idx, BOOL *stop))block;
- (NSArray<ObjectType> *)arrayByAddingObject:(ObjectType)anObject;
- (void)getObjects:(ObjectType __unsafe_unretained _Nonnull [])objects range:(NSRange)range;
- (void)setDelegate:(nullable id<NSCopying>)delegate;
- (id<NSCopying, NSObject>)delegate;
@property (nullable, copy) dispatch_block_t completion;
@property (nullable, copy) void (^handler)(BOOL done);
@end

@interface NSError : NSObject
@property (readonly) NSInteger code;
@end

NS_ASSUME_NONNULL_END

extern void NSLog(NSString *format, ...);
static inline int plain_c(int x) { return x + 1; }
static inline id bad_body(void) { return @"literal"; }
#define NSLocalizedString(key, comment) [NSBundle localizedString:key]
void dispatch_async_f(void *queue, void (^block)(void));
