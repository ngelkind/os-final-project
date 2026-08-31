//
// Created by Nachum Getzel Elkind on 31/08/2026.
//

#include "string.h"
bool are_string_equals(const char* f, const char* s) {
    for (int i = 0; f[i] || s[i]; ++i) {
        if (f[i] != s[i]) {
            return false;
        }
    }
    return true;
}