#!/usr/bin/env bash
# Debug run: identical to run.sh, but QEMU halts before the first instruction
# and waits for gdb to attach on :1234.
#
#   Terminal 1:  ./scripts/debug.sh
#   Terminal 2:  gdb-multiarch -ex 'target remote :1234' build/debug/kernel.elf
#
# The kernel is loaded but stopped, so you can break on the very first
# instruction of _start -- the part that is otherwise impossible to observe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

source "${SCRIPT_DIR}/qemu-flags.sh"

if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    echo "error: ${QEMU_BIN} not found on PATH." >&2
    echo "       See README.md -> 'Setting up your machine'." >&2
    exit 127
fi

if [[ ! -f "${KERNEL}" ]]; then
    echo "error: kernel image '${KERNEL}' does not exist." >&2
    echo "       Build it first:  make          (debug profile has -O0, use it here)" >&2
    exit 1
fi

CMD=(
    "${QEMU_BIN}"
    "${QEMU_MACHINE[@]}"
    "${QEMU_SAFETY[@]}"
    "${QEMU_SEMIHOSTING[@]}"
    "${QEMU_KERNEL[@]}"
    "${QEMU_IO_INTERACTIVE[@]}"
    "${QEMU_DEBUG[@]}"
)
[[ ${#QEMU_EXTRA[@]} -gt 0 ]] && CMD+=( "${QEMU_EXTRA[@]}" )

# The cross debugger's name differs per platform and both are correct:
# gdb-multiarch on Ubuntu/WSL, aarch64-elf-gdb from Homebrew on macOS. Print
# the one that actually exists on THIS machine rather than a name the reader
# has to translate before pasting.
GDB=""
for g in gdb-multiarch aarch64-elf-gdb aarch64-none-elf-gdb; do
    if command -v "${g}" >/dev/null 2>&1; then GDB="${g}"; break; fi
done
if [[ -z "${GDB}" ]]; then
    GDB="gdb-multiarch   # NOT INSTALLED -- see docs/onboarding.md"
fi

cat >&2 <<EOF
+ ${CMD[*]}

QEMU is halted, waiting for a debugger. In another terminal, paste:

    ${GDB} -ex 'target remote :1234' ${KERNEL}

Useful first commands once attached:

    (gdb) break _start          # or: break kernel_main
    (gdb) continue              # releases the CPU -- nothing runs until you do
    (gdb) layout asm            # source view is thin until you are out of asm
    (gdb) info registers        # see the note on x0 below

Note on x0: when QEMU boots an ELF via -kernel it jumps straight to the ELF
entry point -- it installs no boot stub at the start of RAM and loads no device
tree, so x0 is 0 and is NOT a DTB pointer. Passing the DTB in x0 belongs to the
raw-image boot path, not ours. (Measured on QEMU 11.1.0, -machine virt.)

Note: the debug profile is built with -O0 precisely so that stepping matches
the source. Debugging a -O2 build will appear to jump around at random; that
is the optimiser, not a bug.
EOF

exec "${CMD[@]}"
