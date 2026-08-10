void __attribute__((vectorcall)) foo(float *a);
void __vectorcall bar(float *a);
typedef void(__vectorcall *fnptr1)(void);
typedef void (*__vectorcall fnptr2)(void);
void qux(void (__vectorcall *cb)(void));

// translate
// target=x86_64-windows-msvc
//
// pub extern fn foo(a: [*c]f32) callconv(.{ .x86_64_vectorcall = .{} }) void;
// pub extern fn bar(a: [*c]f32) callconv(.{ .x86_64_vectorcall = .{} }) void;
// pub const fnptr1 = ?*const fn () callconv(.{ .x86_64_vectorcall = .{} }) void;
// pub const fnptr2 = ?*const fn () callconv(.{ .x86_64_vectorcall = .{} }) void;
// pub extern fn qux(cb: ?*const fn () callconv(.{ .x86_64_vectorcall = .{} }) void) void;
