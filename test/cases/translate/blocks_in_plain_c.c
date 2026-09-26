typedef void (^dispatch_block_t)(void);
void dispatch_async_f(void *queue, dispatch_block_t block);
void run_inline_block(void (^callback)(int status, const char *message));
void dispatch_apply_f(unsigned long iterations, __attribute__((noescape)) void (^block)(unsigned long));
struct holder {
    void (^on_done)(void);
    int x;
};

// translate
// target=aarch64-macos
//
// pub const dispatch_block_t = ?*const anyopaque;
// pub extern fn dispatch_async_f(queue: ?*anyopaque, block: dispatch_block_t) void;
// pub extern fn run_inline_block(callback: ?*const anyopaque) void;
// pub extern fn dispatch_apply_f(iterations: c_ulong, block: ?*const anyopaque) void;
// pub const struct_holder = extern struct {
//     on_done: ?*const anyopaque,
//     x: c_int,
// };
