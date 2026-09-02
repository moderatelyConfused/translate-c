#include <stdlib.h>

int break_from_switch_condition(void) {
    int x = 0;

    while (x < 2) {
        switch (({
            x++;
            if (x == 1) break;
            0;
        })) {
            default:
                break;
        }
    }

    return x;
}

int main(void) {
    if (break_from_switch_condition() != 1) abort();
    return 0;
}

// run
