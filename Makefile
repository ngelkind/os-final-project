# =============================================================================
#  Kernel build system
# =============================================================================
#
#  Rule for this file: every compiler and linker flag carries a comment saying
#  WHY it is here. A flag you cannot justify is a flag you cargo-culted, and
#  this project is graded on justified decisions. If you add one, explain it.
#
#  The interface contract between this build system and the kernel sources --
#  entry symbol, linker script path, required symbols, defines -- is written
#  down in docs/ci.md. This Makefile is one half of that contract; do not
#  change the contract here without changing it there.
#
#  Quick reference:
#      make                     build the debug profile
#      make PROFILE=release     build optimised
#      make KERNEL_TESTS=1      build with the in-kernel test suite compiled in
#      make run                 boot it in QEMU
#      make debug               boot it halted, waiting for gdb
#      make info                print the resolved configuration
# =============================================================================

# Do not let Make's built-in rules (for .c, .o, yacc, SCCS...) interfere. In a
# freestanding build an implicit rule firing with the *host* compiler produces
# an object file that links but is subtly wrong for the target.
MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

# If a recipe fails partway, delete the half-written target. Otherwise a failed
# link leaves a stale kernel.elf that the next `make run` happily boots.
.DELETE_ON_ERROR:

# -----------------------------------------------------------------------------
#  1. Configuration
# -----------------------------------------------------------------------------

# The target architecture is ONE variable, deliberately. The brief says the
# architecture is not fully locked; if this project moves to x86_64, this line
# and CROSS_COMPILE below are what change -- not twenty scattered assumptions.
ARCH ?= aarch64

# Which cross-toolchain to invoke. See docs/ci.md for why we use the
# Linux-targeted cross compiler rather than a bare-metal *-none-elf one.
CROSS_COMPILE ?= $(ARCH)-linux-gnu-

# debug   : -O0, everything observable, what you develop and gdb against
# release : -O2, what a real build looks like
# CI builds BOTH, because optimisation level changes which bugs are visible:
# missing `volatile` on MMIO, reads of uninitialised memory, and undefined
# behaviour the optimiser is entitled to exploit all tend to appear only at -O2.
PROFILE ?= debug

# 1 => compile the in-kernel test suite into the image (see docs/ci.md).
KERNEL_TESTS ?= 0

# Turn linker warnings into errors. Off by default because early linker-script
# work produces warnings that are noise while you are still shaping the script;
# CI can enable it once the script has settled.
STRICT_LINK ?= 0

BUILD_ROOT ?= build

ifeq ($(filter $(PROFILE),debug release),)
$(error PROFILE must be 'debug' or 'release', got '$(PROFILE)')
endif

ifeq ($(filter $(KERNEL_TESTS),0 1),)
$(error KERNEL_TESTS must be 0 or 1, got '$(KERNEL_TESTS)')
endif

# Each configuration gets its own output directory so that a debug build and a
# release build can coexist. CI builds both in the same workspace; a single
# flat build/ would let one silently overwrite the other, which would quietly
# defeat the entire point of testing two profiles.
BUILD_DIR := $(BUILD_ROOT)/$(PROFILE)$(if $(filter 1,$(KERNEL_TESTS)),-ktests)
OBJ_DIR   := $(BUILD_DIR)/obj

KERNEL_ELF := $(BUILD_DIR)/kernel.elf
KERNEL_IMG := $(BUILD_DIR)/kernel.img
KERNEL_MAP := $(BUILD_DIR)/kernel.map

# -----------------------------------------------------------------------------
#  2. Toolchain
# -----------------------------------------------------------------------------
# .S files are driven through the g++ front end rather than `as` directly, so
# that the C preprocessor runs on them: assembly can then #include the same
# headers as C++ and share constants instead of duplicating magic numbers.
CXX     := $(CROSS_COMPILE)g++
AS      := $(CROSS_COMPILE)g++
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump
SIZE    := $(CROSS_COMPILE)size

