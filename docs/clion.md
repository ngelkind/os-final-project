# CLion on macOS, driving the containerised toolchain

This is the setup for day-to-day kernel work in CLion: editing on macOS, building with the same
compiler CI uses, and stepping through the kernel under QEMU.

**Read the honesty note first.** Parts of this are genuinely fiddly. Where something is awkward or
where I am reasoning from how the tools work rather than from having run it on your machine, it is
labelled. Nothing below is presented as smoother than it is.

---

## 0. What is actually set up on this Mac (verified 2026-08-25)

Everything below this section was written before any of it had been run here. This section is the
opposite: only things that were executed and observed on this machine. Where it contradicts a
later section, this one is right and the later one has been corrected in place.

**Toolchains present.**

| Piece | What is used | Verified |
|---|---|---|
| Build | container `ghcr.io/ngelkind/os-final-project-ci:latest`, pulled `linux/arm64` | `make info` resolves; g++ 13.3.0, QEMU 8.2.2, bear 3.1.3 inside |
| Docker runtime | **colima**, not Docker Desktop — needs no admin rights | `docker info` -> 29.5.2, `linux/aarch64` |
| Run / debug | **native** Homebrew `qemu-system-aarch64` 11.1.0 | boots and accepts a gdb connection |
| Debugger | **native** Homebrew `aarch64-elf-gdb` 17.2 | attached to QEMU, read `pc`/`cpsr`, disassembled |

**The run and debug path does not cross the container boundary.** `scripts/run.sh` and
`scripts/debug.sh` invoke QEMU directly and never call `make`, so they run natively on macOS
against the ELF the container produced in the bind-mounted `build/`. That removes the port
publishing and the `/work` path mapping that section 5 warns about. Only the *build* is
containerised.

Proof the debug path works, run with no kernel at all — QEMU halts before the first instruction,
so a debugger can attach to a bare machine:

```sh
qemu-system-aarch64 -machine virt,gic-version=2 -cpu cortex-a53 -m 512M -accel tcg -display none -s -S &
aarch64-elf-gdb -batch -ex 'set architecture aarch64' -ex 'target remote localhost:1234' \
                -ex 'info registers pc cpsr'
```

Observed: `pc 0x0`, `cpsr 0x400003c5 [ SP EL=1 F I A D ]` — the correct AArch64 reset state for
`-machine virt`. If that works and CLion's debugger does not, the problem is CLion's
configuration, not the toolchain.

**Run configurations** are in `.idea/runConfigurations/` (git-ignored, so they are yours alone):
`build debug (container)`, `build release (container)`, `compdb (container)`, `run QEMU (native)`,
`debug QEMU halted (native)`, `attach to QEMU`. The two QEMU ones have *Execute in terminal*
ticked, for the Ctrl-A X reason in section 4.

**A macOS trap worth knowing.** A GUI-launched CLion does not inherit your shell `PATH`, so
`/opt/homebrew/bin` is invisible to it and `docker`, `qemu-system-aarch64` and the cross GDB all
appear missing. Every run configuration therefore sets `PATH` and `DOCKER_HOST` explicitly rather
than assuming them.

---

## 1. The build-system question, answered first

CLion is built around CMake. Our build is a plain Makefile, chosen because a mentor should be able
to read the entire build in one screen — a goal CMake actively works against for a project this
size.

Three ways to reconcile that:

| Option | What it means | Cost |
|---|---|---|
| **A. Makefile project** | CLion 2020.2+ opens a Makefile directly. It runs `make --dry-run` and parses the compiler invocations to learn your flags. | Zero setup. Flag detection is decent but not perfect — it can miss flags introduced through variable indirection, which our Makefile uses heavily. |
| **B. Compilation database** | Generate `compile_commands.json` from a real build; CLion reads exact per-file flags from it. | One extra command after adding files. Most accurate — the flags are recorded from the actual compiler invocation, not inferred. |
| **C. Switch to CMake** | Rewrite the build. | Loses the "readable in one screen" property that justified Make. CMake's bare-metal cross-compilation story needs a toolchain file, `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` to stop it testing the compiler by linking a hosted executable, and careful handling of the linker script. It is a real afternoon, and it makes the build harder to defend, not easier. |

**Recommendation: B, with A as the fallback.** Keep the Makefile; generate a compilation database
so the indexer sees exactly the flags the compiler saw.

I am **not** switching the build system — the brief says to ask first, and I would argue against
it anyway. If you want C after reading this, say so and I will lay out what it actually costs.

Generate the database (target added for this; runs `bear` inside the container):

```sh
make compdb
```

That writes `compile_commands.json` in the repo root. Re-run it when you add source files or
change flags. It is in `.gitignore` — it is generated output, and it contains absolute paths that
differ per machine.

