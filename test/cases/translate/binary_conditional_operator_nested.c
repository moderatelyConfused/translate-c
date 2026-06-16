int func1(void);
int func2(void);
int func3(void);

void foo_discard(int c, int d) {
    c ? (d ? func1() : func2()) : func3();
}
void foo_discard2(int c, int d) {
    c ? func1() : (d ? func2() : func3());
}

// translate
//
// pub extern fn func1() c_int;
// pub extern fn func2() c_int;
// pub extern fn func3() c_int;
// pub export fn foo_discard(arg_c: c_int, arg_d: c_int) void {
//     var c = arg_c;
//     _ = &c;
//     var d = arg_d;
//     _ = &d;
//     if (c != 0) {
//         if (d != 0) {
//             _ = func1();
//         } else _ = func2();
//     } else _ = func3();
// }
// pub export fn foo_discard2(arg_c: c_int, arg_d: c_int) void {
//     var c = arg_c;
//     _ = &c;
//     var d = arg_d;
//     _ = &d;
//     if (c != 0) {
//         _ = func1();
//     } else if (d != 0) {
//         _ = func2();
//     } else _ = func3();
// }
