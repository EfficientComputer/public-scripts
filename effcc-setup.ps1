<#
.SYNOPSIS
  Install, update, or uninstall the Efficient Computer effcc SDK on Windows (native, no WSL).

.DESCRIPTION
  effcc-setup.ps1 install   [-Wheel <path>] [-Venv <dir>] [-Python <exe>] [-NoDeps] [-Yes]
  effcc-setup.ps1 update    [-Wheel <path>] ...
  effcc-setup.ps1 uninstall [-Yes] [-Purge]

  The SDK lives entirely inside a Python virtual environment (default %USERPROFILE%\effcc-env).
  Activate it in each PowerShell window (& $HOME\effcc-env\Scripts\Activate.ps1) and effcc,
  eff-flash, and the other tools are on your PATH. install/update create or reuse that environment
  and pip install the wheel into it; uninstall deletes the environment.

  Piped form (PowerShell 5.1 or later):
    irm <url>/effcc-setup.ps1 | iex            # runs "install" with defaults
  or download the file and run:
    .\effcc-setup.ps1 install -Wheel $HOME\Downloads\effcc-<version>-py3-none-win_amd64.whl

.NOTES
  Windows support in effcc is preliminary. The compiler, eff-flash, and eff-prof run natively; the ML
  import extras (litert, onnx, executorch) have no Windows build yet. Run those under WSL.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('install', 'update', 'uninstall')]
  [string]$Command = 'install',
  [string]$Wheel = '',
  [string]$Venv = "$HOME\effcc-env",
  [string]$Python = '',
  [switch]$NoDeps,
  [switch]$Yes,
  [switch]$Purge
)

# 'Continue' rather than 'Stop': Windows PowerShell 5.1 turns any stderr line from a native command
# (pip warnings, py.exe probes) into a terminating error under 'Stop'. Exit codes are checked explicitly.
$ErrorActionPreference = 'Continue'

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host " ok  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "warn $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error $m" -ForegroundColor Red; exit 1 }
function Confirm-Step($q) {
  if ($Yes) { return $true }
  $r = Read-Host "$q [y/N]"
  return $r -match '^(y|yes)$'
}

# Run a probe command whose failure (non-zero exit, stderr chatter) must not abort the script.
function Test-Cmd([string]$exe, [string[]]$exeArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & $exe @exeArgs 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch { return $false } finally { $ErrorActionPreference = $prev }
}

# ---------------------------------------------------------------------------
# System dependencies (winget)
# ---------------------------------------------------------------------------
function Install-Deps {
  if ($NoDeps) { return }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Warn 'winget not found; install Git, CMake, and Ninja yourself (https://cmake.org, https://ninja-build.org)'
    return
  }
  Say 'Installing system dependencies with winget (Git, CMake, Ninja)'
  foreach ($id in 'Git.Git', 'Kitware.CMake', 'Ninja-build.Ninja') {
    if (-not (Test-Cmd 'winget' @('install', '--id', $id, '-e', '--accept-source-agreements', '--accept-package-agreements', '--silent'))) {
      Warn "winget could not install $id (already installed, or install it by hand)"
    }
  }
  Ok 'system dependencies'
}

# ---------------------------------------------------------------------------
# Python selection: prefer 3.13 .. 3.10 (the ML extras' range); fall back to any python3
# ---------------------------------------------------------------------------
function Find-Python {
  if ($Python) {
    if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) { Die "python '$Python' not found" }
    return $Python
  }
  if (Get-Command py -ErrorAction SilentlyContinue) {
    foreach ($v in '3.13', '3.12', '3.11', '3.10') {
      if (Test-Cmd 'py' @("-$v", '-c', 'import sys')) { return "py -$v" }
    }
    if (Test-Cmd 'py' @('-3', '-c', 'import sys')) { return 'py -3' }
  }
  foreach ($exe in 'python3', 'python') {
    if ((Get-Command $exe -ErrorAction SilentlyContinue) -and (Test-Cmd $exe @('-c', 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)'))) {
      return $exe
    }
  }
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Say 'Installing Python 3.12 with winget'
    $null = Test-Cmd 'winget' @('install', '--id', 'Python.Python.3.12', '-e', '--accept-source-agreements', '--accept-package-agreements', '--silent')
    return 'py -3.12'
  }
  Die 'Python 3 not found. Install it from https://www.python.org/downloads/windows/ and rerun.'
}

function Invoke-Py([string]$pyCmd, [string[]]$pyArgs) {
  $parts = $pyCmd -split ' '
  & $parts[0] @($parts[1..($parts.Length - 1)] + $pyArgs)
}

function Ensure-Venv {
  $venvPy = Join-Path $Venv 'Scripts\python.exe'
  if (Test-Path $venvPy) {
    $ver = & $venvPy -c "import sys;print('%d.%d'%sys.version_info[:2])"
    Ok "using existing environment $Venv (Python $ver)"
  } else {
    $py = Find-Python
    Say "Creating Python environment at $Venv with '$py'"
    Invoke-Py $py @('-m', 'venv', $Venv) 2>&1 | ForEach-Object { "$_" }
    if (-not (Test-Path $venvPy)) { Die "could not create $Venv" }
  }
  return $venvPy
}