---

## 2. Toolchain: Docker or local?

**Recommendation: use CLion's Docker toolchain.**

The reason is the indexer, not the build. CLion does not just run your compiler — it *interrogates*
it, asking for built-in macros and the default include search path, so it can resolve `#include`
and know what `__ARM_ARCH` expands to. If CLion cannot execute the compiler your flags name, it
falls back to the host compiler's headers, and then a freestanding AArch64 file gets indexed
against macOS's `/usr/include`. That is the failure everyone hits: the file is underlined red
end-to-end, `uint64_t` is unknown, and no amount of editing fixes it, because the problem is that
CLion is asking the wrong compiler.

A Docker toolchain points CLion at the container, so the indexer runs the same
`aarch64-linux-gnu-g++` as the build and CI.

### Configuring it

**Settings → Build, Execution, Deployment → Toolchains → `+` → Docker.**

- **Server**: your Docker daemon (CLion detects Docker Desktop automatically).
- **Image**: the value of `IMAGE` in `scripts/toolchain.env` —
  `ghcr.io/ngelkind/os-final-project-ci:latest`.
- **Container settings**: add `--platform linux/arm64` on Apple Silicon so you get the native
  variant rather than the emulated one.
- **C Compiler / C++ Compiler**: set explicitly to `/usr/bin/aarch64-linux-gnu-gcc` and
  `/usr/bin/aarch64-linux-gnu-g++`. Do not let CLion auto-detect — it will find the container's
  *host* `g++` (which is x86-64 or arm64 Linux, not our freestanding target) and you get the same
  wrong-compiler problem one level down.
- **Debugger**: `/usr/bin/gdb-multiarch`. See the debugging caveat in §5.

Then **Settings → Build, Execution, Deployment → Makefile** and select the Docker toolchain.

### The honest cost

File synchronisation. CLion's Docker toolchain moves your sources into the container, and on
macOS, Docker Desktop's bind mounts have real overhead. For a kernel — tens of files, not
thousands — this should be fine. If it turns out sluggish, fall back to:

**Plan B: a native cross-compiler on macOS purely for indexing.**

```sh
brew install --cask gcc-aarch64-embedded
```

**This does not work for this project, and the reason is worth writing down.** Homebrew's
`aarch64-elf-gcc` (16.2.0, already installed here) is built `--without-headers`: it ships GCC's own
freestanding C headers and nothing else. `#include <stdint.h>` compiles; `#include <cstdint>` fails
with *"cstdint: No such file or directory"*, and so do `<cstddef>` and `<type_traits>`. We build
C++20, and section 3 tells you that unresolved freestanding C++ headers mean the wrong compiler --
so a native cross compiler as the indexer's compiler would produce exactly the symptom it is meant
to cure.

The container's `aarch64-linux-gnu-g++` carries a full libstdc++, so it has those headers. That
makes the Docker toolchain **required** here rather than merely recommended. The native cross
compiler is still useful -- but for `aarch64-elf-gdb`, not for indexing.

---

## 3. Making the indexer behave on freestanding code

Even with the right compiler, a few things commonly go wrong.

**Symptom: standard integer types are unknown (`uint32_t` undefined).**
We build with `-ffreestanding -nostdlib`, but freestanding C++ still provides the *freestanding*
headers — `<cstdint>`, `<cstddef>`, `<type_traits>` — because those are header-only and require no
runtime. If they are unresolved, the indexer is using the wrong compiler. Go back to §2.

**Symptom: everything is red only in `.S` files.**
Expected, and not worth fighting. CLion's assembly support does not run the C preprocessor the way
our build does (we assemble `.S` through the `g++` driver precisely so `#include` works). Syntax
highlighting works; cross-file navigation from assembly into headers is unreliable. Treat assembly
files as a text editor with highlighting.

**Symptom: `-mgeneral-regs-only` or other flags rejected by the indexer.**
CLion passes your flags to its Clang-based parser, which does not recognise every GCC flag. It
usually ignores them silently. If a flag causes visible breakage, add it to
**Settings → Languages & Frameworks → C/C++ → Clangd → ignored flags** rather than removing it
from the build. The build's flags are not negotiable for the indexer's convenience.

**Symptom: linker-script symbols look undefined.**
Declarations like `extern "C" char __bss_start[];` are correct C++ and CLion resolves them fine —
but it cannot know they come from the linker script, so "go to definition" leads nowhere. That is
inherent, not a misconfiguration.

**After changing flags or adding files:** re-run `make compdb`, then
**File → Reload CMake/Makefile Project**. Stale index data is the cause of a surprising share of
"CLion is broken" moments.

---

## 4. Run configurations for `make run` and `make debug`