# -----------------------------------------------------------------------------
#  3. Interface contract with the kernel sources  (see docs/ci.md)
# -----------------------------------------------------------------------------
# These four lines are the entire surface between the scaffolding and the
# kernel. Everything else is discovered automatically.
LDSCRIPT     := linker/kernel.ld
ENTRY_SYMBOL := _start
SRC_DIRS     := boot src
INC_DIRS     := include

ifeq ($(KERNEL_TESTS),1)
SRC_DIRS += tests/kernel
endif

# Sources are discovered, not listed: adding a file to src/ must never require
# editing this Makefile (that is a merge conflict generator for two developers).
#
# The sort is not cosmetic. Link order determines the layout of the final
# image, and `find` returns entries in filesystem order, which differs between
# machines. Sorting makes the link order deterministic, which is what makes
# byte-identical builds across your laptop and CI achievable at all.
ASM_SRCS := $(shell find $(SRC_DIRS) -name '*.S' 2>/dev/null | LC_ALL=C sort)
CXX_SRCS := $(shell find $(SRC_DIRS) -name '*.cpp' 2>/dev/null | LC_ALL=C sort)

OBJS := $(patsubst %.S,$(OBJ_DIR)/%.S.o,$(ASM_SRCS)) \
        $(patsubst %.cpp,$(OBJ_DIR)/%.cpp.o,$(CXX_SRCS))
DEPS := $(OBJS:.o=.d)

# -----------------------------------------------------------------------------
#  4. Preprocessor defines
# -----------------------------------------------------------------------------
DEFINES := -DKERNEL_TESTS=$(KERNEL_TESTS)

ifeq ($(PROFILE),release)
# Standard convention: NDEBUG means "this is an optimised build". Documented in
# docs/ci.md so it is not a surprise -- if your assert macro keys off it, it
# disappears in release, which is intended but must be a conscious choice.
DEFINES += -DNDEBUG
endif

# -----------------------------------------------------------------------------
#  5. Compiler flags -- the part worth reading
# -----------------------------------------------------------------------------
WARNINGS := \
  -Wall -Wextra \
  -Werror

# -Werror rationale: in kernel code the warnings that matter most (uninitialised
# use, type mismatch across an ABI boundary, unused result) do not produce a
# crash at the point of the mistake. They produce a crash three subsystems
# later. A warning you can ignore is a warning you will ignore.

FREESTANDING := \
  -ffreestanding \
  -fno-builtin

# -ffreestanding : there is no operating system underneath us and no C library.
#                  It tells the compiler not to assume the hosted environment
#                  exists -- e.g. that main() has special meaning, or that the
#                  standard library functions behave as specified.
# -fno-builtin   : stops GCC from replacing a call with its own inlined idea of
#                  what that function does. Without it, GCC can recognise your
#                  hand-written string routine and "optimise" it into a call to
#                  the very function you are implementing -- an infinite loop.
#
# NOTE: even with both of these, GCC is still permitted to emit calls to
# memcpy/memset/memmove/memcmp for things like struct assignment and array
# initialisation. Those four symbols must exist in the kernel. See docs/ci.md.

CXX_LANG := \
  -std=c++20 \
  -fno-exceptions \
  -fno-rtti \
  -fno-threadsafe-statics \
  -fno-use-cxa-atexit

# -std=c++20      : pinned explicitly. The compiler's default standard changes
#                   between GCC releases, and "the language changed under us on
#                   a toolchain upgrade" is not a debugging session anyone wants.
# -fno-exceptions : exceptions need unwind tables and a runtime personality
#                   routine that does not exist here; a throw would jump into
#                   nothing. Disabling makes the absence a compile error rather
#                   than a runtime mystery.
# -fno-rtti       : dynamic_cast/typeid need runtime type structures we do not
#                   emit. Also saves image size.
# -fno-threadsafe-statics : a function-local static would otherwise be guarded
#                   by __cxa_guard_acquire/release, which do not exist. We are
#                   single-core for now, so the guard buys nothing anyway.
# -fno-use-cxa-atexit : registering destructors for static objects requires
#                   __cxa_atexit and __dso_handle. A kernel never exits, so
#                   those destructors would never run regardless.

