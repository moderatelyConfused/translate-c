typedef struct foo_s *foo_t;
extern struct foo_s foo_v;

extern foo_t bar(void) {
  return &foo_v;
}

// translate
// 
// pub const struct_foo_s = opaque {};
// pub const foo_t = ?*struct_foo_s;
// pub extern var foo_v: struct_foo_s;
// pub export fn bar() foo_t {
//     return &foo_v;
// }
