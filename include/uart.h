#pragma once
#include <cstdint>
void print_symbol(char ch);
extern "C" void kernel_main();
void print_string (const char* string);
void print_hex (uint64_t value);
char decimal_to_hex (const int value);
char read_symbol ();
int read_input(char* buffer, int max_length);
bool are_string_equals(const char* f, const char* s);
