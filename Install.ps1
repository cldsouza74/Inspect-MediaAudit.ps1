#Requires -Version 7.0
# Install.ps1 — media-audit installer for Windows (PowerShell 7+)
#
# Usage:
#   .\Install.ps1           # installs to ~/bin, adds to user PATH
#   .\Install.ps1 -System   # installs to C:\tools\media-audit (requires admin)
#   .\Install.ps1 -Help

[CmdletBinding()]
param(
    [switch]$System,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ───────────────────────────────────────────────────────────────────
function Info    ($msg) { Write-Host $msg -ForegroundColor Cyan }
function Success ($msg) { Write-Host "OK  $msg" -ForegroundColor Green }
function Warn    ($msg) { Write-Host "WRN $msg" -ForegroundColor Yellow }
function Fail    ($msg) { Write-Host "ERR $msg" -ForegroundColor Red; exit 1 }

# ── Help ──────────────────────────────────────────────────────────────────────
if ($Help) {
    @"
Usage: .\Install.ps1 [-System] [-Help]

  (no flag)   Install to ~/bin, add to user PATH — no admin required
  -System     Install to C:\tools\media-audit, add to system PATH (requires admin)
  -Help       Show this message
"@
    exit 0
}

# ── Banner ────────────────────────────────────────────────────────────────────
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$VersionFile = Join-Path $ScriptDir 'VERSION'
$Version    = if (Test-Path $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { 'unknown' }

Info ""
Info "=============================================="
Info "  media-audit v$Version — Windows installer"
Info "=============================================="
Info ""

# ── Step 1: Check PowerShell version ─────────────────────────────────────────
Info "Checking PowerShell..."
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Fail "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)`nDownload: https://github.com/PowerShell/PowerShell/releases"
}
Success "PowerShell $($PSVersionTable.PSVersion)"

# ── Step 2: Check exiftool ────────────────────────────────────────────────────
Info "Checking exiftool..."
if (Get-Command exiftool -ErrorAction SilentlyContinue) {
    $etVer = exiftool -ver
    Success "exiftool $etVer"
} else {
    Warn "exiftool not found on PATH"
    Warn "Required for media-audit.ps1. Not needed for Perl scripts."
    Write-Host "  Download: https://exiftool.org" -ForegroundColor DarkGray
    Write-Host "  Place exiftool.exe in a folder on your PATH, then re-run." -ForegroundColor DarkGray
    Write-Host ""
}

# ── Step 3: Check Perl (for Perl scripts) ────────────────────────────────────
Info "Checking Perl..."
$perlFound = $false
if (Get-Command perl -ErrorAction SilentlyContinue) {
    $perlVer = perl -e 'printf "%vd", $^V'
    Success "Perl $perlVer"
    $perlFound = $true
} else {
    Warn "Perl not found — Perl scripts (media-audit.pl, sort-by-year.pl) will not work"
    Write-Host "  Download Strawberry Perl: https://strawberryperl.com" -ForegroundColor DarkGray
    Write-Host ""
}

# ── Step 4: Install Perl dependencies ────────────────────────────────────────
if ($perlFound) {
    Info "Installing Perl dependencies..."

    if (-not (Get-Command cpanm -ErrorAction SilentlyContinue)) {
        Info "  cpanm not found — installing via CPAN..."
        perl -MCPAN -e 'install App::cpanminus' | Out-Null
        if (-not (Get-Command cpanm -ErrorAction SilentlyContinue)) {
            Warn "Could not install cpanm automatically."
            Write-Host "  Run manually: perl -MCPAN -e 'install App::cpanminus'" -ForegroundColor DarkGray
        }
    }

    if (Get-Command cpanm -ErrorAction SilentlyContinue) {
        $cpanfile = Join-Path $ScriptDir 'cpanfile'
        if (Test-Path $cpanfile) {
            cpanm --installdeps $ScriptDir
            Success "Perl dependencies installed"
        } else {
            Warn "cpanfile not found — skipping dependency install"
        }
    }
}

# ── Step 5: Set install directory ────────────────────────────────────────────
if ($System) {
    $InstallDir = 'C:\tools\media-audit'
    $PathScope  = 'Machine'
    Info "Installing to $InstallDir (system install)..."
} else {
    $InstallDir = Join-Path $env:USERPROFILE 'bin'
    $PathScope  = 'User'
    Info "Installing to $InstallDir (user install)..."
}

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}

# ── Step 6: Copy scripts ──────────────────────────────────────────────────────
# Perl scripts — installed without .pl so they run as plain commands
Copy-Item (Join-Path $ScriptDir 'media-audit.pl')  (Join-Path $InstallDir 'media-audit.pl')  -Force
Copy-Item (Join-Path $ScriptDir 'sort-by-year.pl') (Join-Path $InstallDir 'sort-by-year.pl') -Force
Copy-Item (Join-Path $ScriptDir 'VERSION')          (Join-Path $InstallDir 'VERSION')          -Force

# PowerShell script
Copy-Item (Join-Path $ScriptDir 'media-audit.ps1') (Join-Path $InstallDir 'media-audit.ps1') -Force

Success "Scripts copied to $InstallDir"

# ── Step 7: Add to PATH ───────────────────────────────────────────────────────
$currentPath = [Environment]::GetEnvironmentVariable('PATH', $PathScope)
if ($currentPath -notlike "*$InstallDir*") {
    Info "Adding $InstallDir to $PathScope PATH..."
    [Environment]::SetEnvironmentVariable('PATH', "$currentPath;$InstallDir", $PathScope)
    $env:PATH += ";$InstallDir"
    Success "$InstallDir added to PATH"
    Warn "Open a new terminal for PATH changes to take effect"
} else {
    Success "$InstallDir already on PATH"
}

# ── Step 8: Verify ───────────────────────────────────────────────────────────
Info ""
Info "----------------------------------------------"
Info "  Verifying installation..."
Info "----------------------------------------------"

if ($perlFound) {
    $result = perl (Join-Path $InstallDir 'media-audit.pl') '--help' 2>&1
    if ($LASTEXITCODE -eq 0 -or $result -match 'media-audit') {
        Success "media-audit.pl — OK"
    } else {
        Warn "media-audit.pl did not run cleanly — check output above"
    }

    $result = perl (Join-Path $InstallDir 'sort-by-year.pl') '--help' 2>&1
    if ($LASTEXITCODE -eq 0 -or $result -match 'sort-by-year') {
        Success "sort-by-year.pl — OK"
    } else {
        Warn "sort-by-year.pl did not run cleanly — check output above"
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────
Info ""
Info "=============================================="
Write-Host "OK  media-audit v$Version installed" -ForegroundColor Green
Info "=============================================="
Info ""
Write-Host "  Quick start (Perl):" -ForegroundColor White
Write-Host "    perl $InstallDir\media-audit.pl --path D:\Photos --dry-run --recurse" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Quick start (PowerShell):" -ForegroundColor White
Write-Host "    $InstallDir\media-audit.ps1 -Path D:\Photos -DryRun -Recurse" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Full docs: $ScriptDir\MANUAL.md" -ForegroundColor DarkGray
Write-Host ""
