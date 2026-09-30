<#
.SYNOPSIS
  Install, update, or uninstall the Efficient Computer effcc SDK on Windows (native, no WSL).

.DESCRIPTION
  effcc-setup.ps1 install   [-Token <token> | -Wheel <path>] [-Extras <list>] [-Rc] [-Version <v>] [-Venv <dir>] [-Python <exe>] [-NoDeps] [-NoDsp] [-Yes]
  effcc-setup.ps1 update    [same options; reuses the index configured at install]
  effcc-setup.ps1 uninstall [-Yes] [-Purge]

  Where the SDK comes from (pick one):
    -Token <token>  install from Efficient's package index with a personal pip token from
                    https://downloads.efficient.computer/ (recommended; also read from the
                    EFFCC_PIP_TOKEN environment variable; prompted for if neither is given)
    -Wheel <path>   install from a downloaded effcc wheel instead (offline)

  The SDK lives entirely inside a Python virtual environment (default %USERPROFILE%\effcc-env).
  Activate it in each PowerShell window (& $HOME\effcc-env\Scripts\Activate.ps1) and effcc,
  eff-flash, and the other tools are on your PATH. The index URL and token are stored in that
  environment's own pip.ini, so a later "update" needs no token.

  Piped form (PowerShell 5.1 or later):
    irm <url>/effcc-setup.ps1 | iex            # runs "install" and prompts for the token
  or download the file and run:
    .\effcc-setup.ps1 install -Token <token> -Extras litert

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
  [string]$Token = $env:EFFCC_PIP_TOKEN,
  [string]$Extras = '',
  [string]$Version = '',
  [switch]$Rc,
  [switch]$NoDsp,
  [string]$Venv = "$HOME\effcc-env",
  [string]$Python = '',
  [switch]$NoDeps,
  [switch]$Yes,
  [switch]$Purge
)

# 'Continue' rather than 'Stop': Windows PowerShell 5.1 turns any stderr line from a native command
# (pip warnings, py.exe probes) into a terminating error under 'Stop'. Exit codes are checked explicitly.
$ErrorActionPreference = 'Continue'
$IndexHost = if ($Rc) { 'testdownloads.efficient.computer' } else { 'downloads.efficient.computer' }

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
    if (Test-Cmd 'winget' @('list', '--id', $id, '-e', '--accept-source-agreements')) { Ok "$id already installed"; continue }
    if (Test-Cmd 'winget' @('install', '--id', $id, '-e', '--accept-source-agreements', '--accept-package-agreements', '--silent')) { Ok "$id installed" }
    else { Warn "winget could not install $id; install it by hand" }
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
  # A current pip avoids "new release of pip is available" noise and old resolver quirks.
  & $venvPy -m pip install --quiet --upgrade pip 2>&1 | Out-Null
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
function Install-FromWheel($venvPy, $wheel) {
  Say "Installing $(Split-Path $wheel -Leaf)$(if ($Extras) { " with extras: $Extras" })"
  $spec = if ($Extras) { "$wheel[$Extras]" } else { $wheel }
  & $venvPy -m pip install --upgrade --find-links (Split-Path $wheel -Parent) $spec 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { Die 'pip install failed' }
  $version = (& $venvPy -m pip show effcc | Select-String '^Version:').ToString().Split(' ')[1]
  Ok "effcc $version installed"
  if (-not $NoDsp) {
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
  }
}

function Install-FromIndex($venvPy) {
  if ($Token) {
    # Stored in the environment's own pip.ini: applies only to this environment, and a later
    # "update" needs no token on the command line.
    & $venvPy -m pip config --site set global.extra-index-url "https://__token__:$Token@$IndexHost/pypi/simple/" 2>&1 | Out-Null
    Ok "package index configured in $Venv (pip.ini)"
  }
  $pre = if ($Rc) { '--pre' } else { $null }
  $spec = 'effcc' + $(if ($Extras) { "[$Extras]" }) + $(if ($Version) { "==$Version" })
  Say "Installing $spec from https://$IndexHost/"
  & $venvPy -m pip install --upgrade $pre $spec 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { Die "pip could not install effcc from https://$IndexHost/. Check the token (a wrong or revoked token gives 401 errors) and your network." }
  $version = (& $venvPy -m pip show effcc | Select-String '^Version:').ToString().Split(' ')[1]
  Ok "effcc $version installed"
  if (-not $NoDsp) {
    Say 'Installing eff-dsp'
    & $venvPy -m pip install --upgrade $pre ('eff-dsp' + $(if ($Version) { "==$Version" })) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn 'eff-dsp is not available on the index for this version; skipping' }
    else { & $venvPy -m pip uninstall -y eff-kit 2>&1 | Out-Null; Ok 'eff-dsp installed' }
  }
}

function Do-Install {
  $wheel = $null
  if ($Wheel) {
    $wheel = Find-Wheel
    Say "$Command`: $(Split-Path $wheel -Leaf) -> $Venv"
  } else {
    $hasIndex = (Test-Path (Join-Path $Venv 'pip.ini')) -and ((Get-Content (Join-Path $Venv 'pip.ini') -ErrorAction SilentlyContinue) -match 'extra-index-url')
    if (-not $Token -and $Command -eq 'update' -and $hasIndex) {
      Say "$Command`: newest effcc from the index configured in $Venv"
    } else {
      if (-not $Token) {
        $secure = Read-Host "Paste your pip token from https://$IndexHost/ (input hidden)" -AsSecureString
        $Token = [System.Net.NetworkCredential]::new('', $secure).Password
      }
      if (-not $Token) { Die "no token given. Pass -Token <token> (from https://$IndexHost/) or -Wheel <file>." }
      Say "$Command`: effcc from https://$IndexHost/ -> $Venv"
    }
  }
  Install-Deps
  $venvPy = Ensure-Venv
  if ($wheel) { Install-FromWheel $venvPy $wheel } else { Install-FromIndex $venvPy }

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
  Write-Host '  cmake -S . -B bld -G Ninja; cmake --build bld --target quickstart'
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
