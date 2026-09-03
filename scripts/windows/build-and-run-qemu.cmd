@echo off
REM Windows counterpart to the "build + run (QEMU)" CLion run configuration.
REM
REM On macOS that configuration builds inside the pinned Docker container,
REM because the Mac has no worthwhile native AArch64 toolchain (docs/clion.md
REM section 2). On WSL there is no such gap: bootstrap-wsl.sh already installs
REM a native aarch64-linux-gnu-g++, so this builds natively for speed and
REM boots the result under QEMU. See docs/clion-windows.md.
REM
REM If your WSL distro is not named exactly "Ubuntu-24.04" (check with
REM `wsl -l -v` in PowerShell), change the -d argument below to match.
REM If you cloned somewhere other than ~/projects/os-final-project, change
REM the cd target below to match.
wsl.exe -d Ubuntu-24.04 -e bash -lc "cd ~/projects/os-final-project && make PROFILE=debug && bash scripts/run.sh"
