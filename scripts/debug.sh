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

cat >&2 <<EOF
+ ${CMD[*]}

QEMU is halted, waiting for a debugger. In another terminal, paste:

    gdb-multiarch -ex 'target remote :1234' ${KERNEL}

Useful first commands once attached:

    (gdb) break _start          # or: break kernel_main
    (gdb) continue              # releases the CPU -- nothing runs until you do
    (gdb) layout asm            # source view is thin until you are out of asm
    (gdb) info registers        # x0 should hold the DTB pointer at entry

Note: the debug profile is built with -O0 precisely so that stepping matches
the source. Debugging a -O2 build will appear to jump around at random; that
is the optimiser, not a bug.
EOF

exec "${CMD[@]}"
