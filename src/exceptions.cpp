//
// Created by Nachum Getzel Elkind on 30/08/2026.
//
#include "uart.cpp"
#include "exceptions.h"
extern "C" void handle_sync_exception_cpp() {
    print_string("exception caught\n");
}