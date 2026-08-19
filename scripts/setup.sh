#!/usr/bin/env bash
# =============================================================================
#  One-command onboarding.
# =============================================================================
#
#      git clone <repo> && cd <repo> && bash scripts/setup.sh
#
#  Deliberately clone-then-run rather than `curl | bash`, so that anyone can
#  read this file before trusting it with their machine.
#
#  DESIGN RULES, in order of importance:
#
#    1. It never installs anything. If a system dependency is missing it prints
#       the exact link and stops. Half-installing Docker behind someone's back
#       is worse than stopping: it leaves a machine in a state nobody chose and
#       nobody can reason about.
#    2. It never starts a daemon or edits a system config for you, for the same
#       reason.
#    3. Every failure mode is distinguished and named. "Docker isn't working"
#       is not an error message. "The docker binary exists, the daemon is
#       running, but your user is not in the docker group" is.
#    4. It is idempotent. Running it ten times in a row does the same thing as
#       running it once.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

SKIP_PULL=0
for arg in "$@"; do
    case "${arg}" in
        --skip-pull) SKIP_PULL=1 ;;
        -h|--help)
            echo "usage: bash scripts/setup.sh [--skip-pull]"
            echo "  --skip-pull   use the local copy of the image, do not contact the registry"
            exit 0 ;;
        *) echo "error: unknown argument '${arg}'" >&2; exit 2 ;;
    esac
done

# --- Output helpers ----------------------------------------------------------
if [[ -t 1 ]]; then
    B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
    B=""; R=""; G=""; Y=""; N=""
fi

step()  { echo; echo "${B}==> $*${N}"; }
ok()    { echo "  ${G}ok${N}    $*"; }
warn()  { echo "  ${Y}warn${N}  $*"; }
info()  { echo "        $*"; }

die() {
    echo >&2
    echo "${R}${B}=============================================================${N}" >&2
    echo "${R}${B} SETUP STOPPED${N}" >&2
    echo "${R}${B}=============================================================${N}" >&2
    echo >&2
    printf '%s\n' "$@" >&2
    echo >&2
    echo "Nothing was installed or changed. Fix the above and re-run:" >&2
    echo "    bash scripts/setup.sh" >&2
    echo >&2
    exit 1
}

# =============================================================================
#  1. Platform
# =============================================================================
step "Detecting platform"

UNAME_S="$(uname -s)"
HOST_ARCH="$(uname -m)"
PLATFORM="unknown"
IS_WSL=0

case "${UNAME_S}" in
    Linux)
        if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
            PLATFORM="wsl"; IS_WSL=1
        else
            PLATFORM="linux"
        fi
        ;;
    Darwin) PLATFORM="macos" ;;
    MINGW*|MSYS*|CYGWIN*)
        die "You are running this from Git Bash / MSYS on Windows." \
            "" \
            "This project does not build under Git Bash. Windows development" \
            "happens inside WSL2, which gives you a real Linux environment." \
            "" \
            "Run this first, from PowerShell:" \
            "    powershell -ExecutionPolicy Bypass -File scripts\\setup.ps1" \
            "" \
            "Then re-run this script from inside WSL. See docs/onboarding.md."
        ;;
esac

if [[ "${PLATFORM}" == "unknown" ]]; then
    die "Unrecognised platform: ${UNAME_S}" \
        "Supported: Linux, macOS, and Windows via WSL2. See docs/onboarding.md."
fi

ok "platform: ${PLATFORM} (${HOST_ARCH})"

if [[ "${IS_WSL}" -eq 1 ]]; then
    # WSL1 cannot run Docker and behaves differently in ways that will waste a
    # day. Worth checking explicitly rather than failing obscurely later.
    if [[ -n "${WSL_INTEROP:-}" || -n "${WSL_DISTRO_NAME:-}" ]]; then
        ok "WSL2 detected (distro: ${WSL_DISTRO_NAME:-unknown})"
    else
        warn "WSL detected but the version could not be confirmed."
        info "Check from PowerShell with:  wsl -l -v   (VERSION must be 2)"
    fi
fi

# =============================================================================
#  2. Where the repository lives
# =============================================================================
# On WSL, a repo under /mnt/c is on the Windows drive, reached through the 9p
# filesystem bridge. Builds are several times slower, file watching is
# unreliable, and the executable bit does not stick. This is a requirement, not
# a style preference -- but it is a warning rather than a hard stop so that a
# throwaway validation run is still possible.
step "Checking repository location"

