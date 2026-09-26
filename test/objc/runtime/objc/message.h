// A minimal stand-in for Apple's <objc/message.h> with the declarations that
// zig-objc uses, used by the translate-c test suite.
#ifndef _OBJC_MESSAGE_H_
#define _OBJC_MESSAGE_H_

#include <objc/objc.h>
#include <objc/runtime.h>

struct objc_super {
    __unsafe_unretained _Nonnull id receiver;
    __unsafe_unretained _Nonnull Class super_class;
};

void objc_msgSend(void);
void objc_msgSendSuper(void);
#if defined(__x86_64__)
void objc_msgSend_stret(void);
void objc_msgSendSuper_stret(void);
void objc_msgSend_fpret(void);
void objc_msgSendSuper_fpret(void);
#endif

#endif
