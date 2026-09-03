struct Command {
    const char* name;
    int (*handler)(void* ctx, int argc, const char* const* argv);
    const char* help;
};