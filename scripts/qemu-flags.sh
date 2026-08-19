#!/usr/bin/env bash
# =============================================================================
#  SINGLE SOURCE OF TRUTH for how this kernel is run under QEMU.
# =============================================================================
#
#  Every script that launches QEMU -- interactive runs, debug sessions, and the
#  CI test harness -- sources THIS file and uses THESE arrays. No other file in
#  the repository is permitted to hardcode a QEMU flag.
#
#  WHY: "works on my machine" is almost always a flag difference. If the flags
#  physically live in one file, a local run and a CI run cannot diverge without
#  someone editing this file, which is a reviewable diff. The property we want
#  is not "we were careful"; it is "divergence is structurally impossible".
#
#  This file DEFINES; it does not EXECUTE. Sourcing it must never start QEMU.
# =============================================================================

set -euo pipefail

# --- Overridable inputs ------------------------------------------------------
# ARCH is a single variable on purpose. The target architecture is not yet
# locked for this project; if we move to x86_64, this variable plus the
# toolchain triple in the Makefile are the only things that should change.
: "${ARCH:=aarch64}"

# Default kernel image. The Makefile always passes KERNEL explicitly (it knows
# which profile it just built); this default exists so `./scripts/run.sh` alone
# does something sensible.
#
# NOTE, deviation from the brief: the brief wrote `build/kernel.elf`. We use
# `build/<profile>/kernel.elf` because CI builds debug and release in the same
# workspace and a single flat path would let one profile silently clobber the
# other -- exactly the class of bug the debug/release matrix exists to catch.
: "${KERNEL:=build/debug/kernel.elf}"

QEMU_BIN="qemu-system-${ARCH}"

# --- Machine definition ------------------------------------------------------
# This block must stay in agreement with the kernel's boot code and linker
# script. See docs/ci.md ("Platform facts") for the addresses these imply.
QEMU_MACHINE=(
  # 'virt' is QEMU's synthetic board: no real hardware to emulate bug-for-bug,
  # a stable memory map across versions, and a device tree describing it.
  # gic-version=2 pins the interrupt controller. Pinned rather than left to
  # QEMU's default because the GIC programming model differs substantially
  # between v2 and v3, and the IRQ driver will be written against exactly one
  # of them. An implicit default that shifts on a QEMU upgrade would break the
  # IRQ subsystem for reasons that look like a kernel bug.
  -machine virt,gic-version=2

  # A concrete, widely documented ARMv8-A core. QEMU's default 'max' CPU
  # advertises every optional feature it can emulate, which invites writing
  # code against features that real hardware may not have -- and 'max' changes
  # meaning between QEMU releases, so it is not reproducible.
  -cpu cortex-a53

  # Start single-core. SMP brings concurrency bugs into every subsystem at
  # once; raise this deliberately when multi-core is an actual goal, not by
  # accident on day one.
  -smp 1

  # Generous but not absurd. Enough to develop a physical memory allocator
  # against without the RAM size itself being the interesting constraint.
  -m 512M

  # TCG = pure software emulation. An aarch64 guest on an x86_64 CI runner
  # cannot use KVM (KVM requires matching host/guest architecture), so TCG is
  # not a preference, it is the only option. It is entirely adequate: this
  # kernel does nothing compute-heavy. Stated explicitly rather than left
  # implicit so nobody spends a weekend chasing nested virtualisation.
  -accel tcg
)

# --- Safety ------------------------------------------------------------------
QEMU_SAFETY=(
  # A triple fault (or any reset request) must stop the machine, not silently
  # reboot. Without this a kernel that faults during early boot reboot-loops
  # forever and the serial log fills with the same banner over and over --
  # which reads like "it booted" until you look closely.
  -no-reboot

  # Likewise for guest-initiated shutdown: QEMU halts instead of exiting, so
  # the reason the machine stopped is still inspectable.
  #
  # CAUTION (verify at M3): -no-shutdown changes what happens on a shutdown
  # request. The semihosting SYS_EXIT path is believed to bypass it and
  # terminate QEMU directly, but that is exactly the kind of assumption the
  # brief says to test rather than trust. If M3 finds that -no-shutdown
  # prevents semihosting from exiting, this flag is removed for CI runs only.
  -no-shutdown
)

# --- Semihosting -------------------------------------------------------------
# Semihosting lets the guest ask the *host* to do something -- in our case, to
# terminate QEMU with a status code, so a finished test run ends immediately
# instead of waiting out the harness timeout.
#
# target=native routes the calls to QEMU itself rather than to an attached
# debugger, which is what we want when running headless in CI with no gdb.
QEMU_SEMIHOSTING=( -semihosting-config enable=on,target=native )

# --- Kernel image ------------------------------------------------------------
# -kernel with an ELF file: QEMU reads the program headers, loads each segment
# at its physical address, and begins execution at the ELF entry point.
QEMU_KERNEL=( -kernel "${KERNEL}" )

# --- Mode-specific I/O -------------------------------------------------------
# interactive: serial appears in this terminal and the QEMU monitor is
#              multiplexed onto the same terminal (Ctrl-A then C to switch,
#              Ctrl-A then X to quit).
QEMU_IO_INTERACTIVE=( -nographic -serial mon:stdio )

# ci: no display subsystem at all, serial goes to stdout and nothing else does.
#     The monitor is disabled explicitly -- if it shared stdout it would
#     interleave its own text into the serial log and corrupt the parser's
#     input. The log must contain kernel output and nothing else.
QEMU_IO_CI=( -display none -serial stdio -monitor none )

# --- Debugging ---------------------------------------------------------------
# -s : open a gdb server on TCP :1234 (shorthand for -gdb tcp::1234)
# -S : do not start the CPU; wait for gdb to say 'continue'. Without -S the
#      kernel has already run past early boot before gdb can attach, which is
#      precisely the part you most often need to step through.
QEMU_DEBUG=( -s -S )

# --- Escape hatch ------------------------------------------------------------
# Ad-hoc flags for a single local run, e.g.:
#     QEMU_EXTRA_ARGS="-d int,mmu -D build/qemu-trace.log" ./scripts/run.sh
# CI never sets this. It exists so that experimenting does not tempt anyone to
# edit the definitions above and forget to revert them.
read -r -a QEMU_EXTRA <<< "${QEMU_EXTRA_ARGS:-}"
