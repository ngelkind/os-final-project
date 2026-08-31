#pragma once
#include <cstdint>

enum class KEYS : char {
    BACKSPACE_FIRST = 8,
    BACKSPACE_SECOND = 127,
    ENTER = 13,

};

void print_symbol(char ch);
char read_symbol ();
void print (const char* string);
void println (const char* string = "");
void print_hex (uint64_t value);
char decimal_to_hex (int value);
int read_input(char* buffer, int max_length);
