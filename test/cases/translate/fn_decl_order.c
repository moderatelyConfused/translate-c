// This declaration should not be causing the corresponding definition to be emitted.
void wcscat();

int wcscat_s();

void wcscat() {
    if (wcscat_s()) {}
}

// translate
//
// pub extern fn wcscat_s(...) c_int;
// pub export fn wcscat() void {
//     if (wcscat_s() != 0) {}
// }
