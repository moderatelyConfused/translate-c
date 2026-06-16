int f(int x);
void g(int y) {
  (y) ? ((y * 2 - 1) ? f(y) : f(y + 1)) : f(y - 1);
}

// translate
//
// pub extern fn f(x: c_int) c_int;
// pub export fn g(arg_y: c_int) void {
//     var y = arg_y;
//     _ = &y;
//     if (y != 0) {
//         if (((y * @as(c_int, 2)) - @as(c_int, 1)) != 0) {
//             _ = f(y);
//         } else _ = f(y + @as(c_int, 1));
//     } else _ = f(y - @as(c_int, 1));
// }
