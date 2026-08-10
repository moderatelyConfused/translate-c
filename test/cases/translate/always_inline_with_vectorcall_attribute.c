__attribute__((always_inline, vectorcall)) int foo(void) {
    return 5;
}

// translate
// target=x86_64-windows-msvc
//
// warning: vectorcall calling convention ignored on inline function
// pub inline fn foo() c_int {
//     return 5;
// }
