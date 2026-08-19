# Getting set up

This walks a brand-new machine to the point where a kernel boots in front of you. It assumes you
have never built an operating system before, and it assumes nothing is installed.

**The whole list of things you install by hand is:**

1. Git
2. Docker
3. An editor

That is it. No cross-compiler, no QEMU, no build tools. Those live inside a container image that
is pulled for you, which is what makes it possible for two people on different operating systems
to get identical results.

**The one-command version, once Docker is running:**

```sh
git clone <repo-url>
cd os-final-project
bash scripts/setup.sh
```

You are set up correctly when that ends with:

```
=============================================================
 YOU ARE SET UP CORRECTLY
=============================================================
```

If the kernel has been written by then, it will also have booted and printed its banner. If it
has not been written yet, the script says so explicitly and still confirms your environment is
good — that is a success, not a failure.

> **Why clone-then-run instead of `curl … | bash`?** So that you, or anyone you hand this to, can
> read `scripts/setup.sh` before trusting it with your machine. It is about 300 lines and it
> installs nothing.

---

## The reference environment

> **The container is the reference environment.** If a native toolchain on your laptop disagrees
> with the container, the container is right and CI agrees with it.

You are allowed — encouraged, even — to install a native cross-compiler and QEMU for speed. Native
builds skip the container layer and feel snappier, and `make` works exactly the same. But when a
native build and a container build disagree, that is not a mystery to debug from both sides: the
container defines truth, because it is bit-for-bit what CI runs.

The practical rule: **develop natively if you like, but reproduce every failure in the container
before reporting it.** Otherwise you will spend an afternoon on a bug that is really a difference
between GCC 13.2 and GCC 13.3.

---

## Windows

Windows development happens **inside WSL2**. There is deliberately no Windows-native build path:
maintaining two of them means the second one is broken half the time and nobody notices until a
deadline.

### 1. WSL2

From an **Administrator** PowerShell:

```powershell
wsl --install -d Ubuntu-24.04
```

Reboot. Ubuntu opens on first launch and asks you to pick a username and password — that password
is your `sudo` password inside Linux, and it is not your Windows password.

Ubuntu 24.04 is specified on purpose: it is the same base as the CI container, so your host
environment matches the reference one.

Verify, from PowerShell:

```powershell
wsl -l -v
```

`VERSION` must be `2`. If it says `1`:

```powershell
wsl --set-version Ubuntu-24.04 2
wsl --set-default-version 2
```

There is a helper that checks all of the above and stops with a specific message if something is
off:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
```

It gets you as far as a working WSL2 and then hands over — everything past that point runs inside
Linux.

### 2. Docker inside WSL

Two options. **Docker Engine inside WSL** is recommended: fewer moving parts, no separate
desktop application, and no licensing questions.

Inside WSL:

```sh
sudo apt-get update
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
```

Then make the daemon start by itself, by enabling systemd:

```sh
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
```

And from **PowerShell** (not from inside WSL):

```powershell
wsl --shutdown
```

Reopen WSL. That restart does two jobs at once: it activates systemd, and it starts a fresh login
session so your new `docker` group membership takes effect. Group membership is captured when a
session begins, which is why adding yourself to a group never affects the shell you are already in.

Check:

```sh
systemctl is-active docker     # should print: active
docker run --rm hello-world    # should print a greeting, no sudo needed
```

The alternative is **Docker Desktop for Windows** with the WSL2 backend enabled. That also works;
`scripts/setup.sh` accepts either.

### 3. Clone into the Linux filesystem

**This is a requirement, not a tip.**

```sh
mkdir -p ~/projects && cd ~/projects
git clone <repo-url>
cd os-final-project
bash scripts/setup.sh
```

Clone into `~/`, **never** into `/mnt/c/...`. A repository under `/mnt/c` lives on the Windows
drive and every file access crosses the WSL filesystem bridge. Consequences:

- Builds run **several times slower** — often 5–10× on a compile-heavy tree.
- File watching is unreliable, so editors and incremental builds miss changes.
- The git executable bit does not persist, so `./scripts/run.sh` stops working.

`scripts/setup.sh` warns if it detects this. Set `STRICT_LOCATION=1` to make it a hard error.

To reach your files from Windows tools, use the `\\wsl$` path (it appears in Explorer as a network
location) or your editor's WSL remote mode. Do not "fix" the slowness by moving the repo back.

---

## macOS

### Apple Silicon (M1–M4)

```sh
# Git — usually already present; this installs the Command Line Tools if not.
xcode-select --install
```

Install **Docker Desktop for Mac, Apple Chip build**:
https://www.docker.com/products/docker-desktop/

Choosing the Apple Chip build matters. The toolchain image is published for `linux/arm64` as well
as `linux/amd64` specifically so that your Mac pulls a native image. If you end up on the amd64
image, the entire toolchain runs under x86 emulation *while QEMU inside it is already emulating
AArch64* — two stacked layers, on every compile, all day. `scripts/setup.sh` prints which
architecture it actually pulled and warns if it is the wrong one.

Then:

```sh
git clone <repo-url>
cd os-final-project
bash scripts/setup.sh
```

### Intel Mac

Identical, with the Intel build of Docker Desktop. You will pull the `linux/amd64` image, which is
the same one CI uses.

### If you want a native toolchain too (optional, for speed)

```sh
brew install qemu
brew install --cask gcc-aarch64-embedded   # or another aarch64 cross toolchain
```

Note the caveat above: native is for speed, the container is for truth. Also note the native
compiler will be a different build from the container's, so `-Werror` may fire on something CI
does not see (or miss something CI catches). That is expected.

---

## Linux

```sh
sudo apt-get update
sudo apt-get install -y git docker.io
sudo usermod -aG docker $USER
sudo systemctl enable --now docker
```

Log out and back in for the group change, then:

```sh
git clone <repo-url>
cd os-final-project
bash scripts/setup.sh
```

---

## If the package is private

The toolchain image is published as a **public** package, so no login is needed. If that ever
changes, `docker pull` will fail with `denied` or `unauthorized`, and you will need a token:

1. Create a personal access token (classic) with the **`read:packages`** scope at
   https://github.com/settings/tokens
2. ```sh
   echo "$GITHUB_PAT" | docker login ghcr.io -u <your-github-username> --password-stdin
   ```

This is exactly the twenty-minute detour that keeping the package public avoids, which is why it
is public. See `docs/ci.md` section 5 for the reasoning.

---

## Mixed-OS gotchas

This team spans macOS, Windows/WSL and Linux CI. The bugs below share one nasty property: they are
**invisible on the machine that introduced them and fatal on someone else's**. The person who
caused it cannot reproduce it; the person who hit it cannot explain it. `scripts/check-hygiene.sh`
checks for all of them, and CI runs it on every pull request.

Run it yourself any time:

```sh
bash scripts/check-hygiene.sh
```

### A. Line endings — the one that will actually bite you

Windows tools like to save files with CRLF (`\r\n`) line endings; Linux and macOS use LF (`\n`).
A shell script committed with CRLF fails inside the Linux container as:

```
bash: ./scripts/setup.sh: /bin/bash^M: bad interpreter: No such file or directory
```

That message names neither the real problem nor how to fix it, and the file looks completely
normal in every editor.

`.gitattributes` prevents it by forcing LF for all tracked text files. You do not need to
configure anything personally — but if you ever see a `^M` in an error message, this is what it
means. CI fails the build if any tracked file has CRLF in the index.

If it ever happens:

```sh
git add --renormalize .
git commit -m "fix: normalise line endings to LF"
```

### B. Filename case

macOS and Windows filesystems are case-**insensitive** by default. Linux is case-**sensitive**.

So `#include "Uart.h"` when the file is really `uart.h` compiles perfectly on both laptops and
fails only in CI. Worse, two files whose names differ only in case (`Uart.h` and `uart.h`) can
both exist in the repository and on CI, but **cannot** both exist in a checkout on either laptop —
one silently overwrites the other and git reports a permanently dirty tree that no amount of
`git checkout` fixes.

