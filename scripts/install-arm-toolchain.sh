#!/usr/bin/env bash
# =============================================================================
#  Install the kernel compiler natively: Arm GNU Toolchain, aarch64-none-elf.
# =============================================================================
#
#      bash scripts/install-arm-toolchain.sh
#
#  For Linux and WSL, where building natively is faster than going through the
#  container. It installs EXACTLY the release the container uses: the version
#  and the SHA-256 sums are read from docker/Dockerfile, so there is one place
#  to change when upgrading and the two can never drift apart.
#
#  Installs to /opt/arm-gnu-toolchain and links the aarch64-none-elf-* tools
#  into /usr/local/bin -- the same paths as inside the container, so a
#  compile_commands.json written by either is valid for both. Uses sudo for
#  those two directories only.
#
#  Safe to run again: it does nothing if that version is already installed.
#
#  macOS: not handled here. Build in the container (the default), or install
#  the same release with:  brew install --cask gcc-aarch64-embedded
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${ROOT}/docker/Dockerfile"
PREFIX="/opt/arm-gnu-toolchain"

die() { echo "error: $*" >&2; exit 1; }
arg() { sed -n "s/^ARG $1=//p" "${DOCKERFILE}"; }

[[ -f "${DOCKERFILE}" ]] || die "cannot find ${DOCKERFILE}."
VERSION="$(arg ARM_GNU_VERSION)"
[[ -n "${VERSION}" ]] || die "ARM_GNU_VERSION is not set in docker/Dockerfile."

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  HOST=x86_64;  SUM="$(arg ARM_GNU_SHA256_AMD64)" ;;
    Linux-aarch64) HOST=aarch64; SUM="$(arg ARM_GNU_SHA256_ARM64)" ;;
    Darwin-*)      die "on macOS use the container, or: brew install --cask gcc-aarch64-embedded" ;;
    *)             die "no Arm GNU Toolchain build for $(uname -s) $(uname -m)." ;;
esac
[[ "${SUM}" =~ ^[0-9a-f]{64}$ ]] || die "no valid SHA-256 for ${HOST} in docker/Dockerfile."

if [[ -x "${PREFIX}/bin/aarch64-none-elf-g++" ]] \
   && [[ "$(cat "${PREFIX}/.version" 2>/dev/null)" == "${VERSION}" ]]; then
    echo "Arm GNU Toolchain ${VERSION} is already installed in ${PREFIX}."
    exit 0
fi

for tool in curl tar xz sha256sum sudo; do
    command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' is required (sudo apt-get install -y curl xz-utils)."
done

NAME="arm-gnu-toolchain-${VERSION}-${HOST}-aarch64-none-elf"
URL="https://gitlab.arm.com/api/v4/projects/tooling%2Fgnu-toolchains-for-arm/packages/generic/gnu-toolchain/${VERSION}/${NAME}.tar.xz"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Downloading ${NAME} (about 100 MB)"
curl -fL --retry 3 -o "${TMP}/toolchain.tar.xz" "${URL}"

# The download is only trusted once its hash matches the pinned one.
echo "${SUM}  ${TMP}/toolchain.tar.xz" | sha256sum -c - \
    || die "checksum mismatch -- the download is corrupt or not what Arm published. Nothing was installed."

echo "Installing to ${PREFIX}"
sudo rm -rf "${PREFIX}"
sudo mkdir -p "${PREFIX}"
sudo tar -xJf "${TMP}/toolchain.tar.xz" -C "${PREFIX}" --strip-components=1
echo "${VERSION}" | sudo tee "${PREFIX}/.version" >/dev/null
sudo ln -sf "${PREFIX}"/bin/aarch64-none-elf-* /usr/local/bin/

aarch64-none-elf-g++ --version | head -n 1
echo "Done. The Makefile picks it up automatically (CROSS_COMPILE=aarch64-none-elf-)."
