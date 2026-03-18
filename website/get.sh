#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# get.sh — Remote installer for prompter
#
# Usage:
#   curl -fsSL https://prompter-7fe6d.web.app/get.sh | bash
#   curl -fsSL https://prompter-7fe6d.web.app/get.sh | bash -s -- ~/.local/bin
# ---------------------------------------------------------------------------

REPO="https://github.com/the-ginger-geek/prompter.git"
INSTALL_DIR="${HOME}/.prompter"
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

info()  { printf '  %s%s%s\n' "$T_DIM" "$1" "$T_RESET"; }
ok()    { printf '  %s%s%s%s\n' "$T_BOLD" "$T_GREEN" "$1" "$T_RESET"; }
err()   { printf '  %s%s%s%s\n' "$T_BOLD" "$T_RED" "$1" "$T_RESET" >&2; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  command -v git    >/dev/null 2>&1 || missing+=("git")
  command -v node   >/dev/null 2>&1 || missing+=("node")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    printf '\n  Install them first, then re-run this script.\n\n'
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Find or create a bin directory on PATH
# ---------------------------------------------------------------------------
find_bin_dir() {
  local custom="${1:-}"
  if [[ -n "$custom" ]]; then
    echo "$custom"
    return
  fi

  for dir in "$HOME/.local/bin" "$HOME/bin"; do
    if echo "$PATH" | tr ':' '\n' | grep -qx "$dir"; then
      echo "$dir"
      return
    fi
  done

  # Default to ~/.local/bin
  echo "$HOME/.local/bin"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  printf '\n'
  printf '  %s%sprompter installer%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET"
  printf '  %s%s%s\n\n' "$T_DIM" "$(printf '%.0s─' {1..40})" "$T_RESET"

  check_deps

  # Clone or update
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only --quiet 2>/dev/null || {
      info "Pull failed, re-cloning..."
      rm -rf "$INSTALL_DIR"
      git clone --quiet "$REPO" "$INSTALL_DIR"
    }
  else
    if [[ -d "$INSTALL_DIR" ]]; then
      rm -rf "$INSTALL_DIR"
    fi
    info "Cloning prompter..."
    git clone --quiet "$REPO" "$INSTALL_DIR"
  fi

  chmod +x "$INSTALL_DIR/prompter.sh"
  chmod +x "$INSTALL_DIR/install.sh"

  # Symlink into PATH
  local bin_dir
  bin_dir="$(find_bin_dir "${1:-}")"
  local link_path="$bin_dir/$COMMAND_NAME"

  mkdir -p "$bin_dir" 2>/dev/null || true

  # Remove existing symlink if present
  if [[ -L "$link_path" ]]; then
    rm "$link_path"
  elif [[ -e "$link_path" ]]; then
    err "$link_path already exists and is not a symlink."
    err "Remove it manually, then re-run."
    exit 1
  fi

  ln -s "$INSTALL_DIR/prompter.sh" "$link_path" 2>/dev/null || {
    err "Cannot create symlink at $link_path"
    printf '\n  Try: sudo ln -s %s %s\n\n' "$INSTALL_DIR/prompter.sh" "$link_path"
    exit 1
  }

  printf '\n'
  ok "prompter installed!"
  printf '\n'
  info "$link_path -> $INSTALL_DIR/prompter.sh"
  printf '\n'

  # Check PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$bin_dir"; then
    printf '  %s%sNote:%s Add %s to your PATH:\n\n' "$T_BOLD" "$T_RED" "$T_RESET" "$bin_dir"
    printf '    export PATH="%s:\$PATH"\n\n' "$bin_dir"
  else
    info "Run ${T_CYAN}prompter${T_RESET}${T_DIM} in any project directory to get started."
    printf '\n'
  fi

  # Update instructions
  printf '  %sTo update:%s  curl -fsSL https://prompter-7fe6d.web.app/get.sh | bash\n' "$T_DIM" "$T_RESET"
  printf '  %sTo remove:%s  rm -rf %s && rm %s\n\n' "$T_DIM" "$T_RESET" "$INSTALL_DIR" "$link_path"
}

main "$@"