HARDENING_OFF := \
  -fno-stack-protector

# -fno-stack-protector : the stack protector emits a check against a canary
#                        held in thread-local storage that the C library sets
#                        up. There is no C library, so the check reads garbage
#                        and every function fails it.

TARGET_FLAGS := \
  -mgeneral-regs-only \
  -fno-pie

# -mgeneral-regs-only : THE one to understand. AArch64 has SIMD/FP registers
#                       (v0-v31), and the compiler will happily use them to
#                       speed up ordinary code -- copying a struct, say. But
#                       after reset, access to the FPU/SIMD unit is TRAPPED
#                       (CPACR_EL1.FPEN) until the kernel explicitly enables
#                       it. So the compiler emits a perfectly reasonable
#                       instruction that traps, and you get a fault at an
#                       address that has nothing obviously to do with floats.
#                       This flag forbids the compiler from touching those
#                       registers at all. Remove it only for code compiled
#                       after you have enabled the FPU -- and if you ever
#                       enable it, note that context switching must then save
#                       and restore those registers too.
#
# -fno-pie            : Ubuntu's cross-GCC is built with --enable-default-pie,
#                       so it generates position-independent code by default.
#                       PIC/PIE assumes a dynamic loader will apply relocations
#                       at load time; nothing does that for us. We link at a
#                       fixed physical address, so we want plain absolute code.

REPRODUCIBILITY := \
  -ffile-prefix-map=$(CURDIR)=.

# -ffile-prefix-map : embeds relative rather than absolute source paths in the
#                     debug info. Without it the same source built in
#                     /home/you/os and in /work inside the container produces
#                     different bytes, and "byte-identical builds" becomes
#                     unachievable for a reason that has nothing to do with the
#                     code.

DEPFLAGS := -MMD -MP

# -MMD : emit a .d file listing the headers each object depends on, so editing
#        a header rebuilds exactly what included it.
# -MP  : also emit a phony target for each header, so deleting or renaming a
#        header does not break the build with "no rule to make target".

# Profile-specific optimisation.
ifeq ($(PROFILE),debug)
OPTFLAGS := -O0
# -O0: variables live where the source says they live and statements execute in
#      source order, so single-stepping in gdb matches what you wrote. At -O2
#      gdb appears to jump around at random and locals read as <optimized out>.
else
OPTFLAGS := -O2
# -O2: the realistic build. Also a bug-finding tool in its own right -- see the
#      PROFILE comment above.
endif

# -g in both profiles: debug info costs nothing at runtime (it is not loaded
# into the image) and having symbols for a release-profile crash is invaluable.
DEBUGINFO := -g

INCLUDES := $(addprefix -I,$(INC_DIRS))

CXXFLAGS := $(OPTFLAGS) $(DEBUGINFO) $(WARNINGS) $(FREESTANDING) $(CXX_LANG) \
            $(HARDENING_OFF) $(TARGET_FLAGS) $(REPRODUCIBILITY) $(DEPFLAGS) \
            $(INCLUDES) $(DEFINES)

# Assembler flags are a deliberate subset: passing C++-only options such as
# -std=c++20 or -fno-rtti to an assembly translation unit makes GCC complain
# that the option is not valid for this language, and -Werror turns that
# complaint into a failed build.
ASFLAGS := $(DEBUGINFO) $(WARNINGS) $(FREESTANDING) $(TARGET_FLAGS) \
           $(REPRODUCIBILITY) $(DEPFLAGS) $(INCLUDES) $(DEFINES)

# -----------------------------------------------------------------------------
#  6. Linker flags
# -----------------------------------------------------------------------------
# We link through the g++ driver rather than calling ld directly, so that it
# can find libgcc for us (see LDLIBS).
LDFLAGS := \
  -nostdlib \
  -nostartfiles \
  -no-pie \
  -Wl,-T,$(LDSCRIPT) \
  -Wl,-Map,$(KERNEL_MAP) \
  -Wl,--build-id=none \
  -Wl,--orphan-handling=warn

