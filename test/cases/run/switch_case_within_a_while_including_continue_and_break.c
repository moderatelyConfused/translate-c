#include <stdio.h>

int main(void) {
    int state = 1;
    int active = 1;
    int counter = 0;
    int y = 1;

    while (active) {
        active = 0;

        switch (state) {
            case 1:
                if (counter == 0) {
                    active = 1;
                    state = 2;
                    counter++;
                    continue;
                }
                break;

            case 2:
                y *= 2;
                break;
        }
    }

    printf("y = %d", y);
    return 0;
}

// run
//
// y = 2
