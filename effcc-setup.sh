#!/usr/bin/env bash
# effcc-setup.sh - install, update, or uninstall the Efficient Computer effcc SDK
# on Linux, Windows (WSL), and macOS from the effcc Python wheel.
#
# The SDK lives entirely inside a Python virtual environment (default ~/effcc-env).
# Activate it in each terminal (source ~/effcc-env/bin/activate) and the compiler,
# eff-flash, and the other tools are on your PATH. Nothing else on the machine is
# changed, apart from the udev rules on Linux.
#
# Usage:
#   effcc-setup.sh install   [options]   # first-time install
#   effcc-setup.sh update    [options]   # move an existing install to the newest release
#   effcc-setup.sh uninstall [options]   # remove everything this script created
#   effcc-setup.sh attach-evk            # (WSL) pass the EVK's USB device through to this WSL instance
#
# Where the SDK comes from (pick one):
#   --token <token>    install from Efficient's package index with a personal pip token from
#                      https://downloads.efficient.computer/ (recommended; also read from
#                      the EFFCC_PIP_TOKEN environment variable; prompted for if neither is given)
#   --wheel <path>     install from a downloaded effcc wheel instead (offline; put the effcc_ml
#                      and eff_dsp wheels in the same folder if you need them)
#
# Options:
#   --extras <list>    comma-separated pip extras: litert, onnx, executorch, all
#   --no-dsp           don't install the eff-dsp library package
#   --rc               use the release-candidate index (testdownloads.efficient.computer) and
#                      allow pre-release versions
#   --version <v>      pin the effcc version to install, for example 26.3.0.0
#   --venv <dir>       Python virtual environment to use (default: ~/effcc-env)
#   --python <exe>     Python interpreter used to create the environment
#   --no-deps          skip installing system packages (cmake, ninja, minicom, ...)
#   --no-udev          skip installing the udev rules (Linux only)
#   --yes              don't ask for confirmation
#   --purge            (uninstall) also offer to delete older zip installs, downloaded
#                      effcc zips and wheels, and older ML environments in your home directory
#   -h, --help         show this help
#
# Piped form:
#   curl -fsSL <url>/effcc-setup.sh | bash -s -- install --token <token> --extras litert

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
VENV="${EFFCC_VENV:-$HOME/effcc-env}"
WHEEL=""
TOKEN="${EFFCC_PIP_TOKEN:-}"
INDEX_HOST="downloads.efficient.computer"
PRE=""
PIN=""
EXTRAS=""
INSTALL_DSP=1
PYTHON=""
DO_DEPS=1
DO_UDEV=1
ASSUME_YES=0
PURGE=0
CMD=""

UDEV_RULES_PATH="/etc/udev/rules.d/99-efficient.rules"
# Copy of the rules for releases that don't ship etc/99-efficient.rules (26.3 RC1 and RC2).
UDEV_RULES='# Efficient Computer udev rules (installed by effcc-setup.sh)
SUBSYSTEM=="tty", ATTRS{idVendor}=="38e1", ATTRS{idProduct}=="0001", ENV{ID_USB_INTERFACE_NUM}=="00", SYMLINK+="eff-prog", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="38e1", ATTRS{idProduct}=="0001", ENV{ID_USB_INTERFACE_NUM}=="02", SYMLINK+="eff-power", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="38e1", ATTRS{idProduct}=="0001", ENV{ID_USB_INTERFACE_NUM}=="04", SYMLINK+="eff-console", MODE="0666"'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() {
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  local reply
  if [ -t 0 ]; then
    read -r -p "$1 [y/N] " reply
  elif [ -e /dev/tty ]; then
    read -r -p "$1 [y/N] " reply </dev/tty
  else
    warn "no terminal to ask '$1'; assuming no (pass --yes to skip prompts)"
    return 1
  fi
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

SCRIPT_URL="https://raw.githubusercontent.com/EfficientComputer/public-scripts/main/effcc-setup.sh"
# How to rerun a subcommand: the file path when run from disk, the curl form when piped.
rerun_hint() { if [ -f "$0" ]; then echo "$0 $1"; else echo "curl -fsSL $SCRIPT_URL | bash -s -- $1"; fi; }

