// Switch test program for DE2 board
// SW[0] displays 0, SW[1] displays 1, ..., SW[9] displays 9.
// When multiple switches are on, the highest one wins.
// When all switches are off, display is blanked.
// Green LED = CPU running. Red LED = reset/trapped.

#define SEG7_REG    (*(volatile unsigned int *)0x30000004)
#define SW_KEY_REG  (*(volatile unsigned int *)0x30000008)
#define CONSOLE_OUT (*(volatile unsigned int *)0x10000000)

void putchar(int c) {
    CONSOLE_OUT = c;
}

void print(const char *s) {
    while (*s) putchar(*s++);
}

void print_dec(unsigned int val) {
    char buf[12];
    int i = 0;
    if (val == 0) { putchar('0'); return; }
    while (val) { buf[i++] = '0' + (val % 10); val /= 10; }
    while (i--) putchar(buf[i]);
}

void main(void) {
    print("PicoRV32 DE2 Switch Test\n");

    int last_displayed = -1;

    while (1) {
        unsigned int raw = SW_KEY_REG;
        unsigned int sw = (raw >> 4) & 0x3FFFF;  // SW[17:0]

        // Find highest active switch among SW[0]-SW[9]
        int highest = -1;
        for (int i = 9; i >= 0; i--) {
            if (sw & (1 << i)) {
                highest = i;
                break;
            }
        }

        if (highest >= 0) {
            SEG7_REG = (unsigned int)highest;
            if (highest != last_displayed) {
                print("Showing: ");
                print_dec(highest);
                print(" (SW[");
                print_dec(highest);
                print("])\n");
                last_displayed = highest;
            }
        } else {
            // No switch active - blank display
            SEG7_REG = 0xFFFFFFFF;
            if (last_displayed != -1) {
                print("All switches off - display blanked\n");
                last_displayed = -1;
            }
        }
    }
}
