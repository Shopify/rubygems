#include <ruby.h>

static VALUE hola(VALUE self) {
  return rb_str_new_cstr("hola from native");
}

void Init_hola(void) {
  rb_define_global_function("hola", hola, 0);
}
