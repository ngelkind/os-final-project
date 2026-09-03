@echo off
REM Windows counterpart to `make kill-qemu`. Closing a CLion terminal tab, or
REM the WSL window it runs in, does not stop QEMU underneath it -- it gets
REM reparented and keeps running, and this kernel never halts on its own (see
REM the comment at the top of scripts/kill-qemu.sh). Run this whenever a
REM previous run/debug session was closed rather than quit with Ctrl-A X.
REM
REM Pass --list to only show what would be killed, without killing it:
REM     kill-qemu.cmd --list
REM
REM Adjust -d and the cd target if your distro name or clone path differ.
wsl.exe -d Ubuntu-24.04 -e bash -lc "cd ~/projects/os-final-project && ./scripts/kill-qemu.sh %*"
