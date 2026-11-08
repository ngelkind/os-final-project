# =============================================================================
#  The reference build environment.
# =============================================================================
#
#  This image is the definition of "the toolchain" for this project. CI runs
#  every job inside it, and both developers build inside it locally. If a build
#  succeeds here and fails on someone's laptop, the laptop is wrong.
#
#  Built for linux/amd64 AND linux/arm64 (see docs/ci.md section 5): CI runners
#  are amd64, the primary development machine is an Apple Silicon Mac. An
#  amd64-only image on that Mac would run the whole toolchain under x86
#  emulation while QEMU inside it is already emulating AArch64 -- two stacked
#  layers of emulation on every compile of every working day.
#
#  The emulated GUEST is identical on both: scripts/qemu-flags.sh forces
#  -accel tcg unconditionally, so we never use KVM even where it is available.
#  Host architecture changes build speed, not kernel behaviour.
# =============================================================================

# Pinned to the distribution release. Note what this does and does not
# guarantee: it fixes the base userland, not the exact package versions inside
# it. The layer that actually makes builds reproducible is that CI pins the
# IMAGE by its immutable commit-SHA tag, so once this image is built and
# published its contents are frozen -- rebuilding it cannot retroactively
# change what an already-open pull request builds against.
# See docs/ci.md section 4, "How pinned is pinned".
FROM ubuntu:24.04

# buildx sets this automatically per target platform. We need it because the
# cross-toolchain package name is not the same on both architectures.
ARG TARGETARCH

LABEL org.opencontainers.image.title="os-final-project CI toolchain"
LABEL org.opencontainers.image.description="AArch64 cross toolchain + QEMU for a bare-metal kernel"
LABEL org.opencontainers.image.source="https://github.com/ngelkind/os-final-project"
LABEL org.opencontainers.image.licenses="MIT"

# Non-interactive so a package that wants to ask about a timezone cannot hang
# the build forever with nobody watching.
ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
#  Architecture-independent packages
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # --- build --- \
      make \
      # Host C++ compiler, for the Layer-1 host unit tests that run natively \
      # without QEMU. Also pulls in a working native binutils.
      g++ \
      # --- emulation ---
      # Ubuntu ships qemu-system-aarch64 inside the qemu-system-arm package.
      qemu-system-arm \
      # --- debugging ---
      # gdb-multiarch understands aarch64 even when running on x86, which is
      # what lets scripts/debug.sh work from any host.
      gdb-multiarch \
      # Reads the device tree QEMU generates, so the platform facts in
      # docs/ci.md section 3 can be verified rather than trusted.
      device-tree-compiler \
      # --- hygiene / tooling ---
      clang-format \
      # Generates compile_commands.json by intercepting the real build, so
      # CLion's indexer sees the exact flags the compiler saw rather than
      # guessing them. See docs/clion.md.
      bear \
      # Not used by our build -- we use Make, and ADR 0002 explains why.
      # It is here because CLion's Docker toolchain DETECTS the compilers by
      # configuring a throwaway CMake project inside the container. With no
      # cmake, that probe fails and CLion reports "C Compiler: not found" even
      # though the cross compiler is sitting right there, which makes the
      # toolchain unusable for indexing. Cheap package, removes a dead end.
      cmake \
      python3 \
      git \
      ca-certificates \
      # Fetch and unpack the Arm GNU Toolchain release below.
      curl \
      xz-utils \
      file \
      xxd \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
#  The AArch64 cross toolchain
# -----------------------------------------------------------------------------
# This differs by host architecture, and the difference is easy to get wrong.
#
# On amd64: aarch64 is a foreign architecture, so we install the explicit cross
#   packages, which provide aarch64-linux-gnu-g++ and friends.
#
# On arm64: aarch64 IS the native architecture. Ubuntu does not ship a
#   "cross" compiler targeting the host's own triple -- the native gcc already
#   targets aarch64-linux-gnu, and Debian's packaging installs the
#   triplet-prefixed names (aarch64-linux-gnu-g++, -objcopy, ...) alongside the
#   unprefixed ones. So the native g++/binutils give us exactly the tool names
#   the Makefile expects.
#
# Getting this wrong produces an image that builds fine on one architecture and
# fails with "aarch64-linux-gnu-g++: not found" on the other -- which is why
# the verification step below is not optional.
RUN set -eux; \
    apt-get update; \
    if [ "${TARGETARCH}" = "arm64" ]; then \
        apt-get install -y --no-install-recommends binutils; \
    else \
        apt-get install -y --no-install-recommends \
            gcc-aarch64-linux-gnu \
            g++-aarch64-linux-gnu \
            binutils-aarch64-linux-gnu; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
