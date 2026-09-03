#!/usr/bin/env bash
# =============================================================================
#  One-script onboarding for Windows / WSL2.
# =============================================================================
#
#      bash bootstrap-wsl.sh
#
#  Run this INSIDE WSL (Ubuntu 24.04), as your normal user -- not as root, and
#  not with sudo in front. It calls sudo itself for the steps that need it, so
#  expect to type your Linux password once or twice.
#
#  It is safe to run again at any point. Every step first checks whether it is
#  already done, so a second run only does whatever the first one could not.
#
#  What it does, in order:
#
#    1. Refuses to run outside WSL, or as root.
#    2. apt-get installs everything the project needs: git, gh (the GitHub
#       CLI), Docker, QEMU, the cross debugger, the aarch64 cross compiler.
#    3. Adds you to the 'docker' group and enables systemd in /etc/wsl.conf,
#       so the Docker daemon starts by itself in every future WSL session.
#    4. Starts the Docker daemon right now, so THIS run can continue.
#    5. Logs you in to GitHub in your browser (gh auth login) if needed.
#    6. Clones the repository into ~/projects if it is not already there.
#    7. Runs scripts/setup.sh -- the verifier -- which builds the kernel in
#       the reference container and boots it under QEMU.
#
#  Two things cannot be done from inside Linux and stay manual:
#
#    - Installing WSL itself. PowerShell, as Administrator:
#          wsl --install -d Ubuntu-24.04
#      then reboot and pick a Linux username and password when Ubuntu opens.
#    - Restarting WSL, which is what activates systemd. This script tells you
#      exactly when that is needed and what to type (wsl --shutdown).
#
#  HOW THIS RELATES TO scripts/setup.sh -- read this before editing either:
#
#  setup.sh is the VERIFIER. It runs on every platform, installs nothing, and
#  is written so anyone can trust it with a machine they care about. This file
#  is the INSTALLER for one platform, aimed at a machine that has nothing yet.
#  They are kept separate so that setup.sh stays honest about being read-only,
#  and this file can be blunt about what it changes -- which it says out loud
#  before every step. Do not fold one into the other.
# =============================================================================
set -euo pipefail

REPO_SLUG="ngelkind/os-final-project"
REPO_DIR_NAME="os-final-project"
DEFAULT_DEST="${HOME}/projects/${REPO_DIR_NAME}"

# --- Output helpers (same vocabulary as setup.sh) -----------------------------
if [[ -t 1 ]]; then
    B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
else
    B=""; R=""; G=""; Y=""; N=""
fi

step()  { echo; echo "${B}==> $*${N}"; }
ok()    { echo "  ${G}ok${N}    $*"; }
warn()  { echo "  ${Y}warn${N}  $*"; }
info()  { echo "        $*"; }
doing() { echo "  ${B}..${N}    $*"; }

die() {
    echo >&2
    echo "${R}${B}=============================================================${N}" >&2
    echo "${R}${B} BOOTSTRAP STOPPED${N}" >&2
    echo "${R}${B}=============================================================${N}" >&2
    echo >&2
    printf '%s\n' "$@" >&2
    echo >&2
    echo "Fix the above and run this script again -- it picks up where it left off." >&2
    echo >&2
    exit 1
}

# Pause is not failure. It is used for the one situation where the next step
# needs a WSL restart that only PowerShell can perform.
pause_for_restart() {
    echo
    echo "${Y}${B}=============================================================${N}"
    echo "${Y}${B} ONE MANUAL STEP, THEN RUN THIS SCRIPT AGAIN${N}"
    echo "${Y}${B}=============================================================${N}"
    echo
    printf '%s\n' "$@"
    echo
    echo "  1. Open PowerShell on Windows and run:"
    echo
    echo "         wsl --shutdown"
    echo
    echo "  2. Open Ubuntu again."
    echo "  3. Run this same script again:"
    echo
    echo "         bash ${SCRIPT_PATH}"
    echo
    echo "Everything done so far is kept. The second run continues from here."
    echo
    exit 0
}

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"

# =============================================================================
#  1. Where are we, and who are we
# =============================================================================
step "Checking the environment"