OS="$(uname -s)"
ARCH="$(uname -m)"
IS_WSL=0
if [ "$OS" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi

shell_rc() {
  case "$(basename "${SHELL:-bash}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "$HOME/.bashrc" ;;
  esac
}

activate_hint() {
  if [[ "$(shell_rc)" == *fish* ]]; then echo "source $VENV/bin/activate.fish"; else echo "source $VENV/bin/activate"; fi
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    install|update|uninstall|attach-evk) CMD="$1" ;;
    --wheel)   WHEEL="$2"; shift ;;
    --wheel=*) WHEEL="${1#*=}" ;;
    --token)   TOKEN="$2"; shift ;;
    --token=*) TOKEN="${1#*=}" ;;
    --rc)      INDEX_HOST="testdownloads.efficient.computer"; PRE="--pre" ;;
    --version) PIN="$2"; shift ;;
    --version=*) PIN="${1#*=}" ;;
    --extras)  EXTRAS="$2"; shift ;;
    --extras=*) EXTRAS="${1#*=}" ;;
    --no-dsp|--no-kit) INSTALL_DSP=0 ;;
    --venv)    VENV="$2"; shift ;;
    --venv=*)  VENV="${1#*=}" ;;
    --python)  PYTHON="$2"; shift ;;
    --python=*) PYTHON="${1#*=}" ;;
    --no-deps) DO_DEPS=0 ;;
    --no-udev) DO_UDEV=0 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --purge)   PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[ -n "$CMD" ] || { usage; exit 1; }

# Run as the user who will use the SDK, not as root: the environment lives in $HOME,
# and the script calls sudo itself for the steps that need it.
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
  die "don't run this script with sudo. Run it as your normal user; it asks for your password when it needs root (system packages, udev rules)."
fi

case "$OS" in
  Linux|Darwin) ;;
  *) die "unsupported OS '$OS'. On Windows, use effcc-setup.ps1 (native) or run this script inside WSL." ;;
esac
if [ "$OS" = "Darwin" ] && [ "$ARCH" != "arm64" ]; then
  die "macOS is supported on Apple Silicon (arm64) only."
fi

# ----------------------------------------------------------------------------
# System dependencies
# ----------------------------------------------------------------------------
install_deps() {
  [ "$DO_DEPS" = 1 ] || return 0
  say "Installing system dependencies"
  if [ "$OS" = "Darwin" ]; then
    command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS. Install it from https://brew.sh and rerun."
    brew install cmake ninja minicom git python@3.12 >/dev/null || warn "brew install reported a problem; continuing"
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    # libsm6/libice6: OpenCV's window plugin needs them for the SDK's host-side viewers
    # (for example the HM0360 camera example); default WSL images lack them.
    sudo apt-get install -y -qq build-essential binutils libcurl4-openssl-dev cmake ninja-build git minicom unzip \
      python3 python3-venv python3-pip libsm6 libice6
    if [ "$IS_WSL" = 1 ]; then
      # USB/IP client tools, so the EVK can be passed through from Windows (usbipd-win).
      sudo apt-get install -y -qq linux-tools-generic hwdata usbutils
    fi
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y gcc glibc-devel binutils libcurl-devel cmake ninja-build git minicom unzip python3 python3-pip libSM libICE
  else
    warn "unknown package manager; make sure cmake, ninja, git, minicom, and python3 (with venv) are installed"
  fi
  ok "system dependencies"
}

# ----------------------------------------------------------------------------
# Python selection
# ----------------------------------------------------------------------------
py_version() { "$1" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null; }
py_minor()   { "$1" -c 'import sys;print(sys.version_info[1])' 2>/dev/null; }
# Usable only if it can create a venv that has pip (Debian/Ubuntu split ensurepip into python3.X-venv).
py_can_venv() { "$1" -c 'import venv, ensurepip' >/dev/null 2>&1; }