CLion's Makefile support may offer targets automatically, but `run` and `debug` are interactive
and want a real terminal, so configure them explicitly.

### `make run`

**Run → Edit Configurations → `+` → Shell Script.**

- Name: `run (QEMU)`
- Execute: **Script text**
- Script text: `make run`
- Working directory: `$ProjectFileDir$`
- **Execute in terminal**: ticked — this matters. QEMU's serial console is interactive, and
  Ctrl-A X (the quit sequence) needs a real terminal. In CLion's plain output pane you will not be
  able to quit QEMU and will have to kill the process.

### `make debug`

Same, with script text `make debug`. It starts QEMU halted, waiting for a debugger on `:1234`, and
prints the exact gdb command line.

Run this **first**, then attach with the configuration in §5.

---

## 5. Attaching CLion's debugger to QEMU

This is the fiddliest part of the whole setup. Read the caveat before configuring.

### The caveat, stated plainly

**CLion's bundled GDB cannot debug an AArch64 target.** It is built for the host architecture. You
must supply a GDB that understands `aarch64`, and on macOS that is the part most likely to cost
you an hour.

Options, best first:

1. **`brew install aarch64-elf-gdb`** — a native cross GDB, runs natively on Apple Silicon. This
   is the option I would try first.
2. **The container's `gdb-multiarch`**, with CLion configured to use the Docker toolchain's
   debugger. Conceptually cleanest — same debugger as everyone else — but you are then debugging
   across the container boundary, and I would expect some friction with path mapping between
   `/work` inside the container and your local project directory.
3. **Terminal GDB, CLion as editor only.** `make debug` prints the exact command to paste. Less
   pretty, zero configuration risk, and it always works. If §5 fights you for more than half an
   hour, this is the pragmatic answer — you lose the GUI, not the debugging.

Option 1 is now installed and verified on this Mac (section 0): `aarch64-elf-gdb` 17.2 attached to
a running QEMU gdbstub and read registers correctly. What is *not* verified is CLion driving it
through the GDB Remote Debug dialog, because that cannot be checked from a terminal. If the GUI
misbehaves, section 0's two-command reproduction tells you immediately whether the fault is CLion
or the toolchain.

### The configuration

**Run → Edit Configurations → `+` → GDB Remote Debug.**

- **Name**: `attach to QEMU`
- **GDB**: the cross GDB — e.g. `/opt/homebrew/bin/aarch64-elf-gdb`. Not the bundled one.
- **'target remote' args**: `localhost:1234`
- **Symbol file**: `$ProjectFileDir$/build/debug/kernel.elf`
- **Sysroot**: leave empty. There is no system to root against.
- **Path mappings**: only needed if you build inside the container, because the debug info will
  say `/work/src/foo.cpp` and your files are at `/Users/you/projects/os-final-project/src/foo.cpp`.
  Map `/work` → `$ProjectFileDir$`.

  We compile with `-ffile-prefix-map=$(CURDIR)=.`, which makes recorded paths *relative*, so this
  may be unnecessary. That flag exists for reproducible builds; helping here is a side benefit.
  Configure a mapping only if you actually see unresolved paths.

### Using it

1. Run the `debug (QEMU)` configuration. QEMU starts and halts before the first instruction.
2. Run the `attach to QEMU` configuration.
3. Set a breakpoint on `_start` or `kernel_main` and continue.

Debug the **debug profile**, not release. It is built `-O0` precisely so that stepping matches the
source; at `-O2` execution appears to jump around at random and locals read `<optimized out>`.
That is the optimiser, not a bug.

### If you build inside the container

QEMU's gdbstub then listens inside the container, so publish the port:

```sh
source scripts/toolchain.env
docker run --rm -it -p 127.0.0.1:1234:1234 -v "$PWD":/work -w /work "$IMAGE" make debug
```

Note `127.0.0.1:` on the publish. Binding the gdbstub to all interfaces would expose a debug port
that grants complete control over the emulated machine to anyone who can reach your host.

---

## 6. Things that will still be imperfect

Stated up front so they read as known rather than as something you broke:

- **Assembly navigation** is weak (§3). Structural, not fixable by configuration.
- **Makefile project support** occasionally loses track after large edits; **File → Reload
  Makefile Project** is the fix, and you will use it more than you would like.
- **The debugger setup is the fragile part.** If it resists, option 3 in §5 — terminal GDB, CLion
  as editor — costs you a GUI and nothing else.
- **CLion's indexer and the actual compiler will occasionally disagree.** The indexer is clangd;
  the build is GCC. When they differ, the build is right.
- I have not verified any of this on your Mac. When something below turns out to be wrong, tell me
  what you saw and I will correct this document — it is mine to maintain.
