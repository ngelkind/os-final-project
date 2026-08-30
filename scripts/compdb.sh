#!/usr/bin/env bash
# Regenerate the IDE's C++ index input.
#
#   ./scripts/compdb.sh                # for CLion's Docker toolchain (default)
#   INDEXER=host ./scripts/compdb.sh   # for a local toolchain, no Docker
#
# You do not normally need to run this. The Makefile maintains
# compile_commands.json as a byproduct of every build (see its section 12), so
# adding a source file or changing a flag updates the index on the next build.
# Run this when the IDE is not the thing driving the build, when switching
# INDEXER modes, or to rebuild the extracted header cache.
#
# Either way CLion still has to be told: File -> Reload Project. See
# docs/clion.md.
#
# WHY THIS SCRIPT EXISTS
#
# The database is written INSIDE the toolchain container and read OUTSIDE it.
# Two things break across that boundary.
#
#   1. Paths. Entries hold absolute paths. Mounted at /work, every entry would
#      say /work/src/kernel_main.cpp -- a directory that does not exist on the
#      host. CLion then matches nothing, and reports every kernel source as
#      "this file does not belong to any project target" with no completion at
#      all. This script always fixes that, in both modes, by binding the repo
#      into the container at the SAME absolute path it has on the host, so the
#      paths recorded are already host-valid. It also makes
#      -ffile-prefix-map=$(CURDIR)=. strip the same prefix a host build would.
#      (The Makefile refuses to write the database at all under a /work-style
#      mount rather than silently replacing a good one with a useless one.)
#
#   2. The compiler. Entries name /usr/bin/aarch64-linux-gnu-g++. The IDE does
#      not merely read the flags, it EXECUTES the compiler to learn its builtin
#      macros and its system header search path. WHERE it looks for that binary
#      depends on which toolchain the IDE is set to, and that is what INDEXER
#      selects:
#
#      INDEXER=container (default)
#          Leave the database exactly as the build wrote it. Correct when the IDE
#          uses a Docker toolchain, because it then runs the real build compiler
#          in the container and reads its real headers -- the indexer and the
#          build are literally the same compiler. Nothing is rewritten and
#          nothing is copied.
#
#      INDEXER=host
#          For an IDE with no Docker toolchain. Extracts the container
#          toolchain's header tree to a local cache and rewrites each entry to
#          use a host cross compiler plus -isystem flags pointing at that copy.
#          Only the driver and the header search path change; every flag the
#          build actually used is preserved verbatim. The untouched build
#          output is kept beside it as compile_commands.raw.json, because
#          the database is no longer a byte-exact transcript of the build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

source "${SCRIPT_DIR}/toolchain.env"

# Where the extracted header tree lands.
#
# Deliberately OUTSIDE the repo. 26MB of glibc and libstdc++ inside the content
# root would become *project* files to CLion -- indexed as ours, listed in the
# project view, and dragged into every Find in Files. Referenced through
# -isystem from a cache directory they stay what they are: someone else's
# headers. It also means there is nothing new to gitignore and nothing to
# commit by accident. Reproducible from the image in one command.
HEADER_DIR="${TOOLCHAIN_HEADERS:-${XDG_CACHE_HOME:-${HOME}/.cache}/os-final-project/toolchain-headers}"
STAMP="${HEADER_DIR}/.image-id"

# Which compiler the IDE will try to execute. See the header comment.
INDEXER="${INDEXER:-container}"
case "${INDEXER}" in
    container|host) ;;
    *) printf "error: INDEXER must be 'container' or 'host', got '%s'\n" "${INDEXER}" >&2; exit 1 ;;
esac

REFRESH_HEADERS=0
[[ "${1:-}" == "--refresh-headers" ]] && REFRESH_HEADERS=1

die() { printf 'error: %s\n' "$@" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 \
    || die "'docker' not found on PATH." \
           "See README.md -> 'Setting up your machine'."
command -v python3 >/dev/null 2>&1 \
    || die "'python3' not found on PATH; it is used to rewrite the JSON."

# The image is published multi-arch. Ask for the variant matching this machine
# rather than hardcoding one, so this script is not macOS-only.
case "$(uname -m)" in
    arm64|aarch64) PLATFORM="${PLATFORM:-linux/arm64}" ;;
    x86_64|amd64)  PLATFORM="${PLATFORM:-linux/amd64}" ;;
    *)             PLATFORM="${PLATFORM:-}" ;;
