#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — Install prompter as a system-wide CLI command
#
# Creates a symlink so you can run `prompter` from any directory.
# The workspace is wherever you invoke it from (cwd).
#
# Usage:
#   ./install.sh              # symlinks to /usr/local/bin/prompter
#   ./install.sh ~/.local/bin # symlinks to ~/.local/bin/prompter
#   ./install.sh --uninstall  # removes the symlink
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTER_SH="$SCRIPT_DIR/prompter.sh"
COMMAND_NAME="prompter"

# Terminal colours
T_BOLD="" T_RESET="" T_GREEN="" T_RED="" T_DIM="" T_CYAN=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  T_BOLD="$(tput bold || true)"
  T_RESET="$(tput sgr0 || true)"
  T_GREEN="$(tput setaf 2 || true)"
  T_RED="$(tput setaf 1 || true)"
  T_DIM="$(tput dim || true)"
  T_CYAN="$(tput setaf 6 || true)"
fi

usage() {
  cat <<EOF
${T_BOLD}Install prompter CLI${T_RESET}

${T_BOLD}Usage${T_RESET}
  ./install.sh [install-dir]   Install (default: /usr/local/bin)
  ./install.sh --uninstall     Remove the symlink

${T_BOLD}Examples${T_RESET}
  ./install.sh                 # ${T_DIM}sudo may be needed for /usr/local/bin${T_RESET}
  ./install.sh ~/.local/bin    # ${T_DIM}no sudo needed${T_RESET}
  ./install.sh --uninstall

${T_BOLD}After install${T_RESET}
  cd /path/to/any/project
  prompter                     # ${T_DIM}interactive mode, workspace = cwd${T_RESET}
  prompter "fix the login bug" # ${T_DIM}one-shot mode${T_RESET}
EOF
}

check_prerequisites() {
  local missing=()

  if ! command -v node >/dev/null 2>&1; then
    missing+=("node")
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    missing+=("python3")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s%sWarning:%s Missing prerequisites: %s\n' "$T_BOLD" "$T_RED" "$T_RESET" "${missing[*]}"
    printf '%sThese are required at runtime. Install them before using prompter.%s\n\n' "$T_DIM" "$T_RESET"
  fi
}

find_best_install_dir() {
  # Prefer user-local dirs that are already in PATH
  for dir in "$HOME/.local/bin" "$HOME/bin"; do
    if echo "$PATH" | tr ':' '\n' | grep -qx "$dir"; then
      echo "$dir"
      return 0
    fi
  done

  # Try /usr/local/bin if writable
  if [[ -d /usr/local/bin ]] && [[ -w /usr/local/bin ]]; then
    echo "/usr/local/bin"
    return 0
  fi

  # Fall back to ~/.local/bin — will be created, user may need to add to PATH
  echo "$HOME/.local/bin"
}

do_install() {
  local install_dir="$1"
  if [[ -z "$install_dir" ]]; then
    install_dir="$(find_best_install_dir)"
  fi
  local link_path="$install_dir/$COMMAND_NAME"

  # Validate source exists
  if [[ ! -f "$PROMPTER_SH" ]]; then
    printf '%s%sError:%s Cannot find prompter.sh at %s\n' "$T_BOLD" "$T_RED" "$T_RESET" "$PROMPTER_SH" >&2
    exit 1
  fi

  # Ensure prompter.sh is executable
  chmod +x "$PROMPTER_SH"

  # Ensure install directory exists
  if [[ ! -d "$install_dir" ]]; then
    printf '%sCreating %s%s\n' "$T_DIM" "$install_dir" "$T_RESET"
    mkdir -p "$install_dir" 2>/dev/null || {
      printf '%s%sError:%s Cannot create %s — try with sudo or use a different directory.\n' \
        "$T_BOLD" "$T_RED" "$T_RESET" "$install_dir" >&2
      exit 1
    }
  fi

  # Check if already installed
  if [[ -L "$link_path" ]]; then
    local existing_target
    existing_target="$(readlink "$link_path")"
    if [[ "$existing_target" == "$PROMPTER_SH" ]]; then
      printf '%s%s✓ Already installed%s at %s\n' "$T_BOLD" "$T_GREEN" "$T_RESET" "$link_path"
      return 0
    fi
    printf '%sReplacing existing symlink%s (%s -> %s)\n' "$T_DIM" "$T_RESET" "$link_path" "$existing_target"
    rm "$link_path" 2>/dev/null || {
      printf '%s%sError:%s Cannot remove existing %s — try with sudo.\n' \
        "$T_BOLD" "$T_RED" "$T_RESET" "$link_path" >&2
      exit 1
    }
  elif [[ -e "$link_path" ]]; then
    printf '%s%sError:%s %s already exists and is not a symlink. Remove it first.\n' \
      "$T_BOLD" "$T_RED" "$T_RESET" "$link_path" >&2
    exit 1
  fi

  # Create symlink
  ln -s "$PROMPTER_SH" "$link_path" 2>/dev/null || {
    printf '%s%sError:%s Cannot create symlink at %s — try with sudo.\n' \
      "$T_BOLD" "$T_RED" "$T_RESET" "$link_path" >&2
    printf '\n  sudo ./install.sh %s\n\n' "$install_dir"
    exit 1
  }

  printf '\n'
  printf '  %s%s✓ Installed%s\n' "$T_BOLD" "$T_GREEN" "$T_RESET"
  printf '  %s%s%s -> %s\n\n' "$T_DIM" "$link_path" "$T_RESET" "$PROMPTER_SH"

  # Check if install_dir is in PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$install_dir"; then
    printf '  %s%sNote:%s %s is not in your PATH.\n' "$T_BOLD" "$T_RED" "$T_RESET" "$install_dir"
    printf '  Add it to your shell profile:\n\n'
    printf '    export PATH="%s:$PATH"\n\n' "$install_dir"
  else
    printf '  Run %s%sprompter%s from any directory to get started.\n\n' "$T_BOLD" "$T_CYAN" "$T_RESET"
  fi

  check_prerequisites
}

do_uninstall() {
  # Search common locations
  local found=false
  for dir in /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    local link_path="$dir/$COMMAND_NAME"
    if [[ -L "$link_path" ]]; then
      local target
      target="$(readlink "$link_path")"
      rm "$link_path" 2>/dev/null || {
        printf '%s%sError:%s Cannot remove %s — try with sudo.\n' \
          "$T_BOLD" "$T_RED" "$T_RESET" "$link_path" >&2
        exit 1
      }
      printf '  %s%s✓ Removed%s %s (was -> %s)\n' "$T_BOLD" "$T_GREEN" "$T_RESET" "$link_path" "$target"
      found=true
    fi
  done

  if [[ "$found" == "false" ]]; then
    printf '  %sNo prompter symlink found in common locations.%s\n' "$T_DIM" "$T_RESET"
    printf '  %sCheck: which prompter%s\n' "$T_DIM" "$T_RESET"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
  --help|-h)
    usage
    ;;
  --uninstall)
    do_uninstall
    ;;
  *)
    do_install "${1:-}"
    ;;
esac