if [[ "${EUID}" -eq 0 ]]; then
    die "You are running this as root (or with sudo)." \
        "" \
        "Run it as your normal user instead:" \
        "    bash ${SCRIPT_PATH}" \
        "" \
        "The script calls sudo itself where needed. Run as root, it would add" \
        "root to the docker group and clone the repository into /root, which" \
        "is not where you want to work."
fi
ME="$(id -un)"
ok "running as ${ME}"

# ALLOW_NON_WSL=1 exists so this script can be exercised in a plain Ubuntu
# container. It is not a supported way to set up a real machine.
if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
    ok "WSL detected (distro: ${WSL_DISTRO_NAME:-unknown})"
    if [[ -z "${WSL_INTEROP:-}" && -z "${WSL_DISTRO_NAME:-}" ]]; then
        warn "could not confirm this is WSL *2*. From PowerShell: wsl -l -v  (VERSION must be 2)"
    fi
elif [[ "${ALLOW_NON_WSL:-0}" == "1" ]]; then
    warn "not WSL, continuing because ALLOW_NON_WSL=1 (testing mode)"
else
    die "This does not look like WSL." \
        "" \
        "This script is for Windows machines, run from inside the Ubuntu" \
        "shell that WSL2 provides. If you have not installed WSL yet, open" \
        "PowerShell AS ADMINISTRATOR and run:" \
        "" \
        "    wsl --install -d Ubuntu-24.04" \
        "" \
        "Reboot, let Ubuntu ask you for a username and password, and run" \
        "this script from inside Ubuntu." \
        "" \
        "On macOS or plain Linux, use scripts/setup.sh and docs/onboarding.md."
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
        ok "Ubuntu 24.04 -- same base as the CI container"
    else
        warn "this is ${PRETTY_NAME:-an unknown distribution}, not Ubuntu 24.04."
        info "Package names below were verified on Ubuntu 24.04 only. Continuing."
    fi
fi

command -v sudo >/dev/null 2>&1 || die "sudo is not installed, and this script needs it to install packages."

# Windows laptops are almost always x86-64, but Windows-on-ARM exists. The
# cross compiler package differs: on x86-64 Ubuntu ships an explicit cross
# package; on an aarch64 host the native compiler already targets aarch64 and
# installs the triplet-prefixed names the Makefile expects. Mirrors the same
# decision in docker/Dockerfile.
HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
    x86_64)  CROSS_PKGS=(g++-aarch64-linux-gnu) ;;
    aarch64) CROSS_PKGS=(g++ binutils) ;;
    *)       die "Unsupported CPU architecture: ${HOST_ARCH}" ;;
esac
ok "host architecture: ${HOST_ARCH}"

# =============================================================================
#  2. Docker: is there one already? (Docker Desktop's WSL integration counts)
# =============================================================================
# Decided before the package list is built: if a working Docker is already
# reachable -- typically Docker Desktop for Windows with WSL integration --
# installing docker.io on top would start a second daemon fighting the first.
step "Checking for an existing Docker"

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    HAVE_DOCKER=1
    ok "docker already works: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'server reachable')"
    info "Skipping the Docker Engine install and the systemd/group steps."
elif command -v docker >/dev/null 2>&1; then
    info "docker binary exists but the daemon is not reachable yet; will configure it below."
else
    info "no docker found; Docker Engine (docker.io) will be installed inside WSL."
fi

# =============================================================================
#  3. Packages
# =============================================================================
step "Installing packages"

# qemu-system-arm : the package that contains qemu-system-aarch64 (yes, really)
# gdb-multiarch   : a gdb that understands aarch64 on an x86-64 host
# gh              : the GitHub CLI, used below to log in and clone
# make            : the build driver; not part of a minimal WSL image
PKGS=(git curl make gh qemu-system-arm gdb-multiarch "${CROSS_PKGS[@]}")
[[ "${HAVE_DOCKER}" -eq 0 ]] && PKGS+=(docker.io)

MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -s "${p}" >/dev/null 2>&1 || MISSING+=("${p}")
done

if [[ "${#MISSING[@]}" -eq 0 ]]; then
    ok "all packages already installed: ${PKGS[*]}"
else
    doing "sudo apt-get update"
    sudo apt-get update -qq \
        || die "apt-get update failed. Is the network up inside WSL?"
    doing "sudo apt-get install -y ${MISSING[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}" \
        || die "Package installation failed. The apt output above says which one."
    ok "installed: ${MISSING[*]}"