find_python() {
  # Prefer an interpreter the ML extras support (3.10-3.13); fall back to python3.
  if [ -n "$PYTHON" ]; then
    command -v "$PYTHON" >/dev/null || die "python '$PYTHON' not found"
    py_can_venv "$PYTHON" || die "'$PYTHON' cannot create virtual environments (missing the venv or ensurepip module)"
    echo "$PYTHON"; return
  fi
  if [ "$OS" = "Darwin" ] && [ -x /opt/homebrew/opt/python@3.12/bin/python3.12 ]; then
    echo /opt/homebrew/opt/python@3.12/bin/python3.12; return
  fi
  local v c
  for v in 3.13 3.12 3.11 3.10; do
    if command -v "python$v" >/dev/null 2>&1 && py_can_venv "python$v"; then echo "python$v"; return; fi
  done
  if command -v uv >/dev/null 2>&1; then
    for v in 3.13 3.12 3.11 3.10; do
      c="$(uv python find "$v" 2>/dev/null || true)"
      if [ -n "$c" ] && [ -x "$c" ] && py_can_venv "$c"; then echo "$c"; return; fi
    done
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  py_can_venv python3 || die "python3 cannot create virtual environments. On Debian/Ubuntu: sudo apt install python3-venv"
  echo python3
}

extras_need_old_python() { [ -n "$EXTRAS" ]; }
python_ok_for_extras() {
  local minor; minor="$(py_minor "$1")"
  [ -n "$minor" ] && [ "$minor" -ge 10 ] && [ "$minor" -le 13 ]
}

ensure_venv() {
  local py
  if [ -x "$VENV/bin/python" ]; then
    ok "using existing environment $VENV (Python $(py_version "$VENV/bin/python"))"
    if extras_need_old_python && ! python_ok_for_extras "$VENV/bin/python"; then
      die "the ML extras ($EXTRAS) need Python 3.10-3.13, but $VENV uses Python $(py_version "$VENV/bin/python").
Move it aside (mv $VENV $VENV.old) and rerun so a compatible environment is created, or pass --venv <other dir>."
    fi
    return
  fi

  py="$(find_python)"
  if extras_need_old_python && ! python_ok_for_extras "$py"; then
    # No suitable interpreter on PATH. uv can fetch one and seed the venv with pip.
    if ! command -v uv >/dev/null 2>&1 && [ -x "$HOME/.local/bin/uv" ]; then PATH="$HOME/.local/bin:$PATH"; fi
    if ! command -v uv >/dev/null 2>&1; then
      if confirm "Python $(py_version "$py") is too new for the ML extras. Install uv (https://astral.sh/uv) to fetch Python 3.13?"; then
        say "Installing uv into ~/.local/bin"
        curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null || die "uv install failed"
        PATH="$HOME/.local/bin:$PATH"
      fi
    fi
    if command -v uv >/dev/null 2>&1; then
      say "Python $(py_version "$py") is too new for the ML extras; creating $VENV with a uv-managed Python 3.13"
      if ! uv venv --seed --python 3.13 "$VENV"; then rm -rf "$VENV"; die "uv could not create a Python 3.13 environment"; fi
      ok "created $VENV (Python $(py_version "$VENV/bin/python"))"
      return
    fi
    die "the ML extras ($EXTRAS) need Python 3.10-3.13, but only Python $(py_version "$py") was found.
Install uv (curl -LsSf https://astral.sh/uv/install.sh | sh) and rerun, or pass --python <a 3.10-3.13 interpreter>."
  fi

  say "Creating Python environment at $VENV with $py (Python $(py_version "$py"))"
  if ! "$py" -m venv "$VENV"; then
    rm -rf "$VENV"
    die "could not create a virtual environment with $py (on Debian/Ubuntu: sudo apt install python3-venv)"
  fi
  # A current pip avoids "new release of pip is available" noise and old resolver quirks.
  "$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# Wheel discovery
# ----------------------------------------------------------------------------
wheel_platform_glob() {
  case "$OS-$ARCH" in
    Linux-x86_64)  echo 'effcc-*manylinux*x86_64.whl' ;;
    Linux-aarch64) echo 'effcc-*manylinux*aarch64.whl' ;;
    Darwin-arm64)  echo 'effcc-*macosx*arm64.whl' ;;
    *) die "no effcc wheel is published for $OS $ARCH" ;;
  esac
}

newest() { ls -t "$@" 2>/dev/null | head -n1 || true; }

