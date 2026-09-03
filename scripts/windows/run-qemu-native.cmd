@echo off
REM Windows counterpart to the "run QEMU (native)" CLion run configuration.
REM Boots whatever is already built at build/debug/kernel.elf -- run
REM build-and-run-qemu.cmd instead if you have not built yet or changed
REM sources since the last build.
REM
REM Adjust -d and the cd target if your distro name or clone path differ.
wsl.exe -d Ubuntu-24.04 -e bash -lc "cd ~/projects/os-final-project && bash scripts/run.sh"
