#!/usr/bin/env bash
# Interactive run: boot the kernel with serial on this terminal.
#
#   ./scripts/run.sh                      # boots build/debug/kernel.elf
#   KERNEL=build/release/kernel.elf ./scripts/run.sh
#
# Quit with Ctrl-A then X.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# All flags come from here. This script contributes no flags of its own; it
# only chooses which of the defined groups apply to an interactive run.
source "${SCRIPT_DIR}/qemu-flags.sh"

if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    echo "error: ${QEMU_BIN} not found on PATH." >&2
    echo "       See README.md -> 'Setting up your machine'." >&2
    exit 127
fi

if [[ ! -f "${KERNEL}" ]]; then
    echo "error: kernel image '${KERNEL}' does not exist." >&2
    echo "       Build it first:  make" >&2
    echo "       Or point at another image:  KERNEL=path/to/kernel.elf $0" >&2
    exit 1
fi

CMD=(
    "${QEMU_BIN}"
    "${QEMU_MACHINE[@]}"
    "${QEMU_SAFETY[@]}"
    "${QEMU_SEMIHOSTING[@]}"
    "${QEMU_KERNEL[@]}"
    "${QEMU_IO_INTERACTIVE[@]}"
)
[[ ${#QEMU_EXTRA[@]} -gt 0 ]] && CMD+=( "${QEMU_EXTRA[@]}" )

# Echo the exact invocation. When a run misbehaves, the first question is
# always "what were the flags?" -- answering it should never require reading
# three scripts.
echo "+ ${CMD[*]}" >&2
echo "  (Ctrl-A X to quit, Ctrl-A C for the QEMU monitor)" >&2
echo >&2

exec "${CMD[@]}"