find_wheel() {
  if [ -n "$WHEEL" ]; then
    [ -f "$WHEEL" ] || die "wheel not found: $WHEEL"
    echo "$WHEEL"; return
  fi
  local glob dir found
  glob="$(wheel_platform_glob)"
  for dir in "$PWD" "$HOME/Downloads" "$HOME/downloads"; do
    # shellcheck disable=SC2086
    found="$(newest $dir/$glob)"
    if [ -n "$found" ]; then echo "$found"; return; fi
  done
  die "no effcc wheel found. Download effcc-<version>-...whl from https://downloads.efficient.computer/ and pass --wheel <path>."
}

# Version encoded in a wheel filename: effcc-26.3.0.0-py3-none-....whl -> 26.3.0.0
wheel_version() { basename "$1" | cut -d- -f2; }

# ----------------------------------------------------------------------------
# Install / update
# ----------------------------------------------------------------------------
pip_install() {
  local wheel="$1" dir spec dsp ml
  dir="$(cd "$(dirname "$wheel")" && pwd)"
  spec="$wheel"
  if [ -n "$EXTRAS" ]; then
    spec="${wheel}[${EXTRAS}]"
    ml="$(newest "$dir"/effcc_ml-"$(wheel_version "$wheel")"*.whl)"
    if [ -z "$ml" ]; then
      if [ "$OS" = "Darwin" ] && [ "$EXTRAS" != "executorch" ]; then
        warn "the litert and onnx extras are not available on macOS (effcc_ml ships no macOS build for them)"
      fi
      warn "no effcc_ml-$(wheel_version "$wheel")*.whl found next to the effcc wheel; pip will look for it on the configured index"
    fi
  fi
  say "Installing $(basename "$wheel")${EXTRAS:+ with extras: $EXTRAS}"
  "$VENV/bin/python" -m pip install --upgrade --find-links "$dir" "$spec"
  ok "effcc $("$VENV/bin/python" -m pip show effcc 2>/dev/null | awk '/^Version:/{print $2}') installed"

  if [ "$INSTALL_DSP" = 1 ]; then
    # The DSP library wheel is eff_dsp; release candidates before the rename shipped it as eff_kit.
    dsp="$(newest "$dir"/eff_dsp-"$(wheel_version "$wheel")"*.whl "$dir"/eff_kit-"$(wheel_version "$wheel")"*.whl "$dir"/eff_dsp-*.whl "$dir"/eff_kit-*.whl)"
    if [ -n "$dsp" ]; then
      say "Installing $(basename "$dsp")"
      "$VENV/bin/python" -m pip install --upgrade "$dsp"
      # eff_dsp replaced the RC-era eff_kit distribution; drop the old one if both are present.
      case "$(basename "$dsp")" in eff_dsp-*) "$VENV/bin/python" -m pip uninstall -y eff-kit >/dev/null 2>&1 || true ;; esac
      ok "eff-dsp installed"
    fi
  fi
}

index_url() { echo "https://__token__:${TOKEN}@${INDEX_HOST}/pypi/simple/"; }

# Store the index URL (with the token) in the environment's own pip.conf, so it applies only
# to this environment and a later `pip install --upgrade effcc` finds the index without the
# token on the command line.
configure_index() {
  "$VENV/bin/python" -m pip config --site set global.extra-index-url "$(index_url)" >/dev/null
  ok "package index configured in $VENV (pip.conf)"
}

venv_has_index() { "$VENV/bin/python" -m pip config --site get global.extra-index-url >/dev/null 2>&1; }

ask_token() {
  local reply=""
  if [ -e /dev/tty ]; then
    read -r -s -p "Paste your pip token from https://${INDEX_HOST}/ (input hidden): " reply </dev/tty || true
    echo
  fi
  TOKEN="$reply"
}

