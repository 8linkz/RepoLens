param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$DoctorArgs,

  [switch]$DryRun,
  [switch]$Wait
)

$ErrorActionPreference = "Stop"

function Quote-BashArg {
  param([string]$Value)
  return "'" + $Value.Replace("'", "'\''") + "'"
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  throw "wsl.exe was not found. Run this launcher from Windows with WSL installed."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = (Resolve-Path (Join-Path $scriptDir "../..")).ProviderPath
$repoRootForWsl = $repoRoot.Replace("\", "/")
$wslRepoRoot = (& wsl.exe wslpath -a "$repoRootForWsl").Trim()
if (-not $wslRepoRoot) {
  throw "Unable to convert repo path to a WSL path: $repoRoot"
}

if (-not $DoctorArgs -or $DoctorArgs.Count -eq 0) {
  $DoctorArgs = @("repolens", "--agent", "codex", "--local")
}

$needsInteractiveSudo = $false
for ($i = 0; $i -lt $DoctorArgs.Count; $i++) {
  if ($DoctorArgs[$i] -eq "--apply" -or $DoctorArgs[$i] -eq "--install-agent") {
    $needsInteractiveSudo = $true
  }
}
if ($needsInteractiveSudo -and ($DoctorArgs -notcontains "--interactive-sudo")) {
  $DoctorArgs += "--interactive-sudo"
}

$bashArgs = @("addons/dev-doctor/dev-doctor.sh") + $DoctorArgs
$quotedArgs = ($bashArgs | ForEach-Object { Quote-BashArg $_ }) -join " "

$runId = [System.Guid]::NewGuid().ToString("N")
$launcherDir = Join-Path $repoRoot "logs/dev-doctor-interactive"
New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
$bashFile = Join-Path $launcherDir ("run-" + $runId + ".sh")
$cmdFile = Join-Path $launcherDir ("run-" + $runId + ".cmd")
$wslBashFile = "$wslRepoRoot/logs/dev-doctor-interactive/run-$runId.sh"

$bashScript = @"
#!/usr/bin/env bash
set -uo pipefail
cd $(Quote-BashArg $wslRepoRoot) || exit 1
echo "dev-doctor interactive run"
echo "cwd: `$(pwd)"
echo
bash $quotedArgs
rc=`$?
echo
echo "dev-doctor exit code: `$rc"
echo
read -r -p "Press Enter to close this window..." _
exit "`$rc"
"@

[System.IO.File]::WriteAllText($bashFile, $bashScript.Replace("`r`n", "`n"), [System.Text.Encoding]::ASCII)

$cmdScript = @"
@echo off
title dev-doctor interactive
wsl.exe -- bash "$wslBashFile"
exit /b %ERRORLEVEL%
"@

Set-Content -LiteralPath $cmdFile -Value $cmdScript -Encoding ASCII

if ($DryRun) {
  Write-Host "Would launch interactive dev-doctor window."
  Write-Host "Bash script: $bashFile"
  Write-Host "CMD script:  $cmdFile"
  Write-Host "Args:        $($DoctorArgs -join ' ')"
  exit 0
}

Write-Host "Opening visible dev-doctor WSL window..."
Write-Host "Command args: $($DoctorArgs -join ' ')"

if ($Wait) {
  $process = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$cmdFile`"") -Wait -PassThru
  exit $process.ExitCode
}

Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$cmdFile`"")
