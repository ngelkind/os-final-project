
#include "console.h"
#include <cstdint>
#include <thread_db.h>
#include <wchar.h>
#include <stdio.h>
#include <stdarg.h>
const auto UART_BASE = reinterpret_cast<volatile uint8_t*>(0x09000000);
const auto UART_FLAGS = reinterpret_cast<volatile uint32_t*>(0x9000018);
//const auto UART_FLAGS = reinterpret
void print_symbol(const char ch) {
    while (*UART_FLAGS >> 5 & 1) {
    } // we wait until the register is fre
    *UART_BASE = ch;
}
int read_input(char* buffer, const int max_length) {
    int i = 0;
    while (true) {
        const char c = read_symbol();
        if (c == static_cast<char>(KEYS::BACKSPACE_FIRST) || c == static_cast<char>(KEYS::BACKSPACE_SECOND)) {
            if (i > 0) {
                print("\b \b"); // b moves cursor to one pos left, space override char with emptiness,
                --i;
            }
            continue;
        }
        if (c == static_cast<char>(KEYS::ENTER)) {
            println();
            break;
        }
        if (i == max_length - 1) {
            while (read_symbol() != static_cast<char>(KEYS::ENTER)) {
            } // let user finish the command and only then throw an error. after the limit the next characters do NOT got printed
            println();
            buffer[i] = 0;
            return -1;
        }
        print_symbol(c);
        buffer[i++] = c;
    }
    buffer[i] = 0;
    return i;
}
char read_symbol() {
    while (*UART_FLAGS >> 4 & 1) {
    } // no char to read
    return static_cast<char>(*UART_BASE);
}
void print(const char* string) {
    for (int i = 0; string[i]; ++i) {
        if (string[i] == '\n') {
            print_symbol('\r');  // r for moving the cursor to the beg of the line
        }
        print_symbol(string[i]);
    }
}
void vvprintf(const char* format, va_list args) {
    
}
void printf (const char* format, ...) {
    va_list args;

    // 1. Initialize the va_list
    va_start(args, format);

    // 2. Use the 'v' version of the function to accept the va_list
    vvprintf(format, args);

    // 3. Clean up
    va_end(args);

}
void println(const char* string) {
    print(string);
    print("\n");
}

void print_hex(uint64_t value) {
    char values[16];
    int i = 0;

    do {
        values[i++] = decimal_to_hex(static_cast<int>(value) % 16);
        value /= 16;
    } while (value != 0);

    print("0x");
    for (; i > 0; --i) {
        print_symbol(values[i - 1]);
    }
}
char decimal_to_hex(const int value) {
    return value < 10 ? '0' + value : 'A' + (value - 10);
}
// template<typename... Args>
// void printf (template<typename... Args>
// )
print_unsigned (uint64_t value, unsigned base) {
    char buffer [65];
    while (value != 0) {
        
    }

}
