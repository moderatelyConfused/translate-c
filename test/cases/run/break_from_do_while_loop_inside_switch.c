#include <stdlib.h>

// Make sure both `while(.true_literal)` and `while(cond)` doesn't escape
// the outer scope.
int const_cond(int i) {
    switch (i) {
        case 0:
            do {
                i++;
                if (i > 3) break;
            } while (1);
            i += 100;
            break;
    }
    return i;
}

int general_cond(int i) {
    switch (i) {
        case 0:
            do {
                i++;
                if (i > 3) break;
            } while (i < 100);
            i += 100;
            break;
    }
    return i;
}

int main(void) {
    if (const_cond(0) != 104) abort();
    if (const_cond(7) != 7) abort();
    if (general_cond(0) != 104) abort();
    if (general_cond(7) != 7) abort();
    return 0;
}

// run