fi

for tool in git gh make qemu-system-aarch64 gdb-multiarch aarch64-linux-gnu-g++; do
    command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' is still not on PATH after installing. This should not happen; report it."
done
ok "tools on PATH: git gh make qemu-system-aarch64 gdb-multiarch aarch64-linux-gnu-g++"

# =============================================================================
#  4. Docker Engine inside WSL: group, systemd, and start it now
# =============================================================================
NEED_WSL_RESTART=0
DOCKER_WRAP=()   # how to run docker as this user in THIS session (see below)

if [[ "${HAVE_DOCKER}" -eq 0 ]]; then
    step "Configuring Docker Engine"

    # --- 4a. docker group ----------------------------------------------------
    # Membership of 'docker' is root-equivalent on this machine. setup.sh
    # refuses to do this for you on principle; this script does it because you
    # asked for an installer, and it says so here rather than quietly.
    if id -nG "${ME}" | tr ' ' '\n' | grep -qx docker; then
        ok "${ME} is in the docker group"
    else
        doing "sudo usermod -aG docker ${ME}   (lets you run docker without sudo)"
        sudo usermod -aG docker "${ME}"
        ok "added ${ME} to the docker group"
        NEED_WSL_RESTART=1
    fi

    # --- 4b. systemd in /etc/wsl.conf ----------------------------------------
    # WSL does not boot systemd unless asked. Without it the Docker daemon has
    # nothing to start it, and every new terminal begins with 'docker: cannot
    # connect'. Editing the file is idempotent: we only ever add the one key.
    if grep -qsE '^\s*systemd\s*=\s*true' /etc/wsl.conf; then
        ok "/etc/wsl.conf already enables systemd"
    else
        doing "enabling systemd in /etc/wsl.conf"
        if grep -qs '^\[boot\]' /etc/wsl.conf; then
            sudo sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
        else
            printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
        fi
        ok "systemd=true written to /etc/wsl.conf"
        NEED_WSL_RESTART=1
    fi

    if [[ -d /run/systemd/system ]]; then
        ok "systemd is running as PID 1"
    else
        warn "systemd is not running yet -- it starts when WSL restarts."
        NEED_WSL_RESTART=1
    fi

    # --- 4c. Start the daemon NOW so this run can continue --------------------
    # Under systemd: enable + start. Without systemd (first run, before the
    # WSL restart): Ubuntu's docker.io ships a classic init script, so
    # 'service docker start' works for this session only. Either way the
    # systemd unit takes over after the restart.
    if sudo docker info >/dev/null 2>&1; then
        ok "Docker daemon is running"
    else
        if [[ -d /run/systemd/system ]]; then
            doing "sudo systemctl enable --now docker"
            sudo systemctl enable --now docker >/dev/null 2>&1 || true
        else
            doing "sudo service docker start   (this session only; systemd owns it after the restart)"
            sudo service docker start >/dev/null 2>&1 || true
        fi
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            sudo docker info >/dev/null 2>&1 && break
            sleep 1
        done
        if sudo docker info >/dev/null 2>&1; then
            ok "Docker daemon is running"
        else
            pause_for_restart \
                "Docker is installed but its daemon could not be started in this" \
                "session. That is normal on a first run: systemd is not active until" \
                "WSL restarts, and systemd is what starts Docker."
        fi
    fi

    # --- 4d. Can THIS shell use it without sudo? ------------------------------
    # Group membership is captured at login, so a user added to 'docker' a
    # moment ago is not in the group as far as this shell is concerned. 'sg'
    # runs one command with the group applied, which is all we need to finish.
    if docker info >/dev/null 2>&1; then
        ok "docker works without sudo in this shell"
    elif sg docker -c 'docker info' >/dev/null 2>&1; then
        DOCKER_WRAP=(sg docker -c)
        ok "docker group not active in this shell yet; using 'sg docker' for the rest of this run"
        NEED_WSL_RESTART=1
    else
        pause_for_restart \
            "Docker is running, but your user cannot use it yet: the group" \
            "membership added above only applies to new login sessions."
    fi
fi

# =============================================================================
#  5. GitHub login
# =============================================================================
step "Checking GitHub access"

