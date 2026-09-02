void switch_fn(int i) {
    int res = 0;
    switch (i) {
        case 0:
            res = 1;
        case 1 ... 3:
            res = 2;
        default:
            res = 3 * i;
            break;
            break;
        case 7: {
           res = 7;
           break;
        }
        case 4:
        case 5:
            res = 69;
        {
            res = 5;
            return;
        }
        case 6:
            switch (res) {
                case 9: break;
            }
            res = 1;
            return;
    }
}

// translate
//
// pub export fn switch_fn(arg_i: c_int) void {
//     var i = arg_i;
//     _ = &i;
//     var res: c_int = 0;
//     _ = &res;
//     blk: {
//         switch (i) {
//             @as(c_int, 0) => {
//                 res = 1;
//                 res = 2;
//                 res = @as(c_int, 3) * i;
//                 break :blk;
//             },
//             @as(c_int, 1)...@as(c_int, 3) => {
//                 res = 2;
//                 res = @as(c_int, 3) * i;
//                 break :blk;
//             },
//             else => {
//                 res = @as(c_int, 3) * i;
//                 break :blk;
//             },
//             @as(c_int, 7) => {
//                 {
//                     res = 7;
//                     break :blk;
//                 }
//             },
//             @as(c_int, 4), @as(c_int, 5) => {
//                 res = 69;
//                 {
//                     res = 5;
//                     return;
//                 }
//             },
//             @as(c_int, 6) => {
//                 blk_1: {
//                     switch (res) {
//                         @as(c_int, 9) => {
//                             break :blk_1;
//                         },
//                         else => {},
//                     }
//                 }
//                 res = 1;
//                 return;
//             },
//         }
//     }
// }
