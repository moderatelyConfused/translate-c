// A minimal stand-in for Apple's <objc/runtime.h> with the declarations that
// zig-objc uses, used by the translate-c test suite.
#ifndef _OBJC_RUNTIME_H_
#define _OBJC_RUNTIME_H_

#include <objc/objc.h>
#include <stddef.h>
#include <stdint.h>

typedef struct objc_method *Method;
typedef struct objc_ivar *Ivar;
typedef struct objc_category *Category;
typedef struct objc_property *objc_property_t;

struct objc_method_description {
    SEL _Nullable name;
    char * _Nullable types;
};

typedef struct {
    const char * _Nonnull name;
    const char * _Nonnull value;
} objc_property_attribute_t;

id _Nullable object_copy(id _Nullable obj, size_t size);
id _Nullable object_dispose(id _Nullable obj);
Class _Nullable object_getClass(id _Nullable obj);
Class _Nullable object_setClass(id _Nullable obj, Class _Nonnull cls);
BOOL object_isClass(id _Nullable obj);
Ivar _Nullable object_getInstanceVariable(id _Nullable obj, const char * _Nonnull name, void * _Nullable * _Nullable outValue);
id _Nullable object_getIvar(id _Nullable obj, Ivar _Nonnull ivar);
void object_setIvar(id _Nullable obj, Ivar _Nonnull ivar, id _Nullable value);
const char * _Nonnull object_getClassName(id _Nullable obj);

Class _Nullable objc_getClass(const char * _Nonnull name);
Class _Nullable objc_getMetaClass(const char * _Nonnull name);
Class _Nullable objc_lookUpClass(const char * _Nonnull name);
Class _Nonnull objc_getRequiredClass(const char * _Nonnull name);
int objc_getClassList(Class _Nonnull * _Nullable buffer, int bufferCount);
Protocol * _Nullable objc_getProtocol(const char * _Nonnull name);

const char * _Nonnull class_getName(Class _Nullable cls);
BOOL class_isMetaClass(Class _Nullable cls);
Class _Nullable class_getSuperclass(Class _Nullable cls);
size_t class_getInstanceSize(Class _Nullable cls);
Ivar _Nullable class_getInstanceVariable(Class _Nullable cls, const char * _Nonnull name);
Method _Nullable class_getInstanceMethod(Class _Nullable cls, SEL _Nonnull name);
Method _Nullable class_getClassMethod(Class _Nullable cls, SEL _Nonnull name);
IMP _Nullable class_getMethodImplementation(Class _Nullable cls, SEL _Nonnull name);
BOOL class_respondsToSelector(Class _Nullable cls, SEL _Nonnull sel);
BOOL class_conformsToProtocol(Class _Nullable cls, Protocol * _Nullable protocol);
objc_property_t _Nullable class_getProperty(Class _Nullable cls, const char * _Nonnull name);
objc_property_t _Nonnull * _Nullable class_copyPropertyList(Class _Nullable cls, unsigned int * _Nullable outCount);
Protocol * __unsafe_unretained _Nonnull * _Nullable class_copyProtocolList(Class _Nullable cls, unsigned int * _Nullable outCount);
BOOL class_addMethod(Class _Nullable cls, SEL _Nonnull name, IMP _Nonnull imp, const char * _Nullable types);
IMP _Nullable class_replaceMethod(Class _Nullable cls, SEL _Nonnull name, IMP _Nonnull imp, const char * _Nullable types);
BOOL class_addIvar(Class _Nullable cls, const char * _Nonnull name, size_t size, uint8_t alignment, const char * _Nullable types);
BOOL class_addProtocol(Class _Nullable cls, Protocol * _Nonnull protocol);

Class _Nullable objc_allocateClassPair(Class _Nullable superclass, const char * _Nonnull name, size_t extraBytes);
void objc_registerClassPair(Class _Nonnull cls);
void objc_disposeClassPair(Class _Nonnull cls);

SEL _Nonnull method_getName(Method _Nonnull m);
IMP _Nonnull method_getImplementation(Method _Nonnull m);
const char * _Nullable method_getTypeEncoding(Method _Nonnull m);

const char * _Nonnull ivar_getName(Ivar _Nonnull v);
const char * _Nullable ivar_getTypeEncoding(Ivar _Nonnull v);
ptrdiff_t ivar_getOffset(Ivar _Nonnull v);

const char * _Nonnull property_getName(objc_property_t _Nonnull property);
const char * _Nullable property_getAttributes(objc_property_t _Nonnull property);
char * _Nullable property_copyAttributeValue(objc_property_t _Nonnull property, const char * _Nonnull attributeName);

BOOL protocol_conformsToProtocol(Protocol * _Nullable proto, Protocol * _Nullable other);
BOOL protocol_isEqual(Protocol * _Nullable proto, Protocol * _Nullable other);
const char * _Nonnull protocol_getName(Protocol * _Nonnull proto);
objc_property_t _Nullable protocol_getProperty(Protocol * _Nonnull proto, const char * _Nonnull name, BOOL isRequiredProperty, BOOL isInstanceProperty);

const char * _Nonnull sel_getName(SEL _Nonnull sel);
SEL _Nonnull sel_registerName(const char * _Nonnull str);
BOOL sel_isEqual(SEL _Nonnull lhs, SEL _Nonnull rhs);

void objc_enumerationMutation(id _Nonnull obj);
void objc_setEnumerationMutationHandler(void (* _Nullable handler)(id _Nonnull));

#endif
