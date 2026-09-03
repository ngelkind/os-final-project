@echo off
REM Windows counterpart to the "debug QEMU halted (native)" CLion run
REM configuration. Boots the kernel halted, waiting for a debugger on
REM localhost:1234. Run this first, then the "attach to QEMU" configuration
REM (see docs/clion-windows.md -- that one is set up through CLion's GDB
REM Remote Debug dialog directly, not through a script).
REM
REM Adjust -d and the cd target if your distro name or clone path differ.
wsl.exe -d Ubuntu-24.04 -e bash -lc "cd ~/projects/os-final-project && bash scripts/debug.sh"