# -nostdlib      : do not link the C library or the standard startup files.
# -nostartfiles  : specifically, no crt0/crt1 -- there is no C runtime to set up
#                  a stack and call main(). Our entry point is $(ENTRY_SYMBOL)
#                  in the boot assembly, and it runs on a stack the boot code
#                  establishes itself.
# -no-pie        : the link-time counterpart of -fno-pie above.
# -T             : use OUR linker script. This is the file that decides where
#                  the kernel lands in physical memory and how sections are
#                  laid out -- for a bare-metal image it is as much a part of
#                  the program as any source file.
# -Map           : produce a map file. When a symbol ends up at an unexpected
#                  address, or the image is mysteriously 4 MB, the map answers
#                  it in seconds.
# --build-id=none: suppresses the .note.gnu.build-id section. It is metadata
#                  for package managers, it has no place in a kernel image, and
#                  as an orphan section it can be placed somewhere awkward and
#                  inflate the flat binary.
# --orphan-handling=warn : warn when a section exists in the objects but the
#                  linker script does not explicitly place it. This is a real
#                  teaching aid: forgetting to place .rodata means your string
#                  literals silently vanish from the image, and the symptom is
#                  a UART that prints nothing.

ifeq ($(STRICT_LINK),1)
LDFLAGS += -Wl,--fatal-warnings
endif

# libgcc provides the compiler's own helper routines -- 128-bit arithmetic,
# some shifts and divides -- that GCC emits calls to rather than open-coding.
# It is part of the compiler, not the C library, so linking it does not
# reintroduce a hosted environment.
LDLIBS := -lgcc

# -----------------------------------------------------------------------------
#  7. Build rules
# -----------------------------------------------------------------------------
.PHONY: all
all: $(KERNEL_ELF) $(KERNEL_IMG) $(BUILD_DIR)/size.txt $(BUILD_DIR)/sections.txt \
     compdb-update

$(KERNEL_ELF): $(OBJS) $(LDSCRIPT) | check-sources check-toolchain
	@mkdir -p $(@D)
	@echo "  LD      $@"
	$(CXX) $(LDFLAGS) $(OBJS) -o $@ $(LDLIBS)

# The flat binary: the ELF with its headers and debug info stripped away,
# leaving only the bytes that belong in memory. Kept because some boot paths
# want a raw image rather than an ELF, and because its size is the honest
# answer to "how big is the kernel".
$(KERNEL_IMG): $(KERNEL_ELF)
	@echo "  OBJCOPY $@"
	$(OBJCOPY) -O binary $< $@

$(OBJ_DIR)/%.cpp.o: %.cpp | check-toolchain
	@mkdir -p $(@D)
	@echo "  CXX     $<"
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OBJ_DIR)/%.S.o: %.S | check-toolchain
	@mkdir -p $(@D)
	@echo "  AS      $<"
	$(AS) $(ASFLAGS) -c $< -o $@

# Size and section reports. CI uploads these as artifacts so we can watch the
# kernel grow over the project and notice a section appearing where it should
# not be.
$(BUILD_DIR)/size.txt: $(KERNEL_ELF)
	@$(SIZE) $< > $@
	@cat $@

$(BUILD_DIR)/sections.txt: $(KERNEL_ELF)
	@$(OBJDUMP) -h $< > $@

# -----------------------------------------------------------------------------
#  8. Guards -- fail with an explanation, not a stack of tool errors
# -----------------------------------------------------------------------------
.PHONY: check-toolchain
check-toolchain:
	@command -v $(CXX) >/dev/null 2>&1 || { \
	  echo ""; \
	  echo "error: cross compiler '$(CXX)' not found on PATH."; \
	  echo ""; \
	  echo "  Install it (Ubuntu/WSL):"; \
	  echo "    sudo apt-get install -y g++-aarch64-linux-gnu"; \
	  echo ""; \
	  echo "  Or build inside the pinned container instead -- see README.md."; \
	  echo ""; \
	  exit 1; }

