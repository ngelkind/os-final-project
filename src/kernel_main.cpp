#include "console.h"
#include "string.h"
constexpr int MAX_INPUT_LENGTH = 128;
int s;
extern "C" void kernel_main() {
    // asm volatile("svc #0");
    //TODO: CHANGE FUNCTION TO BE ONLY AN ENTRY POINT AND NOT A FULL MENU
    //TODO: CREATE MAP-LIKE FUNCTION FOR COMMAND CALLING
    // "[BOOT]" is the boot banner the serial contract requires, see docs/ci.md section 2
    println("[BOOT] kernel aarch64 virt");
    while (true) {
        print(">> ");
        char input [MAX_INPUT_LENGTH + 1];
        if (read_input(input, MAX_INPUT_LENGTH) == -1) {
            println("command is too long. try a shorter command.");
            continue;
        }
        if (are_string_equals(input, "help")) {
            println("help is here: currently supported only commands: hello world and help :-)");
        }
        else if (are_string_equals(input, "hello world")) {
            println("hello, cyber"); //TODO: to create a better answer for hello world
        }
        else {
            print("command not found: ");
            println (input);
        }
    }
}

//TODO: TO GET A BETTER PLACE OF MAKING TODOS (TO AGREE WITH DAVIDI ABOUT PROPER GIT WRAPPER SPACE [GITLAB/HUM])
//TODO: implementing memset, memcpy, memmove, memcmp.