esac
DOCKER_PLATFORM=()
[[ -n "${PLATFORM}" ]] && DOCKER_PLATFORM=( --platform "${PLATFORM}" )

# --- 1. Generate, with the repo mounted where the host expects it ------------
#
# -v "$REPO_ROOT":"$REPO_ROOT" -w "$REPO_ROOT" is the whole of fix 1. It also
# makes -ffile-prefix-map=$(CURDIR)=. strip the same prefix it would strip in a
# host build, so the debug info stays consistent between the two.
# A broken build must NOT stop this. The index is most valuable exactly when
# the code does not compile yet. The Makefile derives each entry from the
# source file rather than from a compiler it watched run, so a file that fails
# to compile is still indexed. --keep-going keeps the rest of the build going
# so the objects, and everything downstream, are as complete as they can be.
info "generating compile_commands.json in ${IMAGE}"
BUILD_RC=0
docker run --rm "${DOCKER_PLATFORM[@]}" \
    -v "${REPO_ROOT}":"${REPO_ROOT}" -w "${REPO_ROOT}" \
    "${IMAGE}" make -k compdb || BUILD_RC=$?

[[ -f compile_commands.json ]] || die "the container did not produce compile_commands.json."

if [[ "${BUILD_RC}" -ne 0 ]]; then
    info "note: the build failed (exit ${BUILD_RC}); indexing the sources anyway"
fi

ENTRIES="$(python3 -c 'import json;print(len(json.load(open("compile_commands.json"))))')"

if [[ "${INDEXER}" == "container" ]]; then
    info "${ENTRIES} entries, left exactly as the build wrote them (INDEXER=container)"
    info "the IDE must be set to the Docker toolchain, which is where"
    info "$(python3 -c 'import json;print(json.load(open("compile_commands.json"))[0]["arguments"][0])') lives."
    info "done. In CLion: File -> Reload Project."
    exit 0
fi

# Everything below rewrites the database for an IDE that has no Docker
# toolchain. Keep the transcript the build produced before touching it.
cp compile_commands.json compile_commands.raw.json

# --- 2. Ask the build compiler where its headers live ------------------------
#
# Read the compiler out of the database rather than reconstructing it from
# ARCH/CROSS_COMPILE. Whatever actually compiled the kernel is the right thing
# to interrogate, and it cannot drift out of sync with the Makefile this way.
BUILD_CXX="$(python3 - <<'PY'
import json
db = json.load(open("compile_commands.json"))
cxx = next((e["arguments"][0] for e in db if e["file"].endswith((".cpp", ".cc", ".cxx"))), None)
print(cxx or "")
PY
)"
[[ -n "${BUILD_CXX}" ]] || die "no C++ entry in compile_commands.json -- nothing to index."
info "build compiler: ${BUILD_CXX}"

# -v on a preprocess-only run prints the include search list. This is the
# compiler's own answer, which is why no header path is hardcoded below.
SEARCH_DIRS="$(docker run --rm "${DOCKER_PLATFORM[@]}" "${IMAGE}" \
    bash -c "echo | '${BUILD_CXX}' -std=c++20 -ffreestanding -E -x c++ - -v 2>&1 \
             | sed -n '/#include <\.\.\.> search starts here/,/End of search list/p' \
             | sed -e '1d' -e '\$d' -e 's/^ //'")"
[[ -n "${SEARCH_DIRS}" ]] || die "could not read the include search path from ${BUILD_CXX}."

# Exported because the rewrite in section 5 reads it out of the environment.
export SEARCH_DIRS

# --- 3. Extract that header tree to the host --------------------------------
IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${IMAGE}")"