# ---------------------------------------------------------------------------
# Wheel discovery
# ---------------------------------------------------------------------------
function Find-Wheel {
  if ($Wheel) {
    if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
    return (Resolve-Path $Wheel).Path
  }
  foreach ($dir in (Get-Location).Path, (Join-Path $HOME 'Downloads')) {
    $found = Get-ChildItem -Path $dir -Filter 'effcc-*win_amd64.whl' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  Die 'no effcc Windows wheel found. Download effcc-<version>-py3-none-win_amd64.whl from https://downloads.efficient.computer/ and pass -Wheel <path>.'
}

# ---------------------------------------------------------------------------
# Legacy cleanup: older guides set EFFCC_DIR / EFFTOOLS_DIR and linked %USERPROFILE%\effcc.
# Either variable overrides the wheel on PATH, so remove them.
# ---------------------------------------------------------------------------
function Clear-Legacy {
  $link = Join-Path $HOME 'effcc'
  foreach ($n in 'EFFCC_DIR', 'EFFTOOLS_DIR') {
    if ([Environment]::GetEnvironmentVariable($n, 'User')) {
      [Environment]::SetEnvironmentVariable($n, $null, 'User')
      Ok "removed the $n user variable (it would override the wheel)"
    }
  }
  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($current -and ($current -like "*$link\bin*")) {
    $parts = $current -split ';' | Where-Object { $_ -and ($_ -notlike "$link\*") }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Ok "removed $link\bin from the user PATH"
  }
  if (Test-Path $link) {
    $item = Get-Item $link
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $item.Delete(); Ok "removed the $link link from an earlier setup" }
    else { Warn "$link is an older extracted install. It is no longer used; delete it when you're ready." }
  }
}

# ---------------------------------------------------------------------------
# Install / update
# ---------------------------------------------------------------------------
function Do-Install {
  $wheel = Find-Wheel
  Say "$Command`: $(Split-Path $wheel -Leaf) -> $Venv"
  Install-Deps
  $venvPy = Ensure-Venv

  Say "Installing $(Split-Path $wheel -Leaf)"
  & $venvPy -m pip install --upgrade --find-links (Split-Path $wheel -Parent) $wheel 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { Die 'pip install failed' }
  $version = (& $venvPy -m pip show effcc | Select-String '^Version:').ToString().Split(' ')[1]
  Ok "effcc $version installed"

  # The DSP library wheel: eff_dsp, or eff_kit in release candidates before the rename.
  $dsp = Get-ChildItem -Path (Split-Path $wheel -Parent) -Include 'eff_dsp-*.whl', 'eff_kit-*.whl' -Recurse -Depth 0 -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($dsp) {
    Say "Installing $($dsp.Name)"
    & $venvPy -m pip install --upgrade $dsp.FullName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn 'eff-dsp install failed' } else {
      if ($dsp.Name -like 'eff_dsp-*') { & $venvPy -m pip uninstall -y eff-kit 2>&1 | Out-Null }
      Ok 'eff-dsp installed'
    }
  }

  Clear-Legacy

  Say 'Verifying'
  & (Join-Path $Venv 'Scripts\effcc.exe') --version | Select-String '^Version'
  & (Join-Path $Venv 'Scripts\eff-flash.exe') --help | Out-Null
  if ($LASTEXITCODE -eq 0) { Ok 'eff-flash runs' }

  Write-Host ''
  Write-Host 'Done. In every PowerShell window where you build or flash, activate the environment first:'
  Write-Host "  & $Venv\Scripts\Activate.ps1"
  Write-Host '  (if PowerShell refuses: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned)'
  Write-Host ''
  Write-Host 'Then, for example:'
  Write-Host '  effcc --version'
  Write-Host '  git clone https://github.com/EfficientComputer/e1x_examples.git'
  Write-Host '  cd e1x_examples\app_examples'
  Write-Host '  cmake -S . -B bld -G Ninja -DCMAKE_SYSTEM_NAME=Generic -DEFF_SDK_ROOT_DIR="$(python -c ''import effcc; print(effcc.__path__[0])'')/sdk"'
  Write-Host '  cmake --build bld --target quickstart'
  Write-Host '  eff-flash bld\quickstart\fabric\quickstart'
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
function Do-Uninstall {
  Say 'Uninstalling the effcc SDK'
  if (Test-Path $Venv) {
    if (Confirm-Step "Delete the Python environment $Venv?") { Remove-Item -Recurse -Force $Venv; Ok "removed $Venv" }
  }
  Clear-Legacy
  # Leftovers from older installs: only with -Purge, and confirmed one by one even with -Yes.
  $leftovers = @(Get-ChildItem -Path $HOME -Filter 'effcc.old-*' -Directory -ErrorAction SilentlyContinue)
  $link = Join-Path $HOME 'effcc'
  if ((Test-Path $link) -and -not ((Get-Item $link).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $leftovers += Get-Item $link }
  if ($Purge) {
    foreach ($d in $leftovers) {
      if ((Read-Host "Delete $($d.FullName)? [y/N]") -match '^(y|yes)$') { Remove-Item -Recurse -Force $d.FullName; Ok "removed $($d.FullName)" }
    }
  } elseif ($leftovers) {
    foreach ($d in $leftovers) { Write-Host "left in place: $($d.FullName) (rerun with -Purge to be asked about it)" }
  }
  Write-Host ''
  Write-Host 'Uninstall complete. Open a new PowerShell window so any removed variables take effect.'
  Write-Host 'Not removed: Git, CMake, Ninja, and Python.'
}

switch ($Command) {
  'install'   { Do-Install }
  'update'    { Do-Install }
  'uninstall' { Do-Uninstall }
}
