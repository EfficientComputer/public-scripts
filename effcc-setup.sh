#!/usr/bin/env bash
# effcc-setup.sh - install, update, or uninstall the Efficient Computer effcc SDK
# on Linux, Windows (WSL), and macOS from the effcc Python wheel.
#
# Usage:
#   effcc-setup.sh install   [options]   # first-time install
#   effcc-setup.sh update    [options]   # move an existing install to a new wheel
#   effcc-setup.sh uninstall [options]   # remove everything this script created
#
# Common options:
#   --wheel <path>     effcc wheel to install (default: newest effcc-*.whl in the
#                      current directory, then ~/Downloads)
#   --extras <list>    comma-separated pip extras: litert, onnx, executorch, all.
#                      Needs the effcc_ml wheel in the same directory as the effcc wheel.
#   --no-kit           don't install the eff_kit wheel even if one is next to the effcc wheel
#   --venv <dir>       Python virtual environment to use (default: ~/effcc-env)
#   --python <exe>     Python interpreter used to create the environment
#   --no-deps          skip installing system packages (cmake, ninja, minicom, ...)
#   --no-udev          skip installing the udev rules (Linux only)
#   --no-shell         don't edit your shell profile
#   --yes              don't ask for confirmation
#   --purge            (uninstall) also offer to delete older zip installs, downloaded
#                      effcc zips, and older ML environments found in your home directory
#   -h, --help         show this help
#
# Piped form:
#   curl -fsSL <url>/effcc-setup.sh | bash -s -- install --wheel ~/Downloads/effcc-<version>-*.whl

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
VENV="${EFFCC_VENV:-$HOME/effcc-env}"
LINK="$HOME/effcc"
WHEEL=""
EXTRAS=""
INSTALL_KIT=1
PYTHON=""
DO_DEPS=1
DO_UDEV=1
DO_SHELL=1
ASSUME_YES=0
PURGE=0
CMD=""

UDEV_RULES_PATH="/etc/udev/rules.d/99-efficient.rules"
UDEV_RULES='# Efficient Computer udev rules (installed by effcc-setup.sh)
SUBSYSTEM=="tty", ATTRS{idVendor}=="38e1", ATTRS{idProduct}=="0001", ENV{ID_USB_INTERFACE_NUM}=="00", SYMLINK+="eff-prog", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="38e1", ATTRS{idProduct}=="0001", ENV{ID_USB_INTERFACE_NUM}=="02", SYMLINK+="eff-power", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="38e1", ATTRS{idProduct}=="0001", ENV{ID_USB_INTERFACE_NUM}=="04", SYMLINK+="eff-console", MODE="0666"'

BEGIN_MARK="# >>> effcc SDK >>>"
END_MARK="# <<< effcc SDK <<<"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

confirm() {
  # confirm <question>; returns 0 for yes
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

OS="$(uname -s)"
ARCH="$(uname -m)"
IS_WSL=0
if [ "$OS" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi

shell_rc() {
  # The profile file the user's login shell reads.
  case "$(basename "${SHELL:-bash}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "$HOME/.bashrc" ;;
  esac
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    install|update|uninstall) CMD="$1" ;;
    --wheel)   WHEEL="$2"; shift ;;
    --wheel=*) WHEEL="${1#*=}" ;;
    --extras)  EXTRAS="$2"; shift ;;
    --extras=*) EXTRAS="${1#*=}" ;;
    --no-kit)  INSTALL_KIT=0 ;;
    --venv)    VENV="$2"; shift ;;
    --venv=*)  VENV="${1#*=}" ;;
    --python)  PYTHON="$2"; shift ;;
    --python=*) PYTHON="${1#*=}" ;;
    --no-deps) DO_DEPS=0 ;;
    --no-udev) DO_UDEV=0 ;;
    --no-shell) DO_SHELL=0 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --purge)   PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[ -n "$CMD" ] || { usage; exit 1; }

# Run as the user who will use the SDK, not as root: the environment, link, and shell
# profile all live in $HOME, and the script calls sudo itself for the steps that need it.
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
    if ! command -v brew >/dev/null 2>&1; then
      die "Homebrew is required on macOS. Install it from https://brew.sh and rerun."
    fi
    brew install cmake ninja minicom git python@3.12 >/dev/null || warn "brew install reported a problem; continuing"
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq build-essential binutils libcurl4-openssl-dev cmake ninja-build git minicom unzip \
      python3 python3-venv python3-pip
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y gcc glibc-devel binutils libcurl-devel cmake ninja-build git minicom unzip python3 python3-pip
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

