<#
.SYNOPSIS
  Install, update, or uninstall the Efficient Computer effcc SDK on Windows (native, no WSL).

.DESCRIPTION
  effcc-setup.ps1 install   [-Wheel <path>] [-Venv <dir>] [-Python <exe>] [-NoDeps] [-NoEnv] [-Yes]
  effcc-setup.ps1 update    [-Wheel <path>] ...
  effcc-setup.ps1 uninstall [-Yes] [-Purge]

  install/update  create (or reuse) the Python environment %USERPROFILE%\effcc-env, pip install the
                  effcc wheel into it, link %USERPROFILE%\effcc to the installed toolchain, and set the
                  EFFCC_DIR and PATH user environment variables.
  uninstall       remove the link, the environment, and the variables.

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
  [switch]$NoEnv,
  [switch]$Yes,
  [switch]$Purge
)

# 'Continue' rather than 'Stop': Windows PowerShell 5.1 turns any stderr line from a native command
# (pip warnings, py.exe probes) into a terminating error under 'Stop'. Exit codes are checked explicitly.
$ErrorActionPreference = 'Continue'
$Link = Join-Path $HOME 'effcc'

function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host " ok  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "warn $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error $m" -ForegroundColor Red; exit 1 }
function Confirm-Step($q) {
  if ($Yes) { return $true }
  $r = Read-Host "$q [y/N]"
  return $r -match '^(y|yes)$'
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
# Run a probe command whose failure (non-zero exit, stderr chatter) must not abort the script.
# Windows PowerShell 5.1 turns native stderr into a terminating error under 'Stop', so relax it here.
function Test-Cmd([string]$exe, [string[]]$exeArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & $exe @exeArgs 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch { return $false } finally { $ErrorActionPreference = $prev }
}

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
# Install / update
# ---------------------------------------------------------------------------
function Set-UserEnv([string]$name, [string]$value) {
  [Environment]::SetEnvironmentVariable($name, $value, 'User')
  Set-Item -Path "Env:$name" -Value $value
}

function Add-UserPath([string]$dir) {
  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @()
  if ($current) { $parts = $current -split ';' | Where-Object { $_ -and ($_ -ne $dir) } }
  $parts += $dir
  [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
  if (-not (($env:Path -split ';') -contains $dir)) { $env:Path = "$env:Path;$dir" }
}

function Remove-UserPath([string]$dir) {
  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $current) { return }
  $parts = $current -split ';' | Where-Object { $_ -and ($_ -ne $dir) -and ($_ -notlike "$Link\*") }
  [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

function Do-Install {
  $wheel = Find-Wheel
  Say "$Command`: $(Split-Path $wheel -Leaf) -> $Venv, linked at $Link"
  Install-Deps
  $venvPy = Ensure-Venv

  Say "Installing $(Split-Path $wheel -Leaf)"
  & $venvPy -m pip install --upgrade --find-links (Split-Path $wheel -Parent) $wheel 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { Die 'pip install failed' }
  $version = (& $venvPy -m pip show effcc | Select-String '^Version:').ToString().Split(' ')[1]
  Ok "effcc $version installed"

  # eff-kit ships either inside the effcc package or as its own wheel next to it.
  $kit = Get-ChildItem -Path (Split-Path $wheel -Parent) -Filter 'eff_kit-*.whl' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($kit) {
    Say "Installing $($kit.Name)"
    & $venvPy -m pip install --upgrade $kit.FullName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn 'eff-kit install failed' } else { Ok 'eff-kit installed' }
  }

  $pkgDir = & $venvPy -c 'import effcc,os;print(os.path.dirname(effcc.__file__))'
  if (-not (Test-Path (Join-Path $pkgDir 'bin\effcc.exe'))) { Die "effcc.exe not found under $pkgDir" }

  # %USERPROFILE%\effcc -> site-packages\effcc, as a directory junction (no admin rights needed).
  if ((Test-Path $Link) -and -not ((Get-Item $Link).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    $stamp = "$Link.old-$(Get-Date -Format yyyyMMdd-HHmmss)"
    if (Confirm-Step "$Link already exists and is not a link. Move it to $stamp?") { Move-Item $Link $stamp }
    else { Die "refusing to overwrite $Link" }
  }
  if (Test-Path $Link) { (Get-Item $Link).Delete() }
  New-Item -ItemType Junction -Path $Link -Target $pkgDir | Out-Null
  Ok "$Link -> $pkgDir"

  $kitPkg = & $venvPy -c "import importlib.util as u;s=u.find_spec('eff_kit');print(s.submodule_search_locations[0] if s and s.submodule_search_locations else '')" 2>$null | Select-Object -First 1
  if ($kitPkg -and (Test-Path "$kitPkg") -and -not (Test-Path (Join-Path $Link 'eff_kit'))) {
    New-Item -ItemType Junction -Path (Join-Path $pkgDir 'eff_kit') -Target $kitPkg | Out-Null
    Ok "$Link\eff_kit -> $kitPkg"
  }

  if (-not $NoEnv) {
    Say 'Setting EFFCC_DIR and PATH (user environment)'
    Set-UserEnv 'EFFCC_DIR' $Link
    Add-UserPath (Join-Path $Link 'bin')
    if ([Environment]::GetEnvironmentVariable('EFFTOOLS_DIR', 'User')) {
      [Environment]::SetEnvironmentVariable('EFFTOOLS_DIR', $null, 'User')
      Ok 'removed the deprecated EFFTOOLS_DIR variable'
    }
    Ok "EFFCC_DIR=$Link; $Link\bin added to PATH (open a new terminal to pick it up)"
  }

  Say 'Verifying'
  & (Join-Path $Link 'bin\effcc.exe') --version | Select-String '^Version'
  & (Join-Path $Link 'bin\eff-flash.exe') --help | Out-Null
  if ($LASTEXITCODE -eq 0) { Ok 'eff-flash runs' }

  Write-Host ''
  Write-Host 'Done. Open a new terminal, then:'
  Write-Host '  effcc --version'
  Write-Host '  git clone https://github.com/EfficientComputer/e1x_examples.git'
  Write-Host '  cd e1x_examples\app_examples; cmake -S . -B bld -G Ninja; cmake --build bld --target quickstart/fabric/quickstart'
  Write-Host '  eff-flash bld\quickstart\fabric\quickstart      # flashes the ELF; the EVK is auto-detected'
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
function Do-Uninstall {
  Say 'Uninstalling the effcc SDK'
  if (Test-Path $Link) {
    $item = Get-Item $Link
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $item.Delete(); Ok "removed link $Link" }
    elseif (Confirm-Step "$Link is a real directory. Delete it?") { Remove-Item -Recurse -Force $Link; Ok "removed $Link" }
  }
  if (Test-Path $Venv) {
    if (Confirm-Step "Delete the Python environment $Venv?") { Remove-Item -Recurse -Force $Venv; Ok "removed $Venv" }
  }
  if (-not $NoEnv) {
    foreach ($n in 'EFFCC_DIR', 'EFFTOOLS_DIR') {
      if ([Environment]::GetEnvironmentVariable($n, 'User')) { [Environment]::SetEnvironmentVariable($n, $null, 'User'); Ok "removed $n" }
    }
    Remove-UserPath (Join-Path $Link 'bin')
    Ok 'removed the toolchain from the user PATH'
  }
  # Leftovers from older installs: only with -Purge, and confirmed one by one even with -Yes.
  $leftovers = Get-ChildItem -Path $HOME -Filter 'effcc.old-*' -Directory -ErrorAction SilentlyContinue
  if ($Purge) {
    foreach ($d in $leftovers) {
      if ((Read-Host "Delete $($d.FullName)? [y/N]") -match '^(y|yes)$') { Remove-Item -Recurse -Force $d.FullName; Ok "removed $($d.FullName)" }
    }
  } elseif ($leftovers) {
    foreach ($d in $leftovers) { Write-Host "left in place: $($d.FullName) (rerun with -Purge to be asked about it)" }
  }
  Write-Host ''
  Write-Host 'Uninstall complete. Open a new terminal so the removed variables take effect.'
  Write-Host 'Not removed: Git, CMake, Ninja, and Python.'
}

switch ($Command) {
  'install'   { Do-Install }
  'update'    { Do-Install }
  'uninstall' { Do-Uninstall }
}
