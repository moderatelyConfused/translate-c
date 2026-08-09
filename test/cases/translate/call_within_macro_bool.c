#include <stdbool.h>

#define M f(true)
#define N g(true)
#define O h(true)
#define P f(1 > 2 ? true : false)

int f(bool a) {
  return a;
}

int (*const g)(bool) = &f;
int (*h)(bool) = &f;

// translate
//
// pub export fn f(arg_a: bool) c_int {
//     var a = arg_a;
//     _ = &a;
//     return @intFromBool(a);
// }
//
// pub export const g: ?*const fn (bool) callconv(.c) c_int = &f;
//
// pub export var h: ?*const fn (bool) callconv(.c) c_int = &f;
//
// pub const M = f(__helpers.cast(bool, @"true"));
//
// pub const N = g(__helpers.cast(bool, @"true"));
// 
// 5:9: warning: macro 'O' contains a runtime value, translated to function
//
// pub inline fn O() @TypeOf(h(__helpers.cast(bool, @"true"))) {
//     return h(__helpers.cast(bool, @"true"));
// }
//
// pub const P = f(__helpers.cast(bool, if (__helpers.cast(bool, @as(c_int, 1) > @as(c_int, 2))) @"true" else @"false"));
