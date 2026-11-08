# ADR 0004 — aarch64-none-elf, not aarch64-linux-gnu

**Status:** Accepted (2026-11-08, GitLab #2)

## Context

Until November 2026 the kernel was built with Ubuntu's `aarch64-linux-gnu` cross compiler, with
the Linux defaults switched off by flags in the Makefile. The project file (chapter 3) already said
`aarch64-none-elf`, so the code and the document disagreed. The team's stated priority is
security, exploitation and understanding exactly what runs, and a compiler built for Linux
carries assumptions we never chose:

- glibc and Linux headers on the include path — `src/console/console.cpp` included
  `<thread_db.h>` and it compiled without a warning;
- `__linux__` defined, default PIE and a default stack protector;
- `-moutline-atomics`: every atomic became a call into a libgcc helper that picks LSE or LL/SC from
  a flag an OS sets at startup. (Measured later: Arm's none-elf build defaults to this as well.)

## Decision

Build the kernel with **`aarch64-none-elf` from the Arm GNU Toolchain** (15.3.rel2 at the time of
writing), pinned by version and SHA-256 in `docker/Dockerfile`. In the Makefile:

- `-mno-outline-atomics`, so atomics are inline instructions in our own disassembly;
- `-nostdinc`, then only GCC's freestanding headers and libstdc++ added back, so a libc header such
  as `<stdio.h>` is a compile error rather than a link-time surprise.

`scripts/install-arm-toolchain.sh` installs the same release natively on Linux/WSL from the same
pins.

## Consequences

**What we gain.** The compiler assumes no OS. Every runtime helper and every mitigation in the
kernel — stack canaries, PAC/BTI, W^X, planned as their own issues — is something we turn on and
implement ourselves, which is both the point of the project and easier to defend.

**What we give up.** The toolchain is no longer one `apt-get install`: it is a ~100 MB download
from Arm, and upgrading means editing three pinned values. The amd64 and arm64 image variants now
download different tarballs, which must both be kept in step.

**What would change our minds.** Arm stopping its binary releases, or a hard need for something
only the distribution compiler provides. In that case the Linux compiler is workable again — but
only with every default listed above overridden explicitly, as it was before.

Full reasoning and measurements: [docs/ci.md](../ci.md) section 4.
