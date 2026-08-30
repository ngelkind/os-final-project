# Project context for Claude Code

Read this before doing anything in this repository.

## What this project is

A bare-metal operating system kernel written from scratch, submitted as a
Magshimim final project. It is graded on engineering rigor and on the
author's ability to justify design decisions in an oral defense, not only on
whether the kernel boots. That grading model drives most of the rules below:
work that the author cannot explain in his own words is worth less than no
work at all.

There is a hard deadline measured in days, not weeks.

## People

**The author** is the primary and effectively sole developer. He is 18, works
on macOS running on Apple Silicon, and is new to AArch64 (his prior assembly
background is 8086). He is learning this material, not just shipping it.

**Yehonatan Davidi** is the project partner. He works on Windows with WSL2.
Onboarding must work on his machine; `scripts/setup.sh` and `scripts/setup.ps1`
exist for this. WSL2 failure modes are a real concern, not a hypothetical one.

**Shay** is the mentor and team lead. He evaluates the work and is known to
scrutinize technical distinctions carefully. Assume anything sloppy or
unjustified will be noticed.

## Technical stack

Target is AArch64 bare metal on the QEMU `virt` machine, single core
(`-smp 1`). The kernel is freestanding C++20 with a small amount of AArch64
assembly. Build is CMake driven, run through a pinned Docker toolchain image,
with GitHub Actions for CI and GHCR for image hosting. The author's IDE is
CLion on macOS, configured for cross-compilation and for remote debugging
against QEMU's GDB stub.

Debugging is done by starting QEMU halted with its debug stub open and
attaching from CLion. This is the primary diagnostic tool in this project and
must keep working.

**Needs verification:** the Dockerfile currently references
`aarch64-linux-gnu-gcc`, while earlier design discussion assumed a bare-metal
`aarch64-none-elf` toolchain. These are not equivalent for freestanding work.
Do not silently change this. Raise it with the author and let him decide.

## Repository layout

    .github/        CI workflows
    boot/           assembly: entry point, exception vectors, context switch
    docker/         Dockerfile for the pinned toolchain image
    docs/           adr/, ci.md, clion.md, onboarding.md
    include/        kernel headers
    linker/         linker script (memory map)
    scripts/        check-hygiene.sh, debug.sh, qemu-flags.sh, run.sh,
                    run-tests.sh, setup.sh, setup.ps1, toolchain.env
    src/            kernel C++ sources
    tests/host/     tests that run on the host
    tests/kernel/   tests that run inside the kernel

Repository URL: `TODO: fill in`
Toolchain image name and tag: `TODO: fill in`

## Ownership boundary — this is the most important section

**You own infrastructure.** You may create and modify: `CMakeLists.txt` and
CMake toolchain files, everything under `.github/`, `docker/`, `scripts/`,
`docs/`, and `tests/host/`. You may modify CLion run and debug configurations.

**The author owns the kernel.** You must not create, modify, or delete
anything under `boot/`, `src/`, `include/`, `linker/`, or `tests/kernel/`.
This includes stub files, placeholder files, and "just so the build has
something to compile" files. There are no exceptions to this.

If you need a file in those directories that does not exist, **stop and ask**.
Do not create it.

If CI fails because of kernel code, diagnose the failure and report what you
found. Do not patch it.

The reason for this rule: those directories contain the work the author must
defend orally. Code he did not write is worse than useless to him.

## How to work

Stop and report after each milestone rather than building everything at once.
Never make a large or architectural decision silently — surface it, explain
the trade-off, and let the author choose. If a task turns out to require
touching kernel directories, stop rather than working around it.

When something is genuinely blocked or genuinely not possible, say so plainly.
Do not offer a workaround that still leaves the actual work to the author
while implying the problem is solved.

Prefer a single source of truth over duplication. QEMU flags in particular
should live in `scripts/qemu-flags.sh` and be consumed everywhere else, not
copied into three places.

## Scope: five features, one proof of concept

The five OS features the project commits to are physical memory management,
virtual memory and the MMU, exception and interrupt handling, threads and
scheduling, and system calls.

The proof of concept currently being built is deliberately narrower: boot,
serial output over the PL011 UART, an exception vector table installed, a
deliberately triggered software exception whose handler prints the cause and
the return address, and a clean return to the interrupted code with the
interrupted work visibly continuing.

Cooperative task switching driven by a software-triggered exception is a
declared stretch goal. Timer and interrupt controller work is explicitly
**out** of the proof of concept pass criteria, because it is a high-complexity
silent-failure risk and the schedule cannot absorb it.

## Architectural decisions already made

Single core only. Both the QEMU flags and the kernel's own entry code enforce
this: secondary cores are parked. Multi-core would require real locks, memory
ordering rules, per-core state, and inter-core signaling, which is a second
project rather than a feature. This is a declared limitation, not an omission.

Serial output rather than graphics. Writing bytes to a memory-mapped UART is
straightforward; a display would require virtio, bitmap fonts, and pixel
drawing, none of which serve the learning goals.

Concurrency without parallelism. Interleaving via interrupts is the property
being demonstrated; true simultaneous execution is not.

## Known hardware facts

RAM starts at `0x40000000` on the `virt` machine and this address is
guaranteed by QEMU's documentation. The PL011 UART is at `0x9000000` on the
author's pinned configuration; this address is **not** architecturally
guaranteed and was extracted from the device tree dumped from QEMU itself.
It is hard-coded with a comment recording that dependency, which is a
documented and deliberate simplification.

When booting an ELF via `-kernel`, QEMU places the device tree blob at the
start of RAM, so the kernel is linked at an offset above `0x40000000` to
avoid overwriting it.

Never take device addresses from blog posts. Dump the device tree from the
actual pinned QEMU version instead.

## Current state

Infrastructure is in place: Docker image, CI workflows, scripts, CLion
configuration, branch protection, docs. The kernel directories are empty by
design. The author is at the point of writing the linker script and the first
assembly file that puts one character on the serial port.

## Housekeeping

`virt.dtb` and `virt.dts` are throwaway artifacts from dumping the device
tree. They should be gitignored, not committed.