# The linker script is a normal prerequisite of the ELF, so Make tries to
# resolve it BEFORE any order-only guard runs. Without this rule the failure
# mode is a bare "No rule to make target 'linker/kernel.ld'", which says
# nothing about whose file it is or what it must contain. This rule replaces
# that with a pointer to the contract. If the file exists, this rule has no
# prerequisites and never fires.
$(LDSCRIPT):
	@echo ""; \
	 echo "error: linker script '$@' does not exist."; \
	 echo "       This file is part of the kernel, not the build scaffolding,"; \
	 echo "       so it is yours to write."; \
	 echo ""; \
	 echo "       docs/ci.md -> 'Interface contract' states exactly what it"; \
	 echo "       must place, where, and which symbols it must export."; \
	 echo ""; \
	 exit 1

.PHONY: check-sources
check-sources:
	@test -f $(LDSCRIPT) || { \
	  echo ""; \
	  echo "error: linker script '$(LDSCRIPT)' does not exist."; \
	  echo "       This file is part of the kernel, not the build scaffolding."; \
	  echo "       See docs/ci.md -> 'Interface contract' for what it must define."; \
	  echo ""; \
	  exit 1; }
	@test -n "$(strip $(OBJS))" || { \
	  echo ""; \
	  echo "error: no kernel sources found under: $(SRC_DIRS)"; \
	  echo "       Expected *.S and/or *.cpp files."; \
	  echo "       See docs/ci.md -> 'Interface contract'."; \
	  echo ""; \
	  exit 1; }

# -----------------------------------------------------------------------------
#  9. Running
# -----------------------------------------------------------------------------
# KERNEL is passed explicitly so the scripts boot the profile we just built
# rather than whatever their default happens to point at. The FLAGS themselves
# come from scripts/qemu-flags.sh and from nowhere else.
.PHONY: run
run: $(KERNEL_ELF)
	@KERNEL=$(KERNEL_ELF) ./scripts/run.sh

.PHONY: debug
debug: $(KERNEL_ELF)
	@KERNEL=$(KERNEL_ELF) ./scripts/debug.sh

# Closing a CLion terminal tab does not kill the QEMU running in it -- the
# process is reparented to launchd and, because this kernel never halts, keeps
# a host core pinned at 100% forever. Recover with this.
.PHONY: kill-qemu
kill-qemu:
	@./scripts/kill-qemu.sh

.PHONY: list-qemu
list-qemu:
	@./scripts/kill-qemu.sh --list

# -----------------------------------------------------------------------------
#  10. Tests  (wired up in M3/M4 -- see docs/ci.md)
# -----------------------------------------------------------------------------
.PHONY: test test-host test-qemu
test: test-host test-qemu

test-host:
	@echo "make test-host: not wired yet -- arrives in M4."
	@echo "  It will build tests/host/ with the NATIVE compiler and run it."
	@exit 1

test-qemu:
	@echo "make test-qemu: not wired yet -- arrives in M3/M4."
	@echo "  It will build with KERNEL_TESTS=1 and run scripts/run-tests.sh."
	@exit 1

# -----------------------------------------------------------------------------
#  11. Formatting
# -----------------------------------------------------------------------------
CLANG_FORMAT ?= clang-format
FORMAT_DIRS  := boot src include tests
FORMAT_FILES  = $(shell find $(FORMAT_DIRS) \
                  \( -name '*.cpp' -o -name '*.hpp' -o -name '*.h' -o -name '*.c' \) \
                  2>/dev/null | LC_ALL=C sort)

# NOTE: the emptiness check and the action MUST live in one recipe line. Each
# recipe line runs in its own shell, so an `exit 0` on the first line only ends
# that shell -- the next line would still run clang-format with no arguments,
# which fails. (Found by running it; the first version of this target had
# exactly that bug.)
.PHONY: format
format:
	@if [ -z "$(strip $(FORMAT_FILES))" ]; then \
	   echo "nothing to format yet"; \
	 else \
	   $(CLANG_FORMAT) -i $(FORMAT_FILES); \
	 fi