**Convention: `lowercase_with_underscores` for all filenames.** `pmm_bitmap.cpp`, not
`PmmBitmap.cpp`. If every name is lowercase, this entire class of bug cannot occur.

CI checks both directions: include-case mismatches, and case-only path collisions.

### C. The executable bit

Git tracks whether a file is executable. Files committed from Windows can lose that bit, and then
`./scripts/run.sh` fails with "permission denied" for one person and works for everyone else.

Two defences, both in place:

1. Scripts are committed with the bit set (`git update-index --chmod=+x`), and CI verifies it.
2. **Every documented command invokes scripts as `bash scripts/foo.sh`**, which works whether or
   not the bit survived. Follow that style when you write documentation or CI steps.

### D. Where the repository lives (Windows only)

Covered above, and worth repeating because the symptom is "everything is just slow" rather than an
error: clone into `~/` inside WSL, never `/mnt/c/`.

### E. Container architecture

The image is built for `linux/amd64` **and** `linux/arm64`, so everyone runs it natively — CI on
amd64, the Apple Silicon Mac on arm64.

The important part is what does *not* change:

> **The emulated guest is always `aarch64` under TCG, on every host.** We force `-accel tcg` and
> never use KVM, even on an arm64 host where it would be available. So the machine the kernel runs
> on is identical everywhere. Host architecture affects build speed only.

Corollary, and it matters: **a bug that reproduces on only one host architecture is a real
finding.** Since the guest is identical, such a divergence points at the toolchain or the harness,
both of which are worth understanding. Do not wave it away as "works on mine".

---

## Everyday commands

All of these work identically on every platform.

```sh
make                    # build the debug profile
make PROFILE=release    # build optimised
make run                # boot the kernel (Ctrl-A then X to quit)
make debug              # boot halted, waiting for gdb on :1234
make test               # host unit tests + in-kernel tests
make format             # apply clang-format
make help               # every target
```

To work inside the container exactly the way CI does:

```sh
source scripts/toolchain.env
docker run --rm -it -v "$PWD":/work -w /work "$IMAGE" bash
```

To check what the reference toolchain actually is:

```sh
docker run --rm "$IMAGE" cat /etc/toolchain-versions.txt
```

---

## When something goes wrong

1. **Read the error.** `scripts/setup.sh` distinguishes between the docker binary missing, the
   daemon not running, and your user lacking permission — three completely different problems that
   all look like "Docker is broken". Each message says exactly what to do.
2. **Reproduce it in the container** before concluding it is a code bug.
3. **For a kernel that misbehaves**, the serial log is the evidence. Locally it is at
   `build/serial.log`; in CI it is an artifact attached to the run, uploaded even when the job
   fails.
4. **For a red CI run**, the failing job prints the exact `docker run …` command to reproduce it
   on your machine.