if [[ "${REFRESH_HEADERS}" -eq 1 ]] || [[ ! -f "${STAMP}" ]] \
   || [[ "$(cat "${STAMP}")" != "${IMAGE_ID}" ]]; then
    info "extracting toolchain headers to ${HEADER_DIR}"

    # tar refuses to store a directory twice, and the search list nests
    # (/usr/include/c++/13 sits inside /usr/include). Extract only the
    # outermost directories; the -isystem list below still uses all of them,
    # in the compiler's own order.
    TAR_DIRS="$(python3 - <<PY
import os
dirs = sorted({d for d in """${SEARCH_DIRS}""".split() if d})
roots = [d for d in dirs if not any(d != o and d.startswith(o.rstrip("/") + "/") for o in dirs)]
print(" ".join(r.lstrip("/") for r in roots))
PY
)"
    # This path is partly environment-derived and is about to be rm -rf'd, so
    # refuse anything that is not the leaf directory we own.
    [[ "${HEADER_DIR}" == */toolchain-headers ]] \
        || die "refusing to delete '${HEADER_DIR}': TOOLCHAIN_HEADERS must end in /toolchain-headers."
    rm -rf "${HEADER_DIR}"
    mkdir -p "${HEADER_DIR}"
    # 2>/dev/null on the container side: tar warns about unreadable paths that
    # are not in our list. A real failure still shows up as a missing header.
    docker run --rm "${DOCKER_PLATFORM[@]}" "${IMAGE}" \
        tar -cf - -C / ${TAR_DIRS} 2>/dev/null | tar -xf - -C "${HEADER_DIR}"
    printf '%s' "${IMAGE_ID}" > "${STAMP}"
else
    info "toolchain headers already match ${IMAGE##*/} (--refresh-headers to force)"
fi

# --- 4. Pick the compiler the IDE will actually be able to run --------------
#
# It only has to be a real AArch64 driver: the IDE runs it for its target
# defaults, and takes every system header from the extracted tree above. On
# macOS this is Homebrew's aarch64-elf-g++.
INDEX_CXX="${INDEX_CXX:-}"
if [[ -z "${INDEX_CXX}" ]]; then
    for c in aarch64-elf-g++ aarch64-none-elf-g++ aarch64-linux-gnu-g++; do
        if command -v "$c" >/dev/null 2>&1; then INDEX_CXX="$(command -v "$c")"; break; fi
    done
fi

if [[ -z "${INDEX_CXX}" ]]; then
    cat >&2 <<MSG

warning: no host AArch64 compiler found, so compile_commands.json still names
         ${BUILD_CXX}, which does not exist outside the
         container. The IDE will list your sources but will not resolve system
         headers such as <cstdint>.

         macOS:  brew install aarch64-elf-gcc
         Linux:  sudo apt-get install -y g++-aarch64-linux-gnu

         Then re-run this script, or set INDEX_CXX to a driver of your choice.

MSG
    exit 0
fi
info "index compiler: ${INDEX_CXX}"

# --- 5. Rewrite --------------------------------------------------------------
python3 - "${INDEX_CXX}" "${HEADER_DIR}" <<'PY'
import json, os, sys

index_cxx, header_dir = sys.argv[1], sys.argv[2]
search_dirs = [d for d in os.environ["SEARCH_DIRS"].split() if d]

# Keep the compiler's own ordering. A directory that was in the container's
# search path but absent from the tarball (an empty /usr/local/include, say)
# is dropped rather than emitted as a dangling -isystem.
isystem = []
for d in search_dirs:
    local = os.path.join(header_dir, d.lstrip("/"))
    if os.path.isdir(local):
        isystem += ["-isystem", local]

db = json.load(open("compile_commands.json"))
for entry in db:
    args = entry.get("arguments")
    if not args:
        continue
    # Swap the driver, then splice the header search path in ahead of the
    # source file. Nothing else is touched: the flags below are the ones the
    # build really used, and the indexer should see exactly those.
    entry["arguments"] = [index_cxx] + isystem + args[1:]

json.dump(db, open("compile_commands.json", "w"), indent=2)
print(f"rewrote {len(db)} entries with {len(isystem)//2} system include paths")
PY

info "done. In CLion: File -> Reload Project."
