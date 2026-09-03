# CLion on Windows/WSL2, driving the native WSL toolchain

This is the Windows counterpart to `docs/clion.md`. The goal is the same green-button experience
the author has on macOS: one click builds the kernel, one click boots it under QEMU.

**Read this note first.** This document was written without a Windows machine or a copy of CLion
to test it on. Everything about *what WSL2 and Docker do* is fact, checked against JetBrains' own
documentation. Everything about *which exact menu CLion puts a WSL setting in* is reasoning from
how CLion is documented to behave, not something observed on a screen. Where it turns out to be a
menu or two off, that is expected, not a sign anything is fundamentally wrong. Report back what
you actually see and this file gets corrected in place, exactly like `docs/clion.md` section 0
was.

**Prerequisite.** `scripts/bootstrap-wsl.sh` must have already finished successfully — see
`docs/onboarding.md`. It installs the exact three things this setup needs inside WSL: the cross
compiler (`aarch64-linux-gnu-g++`), `qemu-system-aarch64`, and `gdb-multiarch`.

---

## Why this looks different from the Mac setup

On macOS, CLion's build goes *into* a Docker container (because the Mac has no native AArch64
Linux toolchain worth using — see `docs/clion.md` §2), and only the run/debug step is native,
talking to QEMU installed via Homebrew.

On Windows, WSL2 already *is* a real Linux environment, and `bootstrap-wsl.sh` already installed a
native `aarch64-linux-gnu-g++` inside it — the same package the container uses
(`docker/Dockerfile`). So there is no reason to route CLion's build through Docker a second time:
**CLion's WSL toolchain gives you the same compiler as the container, without the container.**
That is a real, supported CLion feature (JetBrains calls it a "WSL toolchain"), not a workaround.

The trade-off, same one `docs/onboarding.md` already states for native builds on any platform:
**the container remains the source of truth.** The native `aarch64-linux-gnu-g++` inside WSL and
the one baked into the pinned image can drift by a point release. If a build behaves differently
than CI, reproduce it in the container (`docker run ... make`, see `docs/ci.md`) before concluding
it is a code bug — exactly the rule already in `docs/onboarding.md`, "The reference environment."

---

## 1. Open the project

The repository lives inside WSL (`~/projects/os-final-project`), never under `/mnt/c` — see
`docs/onboarding.md`. CLion runs on Windows but can open a project directly from the WSL
filesystem over the `\\wsl$` network path, which is how JetBrains documents editing WSL projects
from a Windows-side IDE.

**File → Open**, then type the path (adjust the distro name and username to match):

```
\\wsl$\Ubuntu-24.04\home\<your-linux-username>\projects\os-final-project
```

If Explorer's address bar shows `\\wsl.localhost\...` instead, use that form — different Windows
builds expose the same share under different names.

---

## 2. Toolchain: WSL

**Settings → Build, Execution, Deployment → Toolchains → `+` → WSL.**

**Verified 2026-09-03, corrected from the version originally written here** (see the honesty note
at the top): the dialog has more fields than described below, and CLion pre-fills two of them
wrong.

- **Distribution**: the Ubuntu-24.04 distro `bootstrap-wsl.sh` installed. CLion lists it — this is
  a standard, first-party CLion toolchain type, not a manual environment hookup.
- **CMake** and **Build Tool**: CLion showed both as *"Not found, please install this package"*,
  and the toolchain reported *"Test CMake run finished with errors."* This looks alarming for a
  project with no `CMakeLists.txt`, but it is expected: CLion learns a compiler's built-in macros
  and header search path by running a small internal CMake probe project, regardless of what build
  system the actual project uses (`docs/clion.md` §2 describes the same interrogation for the
  Docker toolchain). This is exactly the reason commit `915e6a7`, *"docker: add cmake so CLion can
  detect the cross compilers,"* added `cmake` to the container image for the Mac setup — same
  requirement, different toolchain. Fix it the same way, inside WSL:
  ```sh
  sudo apt-get update
  sudo apt-get install -y cmake
  ```
  `bootstrap-wsl.sh` already installs `make`; confirm with `which make` if the Build Tool field
  still does not resolve after installing `cmake`. Reopen the toolchain dialog (or hit **Apply**)
  once both are installed.