if gh auth status --hostname github.com >/dev/null 2>&1; then
    ok "gh is logged in as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
    if [[ ! -t 0 ]]; then
        die "gh is not logged in and there is no terminal to log in from." \
            "Run this script from an interactive Ubuntu terminal."
    fi
    info "The repository is private, so you need to be logged in to clone it."
    info "gh will show a one-time code and open github.com in your Windows browser."
    info "Answer 'Y' when it asks to authenticate Git with your GitHub credentials."
    echo
    gh auth login --hostname github.com --git-protocol https --web \
        || die "GitHub login did not complete."
    ok "logged in as $(gh api user --jq .login 2>/dev/null || echo '?')"
fi

# Make plain 'git push' use the gh login. Idempotent.
gh auth setup-git >/dev/null 2>&1 || warn "gh auth setup-git failed; git push may prompt for credentials."

# Commits need an identity. Ask once; never guess.
if [[ -z "$(git config --global user.name || true)" || -z "$(git config --global user.email || true)" ]]; then
    if [[ -t 0 ]]; then
        echo
        info "git needs to know who you are for commits (stored in ~/.gitconfig)."
        read -rp "        Your name  : " GIT_NAME
        read -rp "        Your email : " GIT_EMAIL
        [[ -n "${GIT_NAME}" ]]  && git config --global user.name  "${GIT_NAME}"
        [[ -n "${GIT_EMAIL}" ]] && git config --global user.email "${GIT_EMAIL}"
        ok "git identity set"
    else
        warn "git user.name / user.email are not set; set them before committing."
    fi
else
    ok "git identity: $(git config --global user.name) <$(git config --global user.email)>"
fi

# =============================================================================
#  6. The repository
# =============================================================================
step "Locating the repository"

DEST=""
# If this script is running from inside a checkout, use that checkout.
if TOP="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)" \
   && [[ -f "${TOP}/scripts/setup.sh" ]]; then
    DEST="${TOP}"
    ok "running from inside the repository: ${DEST}"
elif [[ -f "${DEFAULT_DEST}/scripts/setup.sh" ]]; then
    DEST="${DEFAULT_DEST}"
    ok "repository already cloned: ${DEST}"
else
    doing "cloning ${REPO_SLUG} into ${DEFAULT_DEST}"
    mkdir -p "$(dirname "${DEFAULT_DEST}")"
    gh repo clone "${REPO_SLUG}" "${DEFAULT_DEST}" \
        || die "Clone failed." \
               "" \
               "If the error mentions 'not found' or 'permission', you have not" \
               "been added as a collaborator on ${REPO_SLUG} yet, or have not" \
               "accepted the invitation email from GitHub."
    DEST="${DEFAULT_DEST}"
    ok "cloned into ${DEST}"
fi

case "${DEST}" in
    /mnt/*)
        warn "the repository is at ${DEST}, on the Windows drive."
        info "Builds are several times slower there and the executable bit"
        info "does not persist. Clone into ~/projects instead. Continuing anyway." ;;
esac

# =============================================================================
#  7. Verify, using the same script every other platform uses
# =============================================================================
step "Running scripts/setup.sh (build in the reference container, boot under QEMU)"

cd "${DEST}"
if [[ "${#DOCKER_WRAP[@]}" -gt 0 ]]; then
    "${DOCKER_WRAP[@]}" "bash scripts/setup.sh" \
        || die "scripts/setup.sh reported the problem above."
else
    bash scripts/setup.sh \
        || die "scripts/setup.sh reported the problem above."
fi

# =============================================================================
#  8. Done
# =============================================================================
echo
echo "${G}${B}=============================================================${N}"
echo "${G}${B} BOOTSTRAP COMPLETE${N}"
echo "${G}${B}=============================================================${N}"
echo
echo "Repository: ${DEST}"
echo
if [[ "${NEED_WSL_RESTART}" -eq 1 ]]; then
    echo "${Y}One last step, so Docker starts by itself from now on:${N}"
    echo
    echo "    In PowerShell:   wsl --shutdown"
    echo "    Then open Ubuntu again."
    echo
fi
echo "Then, inside Ubuntu:"
echo "    cd ${DEST}"
echo "    make run        # boot the kernel; Ctrl-A then X to quit"
echo "    make debug      # boot halted, waiting for gdb-multiarch on :1234"
echo "    make help       # every target"
echo
echo "Everything else you need to know: docs/onboarding.md"
echo
