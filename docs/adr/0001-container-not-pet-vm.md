# ADR 0001 — A pinned container, not a persistent VM

**Status:** Accepted

## Context

The original idea was "a QEMU machine in the cloud" — a VM both developers SSH into, with the
toolchain installed, running builds and tests.

## Decision

The shared environment is a **pinned Docker image published to GHCR**, executed on ephemeral
GitHub Actions runners in CI and pulled locally by both developers. No persistent server.

## Consequences

**What we gain.** The environment is defined by a file in the repository, so a change to it is a
reviewable diff rather than something someone did over SSH at 2am. CI and both laptops run
byte-identical toolchains. There is nothing to pay for, patch, or resurrect the night before a
deadline. A new machine is productive in one command.

**What we give up.** No always-on box to leave a long debugging session running on. Container
startup adds a few seconds to a local build. Anything that genuinely needs persistent state has
nowhere to live.

**What would change our minds.** Long interactive GDB sessions becoming a daily bottleneck. If so,
the answer is an *aarch64* host (Oracle Ampere free tier, Hetzner ARM) — because there the guest
could run under KVM instead of TCG, which is a real speedup. An x86-64 VM would add nothing that
CI does not already provide. It would remain a debugging aid; CI stays on ephemeral runners
regardless, because a pet machine in the test path is a single point of failure.

Reproducibility was always the actual goal. "A machine in the cloud" was a means to it, and not
the best one.
