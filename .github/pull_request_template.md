## What changed

<!-- One or two sentences. The diff says what; say why. -->

## Subsystem

<!-- Tick what this touches. -->

- [ ] `boot`   — early startup, entry, stack, .bss
- [ ] `uart`   — serial driver
- [ ] `pmm`    — physical memory
- [ ] `vmm`    — virtual memory / paging
- [ ] `irq`    — interrupts / exception vectors
- [ ] `sched`  — scheduling
- [ ] `syscall`
- [ ] build / CI / container / docs (scaffolding, not kernel)

## How it was tested

<!-- Be specific. "It builds" is not a test. -->

- [ ] Booted locally under QEMU and observed the expected behaviour
- [ ] Host unit tests pass (`make test-host`)
- [ ] In-kernel tests pass (`make test-qemu`)
- [ ] Built both profiles (`make PROFILE=debug` and `make PROFILE=release`)

<!-- If a failure was involved, paste the relevant serial log lines. -->

## Does this need a new kernel test?

<!--
Answer honestly, including "no, because ...". New behaviour that is pure logic
belongs in tests/host (fast, no emulator). Behaviour that only exists on real
hardware state belongs in tests/kernel.

If the answer is "yes but not in this PR", say so and open an issue.
-->

- [ ] Yes — added in this PR
- [ ] Yes — deliberately deferred, tracked at: <!-- issue link -->
- [ ] No — because: <!-- reason -->

## Design decisions worth reviewing

<!--
Anything you weighed and chose. This project is graded on justified decisions,
and this is the cheapest place to record one. Delete the section if genuinely
nothing applies -- but that should be rare.
-->