# What CI runs. --dry-run + --Werror reports a nonzero exit on any file that
# would change, without touching the working tree.
.PHONY: format-check
format-check:
	@if [ -z "$(strip $(FORMAT_FILES))" ]; then \
	   echo "nothing to check yet"; \
	 else \
	   $(CLANG_FORMAT) --dry-run --Werror $(FORMAT_FILES); \
	 fi

# -----------------------------------------------------------------------------
#  12. IDE support
# -----------------------------------------------------------------------------
# compile_commands.json records the exact compiler invocation for every file,
# which is what lets an IDE index freestanding cross-compiled code correctly
# instead of falling back on the host compiler's headers. See docs/clion.md.
#
# It is generated as a BYPRODUCT OF THE BUILD, not by a separate command you
# have to remember. Each compile rule writes a one-entry fragment next to its
# object file, and the stitch rule below concatenates the fragments belonging
# to the current source list. That has three properties worth the machinery:
#
#   * Automatic. Adding a source file or changing a flag updates the database
#     on the next build, from any entry point. A stale index was the single
#     most common cause of "this file does not belong to any project target".
#   * Incremental. The earlier `bear`-based version had to `make clean` first,
#     because bear can only record compilers it actually watched run, and an
#     up-to-date object runs nothing. Fragments persist, so no forced rebuild.
#   * Honest. The fragment is written by the same recipe that runs the
#     compiler, from the same variables. It cannot drift from the real build,
#     which is the only property that made bear worth using in the first place.
#
# Deleting a source file is handled too: the stitch iterates $(OBJS), so an
# orphaned fragment for a file that no longer exists is simply not included.
#
# Not committed: it contains absolute paths that differ per machine.

COMPDB_JSON  := compile_commands.json
COMPDB_FRAGS := $(OBJS:.o=.o.json)

# 1 => maintain compile_commands.json during the build. Set COMPDB=0 for a
# build that must not touch the working tree (CI does not need an IDE index).
COMPDB ?= 1

# The paths recorded here are $(CURDIR)-relative, and the IDE reads the file
# from OUTSIDE the container that wrote it. So $(CURDIR) has to be a path that
# also exists on the host. scripts/compdb.sh guarantees this by bind-mounting
# the repo at its own host path, and CLion's Docker toolchain does the same by
# default. A build under the /work convention printed by scripts/setup.sh would
# instead record /work/src/... -- paths that resolve to nothing on the host,
# producing exactly the "does not belong to any project target" failure this
# is meant to prevent. Rather than silently overwriting a good database with a
# useless one, such a build skips the index and says so.
COMPDB_PORTABLE := $(if $(filter /work,$(CURDIR)),,1)

