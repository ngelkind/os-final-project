# ADR 0003 — The serial log decides pass/fail, not an exit code

**Status:** Accepted

## Context

A CI harness needs to turn "the kernel ran" into pass or fail. Two mechanisms exist:

1. **ARM semihosting `SYS_EXIT`** — the kernel asks QEMU to terminate with a status code, which
   could become the process exit status.
2. **Parsing the serial output** the kernel prints.

Semihosting is more elegant: an active signal rather than an inference, and it ends the run
immediately instead of waiting out a timeout.

## Decision

**Log parsing owns the verdict.** Semihosting is implemented as a speed optimisation — it lets a
finished run stop early — but the pass/fail decision is never built on it until its behaviour has
been measured on our pinned QEMU version.

## Consequences

**What we gain.** The verdict does not depend on an unverified assumption. How QEMU maps a
semihosting exit status onto its own process exit code has varied across versions, and a harness
that silently reports success because a status did not propagate is worse than no harness at all.
Parsing also gives richer failure information: which test failed, with what detail, and the last
50 lines of context — none of which an exit code carries.

It also lets the harness catch a failure mode an exit code structurally cannot: **output that
stops partway**. A kernel that crashes after printing a cheerful summary still exits "cleanly" by
any status-code measure. The required `[KTEST] DONE` terminator catches it.

**What we give up.** A parser is coupled to an output format, so the format is a documented
contract ([docs/ci.md § 2.6](../ci.md#26-serial-output-format--what-the-harness-parses)) that
cannot be changed on one side alone. Parsing is also weaker against a kernel that prints something
resembling a summary by accident — mitigated by cross-checking the summary counts against the
per-test lines actually printed.

**What would change our minds.** The M3 experiment showing semihosting exit codes propagating
cleanly and reliably on our pinned QEMU. Even then, log parsing would stay as the primary and the
exit code become corroboration — the extra failure modes it catches are worth keeping.