# An interpreter is usable only if it can create a venv that has pip
# (Debian/Ubuntu split ensurepip into python3.X-venv, and deadsnakes builds often lack it).
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
  # uv-managed interpreters, if uv is installed.
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

extras_need_old_python() {
  # ML extras need Python 3.10-3.13 because tosa-converter-for-tflite ships no 3.14 wheel.
  [ -n "$EXTRAS" ]
}

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
  local wheel="$1" dir spec kit ml
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

  if [ "$INSTALL_KIT" = 1 ]; then
    kit="$(newest "$dir"/eff_kit-"$(wheel_version "$wheel")"*.whl "$dir"/eff_kit-*.whl)"
    if [ -n "$kit" ]; then
      say "Installing $(basename "$kit")"
      "$VENV/bin/python" -m pip install --upgrade "$kit"
      ok "eff-kit installed"
    fi
  fi
}

pkg_dir() { "$VENV/bin/python" -I -c "import importlib.util,os;s=importlib.util.find_spec('$1');print(os.path.dirname(s.origin) if s and s.origin else (s.submodule_search_locations[0] if s and s.submodule_search_locations else ''))" 2>/dev/null; }

link_install() {
  local effcc_dir kit_dir stamp
  effcc_dir="$(pkg_dir effcc)"
  [ -n "$effcc_dir" ] && [ -x "$effcc_dir/bin/effcc" ] || die "effcc package not found in $VENV after install"

  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    # A real directory here is an older zip-based install.
    stamp="$LINK.old-$(date +%Y%m%d-%H%M%S)"
    if confirm "$LINK is an existing (zip-based) install. Move it to $stamp?"; then
      mv "$LINK" "$stamp"; ok "moved old install to $stamp (delete it when you no longer need it)"
    else
      die "refusing to overwrite $LINK. Remove or rename it and rerun."
    fi
  fi
  ln -sfn "$effcc_dir" "$LINK"
  ok "$LINK -> $effcc_dir"

  # eff-kit: either folded into the effcc package or installed as its own wheel.
  if [ ! -e "$LINK/eff_kit" ]; then
    kit_dir="$(pkg_dir eff_kit)"
    if [ -n "$kit_dir" ] && [ -d "$kit_dir" ]; then
      ln -sfn "$kit_dir" "$effcc_dir/eff_kit" 2>/dev/null && ok "$LINK/eff_kit -> $kit_dir" || warn "could not link eff_kit into $LINK"
    fi
  fi
}

write_shell_profile() {
  [ "$DO_SHELL" = 1 ] || return 0
  local rc; rc="$(shell_rc)"
  say "Updating $rc"
  mkdir -p "$(dirname "$rc")"; touch "$rc"
  # Drop the deprecated EFFTOOLS_DIR lines and any block we wrote earlier.
  local tmp; tmp="$(mktemp)"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b {skip=1; next} $0==e {skip=0; next}
    skip {next}
    /EFFTOOLS_DIR/ {next}
    {print}' "$rc" > "$tmp" && cat "$tmp" > "$rc" && rm -f "$tmp"
  if [[ "$rc" == *fish* ]]; then
    printf '\n%s\nset -gx EFFCC_DIR "%s"\nfish_add_path -g "$EFFCC_DIR/bin"\n%s\n' "$BEGIN_MARK" "$LINK" "$END_MARK" >> "$rc"
  else
    printf '\n%s\nexport EFFCC_DIR="%s"\ncase ":$PATH:" in *":$EFFCC_DIR/bin:"*) ;; *) export PATH="$PATH:$EFFCC_DIR/bin" ;; esac\n%s\n' \
      "$BEGIN_MARK" "$LINK" "$END_MARK" >> "$rc"
  fi
  ok "EFFCC_DIR and PATH set in $rc (open a new terminal, or: source $rc)"
}

install_udev() {
  [ "$OS" = "Linux" ] || return 0
  [ "$DO_UDEV" = 1 ] || return 0
  say "Installing udev rules for the EVK serial ports ($UDEV_RULES_PATH)"
  if ! command -v sudo >/dev/null 2>&1; then warn "sudo not available; skipping udev rules (use eff-flash --port instead)"; return 0; fi
  printf '%s\n' "$UDEV_RULES" | sudo tee "$UDEV_RULES_PATH" >/dev/null
  sudo udevadm control --reload-rules && sudo udevadm trigger || true
  # Belt and braces: WSL does not always apply MODE from udev, so also join dialout.
  if getent group dialout >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
    sudo usermod -a -G dialout "$USER" && ok "added $USER to the dialout group (takes effect at next login)"
  fi
  ok "udev rules installed; unplug and replug the EVK to get /dev/eff-prog, /dev/eff-power, /dev/eff-console"
}

