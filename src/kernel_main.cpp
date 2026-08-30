#include "uart.h"
constexpr int MAX_INPUT_LENGTH = 128;
int s;
extern "C" void kernel_main() {
    asm volatile("svc #0");
    //TODO: CHANGE FUNCTION TO BE ONLY AN ENTRY POINT AND NOT A FULL MENU
    //TODO: CREATE MAP-LIKE FUNCTION FOR COMMAND CALLING
    while (true) {
        print_string(">>");
        char input [MAX_INPUT_LENGTH + 1];
        if (read_input(input, MAX_INPUT_LENGTH) == -1) {
            print_string("command is too long. try a shorter command.");
            break;
        }
        if (are_string_equals(input, "help")) {
            print_string("currently supported only commands: hello world and help :-)\n");
        }
        else if (are_string_equals(input, "hello world")) {
            print_string("hello, cyber\n"); //TODO: to create a better answer for hello world
        }
        else {
            print_string("unsupported command. please run help for list of available commands\n");
        }
    }
}

//TODO: TO GET A BETTER PLACE OF MAKING TODOS (TO AGREE WITH DAVIDI ABOUT PROPER GIT WRAPPER SPACE [GITLAB/HUM])
//TODO: implementing memset, memcpy, memmove, memcmp.