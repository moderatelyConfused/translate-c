// A minimal stand-in for Apple's <objc/objc.h>, used by the translate-c test
// suite so that Objective-C bindings can be compiled on any host.
#ifndef _OBJC_OBJC_H_
#define _OBJC_OBJC_H_

#include <stdbool.h>

typedef struct objc_class *Class;
struct objc_object {
    Class _Nonnull isa;
};
typedef struct objc_object *id;
typedef struct objc_selector *SEL;
typedef id _Nullable (*IMP)(id _Nonnull, SEL _Nonnull, ...);

#if defined(__OBJC_BOOL_IS_BOOL)
#define OBJC_BOOL_IS_BOOL __OBJC_BOOL_IS_BOOL
#elif defined(__aarch64__)
#define OBJC_BOOL_IS_BOOL 1
#else
#define OBJC_BOOL_IS_BOOL 0
#endif

#if OBJC_BOOL_IS_BOOL
typedef bool BOOL;
#else
typedef signed char BOOL;
#endif

#define YES ((BOOL)1)
#define NO ((BOOL)0)
#define nil ((id)0)
#define Nil ((Class)0)

#ifdef __OBJC__
@class Protocol;
#else
typedef struct objc_object Protocol;
// Objective-C ownership qualifiers are keywords only in Objective-C.
#define __unsafe_unretained
#define __autoreleasing
#define __strong
#define __weak
#endif

#endif