#  The bare-metal kernel compiler: Arm GNU Toolchain, aarch64-none-elf
# -----------------------------------------------------------------------------
# The kernel is built with aarch64-none-elf, not with Ubuntu's
# aarch64-linux-gnu. Same instructions, different defaults: the Linux compiler
# assumes Linux (__linux__, default PIE and stack protector, glibc and Linux
# headers on the include path). none-elf assumes no OS, so every mitigation
# and every runtime helper in the kernel is one we chose. docs/ci.md section 4
# has the full reasoning.
#
# Ubuntu does not package it, so this is Arm's official binary release. The
# version and both SHA-256 sums are pinned here: a changed or tampered tarball
# fails the image build instead of reaching CI. The sums are the ones Arm
# publishes next to each tarball (<name>.tar.xz.sha256asc).
#
# Upgrading: change ARM_GNU_VERSION and both sums together. Releases are
# listed at https://gitlab.arm.com/tooling/gnu-toolchains-for-arm (Arm moved
# downloads there from developer.arm.com in 2026).
ARG ARM_GNU_VERSION=15.3.rel2
ARG ARM_GNU_SHA256_AMD64=1e4dc409cf4d33ef0a2e92c345f9e340302d355858de9bc3353758b6463895b0
ARG ARM_GNU_SHA256_ARM64=63942f3f86e69d7beefa2b946bdb23437628529e7b29f97d32229f65d0905e40
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) host=x86_64;  sum="${ARM_GNU_SHA256_AMD64}" ;; \
        arm64) host=aarch64; sum="${ARM_GNU_SHA256_ARM64}" ;; \
        *) echo "FATAL: no Arm GNU Toolchain for ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    name="arm-gnu-toolchain-${ARM_GNU_VERSION}-${host}-aarch64-none-elf"; \
    curl -fsSL --retry 3 -o /tmp/toolchain.tar.xz \
        "https://gitlab.arm.com/api/v4/projects/tooling%2Fgnu-toolchains-for-arm/packages/generic/gnu-toolchain/${ARM_GNU_VERSION}/${name}.tar.xz"; \
    echo "${sum}  /tmp/toolchain.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/arm-gnu-toolchain; \
    tar -xJf /tmp/toolchain.tar.xz -C /opt/arm-gnu-toolchain --strip-components=1; \
    rm -f /tmp/toolchain.tar.xz; \
    # Manuals and the bundled gdb are not used (we debug with gdb-multiarch);
    # dropping them keeps the image smaller.
    rm -rf /opt/arm-gnu-toolchain/share/doc /opt/arm-gnu-toolchain/share/info \
           /opt/arm-gnu-toolchain/share/man /opt/arm-gnu-toolchain/bin/aarch64-none-elf-gdb*; \
    # Symlinked into /usr/local/bin rather than added to PATH via ENV, so that
    # every way into the container finds them -- including CLion's Docker
    # toolchain, which runs the compiler by absolute path.
    ln -s /opt/arm-gnu-toolchain/bin/aarch64-none-elf-* /usr/local/bin/

# -----------------------------------------------------------------------------
#  Verify -- fail the IMAGE BUILD rather than publish something broken
# -----------------------------------------------------------------------------
# Every tool the Makefile and the scripts invoke by name is checked here. A
# missing tool discovered now costs one red image build; discovered later it
# costs a confusing red CI run on somebody's unrelated pull request.
RUN set -eux; \
    for tool in \
        aarch64-linux-gnu-g++ \
        aarch64-linux-gnu-gcc \
        aarch64-linux-gnu-objcopy \
        aarch64-linux-gnu-objdump \
        aarch64-linux-gnu-size \
        aarch64-none-elf-g++ \
        aarch64-none-elf-gcc \
        aarch64-none-elf-objcopy \
        aarch64-none-elf-objdump \
        aarch64-none-elf-size \
        qemu-system-aarch64 \
        gdb-multiarch \
        clang-format \
        make \
        g++ \
        python3 \
        dtc \
    ; do \
        command -v "$tool" >/dev/null 2>&1 || { \
            echo "FATAL: required tool '$tool' is missing from the image" >&2; \
            exit 1; }; \
    done; \
    echo "all required tools present"

# Prove the cross compiler can actually produce a freestanding AArch64 object,
# not merely that the binary exists. Uses the same core flags as the real
# build. This is a compile-only check: it deliberately touches nothing under
# boot/ or src/ and leaves no artefact behind.
RUN set -eux; \
    printf 'void probe(void) {}\n' > /tmp/probe.c; \
    aarch64-none-elf-gcc -ffreestanding -fno-builtin -mgeneral-regs-only \
        -fno-pie -c /tmp/probe.c -o /tmp/probe.o; \
    file /tmp/probe.o | grep -q 'ARM aarch64' \
        || { echo "FATAL: cross compiler did not emit an AArch64 object" >&2; exit 1; }; \
    rm -f /tmp/probe.c /tmp/probe.o; \
    echo "cross compiler verified"

# -----------------------------------------------------------------------------
#  Record exact versions
# -----------------------------------------------------------------------------
# Written into the image so that any container can be asked what it contains,
# and so CI can publish these into the job log and docs/ci.md section 4 without
# anyone having to remember to update them by hand.
RUN set -eux; \
    { \
      echo "# Toolchain versions baked into this image"; \
      echo "# target platform: ${TARGETARCH}"; \
      echo; \
      echo "## aarch64-none-elf-g++ (Arm GNU Toolchain ${ARM_GNU_VERSION})"; aarch64-none-elf-g++ --version; \
      echo; \
      echo "## qemu-system-aarch64"; qemu-system-aarch64 --version; \
      echo; \
      echo "## gdb-multiarch";       gdb-multiarch --version | head -n 1; \
      echo; \
      echo "## clang-format";        clang-format --version; \
      echo; \
      echo "## make";                make --version | head -n 1; \
      echo; \
      echo "## host g++";            g++ --version | head -n 1; \
      echo; \
      echo "## ubuntu";              cat /etc/os-release | grep PRETTY_NAME; \
    } > /etc/toolchain-versions.txt; \
    cat /etc/toolchain-versions.txt

# -----------------------------------------------------------------------------
#  Runtime defaults
# -----------------------------------------------------------------------------
# /work is where the repository gets bind-mounted, by CI and by setup.sh alike:
#   docker run --rm -v "$PWD":/work -w /work <image> make
WORKDIR /work

# Deliberately left as root. Callers pass --user "$(id -u):$(id -g)" on Linux
# and WSL so that files created in the bind-mounted build/ belong to the person
# who ran the build rather than to root. Baking in a fixed non-root UID would
# just be wrong for everyone whose UID differs from the guess.
CMD ["/bin/bash"]
