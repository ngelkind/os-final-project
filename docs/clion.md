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
| Build | container `ghcr.io/ngelkind/os-final-project-ci:latest`, pulled `linux/arm64` | `make info` resolves; g++ 13.3.0, QEMU 8.2.2 inside |
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

Generate the database:

```sh
./scripts/compdb.sh
```

The output is in `.gitignore` — it is generated, and it contains absolute paths that differ per
machine.

### You do not normally re-run it (changed 2026-08-30)

The Makefile maintains `compile_commands.json` as a **byproduct of every build**. Each source has a
one-entry JSON fragment under `build/<profile>/obj/`, derived from the source file and the flags in
the Makefile, and the build stitches the fragments belonging to the current source list into the
database. Add a file, change a flag, build — the index is current.

Three consequences worth knowing:

* **It is derived from the source, not from a compiler that ran.** So a file that does not compile
  yet is still indexed, and a database deleted by hand comes back on the next build without
  forcing a recompile.
* **The Makefile is a prerequisite of every fragment.** Changing a flag rewrites every entry.
* **CLion still has to reload.** It watches the file and usually offers; accept it, or
  **File → Reload Project**. Nothing in a Makefile can reach into the IDE.

`COMPDB=0` turns the whole thing off for a build that must not touch the working tree.

Run `scripts/compdb.sh` when the IDE is not what is driving the build, when switching `INDEXER`
modes, or to rebuild the extracted header cache.

### Why a script at all (verified 2026-08-29)

The database is written *inside* the container and read *outside* it. Two things break across that
boundary.

**Paths — always broken, always fixed by the script.** Entries hold absolute paths. Mounted at
`/work`, every entry would say `/work/src/kernel_main.cpp`, which does not exist on the host. CLion
matches nothing and reports *"this file does not belong to any project target"* with no completion
at all. CLion's own log is unambiguous about it:

```
RadProjectModelHost - Sending updates, project model has 0 sources, 0 weak sources
                      and 1 unknown sources
```

The fix is a mount trick: bind the repo into the container at the **same absolute path** it has on
the host, so what gets recorded is already host-valid. A build under a `/work`-style mount does not
write the database at all — it prints a note instead, rather than silently replacing a good
database with a useless one. It also makes
`-ffile-prefix-map=$(CURDIR)=.` strip the same prefix a host build would, which keeps the debug
info consistent between the two.

**The compiler — depends on your toolchain.** Entries name `/usr/bin/aarch64-linux-gnu-g++`. The
IDE does not merely read the flags, it *executes* the compiler to learn its builtin macros and its
system header search path (§2). *Where* it looks for that binary depends on which toolchain the IDE
is set to, so the script has two modes:

| Mode | For | What it does |
|---|---|---|
| `INDEXER=container` **(default)** | an IDE using the **Docker toolchain** | Nothing. The database stays exactly as the build wrote it, and the IDE runs the real build compiler in the container. The indexer and the build are then literally the same compiler. |
| `INDEXER=host` | an IDE with **no Docker toolchain** | Extracts the container toolchain's header tree to `~/.cache/os-final-project/toolchain-headers` (26MB, outside the repo so CLion does not index it as ours) and rewrites each entry to a host AArch64 driver plus `-isystem` flags pointing there. Only the driver and header search path change; every build flag is preserved verbatim. |

Getting this wrong produces a very specific error, worth recognising:

```
Cannot find compiler executable: '/opt/homebrew/bin/aarch64-elf-g++'
```

That is `INDEXER=host` output being read by a Docker toolchain — CLion is looking for a Homebrew
path *inside the container*. The reverse mismatch fails the same way with `/usr/bin/aarch64-linux-gnu-g++`.

In `host` mode the database is no longer a byte-exact transcript of the build, so the untouched
output is kept beside it as `compile_commands.raw.json`. In `container` mode there is
nothing to keep, because nothing is modified.

**A failing build still produces an index.** The script passes `-k` and does not abort on a
non-zero exit, because the index is most valuable exactly when the code does not compile yet.
Entries are derived from the sources rather than from compilers that were watched running, so a
file that fails to compile is still indexed; `-k` keeps the rest of the build going so the objects,
and everything downstream, are as complete as they can be.

---

## 2. Toolchain: Docker or local?

> **Confirmed 2026-08-29.** This section's recommendation held up and is now what is configured
> here: CLion's default toolchain is `Docker`, image `ghcr.io/ngelkind/os-final-project-ci:latest`,
> `--platform linux/arm64`, C++ compiler pinned to `/usr/bin/aarch64-linux-gnu-g++`. It is why
> `scripts/compdb.sh` defaults to `INDEXER=container` and leaves the database untouched.
>
> One correction to Plan B below: a native `aarch64-elf-g++` *can* serve as the indexer's driver
> after all, but only because `INDEXER=host` supplies the C++ headers separately from the
> container. On its own the objection below still stands exactly as written.
>
> The Docker connection uses `unix://$USER_HOME$/.docker/run/docker.sock`, which on this Mac is a
> symlink to colima's socket. That works, and is worth knowing before you go looking for a Docker
> Desktop setting that does not exist here.

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

**After changing flags or adding files:** re-run `./scripts/compdb.sh`, then
**File → Reload Project**. Stale index data is the cause of a surprising share of
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
