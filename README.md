# os-final-project

A bare-metal operating system kernel written from scratch in freestanding C++ and AArch64
assembly, targeting `qemu-system-aarch64 -machine virt`.

Magshimim final project. Two developers, one mentor, and a CI pipeline whose job is to make it
impossible for either developer to merge a change that breaks what the other one built.

---

## Quick start

You install three things by hand — **Git, Docker, and an editor**. Everything else (cross
compiler, QEMU, debugger, formatter) lives in a pinned container image that is pulled for you.

```sh
git clone <repo-url>
cd os-final-project
bash scripts/setup.sh
```

That ends with either `YOU ARE SET UP CORRECTLY` or a specific, actionable error. It installs
nothing and starts no daemons — if something is missing it tells you exactly what to run.

Full walkthrough for every platform, including Windows/WSL2 and Apple Silicon:
**[docs/onboarding.md](docs/onboarding.md)**.

> **Windows:** clone into the WSL filesystem (`~/projects/...`), never `/mnt/c/...`. This is a
> requirement — see [the gotchas](docs/onboarding.md#mixed-os-gotchas).

### Everyday commands

```sh
make                    # build the debug profile
make PROFILE=release    # build optimised
make run                # boot the kernel in QEMU  (Ctrl-A then X to quit)
make debug              # boot halted, waiting for gdb on :1234
make test               # host unit tests + in-kernel tests under QEMU
make format             # apply clang-format
make help               # every target
```

---

## Who writes what

This split is deliberate and it is the point of the project, not a division of labour.

**The kernel is written by hand, by its author.** `boot/`, `src/`, `include/`, the linker script,
the UART driver, the panic handler, the in-kernel test registry and every test body. The value of
this project is in understanding and being able to defend every design decision in it, and code
you did not write is worth nothing toward that.

**Everything around the kernel is scaffolding**: the Makefile, the container, the QEMU flags, the
CI pipeline, the test harness, these documents.

The two halves meet at a written interface contract — entry symbol, linker script requirements,
build defines, and the exact serial output format the harness parses. It lives in
**[docs/ci.md § 2](docs/ci.md#2-interface-contract)** and neither side may widen it silently.

---

## Layout

```
boot/            first instructions, before anything else exists
src/             the kernel
include/         kernel headers
linker/          linker script -- decides where everything lands in memory
tests/host/      pure-logic unit tests, run natively, no QEMU
tests/kernel/    tests that run inside the booted kernel
scripts/         QEMU flags, run/debug/test harness, onboarding
docker/          the reference build environment
docs/            the pipeline, the contract, onboarding, IDE setup
.github/         CI workflows, PR template, CODEOWNERS
build/           output (git-ignored, out of tree)
```

`boot/`, `src/`, `include/`, `linker/` and `tests/kernel/` deliberately contain no placeholder
files, so git will not show them in a fresh clone until the first real file lands.
`scripts/setup.sh` recreates them.

---

## How the pipeline works, briefly

Every pull request runs, inside the same container you build in locally:

| Job | What it proves |
|---|---|
| `hygiene` | No CRLF, no filename-case traps, scripts still executable |
| `format` | Code matches `.clang-format` |
| `build` | Compiles clean at `-O0` **and** `-O2`, with `-Werror` |
| `qemu-smoke` | The kernel boots, prints its banner, does not panic |
| `qemu-tests` | The in-kernel suite runs and every test passes |
| `summary` | The single required check branch protection points at |

Every QEMU invocation is wrapped in a hard timeout, so a hung kernel fails the job in seconds
rather than occupying a runner. The serial log is uploaded as an artifact on every run,
**especially on failure**, and failing jobs print the exact `docker run …` line to reproduce them.

Details, and the reasoning behind every flag: **[docs/ci.md](docs/ci.md)**.

---

## Conventions

### Branch names

```
feat/<area>-<short-desc>      feat/pmm-bitmap-allocator
fix/<area>-<short-desc>       fix/uart-fifo-drain
docs/<short-desc>             docs/adr-interrupt-model
ci/<short-desc>               ci/pin-toolchain-image
```

Areas match subsystems: `boot`, `pmm`, `vmm`, `irq`, `sched`, `syscall`, `uart`.

`main` is protected: pull request, one approving review, green `summary` check, no force pushes.

### Filenames: `lowercase_with_underscores`

`pmm_bitmap.cpp`, not `PmmBitmap.cpp`.

This is not aesthetics. macOS and Windows are case-insensitive; Linux is not. `#include "Uart.h"`
against a file named `uart.h` compiles on both laptops and fails only in CI — and two files
differing only in case cannot both exist in a checkout on either laptop. If every name is
lowercase, the entire class of bug is unreachable. CI enforces it.

### Commit messages

Explain **why**, not what — the diff already says what. This project is graded partly on
justified design decisions, and the commit log is the cheapest place to record them.

---

## Design decisions worth knowing

Recorded here because "why is it like this" is the question a reviewer actually asks. Fuller
reasoning in [docs/ci.md](docs/ci.md); one-page ADRs in [docs/adr/](docs/adr/).

**A container, not a server.** The "cloud QEMU machine" is a pinned image plus ephemeral GitHub
Actions runners. A persistent VM that two people mutate by hand drifts, costs money, and becomes a
single point of failure right before a deadline. Reproducibility was the actual goal; a machine in
the cloud was only ever the means.

**One source of truth for QEMU flags.** `scripts/qemu-flags.sh` defines them; local runs, debug
runs and CI all source it. Nothing else may hardcode a QEMU flag. "Works on my machine" is not
discouraged here, it is structurally impossible.

**Both optimisation levels, every time.** `-O0` and `-O2` expose different bugs — missing
`volatile` on MMIO, uninitialised reads, undefined behaviour the optimiser is entitled to exploit.
Building only one profile means finding those bugs later and with less information.

**Pure logic separated from MMIO.** Anything that is arithmetic — allocator bitmaps, page-table
index maths, ring buffers, string formatting — is written so it can compile and be tested on the
host in seconds, with no emulator. This is a design constraint on the kernel, adopted because it
makes most logic bugs findable in a fast feedback loop instead of a slow one.

**TCG, never KVM.** An AArch64 guest cannot use KVM on an x86-64 runner, and we deliberately do
not use it on an arm64 host either. The emulated machine is then identical everywhere, so a bug
that appears on only one host is a genuine finding rather than noise.

**The verdict comes from the serial log, not from an exit code.** How QEMU propagates a
semihosting exit status has varied between versions. That gets measured on our pinned QEMU rather
than assumed; until then, log parsing owns the pass/fail decision.

---

## Documentation

| | |
|---|---|
| [docs/onboarding.md](docs/onboarding.md) | Fresh-machine setup for Windows, macOS and Linux; mixed-OS gotchas |
| [docs/ci.md](docs/ci.md) | The pipeline, the interface contract, flag reasoning, pinned versions |
| [docs/clion.md](docs/clion.md) | CLion on macOS against the containerised toolchain, and debugging QEMU |
| [docs/adr/](docs/adr/) | One-page architecture decision records |