pip_install_index() {
  local spec="effcc${EXTRAS:+[$EXTRAS]}${PIN:+==$PIN}"
  say "Installing $spec from https://${INDEX_HOST}/"
  # shellcheck disable=SC2086
  if ! "$VENV/bin/python" -m pip install --upgrade $PRE "$spec"; then
    die "pip could not install effcc from https://${INDEX_HOST}/. Check the token (a wrong or revoked token gives 401 errors) and your network."
  fi
  ok "effcc $("$VENV/bin/python" -m pip show effcc 2>/dev/null | awk '/^Version:/{print $2}') installed"
  if [ "$INSTALL_DSP" = 1 ]; then
    say "Installing eff-dsp"
    # shellcheck disable=SC2086
    if "$VENV/bin/python" -m pip install --upgrade $PRE "eff-dsp${PIN:+==$PIN}"; then
      "$VENV/bin/python" -m pip uninstall -y eff-kit >/dev/null 2>&1 || true
      ok "eff-dsp installed"
    else
      warn "eff-dsp is not available on the index for this version; skipping"
    fi
  fi
}

pkg_dir() { "$VENV/bin/python" -I -c "import importlib.util,os;s=importlib.util.find_spec('$1');print(os.path.dirname(s.origin) if s and s.origin else (s.submodule_search_locations[0] if s and s.submodule_search_locations else ''))" 2>/dev/null; }

# Older guides pointed the build at a zip install through EFFCC_DIR / EFFTOOLS_DIR and a
# ~/effcc link. Either variable overrides the wheel on PATH, so clear them out.
clean_legacy() {
  local rc tmp
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.zprofile" "$HOME/.config/fish/config.fish"; do
    [ -f "$rc" ] || continue
    if grep -q -e '>>> effcc SDK >>>' -e 'EFFCC_DIR' -e 'EFFTOOLS_DIR' "$rc"; then
      tmp="$(mktemp)"
      awk '
        $0=="# >>> effcc SDK >>>" {skip=1; next} $0=="# <<< effcc SDK <<<" {skip=0; next}
        skip {next}
        /EFFTOOLS_DIR|EFFCC_DIR/ {next}
        {print}' "$rc" > "$tmp" && cat "$tmp" > "$rc" && rm -f "$tmp"
      ok "removed EFFCC_DIR/EFFTOOLS_DIR lines from $rc (they would override the wheel)"
    fi
  done
  if [ -L "$HOME/effcc" ]; then
    rm -f "$HOME/effcc"; ok "removed the ~/effcc link from an earlier setup"
  elif [ -d "$HOME/effcc" ]; then
    warn "~/effcc is a zip-based install. It is no longer used; delete it when you're ready (rm -rf ~/effcc)."
  fi
  if [ -n "${EFFCC_DIR:-}" ] || [ -n "${EFFTOOLS_DIR:-}" ]; then
    warn "EFFCC_DIR or EFFTOOLS_DIR is set in this shell and would override the wheel: run  unset EFFCC_DIR EFFTOOLS_DIR"
  fi
}

install_udev() {
  [ "$OS" = "Linux" ] || return 0
  [ "$DO_UDEV" = 1 ] || return 0
  say "Installing udev rules for the EVK serial ports ($UDEV_RULES_PATH)"
  if ! command -v sudo >/dev/null 2>&1; then warn "sudo not available; skipping udev rules (use eff-flash --port instead)"; return 0; fi
  local pkg; pkg="$(pkg_dir effcc)"
  if [ -f "$pkg/etc/99-efficient.rules" ]; then
    sudo cp "$pkg/etc/99-efficient.rules" "$UDEV_RULES_PATH"
  else
    printf '%s\n' "$UDEV_RULES" | sudo tee "$UDEV_RULES_PATH" >/dev/null
  fi
  if [ -S /run/udev/control ]; then
    sudo udevadm control --reload-rules 2>/dev/null && sudo udevadm trigger 2>/dev/null || true
  else
    warn "udev is not running in this session, so the rule takes effect after a restart (on WSL: run  wsl --shutdown  in PowerShell, then reopen the terminal)."
  fi
  # WSL does not always apply MODE from udev, so also join dialout.
  if getent group dialout >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
    sudo usermod -a -G dialout "$USER" && ok "added $USER to the dialout group (takes effect at next login)"
  fi
  ok "udev rules installed; unplug and replug the EVK to get /dev/eff-prog, /dev/eff-power, /dev/eff-console"
}

