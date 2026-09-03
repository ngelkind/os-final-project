# The build, the pipeline, and the contract between them

This document is written for someone who has never seen this project: a reviewer, a mentor, or
either of us in three months having forgotten why something is the way it is. It covers what the
build system guarantees, what the kernel must guarantee in return, and why each choice was made.

If you only read one section, read **[2. Interface contract](#2-interface-contract)**. It is the
agreement that lets two people work on opposite sides of the same binary without stepping on each
other.

---

## 1. Who owns what

The project has a deliberate split. The kernel is written by hand, by one person, because the
point of the project is understanding it. Everything *around* the kernel — the build, the
container, the CI pipeline, the test harness — is scaffolding.

| Owned by the kernel author | Owned by the scaffolding |
|---|---|
| `boot/`, `src/`, `include/` | `Makefile` |
| `linker/kernel.ld` | `scripts/*` |
| the UART driver | `docker/Dockerfile` |
| the panic handler | `.github/workflows/*` |
| the semihosting exit function | `docs/*`, `README.md` |
| `tests/kernel/` (registry + tests) | `.clang-format`, `.gitignore`, `.gitattributes` |
| the *bodies* of `tests/host/` tests | the host test *runner* |

The two halves meet only at the contract below. Neither side may quietly widen it: if the build
needs something new from the kernel, that is a conversation and a documented change here, not an
edit to someone else's file.

---

## 2. Interface contract

Everything in this section is a promise. The build system depends on it; if you change something
here, the build breaks, and that is by design — a silent mismatch would be far worse.

### 2.1 Entry symbol

```
_start
```

The linker script must declare `ENTRY(_start)`. This sets the `e_entry` field in the ELF header,
which is the address QEMU jumps to after loading the image. Without it the linker picks an entry
point itself (usually the start of `.text`) and warns; with `STRICT_LINK=1` that warning becomes
a build failure.

`_start` runs on no stack, with no initialised `.bss`, and no C++ runtime. It is the first
instruction of the kernel in the literal sense.

### 2.2 Linker script

**Path: `linker/kernel.ld`.** Hardcoded in the Makefile as `LDSCRIPT`. Do not rename it without
changing that variable.

It is passed as `-Wl,-T,linker/kernel.ld` and is a normal prerequisite of the ELF, so editing it
triggers a relink.

**Required of it:**

1. `ENTRY(_start)`.
2. The first loadable segment must be linked at **`0x4000_0000`** — the base of RAM on the QEMU
   `virt` machine. See [3. Platform facts](#3-platform-facts).
3. It must explicitly place `.text`, `.rodata`, `.data`, `.bss`, and `.init_array`. Any section
   present in the objects but not placed by the script is an *orphan*; the linker places orphans
   by its own rules and we build with `--orphan-handling=warn` so you are told when it happens.
   The classic symptom of an unplaced `.rodata` is a UART that prints nothing at all, because
   every string literal vanished from the image.

**Symbols:**

Be aware of an honest distinction here. The build system and the test harness reference **no**
linker symbols at all — they only ever ask for the ELF as a whole. So the list below is not
imposed on you by the scaffolding; it is the conventional set your own boot code will need, and
it is recorded here so that when CI later grows a check that *does* reference one (an image-size
gate, a `.bss`-was-actually-cleared assertion), we already agree on the names.

| Symbol | Why your code will want it |
|---|---|
| `__bss_start`, `__bss_end` | `.bss` is not present in the image file; it is address space that must be zeroed by `_start` before any C++ runs. Skipping this is one of the most common early-kernel bugs, and it presents as a variable that is mysteriously non-zero. |
| `__init_array_start`, `__init_array_end` | C++ objects at namespace scope have constructors. The compiler emits pointers to them into `.init_array`, and **nothing calls them automatically** — there is no C runtime. If you never walk this array, your global objects are simply never constructed, and the failure is silent. |
| `__stack_top` | Only if the stack is defined by the linker script rather than reserved in `.bss` by the boot code. Either approach is fine; this is your design decision. |
| `__kernel_start`, `__kernel_end` | The physical memory allocator will eventually need to know which frames the kernel itself occupies, so that it never hands them out. |

### 2.3 Source discovery, object and output paths

Sources are **discovered, not listed**. Adding a file never requires editing the Makefile — which
also means it never causes a merge conflict between two developers.

```
searched:   boot/  src/                          (+ tests/kernel/ when KERNEL_TESTS=1)
matched:    *.S    *.cpp
```

`.S` (capital S) is assembled through the `g++` front end, so the C preprocessor runs on it. That
means assembly can `#include` the same header as C++ and share constants instead of duplicating
magic numbers. A lowercase `.s` file is **not** picked up.

Discovered files are sorted with `LC_ALL=C sort` before being handed to the linker. This is not
cosmetic: link order determines image layout, `find` returns entries in filesystem order, and
filesystem order differs between machines. The sort is what makes byte-identical builds across a
laptop and a CI runner achievable at all.

Output layout, where `<cfg>` is `debug`, `release`, `debug-ktests` or `release-ktests`:

```
build/<cfg>/kernel.elf        the linked kernel
build/<cfg>/kernel.img        flat binary (objcopy -O binary)
build/<cfg>/kernel.map        linker map
build/<cfg>/size.txt          aarch64-linux-gnu-size output   (CI artifact)
build/<cfg>/sections.txt      objdump -h output                (CI artifact)
build/<cfg>/obj/<path>.<ext>.o
build/<cfg>/obj/<path>.<ext>.d
```

Object paths mirror the source tree, so `src/mm/pmm.cpp` becomes
`build/debug/obj/src/mm/pmm.cpp.o`. The extension is kept in the object name so that `foo.S` and
`foo.cpp` in the same directory cannot collide.

Each configuration has its own directory because CI builds several in the same workspace. A
single flat `build/` would let one profile silently overwrite another, which would defeat the
purpose of testing two profiles.

### 2.4 Preprocessor defines the build injects

| Define | When | Notes |
|---|---|---|
| `KERNEL_TESTS=0` or `KERNEL_TESTS=1` | **always** | Selects the test build. |
| `NDEBUG` | release profile only | The standard "this is an optimised build" convention. |

**`KERNEL_TESTS` is always defined**, as `0` or as `1`. Test it with `#if KERNEL_TESTS`, never
with `#ifdef KERNEL_TESTS` — the latter is true in *both* builds and the test suite would be
compiled into the production image. This is stated loudly because it is an easy mistake that
produces a working build with the wrong contents.

`NDEBUG` appearing only in release is worth knowing about if your assertion macro keys off it:
your assertions will vanish at `-O2`. That may be exactly what you want, but it should be a
decision rather than a surprise.

### 2.5 Symbols the kernel must provide

These are not requests from the build system; they are things the *compiler* will emit references
to, which the linker will then demand. Listed here so the undefined-reference errors are expected
rather than baffling.

| Symbol | Why it appears |
|---|---|
| `memcpy`, `memset`, `memmove`, `memcmp` | Even under `-ffreestanding -fno-builtin`, GCC is explicitly permitted to emit calls to these four for ordinary language constructs — struct assignment, array initialisation, comparison. They need C linkage (`extern "C"`). This is the single most common surprise in a freestanding C++ build. |
| `__cxa_pure_virtual` | Only if you declare a pure virtual function. Called if one is somehow invoked; a sensible implementation panics. |
| `atexit` | Only if you have a namespace-scope object with a non-trivial destructor. We build with `-fno-use-cxa-atexit`, so GCC emits `atexit` rather than `__cxa_atexit`. A kernel never exits, so the usual answer is a stub returning `0` — or, better, not having such objects. |

We deliberately do **not** link a C library, so nothing supplies these for you. We *do* link
`libgcc`, which is part of the compiler rather than the C library: it provides helper routines for
things like 128-bit arithmetic that GCC emits calls to instead of open-coding.

### 2.6 Serial output format — what the harness parses

This is the machine-readable contract between the kernel's test suite and `scripts/run-tests.sh`.
The parser is written against exactly this grammar; anything else is treated as ordinary log
noise and ignored.

All lines are UART output, `\n`-terminated. A trailing `\r` is tolerated and stripped.

#### Boot banner (required in every build)

```
[BOOT] <free text>
```

Must appear at or near the start of output. The smoke test asserts nothing more than that a line
beginning with `[BOOT]` appeared — the rest of the banner is yours to design. Example:

```
[BOOT] kernel v0.1 aarch64 virt
```

#### Per-test line

```
[KTEST] <name><padding><RESULT>[<2+ spaces><detail>]
```

- `<name>` matches `[A-Za-z0-9_]+`. No spaces — that is what keeps the line unambiguous.
- `<padding>` is any run of spaces and/or dots. It is purely cosmetic alignment; the parser
  treats spaces and dots identically here, so you may align the results column however you like,
  or not at all.
- `<RESULT>` is exactly one of `PASS`, `FAIL`, `SKIP`.
- `<detail>` is optional free text on the same line, separated by **two or more spaces**. Use it
  on failure to say where and what. It must not contain a newline.
- `SUMMARY` and `DONE` are reserved; a test may not be named either.

The regular expression the parser uses:

```
^\[KTEST\] ([A-Za-z0-9_]+)[ .]*(PASS|FAIL|SKIP)(?:  +(.*))?$
```

#### Summary line

```
[KTEST] SUMMARY <n> passed, <n> failed
[KTEST] SUMMARY <n> passed, <n> failed, <n> skipped
```

The skipped clause is optional. Parser regex:

```
^\[KTEST\] SUMMARY (\d+) passed, (\d+) failed(?:, (\d+) skipped)?$
```

#### Terminator

```
[KTEST] DONE
```

Must be the final `[KTEST]` line. **Its absence is a failure**, even if the summary said zero
failures — a missing terminator means the kernel stopped producing output partway, which is
exactly the crash-during-teardown case that a summary-only check would score as a pass.

#### Panic

```
[PANIC] <free text>
```

Any line beginning with `[PANIC]` fails the run unconditionally, in every mode, including the
smoke test.

#### Worked example

```
[BOOT] kernel v0.1 aarch64 virt
[KTEST] pmm_alloc_returns_aligned_frame ... PASS
[KTEST] pmm_double_free_detected ......... PASS
[KTEST] vmm_map_then_translate ........... FAIL  src/vmm.cpp:212 expected 0x40001000 got 0x0
[KTEST] SUMMARY 2 passed, 1 failed
[KTEST] DONE
```

#### The verdict the harness computes

Evaluated in order; the first match wins:

| Condition | Verdict |
|---|---|
| test mode, and the timeout expired | **FAIL** — "kernel hung". Last 50 log lines printed. |
| any `[PANIC]` line | **FAIL** |
| test mode, and no `[KTEST] DONE` | **FAIL** — "output truncated" |
| test mode, and summary reports non-zero failed | **FAIL** |
| test mode, and the per-test line count disagrees with the summary counts | **FAIL** — "inconsistent output" |
| smoke mode, and no `[BOOT]` line | **FAIL** — "kernel did not boot" |
| otherwise | **PASS** |

The cross-check in row five is cheap insurance: it catches a kernel that printed a cheerful
summary while half its tests never ran.

In **smoke mode the timeout is not a failure**. The kernel is an interactive shell: it prints its
banner, shows a prompt, and waits on the UART for input forever. It never asks QEMU to exit, so
every smoke run ends at the timeout. Seen from outside, a kernel idle at its prompt and a kernel
that hung look identical, and telling them apart would need a liveness probe (send a command,
expect a reply) that couples the harness to the shell's command set. So smoke asserts only what it
can observe: the banner appeared, and nothing panicked. Test mode is where completion is asserted,
because there the kernel is expected to run its suite and exit through semihosting. The timeout
still bounds the job in both modes, so a runner is never occupied for longer than it.

#### Practical notes

- Keep lines under ~200 characters. Nothing enforces it, but very long lines are painful to read
  in a CI log.
- Make sure output is actually flushed before the kernel exits or halts. With a polled PL011
  driver that means waiting for the transmit FIFO to drain — otherwise the last line or two are
  simply lost, and the missing `DONE` fails the run for a reason that has nothing to do with the
  tests.

### 2.7 Exit codes

**Status: not yet determined. Do not build anything on an assumption here.**

The harness's verdict comes from parsing the log (section 2.6), because that works regardless of
how QEMU chooses to propagate a guest exit status. Semihosting is a speed optimisation on top:
it lets a finished test run end immediately instead of waiting out the timeout.

How QEMU maps a semihosting `SYS_EXIT` onto its own process exit code has varied across versions,
so it will be measured on our pinned QEMU rather than assumed. The experiment (milestone M3) is:
build one kernel that exits with 0 and one that exits with 1, run both, record `echo $?`, and
write the observed behaviour here. If it does not propagate cleanly, semihosting stays purely as
a "stop early" mechanism and log parsing keeps sole ownership of the verdict.

The intended convention, to be confirmed: process exit `0` means pass, anything else means fail.

For the kernel side, read the primary sources rather than a snippet:

- **ARM semihosting specification**, operation `SYS_EXIT` (`0x18`) — including the distinction
  between the legacy single-value form and the AArch64 two-field parameter block, and the
  `ADP_Stopped_ApplicationExit` reason code.
- **QEMU semihosting documentation** for how `-semihosting-config target=native` routes the call.

The flag is already in place: `scripts/qemu-flags.sh` defines
`-semihosting-config enable=on,target=native`.

One thing to watch during that experiment: `scripts/qemu-flags.sh` also sets `-no-shutdown`, which
changes what QEMU does on a guest shutdown request. The semihosting exit path is believed to
bypass it, but that is exactly the kind of belief M3 exists to test. If it turns out `-no-shutdown`
prevents the exit, the flag gets dropped for CI runs only, and the reason gets recorded here.

---

## 3. Platform facts

Values the kernel and linker script depend on. **Marked UNVERIFIED until M1 confirms them on our
pinned QEMU** — they are widely documented, but the brief is right that a reference value copied
from a blog post is not evidence.

| Fact | Value | Status |
|---|---|---|
| RAM base on `-machine virt` | `0x4000_0000` | UNVERIFIED |
| PL011 UART0 MMIO base | `0x0900_0000` | UNVERIFIED |
| Register holding the DTB pointer at entry | `x0` | UNVERIFIED |
| Exception level at entry | EL1 (`virt` defaults to `virtualization=off`, `secure=off`) | UNVERIFIED |
| GIC | v2, pinned by `gic-version=2` | pinned by us |
| Network device | none, pinned by `-nic none` | pinned by us |

`-nic none` is there for a reason that is easy to forget: without it QEMU adds a default
virtio-net card and refuses to start unless it can load that card's PXE boot ROM
(`efi-virtio.rom`). Homebrew's QEMU bundles the ROM; Ubuntu ships it in a separate `ipxe-qemu`
package that the container image does not install. The symptom was a kernel that booted on the Mac
and died in CI with `failed to find romfile` before executing an instruction. The kernel has no
network driver, so the fix is to not have the device.

Two ways to confirm them yourself, both worth doing once:

```sh
# What QEMU says its own machine looks like -- authoritative, and version-specific.
qemu-system-aarch64 -machine virt,gic-version=2 -cpu cortex-a53 -machine dumpdtb=virt.dtb \
    -display none
dtc -I dtb -O dts virt.dtb | less        # look for memory@40000000 and pl011@9000000
```

```sh
# What actually happened at entry -- run under scripts/debug.sh and ask gdb.
(gdb) info registers x0        # the DTB pointer, if the claim holds
(gdb) p/x $CurrentEL >> 2      # the exception level
```

The second is the better evidence: it observes the machine we actually boot on, with our actual
flags, rather than what the documentation says should happen.

---

## 4. Toolchain and pinned versions

To be filled in at M2 from the container build, recording the exact output of:

```
aarch64-linux-gnu-g++ --version
qemu-system-aarch64 --version
```

### Why `aarch64-linux-gnu` and not `aarch64-none-elf`

`aarch64-none-elf` is the "pure" bare-metal target: no operating system in the triple, no
assumptions about a C library. It is also not packaged by Ubuntu, so using it means either
building GCC from source (an afternoon, plus several minutes added to every container build) or
depending on a third-party binary release.

The Linux-targeted cross compiler works perfectly well for a freestanding kernel provided we pass
`-ffreestanding -nostdlib -nostartfiles`, which we do. What the triple actually changes is the
*default* assumptions, and we override every one of them explicitly in the Makefile — where they
are visible and commented, rather than baked invisibly into the toolchain.

This is a pragmatic trade, chosen with open eyes: distro packaging and CI speed in exchange for a
compiler whose defaults we must be explicit about. The Makefile's flag comments are where that
explicitness lives.

### How "pinned" is pinned

Three layers, weakest to strongest:

1. `FROM ubuntu:24.04` — pins the distribution release, not the package versions within it.
2. The exact tool versions are **recorded** in this document, so a change is at least detectable.
3. CI jobs pin the container **by commit-SHA tag**, not `latest`. This is the layer that actually
   matters: once an image is built and tagged, its contents are frozen. Rebuilding the image
   cannot retroactively change what an existing pull request builds against.

Layer 3 is why an unpinned `apt-get install` is acceptable here. The image is the unit of
reproducibility, and the image is immutable once tagged.

---

## 5. Container architecture

The image is built **multi-arch: `linux/amd64` + `linux/arm64`**, via `docker buildx` in
`.github/workflows/toolchain-image.yml`.

The reason is concrete rather than aspirational. The primary development machine is an Apple
Silicon Mac. An amd64-only image on that host runs the entire toolchain under x86 emulation —
while QEMU inside it is *already* emulating AArch64. Two layers of emulation stacked on each
other makes every compile of every working day needlessly slow. CI runners are amd64, so both
platforms genuinely get used.

One consequence worth stating plainly, because it is the thing that makes this safe:

> **The guest is always `aarch64` under TCG, on every host.** `scripts/qemu-flags.sh` sets
> `-accel tcg` unconditionally. We never use KVM, not even on an arm64 host where it would be
> available. So the emulated machine the kernel sees is identical whether it was launched from an
> Apple Silicon Mac, a Windows laptop's WSL2, or a GitHub runner. Host architecture changes how
> fast the build is; it does not change what the kernel runs on.

That has a corollary: **a bug that reproduces on only one host architecture is a real finding, not
noise.** Since the guest is identical, such a divergence points at the toolchain (a codegen
difference between the amd64-hosted and arm64-hosted cross compiler) or at the harness — both of
which are worth understanding rather than shrugging at. Do not dismiss it as "works on mine".

The cost is roughly double image build time and double storage. Storage is free because the
package is public (see below), and the image builds only when `docker/**` changes.

### Package visibility

The repository is **private**; the container package is **public**.

This is deliberate and worth defending. If the package were private too, every `docker pull` would
require `docker login ghcr.io` with a personal access token — turning a one-command onboarding
into a twenty-minute detour involving token scopes, and one that a new team member hits on their
very first interaction with the project. Making the package public removes that entirely.

It is safe because of what the image contains: stock Ubuntu, a stock cross compiler, stock QEMU.
No source, no build output, no credentials. Anyone who wants those packages can `apt-get` them
today.

It also sidesteps a quota. GitHub's free tier allows 500 MB of *private* package storage; this
image is roughly 1 GB. Public packages have no such limit.

If Magshimim requires the package to be private as well, that is a supportable position and the
token flow is documented in `docs/onboarding.md` — but it should be a conscious cost, because
onboarding friction is paid by every person on every machine, forever.

---

## 6. Deviations from the original brief

Recorded because a brief that has been departed from silently is a brief nobody can trust.

| Deviation | Reason |
|---|---|
| Kernel image path is `build/<cfg>/kernel.elf`, not `build/kernel.elf` | CI builds debug and release in one workspace; a flat path lets one profile overwrite the other and quietly defeats the two-profile matrix. `scripts/qemu-flags.sh` defaults to `build/debug/kernel.elf`, and the Makefile always passes `KERNEL` explicitly. |
| `.clang-format` delivered at M1 rather than M5 | A formatter introduced after thousands of lines exist produces one enormous reformat commit and makes `git blame` useless. Introduced before the first line, it costs nothing. |
| M1 validated against a native WSL/Homebrew toolchain, with the container arriving at M2 | M1's purpose is to de-risk the toolchain. Requiring a container runtime to be installed and debugged before the kernel has ever printed a character inverts the risk order. The container then reproduces a toolchain already known to work. |
| `-fno-pie` / `-no-pie` added to the brief's flag list | Ubuntu's cross-GCC is built `--enable-default-pie`. Position-independent code assumes a dynamic loader applies relocations at load time; nothing does that here. |
| `-fno-use-cxa-atexit` added | Avoids requiring `__cxa_atexit` and `__dso_handle`. See §2.5. |
| `-ffile-prefix-map` added | Without it, the same source built in two different directories produces different bytes, and "byte-identical builds" fails for a reason unrelated to the code. |
| `.gitattributes` added (not in the brief) | Mixed-OS team. A script checked out with CRLF fails inside the Linux container as `bad interpreter: /bin/bash^M`. |

---

## 7. Acceptance checklist

What "done" means. Ticked only against observed evidence, never against intent.

**Environment and reproducibility**

- [ ] Clone the repo, run one documented command, and see the kernel boot in QEMU.
- [ ] On a machine that has never seen this project, `git clone && bash scripts/setup.sh` ends
      with a booting kernel and no manual steps beyond installing Docker itself.
- [ ] The same command inside the CI container produces byte-identical build output.

**Pipeline**

- [ ] Opening a pull request runs format, host tests, both build profiles, smoke test and kernel
      tests automatically.
- [ ] A deliberately broken kernel (an infinite loop before the banner) makes CI go **red within
      two minutes**, not hang.
- [ ] A failing kernel test makes CI go red and the serial log is downloadable from the run.
- [ ] `main` cannot be pushed to directly, and cannot be merged into with a red check.
- [ ] Tagging `v0.1.0` produces a GitHub Release with the kernel binaries attached.

**Documentation**

- [ ] This document explains the pipeline, the flag choices and the pinned tool versions well
      enough to be read without asking a question.

**Ownership and hygiene**

- [ ] `git log --diff-filter=A -- boot/ src/ include/ linker/ tests/kernel/` shows **only the
      kernel author's commits**. Not one line of kernel code has any other authorship.
- [ ] No `scratch/` directory survives on any merged branch.
- [ ] No tracked text file contains CRLF.

The last three are machine-checkable. `scripts/check-hygiene.sh` covers the final two on every
pull request; the authorship one is a single command:

```sh
git log --diff-filter=A --format='%an  %h  %s' -- boot/ src/ include/ linker/ tests/kernel/
```
