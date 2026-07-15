#Requires -Version 5.1
<#
.SYNOPSIS
  ShePaw Windows desktop build script.

.DESCRIPTION
  Must run on Windows with Flutter + Visual Studio ("Desktop development with C++").
  Produces a zip under dist/ containing the Release/Debug runner.

.PARAMETER Mode
  release (default) or debug

.PARAMETER Clean
  Run flutter clean before building

.PARAMETER SkipPubGet
  Skip flutter pub get

.PARAMETER Out
  Output directory (default: dist)

.PARAMETER Init
  If windows/ is missing, run: flutter create --platforms=windows .

.EXAMPLE
  .\build_windows.ps1
  .\build_windows.ps1 -Mode debug
  .\build_windows.ps1 -Clean -Out releases
  .\build_windows.ps1 -Init
#>

[CmdletBinding()]
param(
  [ValidateSet('release', 'debug')]
  [string]$Mode = 'release',

  [switch]$Clean,
  [switch]$SkipPubGet,
  [switch]$Init,

  [string]$Out = 'dist',

  [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) {
  Write-Host "[INFO] $Message" -ForegroundColor Cyan
}
function Write-Ok([string]$Message) {
  Write-Host "[OK] $Message" -ForegroundColor Green
}
function Write-Warn([string]$Message) {
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}
function Write-Err([string]$Message) {
  Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Show-Help {
  @'
ShePaw Windows desktop build

Usage:
  .\build_windows.ps1 [-Mode release|debug] [-Clean] [-SkipPubGet] [-Init] [-Out <dir>]

Parameters:
  -Mode release|debug   Build mode (default: release)
  -Clean                flutter clean before build
  -SkipPubGet           Skip flutter pub get
  -Init                 Create windows/ via flutter create if missing
  -Out <dir>            Output directory (default: dist)
  -Help                 Show this help

Requirements (Windows only):
  - Flutter SDK on PATH
  - Visual Studio with "Desktop development with C++"
  - windows/ folder (or pass -Init once)

Examples:
  .\build_windows.ps1
  .\build_windows.ps1 -Mode debug
  .\build_windows.ps1 -Init -Clean
'@ | Write-Host
}

if ($Help) {
  Show-Help
  exit 0
}

# ── host check ──────────────────────────────────────────────────────
if ($env:OS -ne 'Windows_NT') {
  Write-Err 'This script must run on Windows. Use build_all.sh on macOS/Linux.'
  exit 1
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

# ── flutter ─────────────────────────────────────────────────────────
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
  Write-Err 'flutter not found on PATH. Install Flutter and reopen the terminal.'
  exit 1
}

function Get-PubspecVersion {
  $line = Get-Content -Path (Join-Path $Root 'pubspec.yaml') |
    Where-Object { $_ -match '^\s*version:\s*' } |
    Select-Object -First 1
  if (-not $line) { return '0.0.0+0' }
  return ($line -replace '^\s*version:\s*', '').Trim()
}

$Version = Get-PubspecVersion
$VersionName = ($Version -split '\+', 2)[0]
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ArtifactPrefix = "shepaw-$VersionName"
$OutDir = Join-Path $Root $Out

Write-Info "ShePaw Windows build  version=$Version  mode=$Mode  out=$Out"
Write-Info ("Flutter: " + (& flutter --version 2>$null | Select-Object -First 1))

# ── windows/ platform ───────────────────────────────────────────────
$WindowsDir = Join-Path $Root 'windows'
if (-not (Test-Path $WindowsDir)) {
  if ($Init) {
    Write-Info 'windows/ missing — running: flutter create --platforms=windows .'
    & flutter create --platforms=windows .
    if ($LASTEXITCODE -ne 0) {
      Write-Err 'flutter create --platforms=windows failed'
      exit $LASTEXITCODE
    }
  }
  else {
    Write-Err 'No windows/ folder in this repo.'
    Write-Err 'First run:  .\build_windows.ps1 -Init'
    Write-Err 'Or manually: flutter create --platforms=windows .'
    exit 1
  }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if ($Clean) {
  Write-Info 'flutter clean...'
  & flutter clean
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not $SkipPubGet) {
  Write-Info 'flutter pub get...'
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# ── build ───────────────────────────────────────────────────────────
Write-Info "Building Windows ($Mode)..."
& flutter build windows "--$Mode"
if ($LASTEXITCODE -ne 0) {
  Write-Err 'flutter build windows failed'
  Write-Warn 'Check: Visual Studio with "Desktop development with C++", then flutter doctor -v'
  exit $LASTEXITCODE
}

# Flutter 3.x typically: build\windows\x64\runner\Release
$ModeDirName = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }
$Candidates = @(
  (Join-Path $Root "build\windows\x64\runner\$ModeDirName"),
  (Join-Path $Root "build\windows\runner\$ModeDirName")
)

$RunnerDir = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $RunnerDir) {
  Write-Err "Build output not found. Looked under build\windows\**\runner\$ModeDirName"
  exit 1
}

Write-Ok "Runner: $RunnerDir"

# ── package ─────────────────────────────────────────────────────────
$ZipName = "$ArtifactPrefix-windows-$Mode.zip"
$ZipPath = Join-Path $OutDir $ZipName
$StageName = 'ShePaw'
$StageRoot = Join-Path $env:TEMP ("shepaw-win-build-" + [guid]::NewGuid().ToString('N'))
$StageDir = Join-Path $StageRoot $StageName

try {
  New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
  Copy-Item -Path (Join-Path $RunnerDir '*') -Destination $StageDir -Recurse -Force

  if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
  }
  Compress-Archive -Path $StageDir -DestinationPath $ZipPath -Force
  Write-Ok "→ $ZipPath"

  # Unpacked copy for quick local run
  $Unpacked = Join-Path $OutDir $StageName
  if (Test-Path $Unpacked) {
    Remove-Item -Recurse -Force $Unpacked
  }
  Copy-Item -Path $StageDir -Destination $Unpacked -Recurse -Force
  Write-Ok "→ $Unpacked\"
}
finally {
  if (Test-Path $StageRoot) {
    Remove-Item -Recurse -Force $StageRoot
  }
}

# ── report ──────────────────────────────────────────────────────────
$Report = Join-Path $OutDir "build-report-windows-$Stamp.txt"
@(
  'ShePaw Windows build report'
  "time:     $(Get-Date -Format o)"
  "version:  $Version"
  "mode:     $Mode"
  "host:     $([System.Environment]::OSVersion.VersionString)"
  "flutter:  $((& flutter --version 2>$null | Select-Object -First 1))"
  "runner:   $RunnerDir"
  ''
  'artifacts:'
  (Get-ChildItem $OutDir | Format-Table Name, Length, LastWriteTime | Out-String)
) | Set-Content -Path $Report -Encoding UTF8
Write-Ok "Report: $Report"

Write-Info 'Done.'
Get-ChildItem $OutDir | Format-Table Name, @{N='Size';E={ if ($_.PSIsContainer) { '<dir>' } else { '{0:N1} MB' -f ($_.Length/1MB) } }}, LastWriteTime
