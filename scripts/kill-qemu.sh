#!/usr/bin/env bash
# Kill every QEMU instance this project may have left running.
#
#   ./scripts/kill-qemu.sh          # kill them
#   ./scripts/kill-qemu.sh --list   # just show what would be killed
#
# WHY THIS EXISTS: closing a CLion terminal tab does not signal the process
# running in it. QEMU is reparented to launchd (PPID 1) and keeps going. Worse,
# this kernel never halts -- kernel_main() returns into nothing and the CPU
# faults forever -- and -no-reboot/-no-shutdown tell QEMU not to stop on that.
# Under TCG that is one host core pinned at 100%, permanently, per abandoned
# run. Seven of them once ran for 27 hours straight and ate a full battery.
#
# The match is deliberately narrow: only aarch64 QEMU booting a kernel.elf via
# -kernel. Colima/Lima run their own QEMU for Docker; killing those would take
# the container toolchain down with them.
#
# Written for bash 3.2 -- the version macOS actually ships. No mapfile, no
# associative arrays, no ${arr[@]} on a possibly-empty array under `set -u`.
set -uo pipefail

PATTERN='qemu-system-aarch64.*-kernel.*kernel\.elf'

PIDS=""
while IFS= read -r pid; do
    [ -n "$pid" ] && PIDS="${PIDS}${pid} "
done < <(pgrep -f "${PATTERN}" 2>/dev/null)

if [ -z "${PIDS}" ]; then
    echo "No stray QEMU instances."
    exit 0
fi

COUNT=$(echo ${PIDS} | wc -w | tr -d ' ')
echo "Found ${COUNT} QEMU instance(s):"
ps -o pid,etime,%cpu,command -p ${PIDS// /,} | cut -c1-140

case "${1:-}" in
    --list|-l) exit 0 ;;
esac

echo
kill -TERM ${PIDS} 2>/dev/null

# TERM is enough for a healthy QEMU. One wedged in a fault loop can ignore it,
# so anything still breathing after the grace period gets SIGKILL.
sleep 2
STUBBORN=""
for p in ${PIDS}; do
    kill -0 "$p" 2>/dev/null && STUBBORN="${STUBBORN}${p} "
done

if [ -n "${STUBBORN}" ]; then
    echo "SIGKILL: ${STUBBORN}"
    kill -9 ${STUBBORN} 2>/dev/null
fi

echo "Killed ${COUNT} instance(s)."
