#!/usr/bin/env bash
# =============================================================================
#  Cross-platform hygiene checks.
# =============================================================================
#
#      bash scripts/check-hygiene.sh
#
#  This team spans macOS, Windows/WSL and Linux CI. Each of the checks below
#  catches a class of bug that is INVISIBLE on one developer's machine and
#  fatal on another's -- the worst kind, because the person who introduced it
#  cannot reproduce it and the person who hit it cannot explain it.
#
#  Runs locally and in CI, identically. Exits non-zero if any check fails.
# =============================================================================
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else B=""; R=""; G=""; Y=""; N=""; fi

FAILURES=0
check() { echo; echo "${B}==> $*${N}"; }
pass()  { echo "  ${G}pass${N}  $*"; }
fail()  { echo "  ${R}FAIL${N}  $*"; FAILURES=$((FAILURES + 1)); }
warn()  { echo "  ${Y}warn${N}  $*"; }
note()  { echo "        $*"; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: not inside a git repository." >&2
    exit 2
fi

# =============================================================================
#  1. CRLF line endings
# =============================================================================
# A shell script committed with CRLF fails inside the Linux container as
#     bash: ./scripts/setup.sh: /bin/bash^M: bad interpreter
# which names neither the real cause nor the file that caused it. .gitattributes
# prevents this; this check proves .gitattributes is actually working.
#
# We inspect the INDEX (i/...), not the working tree, because the index is what
# other people will check out. 'i/none' means git considers the blob binary.
check "Line endings (no CRLF in tracked text files)"

CRLF_FILES="$(git ls-files --eol | grep -E '^i/(crlf|mixed)' | sed 's/.*\t//' || true)"
if [[ -n "${CRLF_FILES}" ]]; then
    fail "these tracked files contain CRLF in the index:"
    while IFS= read -r f; do [[ -n "$f" ]] && note "  ${f}"; done <<< "${CRLF_FILES}"
    note ""
    note "Fix: ensure .gitattributes covers the file type, then renormalise:"
    note "    git add --renormalize ."
    note "    git commit -m 'fix: normalise line endings to LF'"
else
    pass "no tracked file has CRLF in the index"
fi

# =============================================================================
#  2. Filename case collisions
# =============================================================================
# macOS and Windows filesystems are case-insensitive by default; Linux is not.
# Two tracked files differing only in case are legal in the repository and on
# the CI runner, but CANNOT both exist in a checkout on either laptop -- one
# silently overwrites the other and git reports a permanently dirty tree.
check "Filename case collisions"

COLLISIONS="$(git ls-files | tr '[:upper:]' '[:lower:]' | sort | uniq -d || true)"
if [[ -n "${COLLISIONS}" ]]; then
    fail "these paths collide when case is ignored:"
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        note "  ${c}"
        git ls-files | grep -i -x -- "$c" | while IFS= read -r real; do note "      ${real}"; done
    done <<< "${COLLISIONS}"
    note ""
    note "Fix: rename one of them. Use 'git mv' with a temporary name in"
    note "between, because a case-only rename is a no-op on macOS/Windows:"
    note "    git mv Foo.h tmp.h && git mv tmp.h foo.h"
else
    pass "no case-insensitive path collisions"
fi

# =============================================================================
#  3. #include case matches the real filename
# =============================================================================
# #include "Uart.h" against a file actually named uart.h compiles happily on
# macOS and Windows and fails ONLY in the Linux container. The developer who
# wrote it cannot reproduce the failure; CI looks broken rather than correct.
check "#include case matches actual filenames"

INCLUDE_REPORT="$(git ls-files -- '*.c' '*.cpp' '*.h' '*.hpp' '*.S' 2>/dev/null | python3 -c '
import os, re, sys

tracked = {}
for line in os.popen("git ls-files"):
    p = line.strip()
    if p:
        tracked[p.lower()] = p

# Directories an #include "..." is resolved against, mirroring the Makefile
# (-Iinclude) plus the including file own directory.
search_dirs = ["include", "."]

pattern = re.compile(r"^\s*#\s*include\s+\"([^\"]+)\"")
problems = []

for src in sys.stdin:
    src = src.strip()
    if not src or not os.path.exists(src):
        continue
    try:
        with open(src, "r", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        continue
    for n, line in enumerate(lines, 1):
        m = pattern.match(line)
        if not m:
            continue
        inc = m.group(1)
        candidates = [os.path.normpath(os.path.join(os.path.dirname(src), inc))]
        for d in search_dirs:
            candidates.append(os.path.normpath(os.path.join(d, inc)))
        exact = any(c.replace(os.sep, "/") in tracked.values() for c in candidates)
        if exact:
            continue
        for c in candidates:
            key = c.replace(os.sep, "/").lower()
            if key in tracked:
                problems.append((src, n, inc, tracked[key]))
                break

for src, n, inc, real in problems:
    print("%s:%d: includes \"%s\" but the file is named \"%s\"" % (src, n, inc, real))
' 2>/dev/null || true)"

if [[ -n "${INCLUDE_REPORT}" ]]; then
    fail "include directives whose case does not match the real filename:"
    while IFS= read -r l; do [[ -n "$l" ]] && note "  ${l}"; done <<< "${INCLUDE_REPORT}"
    note ""
    note "These compile on macOS and Windows and fail only on Linux/CI."
else
    pass "every #include resolves with matching case"
fi

# =============================================================================
#  4. Executable bit on scripts
# =============================================================================
# Files committed from Windows can lose the executable bit. Every documented
# command invokes scripts as 'bash scripts/foo.sh' so they work regardless --
# but the bit should still be right, and it is one command to fix.
check "Executable bit on shell scripts"

NON_EXEC="$(git ls-files -s -- 'scripts/*.sh' | awk '$1 != "100755" {print $4}' || true)"
if [[ -n "${NON_EXEC}" ]]; then
    fail "these scripts are not marked executable in the index:"
    while IFS= read -r f; do [[ -n "$f" ]] && note "  ${f}"; done <<< "${NON_EXEC}"
    note ""
    note "Fix:"
    note "    git update-index --chmod=+x ${NON_EXEC//$'\n'/ }"
else
    pass "all shell scripts have the executable bit"
fi

# =============================================================================
#  5. Filename convention  (advisory)
# =============================================================================
# lowercase_with_underscores. A convention rather than a correctness issue, so
# this warns instead of failing -- but consistency here is what keeps check 3
# from ever having anything to find.
check "Filename convention (lowercase_with_underscores) -- advisory"

ODD_NAMES="$(git ls-files -- 'boot/*' 'src/*' 'include/*' 'tests/*' 2>/dev/null \
             | while IFS= read -r f; do
                 base="$(basename "$f")"
                 if [[ ! "${base}" =~ ^[a-z0-9_]+\.[A-Za-z]+$ ]]; then echo "$f"; fi
               done || true)"
if [[ -n "${ODD_NAMES}" ]]; then
    warn "these do not follow lowercase_with_underscores:"
    while IFS= read -r f; do [[ -n "$f" ]] && note "  ${f}"; done <<< "${ODD_NAMES}"
    note ""
    note "Advisory only -- nothing fails because of this."
    note "(Note: .S files are legitimately uppercase in their EXTENSION; only"
    note " the base name is checked here.)"
else
    pass "filenames follow the convention"
fi

# =============================================================================
#  6. No scratch/ directory committed
# =============================================================================
# The brief permits a throwaway pipeline-probe file outside boot/ and src/,
# on the condition that it never merges.
check "No scratch/ directory tracked"

SCRATCH="$(git ls-files -- 'scratch/*' 2>/dev/null || true)"
if [[ -n "${SCRATCH}" ]]; then
    fail "scratch/ files are tracked and must never be merged:"
    while IFS= read -r f; do [[ -n "$f" ]] && note "  ${f}"; done <<< "${SCRATCH}"
    note ""
    note "Fix:    git rm -r --cached scratch/"
else
    pass "no scratch/ files tracked"
fi

# =============================================================================
echo
if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${R}${B}${FAILURES} hygiene check(s) failed.${N}"
    echo "Each of these breaks on someone else's machine but not on yours."
    exit 1
fi
echo "${G}${B}All hygiene checks passed.${N}"