- **C Compiler**: set explicitly to `/usr/bin/aarch64-linux-gnu-gcc`.
- **C++ Compiler**: set explicitly to `/usr/bin/aarch64-linux-gnu-g++`.
  Do not let CLion auto-detect either of these. Left alone, CLion filled *both* the C and C++
  fields with `aarch64-linux-gnu-gcc` — the C driver in both slots, never offering `g++` at all.
  That is the same wrong-compiler trap `docs/clion.md` §2 warns about for the Docker toolchain, one
  level removed, and CLion does not catch it for you; it must be typed in by hand.
- **Debugger**: `/usr/bin/gdb-multiarch`, typed as a plain WSL path. CLion's auto-fill produced
  `\bin\gdb-multiarch` here — Windows-style backslashes and a missing `/usr` — which happened to
  still resolve (green checkmark, version reported), but is not a path worth trusting once things
  get more complicated later. Retype it explicitly. Not CLion's bundled debugger either way — that
  one is built for the host architecture and cannot debug AArch64, the same fact `docs/clion.md`
  §5 states for macOS.
- You may see a note that *"the toolchain Debugger is deprecated, use Debug Profiles instead."*
  That is a newer CLion preference, not an error — safe to ignore for the setup in §5 below.

Then **Settings → Build, Execution, Deployment → Makefile** and select this WSL toolchain.

---

## 3. Indexing: no extra step, most likely

`docs/clion.md` §1 explains that `compile_commands.json` is a byproduct of every `make` build, and
that the database only needs *rewriting* (`scripts/compdb.sh`, `INDEXER=host`) when the paths or
compiler recorded in it do not match what the IDE can see — which happens specifically when the
build ran **inside a container** and the IDE runs **outside it**.