verify() {
  say "Verifying"
  "$LINK/bin/effcc" --version | sed -n 's/^Version: /  effcc /p'
  "$LINK/bin/eff-flash" --help >/dev/null 2>&1 && echo "  eff-flash $("$LINK/bin/eff-flash" --version 2>/dev/null | awk '/^eff-flash/{print $2}')"
  if [ "$OS" = "Linux" ] && ! "$LINK/bin/eff-lldb" --version >/dev/null 2>&1; then
    warn "eff-lldb/eff-prof could not start; on Ubuntu 26.04 they need libxml2.so.2 (see the FAQ in the docs)"
  fi
}

do_install() {
  local wheel; wheel="$(find_wheel)"
  say "$CMD: $(basename "$wheel") -> $VENV, linked at $LINK"
  install_deps
  ensure_venv
  pip_install "$wheel"
  link_install
  write_shell_profile
  install_udev
  verify
  cat <<EOF

Done. Open a new terminal (or run: source $(shell_rc)) and then:
  effcc --version
  git clone https://github.com/EfficientComputer/e1x_examples.git
  cd e1x_examples/app_examples && cmake -S . -B bld -G Ninja && cmake --build bld --target quickstart/fabric/quickstart
  eff-flash bld/quickstart/fabric/quickstart
EOF
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
do_uninstall() {
  say "Uninstalling the effcc SDK"
  local rc tmp d f

  # 1. The ~/effcc link (or directory, for zip-based installs).
  if [ -L "$LINK" ]; then rm -f "$LINK"; ok "removed symlink $LINK"
  elif [ -d "$LINK" ]; then
    if confirm "$LINK is a directory (zip-based install). Delete it?"; then rm -rf "$LINK"; ok "removed $LINK"; fi
  fi

  # 2. The Python environment that holds the wheel.
  if [ -d "$VENV" ]; then
    if confirm "Delete the Python environment $VENV?"; then rm -rf "$VENV"; ok "removed $VENV"; fi
  fi

  # 3. Shell profile lines.
  if [ "$DO_SHELL" = 1 ]; then
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.zprofile" "$HOME/.config/fish/config.fish"; do
      [ -f "$rc" ] || continue
      if grep -q -e "$BEGIN_MARK" -e EFFCC_DIR -e EFFTOOLS_DIR "$rc"; then
        tmp="$(mktemp)"
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
          $0==b {skip=1; next} $0==e {skip=0; next}
          skip {next}
          /EFFTOOLS_DIR|EFFCC_DIR/ {next}
          {print}' "$rc" > "$tmp" && cat "$tmp" > "$rc" && rm -f "$tmp"
        ok "removed effcc lines from $rc"
      fi
    done
  fi

  # 4. udev rules.
  if [ "$OS" = "Linux" ] && [ -f "$UDEV_RULES_PATH" ] && [ "$DO_UDEV" = 1 ]; then
    if confirm "Remove the EVK udev rules ($UDEV_RULES_PATH)?"; then
      sudo rm -f "$UDEV_RULES_PATH" && sudo udevadm control --reload-rules && ok "removed udev rules"
    fi
  fi

  # 5. Optional: leftovers from older installs. Only with --purge, and each one is
  #    confirmed individually even when --yes was given.
  if [ "$PURGE" = 1 ]; then
    local saved_yes="$ASSUME_YES"; ASSUME_YES=0
    for d in "$LINK".old-* "$HOME"/effcc_v*/ "$HOME/effcc-litert-env" "$HOME/effcc-onnx-env"; do
      [ -d "$d" ] || continue
      if confirm "Delete $d?"; then rm -rf "$d"; ok "removed $d"; fi
    done
    for f in "$HOME"/effcc_v*.zip "$HOME"/Downloads/effcc*.whl "$HOME"/Downloads/effcc_v*.zip "$HOME"/Downloads/eff_kit-*.whl; do
      [ -f "$f" ] || continue
      if confirm "Delete $f?"; then rm -f "$f"; ok "removed $f"; fi
    done
    ASSUME_YES="$saved_yes"
  else
    for d in "$LINK".old-* "$HOME"/effcc_v*/ "$HOME/effcc-litert-env" "$HOME/effcc-onnx-env"; do
      [ -d "$d" ] && echo "left in place: $d (rerun with --purge to be asked about it)"
    done
  fi

  echo
  echo "Uninstall complete. Open a new terminal so the removed environment variables take effect."
  echo "Not removed: system packages (cmake, ninja, minicom, ...) and your dialout group membership."
}

case "$CMD" in
  install|update) do_install ;;
  uninstall) do_uninstall ;;
esac
