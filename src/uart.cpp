#include "uart.h"
const auto UART_BASE = reinterpret_cast<volatile uint8_t*>(0x09000000);
const auto UART_FLAGS = reinterpret_cast<volatile uint32_t*>(0x9000018);
void print_symbol(const char ch) {

    while (*UART_FLAGS >> 5 & 1) {
    } // we wait until the register is free
    *UART_BASE = ch;
}
int read_input(char* buffer, const int max_length) {
    int i = 0;
    while (true) {
        const char c = read_symbol();
        if (c == 8 || c == 127) { //backspace
            if (i > 0) {
                print_string("\b \b");
                --i;
            }
            continue;
        }
        if (c == '\r') { //enter
            print_string("\n");
            break;
        }
        if (i == max_length - 1) {
            while (read_symbol() != '\r') {
            } // let user finish the command and only then throw an error
            print_string("\n");
            buffer[i] = 0;
            return -1;
        }
        print_symbol(c);
        buffer[i++] = c;
    }
    buffer[i] = 0;
    return i;
}
bool are_string_equals(const char* f, const char* s) {
    for (int i = 0; f[i] || s[i]; ++i) {
        if (f[i] != s[i]) {
            return false;
        }
    }
    return true;
}
char read_symbol() {
    while (*UART_FLAGS >> 4 & 1) {
    } // no char to read
    return static_cast<char>(*UART_BASE);
}
void print_string(const char* string) {
    for (int i = 0; string[i]; ++i) {
        if (string[i] != '\n') {
            print_symbol(string[i]);
        } else {
            print_symbol('\r'); // r for move the cursor to the beg of the line
            print_symbol('\n');
        }
    }
}
void print_hex(uint64_t value) {
    char values[16] = {0};

    int i = 0;
    do {
        values[i++] = decimal_to_hex(static_cast<int>(value) % 16);
        value /= 16;
    } while (value != 0);

    print_string("0x");
    for (; i > 0; --i) {
        print_symbol(values[i - 1]);
    }
}
char decimal_to_hex(const int value) {
    return value < 10 ? '0' + value : 'A' + (value - 10);
}