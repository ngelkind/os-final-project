# =============================================================================
#  Windows bootstrap -- gets you into WSL2, and stops there.
# =============================================================================
#
#      powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
#
#  This script's ONLY job is to confirm you have a working WSL2 with a Linux
#  distribution, and then hand you the command to continue inside it.
#
#  Everything past that point -- Docker, the toolchain, the build, the kernel --
#  runs inside WSL via scripts/setup.sh. There is deliberately no Windows-native
#  build path: maintaining two of them means the Windows one is broken half the
#  time and nobody notices until a deadline.
#
#  Like setup.sh, this installs nothing on your behalf. It tells you the exact
#  command to run and why.
# =============================================================================

$ErrorActionPreference = "Stop"

# WSL emits UTF-16LE by default, which PowerShell 5.1 renders as text with a
# space between every character. This makes its output parseable and readable.
$env:WSL_UTF8 = "1"

function Write-Step { param($m) Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  warn  $m" -ForegroundColor Yellow }
function Write-Info { param($m) Write-Host "        $m" }

function Stop-Setup {
    param($Lines)
    Write-Host ""
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host " SETUP STOPPED" -ForegroundColor Red
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host ""
    foreach ($l in $Lines) { Write-Host $l }
    Write-Host ""
    Write-Host "Nothing was installed or changed."
    Write-Host ""
    exit 1
}

# -----------------------------------------------------------------------------
#  1. Windows version
# -----------------------------------------------------------------------------
Write-Step "Checking Windows version"

$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 19041) {
    Stop-Setup @(
        "Windows build $build is too old for WSL2.",
        "",
        "WSL2 needs build 19041 (Windows 10 version 2004) or newer.",
        "Update Windows, then re-run this script."
    )
}
Write-Ok "Windows build $build (WSL2 capable)"

# -----------------------------------------------------------------------------
#  2. Is WSL present at all?
# -----------------------------------------------------------------------------
Write-Step "Checking WSL"

$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if ($null -eq $wsl) {
    Stop-Setup @(
        "WSL is not installed.",
        "",
        "Open PowerShell AS ADMINISTRATOR and run:",
        "",
        "    wsl --install -d Ubuntu-24.04",
        "",
        "Then REBOOT, let Ubuntu finish its first-run setup (it will ask you to",
        "choose a username and password), and run this script again.",
        "",
        "Ubuntu 24.04 is specified deliberately: it is the same base as the CI",
        "container image, so your environment matches the reference one.",
        "",
        "This script will not run the install for you -- it needs administrator",
        "rights and a reboot, and those should be your decision."
    )
}
Write-Ok "wsl found at $($wsl.Source)"

# -----------------------------------------------------------------------------
#  3. Is there a distro, and is it version 2?
# -----------------------------------------------------------------------------
Write-Step "Checking installed distributions"

$listOutput = & wsl -l -v 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $listOutput -match "no installed distributions") {
    Stop-Setup @(
        "WSL is installed but has no Linux distribution.",
        "",
        "Install Ubuntu 24.04 (matches the CI container base):",
        "",
        "    wsl --install -d Ubuntu-24.04",
        "",
        "Let it finish its first-run setup, then re-run this script."
    )
}

Write-Info "wsl -l -v reports:"
foreach ($line in ($listOutput -split "`r?`n")) {
    if ($line.Trim().Length -gt 0) { Write-Info "  $line" }
}

# The default distro is the one marked with '*'. Its VERSION column must be 2:
# WSL1 cannot run Docker and differs in ways that will cost you a day.
$defaultLine = ($listOutput -split "`r?`n") | Where-Object { $_ -match '^\s*\*' } | Select-Object -First 1
if ($null -eq $defaultLine) {
    Write-Warn "could not identify the default distribution; check 'wsl -l -v' by hand"
} else {
    $fields = ($defaultLine -replace '^\s*\*\s*', '') -split '\s+' | Where-Object { $_ -ne "" }
    $distroName = $fields[0]
    $distroVersion = $fields[-1]

    if ($distroVersion -ne "2") {
        Stop-Setup @(
            "Your default distribution '$distroName' is running under WSL$distroVersion.",
            "",
            "WSL1 cannot run Docker. Convert it:",
            "",
            "    wsl --set-version $distroName 2",
            "    wsl --set-default-version 2",
            "",
            "The conversion can take several minutes. Then re-run this script."
        )
    }
    Write-Ok "default distribution: $distroName (WSL2)"
}

# -----------------------------------------------------------------------------
#  4. Hand off
# -----------------------------------------------------------------------------
Write-Step "Next steps -- inside WSL, not here"

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Green
Write-Host " WSL2 IS READY" -ForegroundColor Green
Write-Host "=============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Everything from here runs inside Linux. Open WSL:"
Write-Host ""
Write-Host "    wsl"
Write-Host ""
Write-Host "Then, INSIDE WSL, run the one-script installer. It is"
Write-Host "scripts/bootstrap-wsl.sh in the repository. If you do not have the"
Write-Host "repository yet, ask a teammate for that one file (or download it from"
Write-Host "GitHub once you have accepted the collaborator invitation), then:"
Write-Host ""
Write-Host "    bash bootstrap-wsl.sh"
Write-Host ""
Write-Host "It installs the packages, sets up Docker, logs you in to GitHub,"
Write-Host "clones the repository into ~/projects and runs scripts/setup.sh."
Write-Host "It pauses once if WSL needs a restart and tells you what to type."
Write-Host ""
Write-Host "Prefer to do it by hand? Every step is in docs/onboarding.md, under"
Write-Host "'Windows'. The short version:"
Write-Host ""
Write-Host "    mkdir -p ~/projects && cd ~/projects"
Write-Host "    git clone https://github.com/ngelkind/os-final-project.git"
Write-Host "    cd os-final-project"
Write-Host "    bash scripts/setup.sh"
Write-Host ""
Write-Host "Either way, the repository lives under ~/ inside WSL, never under" -ForegroundColor Yellow
Write-Host "/mnt/c. A repo on the Windows drive crosses the WSL filesystem" -ForegroundColor Yellow
Write-Host "bridge: builds run several times slower, file watching is" -ForegroundColor Yellow
Write-Host "unreliable, and the git executable bit does not persist." -ForegroundColor Yellow
Write-Host ""
