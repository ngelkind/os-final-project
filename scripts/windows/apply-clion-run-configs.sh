#!/usr/bin/env bash
# =============================================================================
#  Drop the CLion run configurations straight into .idea/, from inside WSL.
# =============================================================================
#
#      bash scripts/windows/apply-clion-run-configs.sh
#
#  Run this from a terminal INSIDE WSL -- including the Terminal tool window
#  in CLion itself, if the project was opened from its \\wsl$ path (see
#  docs/clion-windows.md section 1). That terminal already IS the WSL shell,
#  which is what makes this possible: .idea/ lives on the same Linux
#  filesystem this script is running on, so it can just write the files.
#
#  It creates the same five run configurations the author has on macOS
#  (docs/clion.md), adapted for a native WSL build instead of the Docker
#  container: build + run (QEMU), run QEMU (native), debug QEMU halted
#  (native), attach to QEMU, and qkill.
#
#  It also adds the `qkill` shell function to ~/.bashrc -- the same thing
#  the author has in his own ~/.zshrc on macOS -- so a stray QEMU left
#  running after a closed terminal or window can be killed by typing `qkill`
#  from any WSL shell, not only from inside CLion.
#
#  Idempotent: run it again after a `git pull` and it just rewrites the same
#  files with whatever this script currently says.
#
#  WHAT THIS DOES NOT DO: it cannot make CLion reload them for you -- that is
#  a GUI action. After running this, in CLion: File -> Reload Project (or
#  just restart CLion). Open a NEW terminal, or run `source ~/.bashrc`, for
#  the `qkill` command itself to become available in that shell.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

if [[ -t 1 ]]; then
    B=$'\033[1m'; G=$'\033[32m'; N=$'\033[0m'
else
    B=""; G=""; N=""
fi
ok() { echo "  ${G}ok${N}    $*"; }

RC_DIR=".idea/runConfigurations"
mkdir -p "${RC_DIR}"

# --- build + run (QEMU) ------------------------------------------------------
# Native build, not the container: WSL already has the native cross compiler
# (bootstrap-wsl.sh), which is what this whole Windows setup is built around
# (docs/clion-windows.md, "Why this looks different from the Mac setup").
cat > "${RC_DIR}/build_run_qemu.xml" <<'XML'
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="build + run (QEMU)" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="make PROFILE=debug &amp;&amp; bash scripts/run.sh" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="" />
    <option name="SCRIPT_OPTIONS" value="" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
    <option name="INDEPENDENT_INTERPRETER_PATH" value="true" />
    <option name="INTERPRETER_PATH" value="/bin/bash" />
    <option name="INTERPRETER_OPTIONS" value="" />
    <option name="EXECUTE_IN_TERMINAL" value="true" />
    <option name="EXECUTE_SCRIPT_FILE" value="false" />
    <envs />
    <method v="2" />
  </configuration>
</component>
XML
ok "wrote ${RC_DIR}/build_run_qemu.xml"

# --- run QEMU (native) -------------------------------------------------------
cat > "${RC_DIR}/run_qemu_native.xml" <<'XML'
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="run QEMU (native)" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="bash scripts/run.sh" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="" />
    <option name="SCRIPT_OPTIONS" value="" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
    <option name="INDEPENDENT_INTERPRETER_PATH" value="true" />
    <option name="INTERPRETER_PATH" value="/bin/bash" />
    <option name="INTERPRETER_OPTIONS" value="" />
    <option name="EXECUTE_IN_TERMINAL" value="true" />
    <option name="EXECUTE_SCRIPT_FILE" value="false" />
    <envs />
    <method v="2" />
  </configuration>
</component>
XML
ok "wrote ${RC_DIR}/run_qemu_native.xml"

