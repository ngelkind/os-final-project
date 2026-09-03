#!/usr/bin/env bash
# =============================================================================
#  CI harness: boot the kernel, capture the serial log, decide pass/fail.
# =============================================================================
#
#   bash scripts/run-tests.sh --mode smoke   --kernel build/debug/kernel.elf
#   bash scripts/run-tests.sh --mode ktest   --kernel build/debug-ktests/kernel.elf
#
#  The verdict comes from PARSING THE SERIAL LOG, not from QEMU's exit status.
#  That is deliberate: how QEMU propagates a semihosting exit code has varied
#  between versions, and a verdict built on an unverified assumption is worse
#  than no verdict at all. Semihosting is a speed optimisation on top -- it
#  lets a finished run end immediately instead of waiting out the timeout --
#  and it is measured, not assumed, in milestone M3. See docs/ci.md section 2.7.
#
#  The grammar this parses is specified in docs/ci.md section 2.6. If you change
#  one, change the other in the same commit.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

MODE="smoke"
TIMEOUT_SECONDS=""
SERIAL_LOG="${SERIAL_LOG:-build/serial.log}"

usage() {
    cat <<EOF
usage: bash scripts/run-tests.sh [options]

  --mode smoke|ktest   what to assert (default: smoke)
                         smoke : the kernel booted and did not panic
                         ktest : the in-kernel test suite ran and all passed
  --kernel PATH        kernel ELF to boot (default: \$KERNEL, else
                       build/debug/kernel.elf)
  --timeout SECONDS    hard timeout (default: 60 smoke, 120 ktest)
  --log PATH           where to write the serial capture
                       (default: build/serial.log)
  -h, --help           this message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)    MODE="${2:?--mode needs a value}"; shift 2 ;;
        --kernel)  KERNEL="${2:?--kernel needs a value}"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="${2:?--timeout needs a value}"; shift 2 ;;
        --log)     SERIAL_LOG="${2:?--log needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

case "${MODE}" in
    smoke) : "${TIMEOUT_SECONDS:=60}" ;;
    ktest) : "${TIMEOUT_SECONDS:=120}" ;;
    *) echo "error: --mode must be 'smoke' or 'ktest', got '${MODE}'" >&2; exit 2 ;;
esac

# All QEMU flags come from here and nowhere else.
source "${SCRIPT_DIR}/qemu-flags.sh"

if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
    echo "error: ${QEMU_BIN} not found on PATH." >&2
    exit 127
fi
if [[ ! -f "${KERNEL}" ]]; then
    echo "error: kernel image '${KERNEL}' does not exist. Build it first." >&2
    exit 1
fi

mkdir -p "$(dirname "${SERIAL_LOG}")"

