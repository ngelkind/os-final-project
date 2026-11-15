//
// Created by Nachum Getzel Elkind on 30/08/2026.
//
#include "console.h"
#include "exceptions.h"

static unsigned append_text(char* buffer, unsigned pos, const char* text)
{
    while (*text != '\0')
    {
        buffer[pos++] = *text++;
    }
    return pos;
}

static unsigned append_number(char* buffer, unsigned pos, uint64_t value)
{
    char digits[21];
    unsigned count = 0;

    if (value == 0)
    {
        digits[count++] = '0';
    }
    while (value > 0)
    {
        digits[count++] = static_cast<char>('0' + (value % 10));
        value /= 10;
    }
    while (count > 0)
    {
        buffer[pos++] = digits[--count];
    }
    return pos;
}

extern "C" void handle_exception_cpp(uint64_t entry)
{
    char line[96];
    unsigned pos = 0;

    pos = append_text(line, pos, "exception: entry ");
    pos = append_number(line, pos, entry);
    pos = append_text(line, pos, " (");
    pos = append_text(line, pos, entry < 16 ? vector_names[entry] : "unknown");
    pos = append_text(line, pos, ")");
    line[pos] = '\0';

    println(line);
    if (entry == 4)
    {
        return;
    }

    for (;;)
    {
        asm volatile("wfi");
    }
}