# $(call compdb-fragment,object,source,full command line)
#
# Written with printf and sed rather than a JSON library because this runs
# inside the toolchain container, and the container is not required to have
# python. Backslashes and quotes are escaped; a flag containing a literal
# space would still be split, which no flag in this Makefile does.
#
# The compiler (first word) is resolved to an absolute path. The IDE EXECUTES
# it to learn its builtin macros and system header search path, and it does
# not necessarily do so with the same PATH the build had; a bare
# aarch64-linux-gnu-g++ is a "Cannot find compiler executable" waiting to
# happen. See docs/clion.md section 1.
ifeq ($(COMPDB)$(COMPDB_PORTABLE),11)
define compdb-fragment
@{ printf '{"directory":"%s","file":"%s","output":"%s","arguments":[' \
        '$(CURDIR)' '$(CURDIR)/$(2)' '$(CURDIR)/$(1)'; \
   sep=''; \
   for a in $(3); do \
       if [ -z "$$sep" ]; then a="$$(command -v "$$a" || printf '%s' "$$a")"; fi; \
       printf '%s"%s"' "$$sep" \
           "$$(printf '%s' "$$a" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; \
       sep=','; \
   done; \
   printf ']}'; } > $(1).json
endef
else
compdb-fragment =
endif

# The fragment is a real target derived from the source, NOT a side effect of
# compiling. That distinction matters twice: a fragment missing for an
# already-up-to-date object is regenerated without forcing a recompile, and a
# file that does not compile yet still gets indexed -- which is exactly when
# an IDE index is most valuable. The Makefile is a prerequisite because it is
# where the flags live, so changing a flag refreshes every entry.
$(OBJ_DIR)/%.cpp.o.json: %.cpp Makefile
	@mkdir -p $(@D)
	$(call compdb-fragment,$(OBJ_DIR)/$*.cpp.o,$<,$(CXX) $(CXXFLAGS) -c $< -o $(OBJ_DIR)/$*.cpp.o)

$(OBJ_DIR)/%.S.o.json: %.S Makefile
	@mkdir -p $(@D)
	$(call compdb-fragment,$(OBJ_DIR)/$*.S.o,$<,$(AS) $(ASFLAGS) -c $< -o $(OBJ_DIR)/$*.S.o)

.PHONY: compdb-update
compdb-update: $(COMPDB_FRAGS)
ifeq ($(COMPDB)$(COMPDB_PORTABLE),11)
	@{ printf '[\n'; first=1; \
	   for f in $(COMPDB_FRAGS); do \
	       [ -f "$$f" ] || continue; \
	       [ "$$first" = 1 ] || printf ',\n'; first=0; \
	       printf '  '; cat "$$f"; \
	   done; \
	   printf '\n]\n'; } > $(COMPDB_JSON)
else ifneq ($(COMPDB),1)
	@:
else
	@echo "  note    compile_commands.json not updated: \$$(CURDIR) is $(CURDIR),"
	@echo "          which does not exist on the host running the IDE."
	@echo "          Use scripts/compdb.sh, which mounts the repo at its host path."
endif

# Kept as a named entry point because docs and muscle memory refer to it, and
# because scripts/compdb.sh drives the build through it. It is now just a
# build: the database falls out of `all`.
.PHONY: compdb
compdb: all
	@echo "wrote compile_commands.json"

# -----------------------------------------------------------------------------
#  13. Housekeeping
# -----------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf $(BUILD_ROOT)

# Prints the configuration this invocation resolved to. CI runs this first, so
# that every log begins with an unambiguous record of what was built and how.
.PHONY: info
info:
	@echo "ARCH          = $(ARCH)"
	@echo "CROSS_COMPILE = $(CROSS_COMPILE)"
	@echo "PROFILE       = $(PROFILE)"
	@echo "KERNEL_TESTS  = $(KERNEL_TESTS)"
	@echo "STRICT_LINK   = $(STRICT_LINK)"
	@echo "BUILD_DIR     = $(BUILD_DIR)"
	@echo "LDSCRIPT      = $(LDSCRIPT)"
	@echo "ENTRY_SYMBOL  = $(ENTRY_SYMBOL)"
	@echo "ASM_SRCS      = $(ASM_SRCS)"
	@echo "CXX_SRCS      = $(CXX_SRCS)"
	@echo "CXXFLAGS      = $(CXXFLAGS)"
	@echo "ASFLAGS       = $(ASFLAGS)"
	@echo "LDFLAGS       = $(LDFLAGS)"
	@echo "LDLIBS        = $(LDLIBS)"

.PHONY: help
help:
	@echo "Targets:"
	@echo "  all           build kernel.elf + kernel.img   (default)"
	@echo "  run           boot the kernel in QEMU"
	@echo "  debug         boot halted, waiting for gdb on :1234"
	@echo "  list-qemu     show stray QEMU instances left by closed terminals"
	@echo "  kill-qemu     kill them"
	@echo "  test          host unit tests + in-kernel tests under QEMU"
	@echo "  test-host     host unit tests only"
	@echo "  test-qemu     in-kernel tests under QEMU only"
	@echo "  format        apply clang-format"
	@echo "  format-check  verify formatting (what CI runs)"
	@echo "  info          print resolved configuration"
	@echo "  clean         remove $(BUILD_ROOT)/"
	@echo ""
	@echo "Variables:  PROFILE=debug|release  KERNEL_TESTS=0|1  STRICT_LINK=0|1"

# Pull in the auto-generated header dependencies. The leading '-' suppresses
# the error on the first build, when no .d files exist yet.
-include $(DEPS)