# ----------------------------------------------------------------------------
# WSL: USB passthrough of the EVK from Windows (usbipd-win)
# ----------------------------------------------------------------------------
setup_wsl_usbip() {
  [ "$IS_WSL" = 1 ] || return 0
  # USB/IP client tools and lsusb, in case install ran without them (or with --no-deps).
  if ! command -v lsusb >/dev/null 2>&1 || ! ls -d /usr/lib/linux-tools/*/usbip >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      say "Installing the USB/IP client tools (linux-tools-generic hwdata usbutils)"
      sudo apt-get install -y -qq linux-tools-generic hwdata usbutils
    fi
  fi
  # The usbip client binary ships under a kernel-version directory; register the newest one.
  if ! command -v usbip >/dev/null 2>&1; then
    local u; u="$(ls -d /usr/lib/linux-tools/*/usbip 2>/dev/null | sort -V | tail -n1)"
    if [ -n "$u" ]; then
      sudo update-alternatives --install /usr/local/bin/usbip usbip "$u" 20 >/dev/null 2>&1 && ok "usbip client registered ($u)"
    else
      warn "usbip client not found; install it with: sudo apt install linux-tools-generic hwdata usbutils"
    fi
  fi
}

# Find usbipd on the Windows side through WSL interop.
usbipd_exe() {
  local c
  for c in usbipd.exe "/mnt/c/Program Files/usbipd-win/usbipd.exe"; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then echo "$c"; return; fi
  done
  return 1
}

attach_evk() {
  [ "$IS_WSL" = 1 ] || { warn "attach-evk only applies inside WSL"; return 0; }
  say "Passing the EVK through to WSL"
  local exe list line busid state
  if ! exe="$(usbipd_exe)"; then
    cat <<MSG
usbipd is not installed on the Windows side. In PowerShell (as Administrator) run:
  winget install usbipd
then close and reopen PowerShell and rerun:  $(rerun_hint attach-evk)
MSG
    return 0
  fi
  list="$("$exe" list 2>/dev/null | tr -d '\r')"
  line="$(printf '%s\n' "$list" | grep -i '38e1:0001' | head -n1)"
  if [ -z "$line" ]; then
    warn "no EVK found on the Windows side. Connect it over USB, power it on, and rerun:  $(rerun_hint attach-evk)"
    return 0
  fi
  busid="$(printf '%s' "$line" | awk '{print $1}')"
  state="$(printf '%s' "$line" | awk '{print $NF}')"
  case "$state" in
    Attached) ok "EVK (bus $busid) is already attached to WSL" ;;
    Shared)
      "$exe" attach --wsl --busid "$busid" >/dev/null 2>&1 && ok "EVK (bus $busid) attached to WSL" || warn "attach failed; in PowerShell run:  usbipd attach --wsl --busid $busid" ;;
    *)
      # First time only: sharing the device needs administrator rights (one UAC prompt).
      say "Sharing the EVK (bus $busid) with WSL; approve the Windows administrator prompt"
      powershell.exe -NoProfile -Command "Start-Process usbipd -ArgumentList 'bind --busid $busid' -Verb RunAs -Wait" >/dev/null 2>&1 || true
      sleep 2
      "$exe" attach --wsl --busid "$busid" >/dev/null 2>&1 && ok "EVK (bus $busid) attached to WSL" \
        || warn "could not attach. In PowerShell (as Administrator) run:  usbipd bind --busid $busid; usbipd attach --wsl --busid $busid" ;;
  esac
  sleep 3
  if ls /dev/eff-prog >/dev/null 2>&1; then ok "/dev/eff-prog, /dev/eff-power, /dev/eff-console are present"
  elif ls /dev/ttyACM0 >/dev/null 2>&1; then warn "the EVK is visible as /dev/ttyACM* but the udev names are missing; unplug and replug it, or run  sudo udevadm trigger"
  else warn "the EVK is not visible in WSL yet; check  lsusb  after a few seconds, or rerun:  $(rerun_hint attach-evk)"; fi
  echo "Note: after a power cycle or reconnect, rerun  $(rerun_hint attach-evk)  if the EVK disappears from WSL."
}

