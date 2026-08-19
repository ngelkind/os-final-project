# ADR 0002 — GNU Make, not CMake

**Status:** Accepted

## Context

The project needs an out-of-tree build with dependency tracking, two optimisation profiles, a
test-selecting define, and a custom linker script. CLion — the primary IDE — prefers CMake.

## Decision

**GNU Make**, in a single commented Makefile.

## Consequences

**What we gain.** The entire build is readable top to bottom in one sitting, and every flag
carries a comment explaining why it exists. That matters more than usual here: the project is
graded on justified design decisions, and a build system nobody can read is a set of decisions
nobody can defend. Bare-metal cross-compilation is also simply more direct in Make — CMake needs a
toolchain file plus `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` to stop it validating the
compiler by linking a hosted executable, which is exactly the kind of incidental complexity that
teaches nothing.

**What we give up.** CLion's first-class integration. Its Makefile support infers flags by parsing
a dry run, and our heavy use of variables makes that inference imperfect. Mitigated by generating
`compile_commands.json` (`make compdb`), which records the real invocations — see
[docs/clion.md](../clion.md).

**What would change our minds.** Needing to build for multiple targets with genuinely different
source sets, or the IDE integration becoming a daily obstacle rather than a one-time setup cost.

Not chosen by default: chosen because a student kernel does not need a meta-build system, and the
mentor should be able to read the whole build in one screen.
