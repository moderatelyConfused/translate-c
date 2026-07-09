typedef struct {
  unsigned int a : 16;
  unsigned int b : 16;
} foo;

_Static_assert(sizeof(foo) == 4, "bad size for foo");

// translate
//
// 2:16: warning: struct demoted to opaque type - has bitfield
//
// pub const foo = opaque {};
//
// 6:16: warning: unable to translate _Static_assert condition