verify() {
  say "Verifying"
  "$VENV/bin/effcc" --version | sed -n 's/^Version: /  effcc /p'
  "$VENV/bin/eff-flash" --help >/dev/null 2>&1 && echo "  eff-flash $("$VENV/bin/eff-flash" --version 2>/dev/null | awk '/^eff-flash/{print $2}')"
  if [ "$OS" = "Linux" ] && ! "$VENV/bin/eff-lldb" --version >/dev/null 2>&1; then
    warn "eff-lldb/eff-prof could not start (see the FAQ in the docs)"
  fi
}

do_install() {
  local wheel=""
  if [ -n "$WHEEL" ]; then
    wheel="$(find_wheel)"
    say "$CMD: $(basename "$wheel") -> $VENV"
  else
    # Index install. On update, reuse the index already configured in the environment.
    if [ -z "$TOKEN" ] && [ "$CMD" = update ] && [ -x "$VENV/bin/python" ] && venv_has_index; then
      say "$CMD: newest effcc from the index configured in $VENV"
    else
      [ -n "$TOKEN" ] || ask_token
      [ -n "$TOKEN" ] || die "no token given. Pass --token <token> (from https://${INDEX_HOST}/) or --wheel <file>."
      say "$CMD: effcc from https://${INDEX_HOST}/ -> $VENV"
    fi
  fi
  install_deps
  ensure_venv
  if [ -n "$wheel" ]; then
    pip_install "$wheel"
  else
    [ -n "$TOKEN" ] && configure_index
    pip_install_index
  fi
  clean_legacy
  install_udev
  setup_wsl_usbip
  verify
  if [ "$IS_WSL" = 1 ]; then attach_evk; fi
  cat <<DONE

Done. In every terminal where you build or flash, activate the environment first:
  $(activate_hint)

Then, for example:
  effcc --version
  cd ~ && git clone https://github.com/EfficientComputer/e1x_examples.git
  cd e1x_examples/app_examples
  cmake -S . -B bld -G Ninja && cmake --build bld --target quickstart/fabric/quickstart
  eff-flash bld/quickstart/fabric/quickstart
DONE
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
do_uninstall() {
  say "Uninstalling the effcc SDK"
  local d f

  if [ -d "$VENV" ]; then
    if confirm "Delete the Python environment $VENV?"; then rm -rf "$VENV"; ok "removed $VENV"; fi
  fi

  clean_legacy

  if [ "$OS" = "Linux" ] && [ -f "$UDEV_RULES_PATH" ] && [ "$DO_UDEV" = 1 ]; then
    if confirm "Remove the EVK udev rules ($UDEV_RULES_PATH)?"; then
      sudo rm -f "$UDEV_RULES_PATH" && sudo udevadm control --reload-rules && ok "removed udev rules"
    fi
  fi

  # Leftovers from older installs: only with --purge, each confirmed even under --yes.
  if [ "$PURGE" = 1 ]; then
    local saved_yes="$ASSUME_YES"; ASSUME_YES=0
    for d in "$HOME/effcc" "$HOME"/effcc.old-* "$HOME"/effcc_v*/ "$HOME/effcc-litert-env" "$HOME/effcc-onnx-env"; do
      [ -d "$d" ] || continue
      if confirm "Delete $d?"; then rm -rf "$d"; ok "removed $d"; fi
    done
    for f in "$HOME"/effcc_v*.zip "$HOME"/Downloads/effcc*.whl "$HOME"/Downloads/effcc_v*.zip "$HOME"/Downloads/eff_dsp-*.whl "$HOME"/Downloads/eff_kit-*.whl; do
      [ -f "$f" ] || continue
      if confirm "Delete $f?"; then rm -f "$f"; ok "removed $f"; fi
    done
    ASSUME_YES="$saved_yes"
  else
    for d in "$HOME/effcc" "$HOME"/effcc.old-* "$HOME"/effcc_v*/ "$HOME/effcc-litert-env" "$HOME/effcc-onnx-env"; do
      [ -d "$d" ] && echo "left in place: $d (rerun with --purge to be asked about it)"
    done
  fi

  echo
  echo "Uninstall complete. Open a new terminal so any removed environment variables take effect."
  echo "Not removed: system packages (cmake, ninja, minicom, ...) and your dialout group membership."
}

case "$CMD" in
  install|update) do_install ;;
  uninstall) do_uninstall ;;
  attach-evk) setup_wsl_usbip; attach_evk ;;
esac
