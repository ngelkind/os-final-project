//
// Created by Nachum Getzel Elkind on 30/08/2026.
//
#include "console.h"
#include "exceptions.h"
extern "C" void handle_sync_exception_cpp() {
    println("exception caught");
}