That mismatch does not apply here. A WSL-toolchain build runs `make` natively inside the same WSL
filesystem CLion is reading the project from, so the paths in the database are already correct,
and the compiler path it records — `/usr/bin/aarch64-linux-gnu-g++` — is exactly the binary the WSL
toolchain is configured to call. Build once (`make`, or the IDE's own build action), then
**File → Reload Project** if CLion does not pick up the fresh database automatically.

If files still show as unindexed or `uint64_t` as unknown after that, the fix is the same as
`docs/clion.md` §3: confirm Settings → Toolchains actually points the *C++ Compiler* field at
`aarch64-linux-gnu-g++`, not the native `g++` CLion may have auto-filled.

---

## 4. Run configurations: point CLion at the checked-in scripts

These match the four native, non-container configurations on the Mac
(`build + run (QEMU)`, `run QEMU (native)`, `debug QEMU halted (native)`, `attach to QEMU` — see
`.idea/runConfigurations/` in `docs/clion.md`'s setup, which is git-ignored per developer, so it
cannot simply be copied over). The Windows counterparts live as real files in the repository,
under `scripts/windows/`, because the one fragile, version-dependent part of a Windows Shell
Script configuration is *which interpreter CLion uses to run typed script text* — a detail I
cannot verify without a Windows CLion to test on (see the honesty note at the top). Pointing a
configuration at a checked-in `.cmd` file sidesteps that entirely: Windows always knows how to run
a `.cmd` file directly, regardless of what CLion's interpreter setting defaults to.

Each file has a comment at the top saying what to edit if your distro name (check with
`wsl -l -v` in PowerShell) or clone path differs from the default.

| File | Matches the Mac configuration | What it does |
|---|---|---|
| `scripts/windows/build-and-run-qemu.cmd` | `build + run (QEMU)` | Native `make PROFILE=debug`, then boots it |
| `scripts/windows/run-qemu-native.cmd` | `run QEMU (native)` | Boots whatever is already built |
| `scripts/windows/debug-qemu-halted.cmd` | `debug QEMU halted (native)` | Boots halted, waiting for gdb on `:1234` |
| `scripts/windows/kill-qemu.cmd` | (no Mac CLion configuration; run from a terminal there) | Kills any QEMU left running after a closed window — see §7 |

For each of the first three, **Run → Edit Configurations → `+` → Shell Script**:

- **Name**: matching the table above, e.g. `build + run (QEMU)`.
- **Execute**: switch from *Script text* to *Script path* (the exact wording may read
  *"Execute script file"* instead, depending on CLion version), then **Browse** to the matching
  `.cmd` file under `scripts\windows\`.
- **Execute in terminal**: ticked. This is not optional, for the same reason `docs/clion.md` §4
  gives: QEMU's serial console is interactive, and Ctrl-A then X (the quit sequence) needs a real
  terminal underneath it. In CLion's plain output pane there is no way to send that sequence, and
  QEMU has to be killed instead of quit cleanly.

---

## 5. Debug configuration: attaching to QEMU

Same two-step pattern as `docs/clion.md` §5: one configuration boots QEMU halted, a second one
attaches a debugger to it.

### Step 1 — `debug QEMU halted (native)`

The third Shell Script configuration from §4, pointed at `scripts/windows/debug-qemu-halted.cmd`.
This starts QEMU with the CPU halted, waiting for a debugger on port 1234, and prints the exact
`gdb` command line to the terminal — useful for comparing against what CLion ends up doing.

### Step 2 — `attach to QEMU`

**Run → Edit Configurations → `+` → GDB Remote Debug.**

- **Name**: `attach to QEMU`
- **'target remote' args**: `localhost:1234`
- **Symbol file**: the path to `build/debug/kernel.elf`, as CLion sees it in the project (the
  `\\wsl$\...` path, or `$ProjectFileDir$/build/debug/kernel.elf`).
- **GDB**: this is the part I have not been able to verify without a Windows machine. Two ways it
  is documented to work, try them in this order:
  1. A **"Toolchain"** selector in this dialog, set to the WSL toolchain from §2 — CLion then uses
     that toolchain's configured debugger (`gdb-multiarch`) automatically. This is the intended,
     documented path.
  2. If there is no such selector, or it does not resolve `gdb-multiarch` correctly, the pragmatic
     fallback is the same one `docs/clion.md` §5 gives for macOS: skip the GUI debugger and paste
     the `gdb-multiarch` command line `make debug` already printed into a WSL terminal. You lose
     the GUI, not the ability to debug.
- **Sysroot**: leave empty.
- **Path mappings**: should not be needed. Unlike the container case in `docs/clion.md` §5, there
  is no `/work` versus host split here — the WSL toolchain builds and CLion reads the project from
  the same filesystem, so debug info paths and CLion's project paths already agree.

### Using it

1. Run `debug QEMU halted (native)`. QEMU starts and halts before the first instruction.
2. Run `attach to QEMU`.
3. Set a breakpoint on `kernel_main` and continue.

Debug the **debug profile**, not release, for the reason `docs/clion.md` §5 gives: `-O0` is what
makes stepping match the source line-for-line.

---

## 7. Killing a QEMU left running after a closed window

Same problem `scripts/kill-qemu.sh` solves on macOS (see the comment at the top of that file):
closing a terminal or a WSL window does not stop QEMU running inside it, and this kernel never
halts on its own, so an abandoned run pins a CPU core at 100% indefinitely. The script itself
already works unmodified inside WSL — it is plain, portable bash — so the only thing needed on
Windows is a way to reach it without opening a WSL terminal by hand.

**`scripts/windows/kill-qemu.cmd`** does that. Run it directly — double-click it in Explorer, or
from PowerShell/cmd — whenever a run or debug session was closed rather than quit cleanly with
Ctrl-A X. `kill-qemu.cmd --list` shows what it would kill without killing it.

To reach it from inside CLion the same way as the others, add one more Shell Script configuration
following §4's recipe, named `kill QEMU`, pointed at `scripts/windows/kill-qemu.cmd`. It does not
need **Execute in terminal** ticked — it prints a short report and exits on its own.

---

## 8. If any of this fights you

- **The WSL toolchain does not appear in Settings → Toolchains at all.** This CLion feature has a
  minimum supported version; if it is missing entirely, update CLion. It is not something to work
  around by hand.
- **`wsl.exe` in the Shell Script configuration does nothing visible.** Test the exact same command
  in an ordinary Windows Command Prompt first, outside CLion. If it works there and not inside
  CLion, the fault is the run configuration, not WSL or the kernel.
- **The debugger step is the fragile part**, exactly as flagged in `docs/clion.md` §5. Terminal
  `gdb-multiarch`, CLion as editor only, is not a lesser setup — it is the documented fallback on
  both platforms.
- Tell me what you actually saw at each step and this document gets corrected the way
  `docs/clion.md` section 0 was, from "reasoned" to "verified."