# --- debug QEMU halted (native) ----------------------------------------------
cat > "${RC_DIR}/debug_qemu_halted.xml" <<'XML'
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="debug QEMU halted (native)" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="bash scripts/debug.sh" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="" />
    <option name="SCRIPT_OPTIONS" value="" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
    <option name="INDEPENDENT_INTERPRETER_PATH" value="true" />
    <option name="INTERPRETER_PATH" value="/bin/bash" />
    <option name="INTERPRETER_OPTIONS" value="" />
    <option name="EXECUTE_IN_TERMINAL" value="true" />
    <option name="EXECUTE_SCRIPT_FILE" value="false" />
    <envs />
    <method v="2" />
  </configuration>
</component>
XML
ok "wrote ${RC_DIR}/debug_qemu_halted.xml"

# --- attach to QEMU -----------------------------------------------------------
cat > "${RC_DIR}/attach_to_qemu.xml" <<'XML'
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="attach to QEMU" type="CLion_Remote" factoryName="CLion Remote" remoteCommand="localhost:1234" symbolFile="$PROJECT_DIR$/build/debug/kernel.elf" sysroot="">
    <debuggerData debuggerKind="CUSTOM_GDB" path="/usr/bin/gdb-multiarch" version="1" />
    <method v="2" />
  </configuration>
</component>
XML
ok "wrote ${RC_DIR}/attach_to_qemu.xml"

# --- qkill --------------------------------------------------------------------
cat > "${RC_DIR}/qkill.xml" <<'XML'
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="qkill" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="bash scripts/kill-qemu.sh" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="" />
    <option name="SCRIPT_OPTIONS" value="" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
    <option name="INDEPENDENT_INTERPRETER_PATH" value="true" />
    <option name="INTERPRETER_PATH" value="/bin/bash" />
    <option name="INTERPRETER_OPTIONS" value="" />
    <option name="EXECUTE_IN_TERMINAL" value="true" />
    <option name="EXECUTE_SCRIPT_FILE" value="false" />
    <envs />
    <method v="2" />
  </configuration>
</component>
XML
ok "wrote ${RC_DIR}/qkill.xml"

# --- the qkill shell function, for any WSL terminal, not only CLion ----------
MARKER="# >>> os-final-project qkill >>>"
if grep -qF "${MARKER}" ~/.bashrc 2>/dev/null; then
    ok "qkill already in ~/.bashrc"
else
    cat >> ~/.bashrc <<'RC'

# >>> os-final-project qkill >>>
# Kill stray bare-metal QEMU left behind by a closed CLion terminal or WSL
# window. Closing that window does not signal the process inside it -- QEMU
# is reparented to init and, since this kernel never halts on its own
# (-no-reboot/-no-shutdown), keeps a host core pinned at 100% indefinitely.
# `qkill` from anywhere; `qkill -l` to only look, not kill.
# Narrow match on purpose: this must never touch an unrelated QEMU.
qkill() {
    local pattern='qemu-system-aarch64.*-kernel.*kernel\.elf'
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null)
    if [[ -z "$pids" ]]; then
        echo "No stray QEMU instances."
        return 0
    fi
    ps -o pid,etime,%cpu,command -p "$(echo "$pids" | tr '\n' ',' | sed 's/,$//')" | cut -c1-140
    if [[ "$1" == "-l" || "$1" == "--list" ]]; then
        return 0
    fi
    echo "$pids" | xargs kill -TERM 2>/dev/null
    sleep 2
    echo "$pids" | xargs -I{} sh -c 'kill -0 {} 2>/dev/null && kill -9 {} 2>/dev/null' 2>/dev/null
    echo "Killed $(echo "$pids" | wc -l | tr -d ' ') instance(s)."
}
# <<< os-final-project qkill <<<
RC
    ok "added qkill() to ~/.bashrc"
fi

echo
echo "${B}Done.${N} Two things left, both manual:"
echo "  1. In CLion: File -> Reload Project (or restart CLion) to pick up the"
echo "     new run configurations."
echo "  2. Open a NEW terminal, or run 'source ~/.bashrc', for the 'qkill'"
echo "     command itself to be available in that shell."