CMD=(
    "${QEMU_BIN}"
    "${QEMU_MACHINE[@]}"
    "${QEMU_SAFETY[@]}"
    "${QEMU_SEMIHOSTING[@]}"
    "${QEMU_KERNEL[@]}"
    "${QEMU_IO_CI[@]}"
)
[[ ${#QEMU_EXTRA[@]} -gt 0 ]] && CMD+=( "${QEMU_EXTRA[@]}" )

echo "=== run-tests.sh ==============================================="
echo "mode     : ${MODE}"
echo "kernel   : ${KERNEL}"
echo "timeout  : ${TIMEOUT_SECONDS}s"
echo "log      : ${SERIAL_LOG}"
echo "command  : ${CMD[*]}"
echo "================================================================"

# --- Run ---------------------------------------------------------------------
#
# GNU coreutils' `timeout` is not present on macOS, which is the primary dev
# machine here. Without a fallback this script reports "no [BOOT] line" -- a
# kernel failure -- when what actually happened is that the harness could not
# start QEMU at all. A test harness that blames the code under test for its own
# missing dependency is worse than no harness, so resolve a timeout
# implementation once, here, and fall back to a shell watchdog.
#
#   timeout   GNU coreutils (Linux, the CI container)
#   gtimeout  same binary under Homebrew's coreutils on macOS
#   (neither) the run_with_timeout function below
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    TIMEOUT_BIN=""
fi

# Shell fallback. Runs the command in the background with a sleeping watchdog
# alongside it; whichever finishes first, the other is cleaned up.
#
# It reports 124 on timeout to match GNU timeout, because the verdict logic
# below keys on that number. The watchdog leaves a marker file when it fires,
# and that marker -- not the child's exit status -- is what decides "timed
# out". The exit status alone is not enough: QEMU catches SIGTERM and exits 0
# ("terminating on signal 15"), which would otherwise look like a clean exit.
# Like GNU timeout, a run the watchdog had to kill is a timeout regardless of
# what the child said on its way out.
run_with_timeout() {
    local secs="$1"; shift
    local fired
    fired="$(mktemp)"; rm -f "${fired}"

    "$@" &
    local child=$!
    ( sleep "${secs}"; touch "${fired}"; kill -TERM "${child}" 2>/dev/null; \
      sleep 2;         kill -KILL "${child}" 2>/dev/null ) &
    local watchdog=$!

    local rc=0
    wait "${child}" || rc=$?

    kill "${watchdog}" 2>/dev/null || true
    wait "${watchdog}" 2>/dev/null || true

    if [[ -e "${fired}" ]]; then
        rm -f "${fired}"
        return 124
    fi
    return ${rc}
}

set +e
if [[ -n "${TIMEOUT_BIN}" ]]; then
    # --foreground: without it, timeout puts the child in its own process group
    # and QEMU cannot receive the terminal signals that let Ctrl-C work when a
    # human runs this locally.
    #
    # A hung kernel MUST fail the job rather than occupy a runner for six
    # hours, so the timeout is not optional and is not generous.
    "${TIMEOUT_BIN}" --foreground "${TIMEOUT_SECONDS}s" "${CMD[@]}" 2>&1 | tee "${SERIAL_LOG}"
else
    run_with_timeout "${TIMEOUT_SECONDS}" "${CMD[@]}" 2>&1 | tee "${SERIAL_LOG}"
fi
QEMU_STATUS="${PIPESTATUS[0]}"
set -e

# --- Normalise ---------------------------------------------------------------
# Strip carriage returns before parsing. A UART driver that emits CRLF is
# perfectly reasonable, and every regex below would silently fail to match if
# we did not do this. (Cheap, and removes an entire class of phantom failure.)
CLEAN_LOG="$(mktemp)"
trap 'rm -f "${CLEAN_LOG}"' EXIT
sed 's/\r$//' "${SERIAL_LOG}" > "${CLEAN_LOG}"

fail() {
    echo
    echo "=== VERDICT: FAIL =============================================="
    echo "reason: $*"
    echo
    echo "--- last 50 lines of ${SERIAL_LOG} ---"
    tail -n 50 "${SERIAL_LOG}" || true
    echo "--- end of serial log ---"
    echo
    echo "Reproduce locally with the identical flags:"
    echo "    bash scripts/run-tests.sh --mode ${MODE} --kernel ${KERNEL}"
    echo "================================================================"
    exit 1
}

pass() {
    echo
    echo "=== VERDICT: PASS =============================================="
    echo "$*"
    echo "================================================================"
    exit 0
}

count() { grep -cE "$1" "${CLEAN_LOG}" || true; }

# --- Decide, in the order specified by docs/ci.md section 2.6 ----------------

# 1. Timeout. GNU timeout reports 124 when it had to kill the child.
#
#    ktest mode: a hang. The suite must run to completion and ask QEMU to exit
#    via semihosting; reaching the timeout means it did not.
#
#    smoke mode: expected, not a failure. The kernel is an interactive shell
#    that waits on the UART for input forever and never asks QEMU to exit.
#    From the outside, "hung" and "idle at its prompt" are the same picture,
#    and telling them apart would need a liveness probe (send a command,
#    expect a reply) that couples this harness to the shell's command set. So
#    smoke asserts only what it can observe: the banner appeared and nothing
#    panicked. The timeout still bounds the job. See docs/ci.md section 2.6.
TIMED_OUT=0
if [[ "${QEMU_STATUS}" -eq 124 ]]; then
    if [[ "${MODE}" == "ktest" ]]; then
        fail "kernel hung -- no exit within ${TIMEOUT_SECONDS}s"
    fi
    TIMED_OUT=1
fi

# 2. Panic, in any mode.
if [[ "$(count '^\[PANIC\]')" -gt 0 ]]; then
    echo
    echo "--- panic lines ---"
    grep -E '^\[PANIC\]' "${CLEAN_LOG}" || true
    fail "kernel panicked"
fi

# 3. The kernel must have booted at all. Checked in both modes: a test build
#    that never reached its banner has a more basic problem than a failing test.
if [[ "$(count '^\[BOOT\]')" -eq 0 ]]; then
    fail "no [BOOT] line -- the kernel did not reach its banner. \
If the banner is printed but missing here, suspect the UART transmit FIFO \
was not drained before the kernel halted."
fi

if [[ "${MODE}" == "smoke" ]]; then
    if [[ "${TIMED_OUT}" -eq 1 ]]; then
        pass "kernel booted, printed its banner, and did not panic. \
It was still running at the ${TIMEOUT_SECONDS}s timeout, which is what an interactive kernel does."
    fi
    pass "kernel booted, printed its banner, and did not panic."
fi

# --- ktest mode --------------------------------------------------------------

# 4. Terminator. Its absence means output stopped partway -- a crash during
#    teardown that a summary-only check would happily score as a pass.
if [[ "$(count '^\[KTEST\] DONE$')" -eq 0 ]]; then
    fail "output truncated -- no '[KTEST] DONE' terminator. \
The suite started but never finished cleanly."
fi

SUMMARY_LINE="$(grep -E '^\[KTEST\] SUMMARY ' "${CLEAN_LOG}" | tail -n 1 || true)"
if [[ -z "${SUMMARY_LINE}" ]]; then
    fail "no '[KTEST] SUMMARY' line found. Expected: \
'[KTEST] SUMMARY <n> passed, <n> failed' (see docs/ci.md section 2.6)."
fi

SUMMARY_RE='^\[KTEST\] SUMMARY ([0-9]+) passed, ([0-9]+) failed(, ([0-9]+) skipped)?$'
if [[ ! "${SUMMARY_LINE}" =~ ${SUMMARY_RE} ]]; then
    fail "summary line does not match the agreed format (docs/ci.md 2.6).
       got:      ${SUMMARY_LINE}
       expected: [KTEST] SUMMARY <n> passed, <n> failed[, <n> skipped]"
fi
SUM_PASSED="${BASH_REMATCH[1]}"
SUM_FAILED="${BASH_REMATCH[2]}"
SUM_SKIPPED="${BASH_REMATCH[4]:-0}"

# 5. Any test reported as failed.
if [[ "${SUM_FAILED}" -ne 0 ]]; then
    echo
    echo "--- failing tests ---"
    grep -E '^\[KTEST\] [A-Za-z0-9_]+[ .]*FAIL' "${CLEAN_LOG}" || true
    fail "${SUM_FAILED} kernel test(s) failed"
fi

# 6. Cross-check: the summary must agree with the lines actually printed.
#    Cheap insurance against a kernel that prints a cheerful summary while half
#    its tests never ran.
N_PASS="$(count '^\[KTEST\] [A-Za-z0-9_]+[ .]*PASS(  +.*)?$')"
N_FAIL="$(count '^\[KTEST\] [A-Za-z0-9_]+[ .]*FAIL(  +.*)?$')"
N_SKIP="$(count '^\[KTEST\] [A-Za-z0-9_]+[ .]*SKIP(  +.*)?$')"

if [[ "${N_PASS}" -ne "${SUM_PASSED}" || "${N_FAIL}" -ne "${SUM_FAILED}" \
      || "${N_SKIP}" -ne "${SUM_SKIPPED}" ]]; then
    fail "inconsistent output -- the summary disagrees with the per-test lines.
       summary says : ${SUM_PASSED} passed, ${SUM_FAILED} failed, ${SUM_SKIPPED} skipped
       lines show   : ${N_PASS} passed, ${N_FAIL} failed, ${N_SKIP} skipped
       Either some tests did not print a result line, or the counters are wrong."
fi

if [[ "${SUM_PASSED}" -eq 0 && "${SUM_SKIPPED}" -eq 0 ]]; then
    fail "the suite reported zero tests. A test build that runs no tests is \
almost certainly a registration problem, not a green result."
fi

pass "${SUM_PASSED} passed, ${SUM_FAILED} failed, ${SUM_SKIPPED} skipped."