case "${REPO_ROOT}" in
    /mnt/*)
        if [[ "${IS_WSL}" -eq 1 ]]; then
            FS_TYPE="$(df -T . 2>/dev/null | awk 'NR==2 {print $2}')"
            warn "this repository is at ${REPO_ROOT}"
            info "That is the Windows drive (filesystem: ${FS_TYPE:-9p/drvfs}),"
            info "reached across the WSL filesystem boundary."
            info ""
            info "Consequences: builds run several times slower, file watching"
            info "is unreliable, and the git executable bit does not persist."
            info ""
            info "Recommended fix -- clone inside the Linux filesystem instead:"
            info "    mkdir -p ~/projects && cd ~/projects"
            info "    git clone <repo-url> && cd os-final-project"
            info "    bash scripts/setup.sh"
            info ""
            if [[ "${STRICT_LOCATION:-0}" == "1" ]]; then
                die "STRICT_LOCATION=1 and the repo is under /mnt/. Refusing to continue."
            fi
            info "Continuing anyway. Set STRICT_LOCATION=1 to make this fatal."
        fi
        ;;
    *)
        FS_TYPE="$(df -T . 2>/dev/null | awk 'NR==2 {print $2}' || true)"
        ok "location: ${REPO_ROOT}${FS_TYPE:+ (filesystem: ${FS_TYPE})}"
        ;;
esac

# =============================================================================
#  3. Git
# =============================================================================
step "Checking git"
command -v git >/dev/null 2>&1 || die \
    "git is not installed." \
    "" \
    "  macOS  : xcode-select --install    (or: brew install git)" \
    "  Ubuntu : sudo apt-get install -y git" \
    "  WSL    : sudo apt-get install -y git"
ok "git: $(git --version)"

# The line-ending configuration matters more than it looks on a mixed-OS team.
# .gitattributes enforces LF for tracked files, so a global core.autocrlf=true
# is harmless -- but flag it, because it is the first thing to suspect if a
# script mysteriously fails with a ^M error.
AUTOCRLF="$(git config --get core.autocrlf || echo "unset")"
if [[ "${AUTOCRLF}" == "true" ]]; then
    info "core.autocrlf=true -- overridden by .gitattributes, so this is fine."
fi

# =============================================================================
#  4. Docker -- three separate failure modes, named separately
# =============================================================================
step "Checking Docker"

# --- 4a. Is the binary even there? -------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    case "${PLATFORM}" in
        macos)
            die "The 'docker' command was not found." \
                "" \
                "Install Docker Desktop for Mac:" \
                "    https://www.docker.com/products/docker-desktop/" \
                "" \
                "On Apple Silicon choose the Apple Chip build." \
                "" \
                "This script will not install it for you -- a system dependency" \
                "installed behind your back is one you cannot reason about." ;;
        wsl)
            die "The 'docker' command was not found inside WSL." \
                "" \
                "Install Docker Engine inside this WSL distro:" \
                "" \
                "    sudo apt-get update" \
                "    sudo apt-get install -y docker.io" \
                "    sudo usermod -aG docker \$USER" \
                "" \
                "Then enable systemd so the daemon starts by itself. Create or" \
                "edit /etc/wsl.conf:" \
                "" \
                "    sudo tee /etc/wsl.conf >/dev/null <<'EOF'" \
                "    [boot]" \
                "    systemd=true" \
                "    EOF" \
                "" \
                "and from a Windows PowerShell prompt:" \
                "" \
                "    wsl --shutdown" \
                "" \
                "Re-open WSL (that also picks up your new group membership) and" \
                "run this script again. Full walkthrough: docs/onboarding.md" \
                "" \
                "Docker Desktop for Windows with the WSL2 backend is an" \
                "alternative and also works." ;;
        linux)
            die "The 'docker' command was not found." \
                "" \
                "Install Docker Engine:" \
                "    https://docs.docker.com/engine/install/" \
                "" \
                "Debian/Ubuntu quick path:" \
                "    sudo apt-get update && sudo apt-get install -y docker.io" \
                "    sudo usermod -aG docker \$USER    # then log out and back in" ;;
    esac
fi
ok "docker binary: $(command -v docker)"

# --- 4b. Is the daemon running, and may we talk to it? -----------------------
# `docker info` is the honest test. `docker --version` succeeds even when the
# daemon is stone dead, which is why it is not used here.
DOCKER_ERR=""
if ! DOCKER_ERR="$(docker info 2>&1 >/dev/null)"; then

    # --- Failure mode 3: permissions (socket exists, we may not use it) ------
    if grep -qiE 'permission denied' <<<"${DOCKER_ERR}"; then
        IN_GROUP="no"
        id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker && IN_GROUP="yes"

        if [[ "${IN_GROUP}" == "yes" ]]; then
            die "Docker is running, but this shell was denied access to its socket." \
                "" \
                "Your user IS in the 'docker' group -- but group membership is" \
                "captured when a login session starts, so the shell you are in" \
                "now predates it." \
                "" \
                "Fix: close this terminal and open a new one. On WSL, run" \
                "'wsl --shutdown' from PowerShell first so the whole distro" \
                "restarts." \
                "" \
                "Raw error:" \
                "  ${DOCKER_ERR}"
        else
            die "Docker is running, but your user is not in the 'docker' group." \
                "" \
                "Add yourself:" \
                "    sudo usermod -aG docker \$USER" \
                "" \
                "Then start a NEW login session so the membership takes effect:" \
                "  - WSL   : run 'wsl --shutdown' in PowerShell, reopen WSL" \
                "  - Linux : log out and back in" \
                "" \
                "This script will not run 'sudo usermod' for you: adding a user" \
                "to the docker group grants root-equivalent access to the host," \
                "and that is a decision to make deliberately, not one to have" \
                "made on your behalf by a setup script." \
                "" \
                "Raw error:" \
                "  ${DOCKER_ERR}"
        fi
    fi

    # --- Failure mode 2: daemon not running ----------------------------------
    if grep -qiE 'cannot connect to the docker daemon|is the docker daemon running|docker daemon is not running' \
            <<<"${DOCKER_ERR}"; then
        case "${PLATFORM}" in
            macos)
                die "The Docker daemon is not running." \
                    "" \
                    "Start Docker Desktop (from Applications, or Spotlight)," \
                    "wait for the whale icon in the menu bar to stop animating," \
                    "then re-run this script." \
                    "" \
                    "Raw error:" \
                    "  ${DOCKER_ERR}" ;;
            wsl)
                die "The Docker daemon is not running inside WSL." \
                    "" \
                    "If you enabled systemd in /etc/wsl.conf, it should start" \
                    "automatically. Check:" \
                    "" \
                    "    systemctl is-active docker" \
                    "    sudo systemctl enable --now docker" \
                    "" \
                    "Without systemd, start it manually each session:" \
                    "" \
                    "    sudo service docker start" \
                    "" \
                    "The permanent fix is systemd -- see docs/onboarding.md." \
                    "" \
                    "This script will not start the daemon for you: a background" \
                    "service started by a setup script is one you will not know" \
                    "to restart tomorrow." \
                    "" \
                    "Raw error:" \
                    "  ${DOCKER_ERR}" ;;
            linux)
                die "The Docker daemon is not running." \
                    "" \
                    "    sudo systemctl enable --now docker" \
                    "" \
                    "Raw error:" \
                    "  ${DOCKER_ERR}" ;;
        esac
    fi

    # --- Anything else -------------------------------------------------------
    die "Docker is installed but 'docker info' failed for a reason this script" \
        "does not recognise. The raw error is below -- please read it, it is" \
        "usually specific." \
        "" \
        "  ${DOCKER_ERR}"
fi

DOCKER_SERVER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")"
ok "docker daemon: reachable (server ${DOCKER_SERVER_VERSION})"

# =============================================================================
#  5. The reference container image
# =============================================================================
step "Fetching the toolchain image"

# shellcheck source=scripts/toolchain.env
source "${SCRIPT_DIR}/toolchain.env"
info "image: ${IMAGE}"

if [[ "${SKIP_PULL}" -eq 1 ]]; then
    warn "--skip-pull given, using whatever is already local"
    docker image inspect "${IMAGE}" >/dev/null 2>&1 \
        || die "--skip-pull was given but ${IMAGE} is not present locally."
else
    if ! PULL_ERR="$(docker pull "${IMAGE}" 2>&1)"; then
        if grep -qiE 'denied|unauthorized|authentication required' <<<"${PULL_ERR}"; then
            die "Could not pull ${IMAGE}: access denied." \
                "" \
                "The image is published as a PUBLIC package, so this should not" \
                "normally happen. Two likely causes:" \
                "" \
                "  1. The image has not been built yet. It is published by the" \
                "     'toolchain-image' workflow on the first push that touches" \
                "     docker/. Check the Actions tab." \
                "" \
                "  2. The package visibility was changed to private. In that case" \
                "     you need to authenticate:" \
                "         echo \$GITHUB_PAT | docker login ghcr.io -u <username> --password-stdin" \
                "     with a token carrying the read:packages scope." \
                "     See docs/onboarding.md, 'If the package is private'." \
                "" \
                "Raw error:" \
                "  ${PULL_ERR}"
        fi
        die "Could not pull ${IMAGE}." \
            "" \
            "Raw error:" \
            "  ${PULL_ERR}"
    fi
    ok "pulled ${IMAGE}"
fi

# Report which architecture actually got pulled. On Apple Silicon this is the
# line that tells you whether you are running natively or under emulation.
IMAGE_ARCH="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE}" 2>/dev/null || echo unknown)"
ok "image platform: ${IMAGE_ARCH}"
if [[ "${PLATFORM}" == "macos" && "${HOST_ARCH}" == "arm64" && "${IMAGE_ARCH}" == "linux/amd64" ]]; then
    warn "you are on Apple Silicon but pulled the amd64 image."
    info "Everything will work, but the toolchain runs under emulation and will"
    info "be noticeably slow. Expected image platform here is linux/arm64."
fi

# =============================================================================
#  6. Directories git cannot carry
# =============================================================================
# git does not track empty directories, and these deliberately contain no
# placeholder file -- a .gitkeep under boot/ would put the scaffolding's
# authorship on a file inside the kernel author's territory. So a fresh clone
# is missing them and we recreate them here.
step "Ensuring source directories exist"
for d in boot src include linker tests/kernel tests/host; do
    if [[ -d "${d}" ]]; then
        info "exists : ${d}/"
    else
        mkdir -p "${d}"
        ok "created: ${d}/"
    fi
done

# =============================================================================
#  7. Build and smoke test
# =============================================================================
DOCKER_RUN=( docker run --rm -v "${REPO_ROOT}:/work" -w /work )

# On Linux and WSL the container runs as root by default, so every file it
# creates in the bind-mounted build/ is root-owned and your editor cannot
# delete it. Mapping the container user to yours avoids that entirely.
# Docker Desktop on macOS already handles ownership through its VM.
if [[ "${PLATFORM}" == "linux" || "${PLATFORM}" == "wsl" ]]; then
    DOCKER_RUN+=( --user "$(id -u):$(id -g)" )
fi
DOCKER_RUN+=( "${IMAGE}" )

step "Checking for kernel sources"

KERNEL_SOURCES="$(find boot src -name '*.S' -o -name '*.cpp' 2>/dev/null | head -n 1 || true)"
HAVE_LINKER_SCRIPT=0
[[ -f linker/kernel.ld ]] && HAVE_LINKER_SCRIPT=1

if [[ -z "${KERNEL_SOURCES}" || "${HAVE_LINKER_SCRIPT}" -eq 0 ]]; then
    warn "no kernel to build yet."
    [[ -z "${KERNEL_SOURCES}"       ]] && info "missing: any *.S or *.cpp under boot/ or src/"
    [[ "${HAVE_LINKER_SCRIPT}" -eq 0 ]] && info "missing: linker/kernel.ld"
    info ""
    info "This is expected before the boot subsystem has been written; it is"
    info "not a setup failure. Your environment is verified and ready."

    echo
    echo "${G}${B}=============================================================${N}"
    echo "${G}${B} YOU ARE SET UP CORRECTLY${N}"
    echo "${G}${B}=============================================================${N}"
    echo
    echo "The toolchain container is present and working. There is no kernel"
    echo "to boot yet -- write boot/ and linker/kernel.ld against the contract"
    echo "in docs/ci.md section 2, then re-run this script."
    echo
    echo "Verify the toolchain itself right now if you like:"
    echo "    docker run --rm ${IMAGE} aarch64-linux-gnu-g++ --version"
    echo "    docker run --rm ${IMAGE} qemu-system-aarch64 --version"
    echo
    exit 0
fi

ok "kernel sources found"

step "Building (debug profile, inside the container)"
"${DOCKER_RUN[@]}" make PROFILE=debug \
    || die "The build failed. The compiler output above is the primary evidence." \
           "" \
           "If it is a missing symbol such as memcpy or __cxa_pure_virtual, see" \
           "docs/ci.md section 2.5 -- those are expected in a freestanding build" \
           "and the kernel must provide them."
ok "build succeeded"

step "Smoke test (booting the kernel under QEMU)"
"${DOCKER_RUN[@]}" bash scripts/run-tests.sh --mode smoke --kernel build/debug/kernel.elf \
    || die "The kernel built but did not boot cleanly." \
           "" \
           "The serial log is at build/serial.log and the verdict above says" \
           "which check failed. This is a kernel problem, not a setup problem --" \
           "your environment is working correctly."

# =============================================================================
#  8. Done
# =============================================================================
echo
echo "${G}${B}=============================================================${N}"
echo "${G}${B} YOU ARE SET UP CORRECTLY${N}"
echo "${G}${B}=============================================================${N}"
echo
echo "The kernel built in the reference container and booted under QEMU."
echo
echo "Next:"
echo "    make run                 boot it interactively (Ctrl-A X to quit)"
echo "    make debug               boot halted, waiting for gdb on :1234"
echo "    make PROFILE=release     build optimised"
echo "    make help                every target"
echo
echo "To work inside the container the way CI does:"
echo "    docker run --rm -it -v \"\$PWD\":/work -w /work ${IMAGE} bash"
echo
