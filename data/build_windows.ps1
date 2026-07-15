#Requires -Version 5.1
<#
.SYNOPSIS
  Local Windows build entry from data/ (uses data/key.properties when present).

.EXAMPLE
  .\data\build_windows.ps1
  .\data\build_windows.ps1 -Init
  .\data\build_windows.ps1 -Mode debug -Out data\out
#>
[CmdletBinding()]
param(
  [ValidateSet('release', 'debug')]
  [string]$Mode = 'release',
  [switch]$Clean,
  [switch]$SkipPubGet,
  [switch]$Init,
  [string]$Out = 'data\out',
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
$DataDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $DataDir
Set-Location $Root

$KeyProps = Join-Path $DataDir 'key.properties'
if (Test-Path $KeyProps) {
  Write-Host "[INFO] Android signing file present at data/key.properties (used by Gradle for APK if you build Android on Windows)." -ForegroundColor Cyan
}

$Script = Join-Path $Root 'build_windows.ps1'
if (-not (Test-Path $Script)) {
  Write-Host "[ERROR] Missing build_windows.ps1 at repo root" -ForegroundColor Red
  exit 1
}

$forward = @{}
if ($Mode) { $forward['Mode'] = $Mode }
if ($Clean) { $forward['Clean'] = $true }
if ($SkipPubGet) { $forward['SkipPubGet'] = $true }
if ($Init) { $forward['Init'] = $true }
if ($Out) { $forward['Out'] = $Out }
if ($Help) { $forward['Help'] = $true }

& $Script @forward
exit $LASTEXITCODE
