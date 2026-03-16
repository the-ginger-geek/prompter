#!/usr/bin/env bash
set -euo pipefail

# Resolve through symlinks so PROMPTER_DIR points to the real source,
# not e.g. /usr/local/bin when installed as a symlink.
_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    # If readlink returns a relative path, resolve it against the dir
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
PROMPTER_DIR="$(_resolve_script_dir)"
INPUT_CAPTURE_SCRIPT="$PROMPTER_DIR/prompter-input.mjs"
WORKSPACE_DIR="$(pwd)"

# ---------------------------------------------------------------------------
# Startup checks — only node is required upfront; agent CLI checked lazily
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "Error: node is required for secure interactive capture." >&2
  exit 1
fi

if [[ ! -f "$INPUT_CAPTURE_SCRIPT" ]]; then
  echo "Error: missing input capture module at $INPUT_CAPTURE_SCRIPT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Terminal colours — resolved once, reused everywhere
# ---------------------------------------------------------------------------
T_BOLD="" T_RESET="" T_CYAN="" T_DIM="" T_GREEN="" T_RED="" T_YELLOW="" T_MAGENTA="" T_WHITE=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  T_BOLD="$(tput bold || true)"
  T_RESET="$(tput sgr0 || true)"
  T_CYAN="$(tput setaf 6 || true)"
  T_DIM="$(tput dim || true)"
  T_GREEN="$(tput setaf 2 || true)"
  T_RED="$(tput setaf 1 || true)"
  T_YELLOW="$(tput setaf 3 || true)"
  T_MAGENTA="$(tput setaf 5 || true)"
  T_WHITE="$(tput setaf 7 || true)"
fi

# ---------------------------------------------------------------------------
# Settings — global + per-project config
# ---------------------------------------------------------------------------
SETTINGS_DIR="$HOME/.config/prompter"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

SETTING_AGENT="codex"
SETTING_DEFAULT_MODE="execute"
SETTING_MODEL=""
SETTING_CODEX_SANDBOX="workspace-write"

ensure_settings_dir() {
  [[ -d "$SETTINGS_DIR" ]] || mkdir -p "$SETTINGS_DIR"
}

load_settings() {
  ensure_settings_dir

  # Create default global settings if missing
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    cat > "$SETTINGS_FILE" <<'JSON'
{
  "agent": "codex",
  "defaultMode": "execute",
  "codex": { "model": null, "sandbox": "workspace-write" },
  "claude": { "model": null },
  "gemini": { "model": null }
}
JSON
  fi

  # Read global settings via python3
  eval "$(python3 - "$SETTINGS_FILE" <<'PY'
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
agent = data.get('agent', 'codex')
mode = data.get('defaultMode', 'execute')
agent_cfg = data.get(agent, {})
model = agent_cfg.get('model') or ''
sandbox = data.get('codex', {}).get('sandbox', 'workspace-write')
print(f'SETTING_AGENT="{agent}"')
print(f'SETTING_DEFAULT_MODE="{mode}"')
print(f'SETTING_MODEL="{model}"')
print(f'SETTING_CODEX_SANDBOX="{sandbox}"')
PY
  )"

  # Override with per-project .prompter.json if present
  local project_config="$WORKSPACE_DIR/.prompter.json"
  if [[ -f "$project_config" ]]; then
    eval "$(python3 - "$project_config" "$SETTING_AGENT" "$SETTING_DEFAULT_MODE" <<'PY'
import json, sys
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
agent = data.get('agent', sys.argv[2])
mode = data.get('defaultMode', sys.argv[3])
print(f'SETTING_AGENT="{agent}"')
print(f'SETTING_DEFAULT_MODE="{mode}"')
PY
    )"
    HAS_PROJECT_CONFIG=true
  else
    HAS_PROJECT_CONFIG=false
  fi
}

save_global_settings() {
  ensure_settings_dir
  python3 - "$SETTINGS_FILE" "$SETTING_AGENT" "$SETTING_DEFAULT_MODE" "$SETTING_MODEL" "$SETTING_CODEX_SANDBOX" <<'PY'
import json, sys
path, agent, mode, model, sandbox = sys.argv[1:6]
try:
    with open(path, 'r') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data['agent'] = agent
data['defaultMode'] = mode
for a in ['codex', 'claude', 'gemini']:
    if a not in data:
        data[a] = {}
if model:
    data[agent]['model'] = model
else:
    data[agent]['model'] = None
data['codex']['sandbox'] = sandbox
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
}

# ---------------------------------------------------------------------------
# Progress spinner
# ---------------------------------------------------------------------------
SPINNER_PID=""

start_spinner() {
  local msg="${1:-Working}"
  printf "\r${T_CYAN}⠋${T_RESET} ${T_DIM}%s${T_RESET}" "$msg"

  (
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=1
    while true; do
      sleep 0.08
      printf "\r${T_CYAN}${frames[$i]}${T_RESET} ${T_DIM}%s${T_RESET}" "$msg"
      i=$(( (i + 1) % ${#frames[@]} ))
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[2K"
  fi
}

cleanup_on_exit() {
  stop_spinner
  if [[ "${_WINDOW_ACTIVE:-}" == "true" ]]; then
    [[ -n "${_WINDOW_RENDER_PID:-}" ]] && kill "$_WINDOW_RENDER_PID" 2>/dev/null || true
    printf '\e[?25h'   # show cursor
    printf '\e[?1049l'  # leave alternate screen
    _WINDOW_ACTIVE=false
  fi
}
trap 'cleanup_on_exit' EXIT

# ---------------------------------------------------------------------------
# Output colorizer — highlights code/diffs in agent output
# ---------------------------------------------------------------------------
colorize_output() {
  if [[ -z "$T_RESET" ]]; then
    cat
    return
  fi

  # Strip agent's own ANSI codes, then render everything in light grey
  sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s%s%s\n' "$T_DIM" "$line" "$T_RESET"
  done
}

# ---------------------------------------------------------------------------
# Windowed output — agent output rendered in a fixed terminal viewport
#
# Strategy: agent writes to a log file only (no terminal output). A background
# renderer periodically tails the file and redraws the last N lines in a fixed
# window area. This avoids scroll region issues with agents that write directly
# to the terminal or emit their own ANSI sequences.
# ---------------------------------------------------------------------------
_WINDOW_ACTIVE=false
_WINDOW_ROWS=0
_WINDOW_COLS=0
_WINDOW_CONTENT_TOP=0
_WINDOW_CONTENT_BOTTOM=0
_WINDOW_STATUS_ROW=0
_WINDOW_START_TIME=0
_WINDOW_RENDER_PID=""
_WINDOW_LOG_FILE=""

setup_output_window() {
  local header="$1"
  local sub_header="${2:-}"

  if [[ -z "$T_RESET" ]] || ! command -v tput >/dev/null 2>&1; then
    printf '\n  %s\n\n' "$header"
    return 1
  fi

  local rows cols
  rows=$(tput lines 2>/dev/null) || rows=24
  cols=$(tput cols 2>/dev/null) || cols=80

  if [[ $rows -lt 12 ]]; then
    printf '\n  %s\n\n' "$header"
    return 1
  fi

  # Layout:
  #   Row 1:          header
  #   Row 2:          sub-header
  #   Row 3:          top border ────
  #   Row 4..(R-3):   content area (last N lines of agent output)
  #   Row (R-2):      bottom border ────
  #   Row (R-1):      status line (spinner + elapsed)
  #   Row R:          (cursor park)

  local content_top=4
  local content_bottom=$((rows - 3))
  local status_row=$((rows - 2))
  local border_char
  border_char="$(printf '%.0s─' $(seq 1 "$cols"))"

  # Switch to alternate screen buffer — preserves original terminal content
  printf '\e[?1049h'
  printf '\e[2J\e[H'

  # Header
  printf '  %s%s%s\n' "$T_BOLD" "$header" "$T_RESET"

  # Sub-header
  if [[ -n "$sub_header" ]]; then
    printf '  %s%s%s\n' "$T_DIM" "$sub_header" "$T_RESET"
  else
    printf '\n'
  fi

  # Top border
  printf '%s%s%s' "$T_DIM" "$border_char" "$T_RESET"

  # Bottom border
  printf '\e[%d;1H' "$((content_bottom + 1))"
  printf '%s%s%s' "$T_DIM" "$border_char" "$T_RESET"

  # Initial status
  printf '\e[%d;1H' "$status_row"
  printf '  %s⠋ Starting...%s' "$T_CYAN" "$T_RESET"

  # Hide cursor
  printf '\e[?25l'

  _WINDOW_ACTIVE=true
  _WINDOW_ROWS=$rows
  _WINDOW_COLS=$cols
  _WINDOW_CONTENT_TOP=$content_top
  _WINDOW_CONTENT_BOTTOM=$content_bottom
  _WINDOW_STATUS_ROW=$status_row
  _WINDOW_START_TIME=$(date +%s)

  return 0
}

# Background process: renders log file tail + status into the window
_start_window_renderer() {
  local log_file="$1"
  _WINDOW_LOG_FILE="$log_file"

  _window_render_loop "$log_file" &
  _WINDOW_RENDER_PID=$!
  disown "$_WINDOW_RENDER_PID" 2>/dev/null || true
}

_window_render_loop() {
  local log_file="$1"
  local content_top=$_WINDOW_CONTENT_TOP
  local content_bottom=$_WINDOW_CONTENT_BOTTOM
  local status_row=$_WINDOW_STATUS_ROW
  local cols=$_WINDOW_COLS
  local visible_lines=$((content_bottom - content_top + 1))
  local start_time=$_WINDOW_START_TIME

  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local frame_i=0
  local last_line_count=0

  while true; do
    sleep 0.5

    # ---- Render content area ----
    local current_lines=0
    if [[ -f "$log_file" ]]; then
      # Get last N lines, strip ANSI codes, truncate to terminal width
      local content
      content="$(tail -n "$visible_lines" "$log_file" 2>/dev/null | \
        sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | \
        cut -c1-"$((cols - 1))")"

      local row=$content_top
      while IFS= read -r line; do
        printf '\e[%d;1H\e[2K %s%s%s' "$row" "$T_DIM" "$line" "$T_RESET"
        row=$((row + 1))
        current_lines=$((current_lines + 1))
      done <<< "$content"

      # Clear remaining rows if content shrank
      while [[ $row -le $content_bottom ]]; do
        printf '\e[%d;1H\e[2K' "$row"
        row=$((row + 1))
      done
    fi

    # ---- Render status line ----
    local now elapsed_s mins secs elapsed_str
    now=$(date +%s)
    elapsed_s=$((now - start_time))
    mins=$((elapsed_s / 60))
    secs=$((elapsed_s % 60))
    if [[ $mins -gt 0 ]]; then
      elapsed_str="${mins}m ${secs}s"
    else
      elapsed_str="${secs}s"
    fi

    printf '\e[%d;1H\e[2K' "$status_row"
    printf '  %s%s Running...  %s%s' "$T_CYAN" "${frames[$frame_i]}" "$elapsed_str" "$T_RESET"

    frame_i=$(( (frame_i + 1) % ${#frames[@]} ))
  done
}

teardown_output_window() {
  local exit_code="${1:-0}"

  if [[ "${_WINDOW_ACTIVE}" != "true" ]]; then
    return
  fi

  # Stop renderer
  if [[ -n "${_WINDOW_RENDER_PID:-}" ]]; then
    kill "$_WINDOW_RENDER_PID" 2>/dev/null || true
    wait "$_WINDOW_RENDER_PID" 2>/dev/null || true
    _WINDOW_RENDER_PID=""
  fi

  # Final render of content
  if [[ -f "${_WINDOW_LOG_FILE:-}" ]]; then
    local visible_lines=$((_WINDOW_CONTENT_BOTTOM - _WINDOW_CONTENT_TOP + 1))
    local content
    content="$(tail -n "$visible_lines" "$_WINDOW_LOG_FILE" 2>/dev/null | \
      sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | \
      cut -c1-"$((_WINDOW_COLS - 1))")"
    local row=$_WINDOW_CONTENT_TOP
    while IFS= read -r line; do
      printf '\e[%d;1H\e[2K %s%s%s' "$row" "$T_DIM" "$line" "$T_RESET"
      row=$((row + 1))
    done <<< "$content"
    while [[ $row -le $_WINDOW_CONTENT_BOTTOM ]]; do
      printf '\e[%d;1H\e[2K' "$row"
      row=$((row + 1))
    done
  fi

  # Elapsed time
  local now elapsed_s mins secs elapsed_str
  now=$(date +%s)
  elapsed_s=$((now - _WINDOW_START_TIME))
  mins=$((elapsed_s / 60))
  secs=$((elapsed_s % 60))
  if [[ $mins -gt 0 ]]; then
    elapsed_str="${mins}m ${secs}s"
  else
    elapsed_str="${secs}s"
  fi

  # Update status line with result
  printf '\e[%d;1H\e[2K' "$_WINDOW_STATUS_ROW"
  if [[ "$exit_code" -eq 0 ]]; then
    printf '  %s%s✓ Done%s  %s%s%s' "$T_BOLD" "$T_GREEN" "$T_RESET" "$T_DIM" "$elapsed_str" "$T_RESET"
  else
    printf '  %s%s✗ Failed%s (exit %s)  %s%s%s' "$T_BOLD" "$T_RED" "$T_RESET" "$exit_code" "$T_DIM" "$elapsed_str" "$T_RESET"
  fi

  # Show cursor, wait for user to see the result
  printf '\e[?25h'
  printf '\e[%d;1H' "$_WINDOW_ROWS"

  if [[ -t 0 ]]; then
    printf '\n  %sPress any key to continue...%s' "$T_DIM" "$T_RESET"
    read -r -n 1 -s </dev/tty 2>/dev/null || true
  fi

  # Leave alternate screen — restores original terminal content
  printf '\e[?1049l'

  _WINDOW_ACTIVE=false
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
print_help() {
  cat <<HELP
${T_BOLD}Prompter CLI${T_RESET}

${T_BOLD}Commands${T_RESET}
  /help             Show this help
  /settings         Configure agent, mode, and model
  /workspace [path] Change workspace directory (tab-completes)
  /discover         Re-discover project expertise categories
  /quit             Exit the CLI

${T_BOLD}Usage${T_RESET}
  ${T_DIM}Interactive:${T_RESET}   ./prompter.sh
  ${T_DIM}One-shot:${T_RESET}     ./prompter.sh "your prompt"
  ${T_DIM}Pipe:${T_RESET}         echo "your prompt" | ./prompter.sh
  ${T_DIM}Workspace:${T_RESET}    ./prompter.sh -w /path/to/repo "your prompt"

${T_BOLD}Options${T_RESET}
  -w, --workspace <dir>  Set workspace directory (default: cwd)

${T_BOLD}Agents${T_RESET}
  codex      OpenAI Codex CLI (default)
  claude     Anthropic Claude Code CLI
  gemini     Google Gemini CLI

${T_BOLD}Configuration${T_RESET}
  Global:   ~/.config/prompter/settings.json
  Project:  .prompter.json (in workspace root)
HELP
}

print_startup_banner() {
  local config_status
  if [[ "$HAS_PROJECT_CONFIG" == "true" ]]; then
    config_status="${T_GREEN}.prompter.json found${T_RESET}"
  else
    config_status="${T_DIM}global only${T_RESET}"
  fi

  printf '\n'
  printf '  %s%sprompter%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET"
  printf '  %s%s%s\n' "$T_DIM" "$(printf '%.0s─' {1..40})" "$T_RESET"
  local cat_count=""
  if [[ -f "$CATEGORIES_FILE" ]]; then
    cat_count="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
cats = d.get('categories', [])
print(len(cats))
" "$CATEGORIES_FILE" 2>/dev/null || echo 0)"
  fi

  printf '  %sWorkspace:%s  %s\n' "$T_DIM" "$T_RESET" "$WORKSPACE_DIR"
  printf '  %sAgent:%s      %s\n' "$T_DIM" "$T_RESET" "$SETTING_AGENT"
  printf '  %sConfig:%s     %s\n' "$T_DIM" "$T_RESET" "$config_status"
  if [[ -n "$cat_count" && "$cat_count" != "0" ]]; then
    printf '  %sExperts:%s    %s categories  %s(/discover to refresh)%s\n' "$T_DIM" "$T_RESET" "$cat_count" "$T_DIM" "$T_RESET"
  fi
  printf '\n'
  printf '  %s/help%s for commands, %s/settings%s to configure, %s/workspace%s to switch repos.\n\n' \
    "$T_BOLD" "$T_RESET" "$T_BOLD" "$T_RESET" "$T_BOLD" "$T_RESET"
}

print_separator() {
  printf '%s%s%s\n' "$T_DIM" "$(printf '%.0s─' {1..60})" "$T_RESET"
}

print_done_banner() {
  local exit_code="${1:-0}"
  printf '\n'
  print_separator
  if [[ "$exit_code" -eq 0 ]]; then
    printf '  %s%s✓ Done%s\n' "$T_BOLD" "$T_GREEN" "$T_RESET"
  else
    printf '  %s%s✗ Failed%s (exit %s)\n' "$T_BOLD" "$T_RED" "$T_RESET" "$exit_code"
  fi
  print_separator
  printf '\n'
}

count_lines() {
  local text="$1"
  if [[ -z "$text" ]]; then
    echo 0
    return
  fi
  printf '%s\n' "$text" | wc -l | tr -d ' '
}

sha256_of_text() {
  local text="$1"
  printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Workspace detection & directory selection
# ---------------------------------------------------------------------------
detect_workspace() {
  if git -C "$WORKSPACE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  # Not a git repo — prompt for directory if interactive
  if [[ ! -t 0 ]]; then
    return 0  # non-interactive, just use cwd
  fi

  printf '\n' >/dev/tty
  printf '  %s%sNot in a git repository.%s\n' "$T_BOLD" "$T_YELLOW" "$T_RESET" >/dev/tty
  printf '\n' >/dev/tty
  printf '  %s[1]%s Enter a directory path\n' "$T_BOLD" "$T_RESET" >/dev/tty
  printf '  %s[2]%s Continue with current directory (%s)\n' "$T_BOLD" "$T_RESET" "$WORKSPACE_DIR" >/dev/tty
  printf '  %s[q]%s Quit\n' "$T_BOLD" "$T_RESET" >/dev/tty
  printf '\n' >/dev/tty
  printf '  %sChoice%s [1/2/q]: ' "$T_BOLD" "$T_RESET" >/dev/tty

  local choice
  read -r -n 1 choice </dev/tty 2>/dev/null || choice=""
  printf '\n' >/dev/tty

  case "$choice" in
    1)
      printf '  %sPath:%s ' "$T_BOLD" "$T_RESET" >/dev/tty
      local entered_path
      read -r -e entered_path </dev/tty 2>/dev/null || entered_path=""

      # Expand ~ manually
      entered_path="${entered_path/#\~/$HOME}"

      if [[ -z "$entered_path" ]]; then
        printf '  %sNo path entered, using current directory.%s\n' "$T_DIM" "$T_RESET" >/dev/tty
        return 0
      fi

      if [[ ! -d "$entered_path" ]]; then
        printf '  %s%sDirectory does not exist: %s%s\n' "$T_BOLD" "$T_RED" "$entered_path" "$T_RESET" >/dev/tty
        exit 1
      fi

      WORKSPACE_DIR="$(cd "$entered_path" && pwd)"

      if ! git -C "$WORKSPACE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '  %s%sWarning: %s is not a git repository. Continuing anyway.%s\n' \
          "$T_BOLD" "$T_YELLOW" "$WORKSPACE_DIR" "$T_RESET" >/dev/tty
      fi
      ;;
    q|Q)
      printf '%sGoodbye.%s\n' "$T_DIM" "$T_RESET" >/dev/tty
      exit 0
      ;;
    *)
      # Default: continue with current directory
      ;;
  esac
}

# ---------------------------------------------------------------------------
# /settings interactive menu
# ---------------------------------------------------------------------------
interactive_settings_menu() {
  # Reset terminal state — Node's raw mode capture may leave it dirty
  stty sane </dev/tty 2>/dev/null || true
  while true; do
    local model_display="${SETTING_MODEL:-${T_DIM}(default)${T_RESET}}"

    printf '\n' >/dev/tty
    printf '  %s%sSettings%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET" >/dev/tty
    printf '\n' >/dev/tty
    printf '  %s[1]%s Agent:          %s%s%s  %s(codex | claude | gemini)%s\n' \
      "$T_BOLD" "$T_RESET" "$T_YELLOW" "$SETTING_AGENT" "$T_RESET" "$T_DIM" "$T_RESET" >/dev/tty
    printf '  %s[2]%s Default mode:   %s%s%s  %s(execute | plan | loop)%s\n' \
      "$T_BOLD" "$T_RESET" "$T_YELLOW" "$SETTING_DEFAULT_MODE" "$T_RESET" "$T_DIM" "$T_RESET" >/dev/tty
    printf '  %s[3]%s Model override: %s\n' \
      "$T_BOLD" "$T_RESET" "$model_display" >/dev/tty
    printf '\n' >/dev/tty
    printf '  %sChoice%s [1-3, q]: ' "$T_BOLD" "$T_RESET" >/dev/tty

    local choice
    read -r -n 1 choice </dev/tty 2>/dev/null || choice=""
    printf '\n' >/dev/tty

    case "$choice" in
      1)
        printf '  %sAgent%s (codex/claude/gemini): ' "$T_BOLD" "$T_RESET" >/dev/tty
        local new_agent
        read -r new_agent </dev/tty 2>/dev/null || new_agent=""
        case "$new_agent" in
          codex|claude|gemini)
            SETTING_AGENT="$new_agent"
            SETTING_MODEL=""  # reset model when changing agent
            save_global_settings
            printf '  %s✓ Agent set to %s%s\n' "$T_GREEN" "$new_agent" "$T_RESET" >/dev/tty
            ;;
          *)
            printf '  %sInvalid agent. Must be codex, claude, or gemini.%s\n' "$T_RED" "$T_RESET" >/dev/tty
            ;;
        esac
        ;;
      2)
        printf '  %sDefault mode%s (execute/plan/loop): ' "$T_BOLD" "$T_RESET" >/dev/tty
        local new_mode
        read -r new_mode </dev/tty 2>/dev/null || new_mode=""
        case "$new_mode" in
          execute|plan|loop)
            SETTING_DEFAULT_MODE="$new_mode"
            save_global_settings
            printf '  %s✓ Default mode set to %s%s\n' "$T_GREEN" "$new_mode" "$T_RESET" >/dev/tty
            ;;
          *)
            printf '  %sInvalid mode. Must be execute, plan, or loop.%s\n' "$T_RED" "$T_RESET" >/dev/tty
            ;;
        esac
        ;;
      3)
        printf '  %sModel override%s (leave blank for default): ' "$T_BOLD" "$T_RESET" >/dev/tty
        local new_model
        read -r new_model </dev/tty 2>/dev/null || new_model=""
        SETTING_MODEL="$new_model"
        save_global_settings
        if [[ -n "$new_model" ]]; then
          printf '  %s✓ Model set to %s%s\n' "$T_GREEN" "$new_model" "$T_RESET" >/dev/tty
        else
          printf '  %s✓ Model reset to default%s\n' "$T_GREEN" "$T_RESET" >/dev/tty
        fi
        ;;
      q|Q|"")
        return
        ;;
      *)
        printf '  %sInvalid choice.%s\n' "$T_RED" "$T_RESET" >/dev/tty
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# /workspace — change workspace directory interactively
# ---------------------------------------------------------------------------
change_workspace() {
  local inline_path="$1"
  local new_path=""

  if [[ -n "$inline_path" ]]; then
    # Path provided inline: /workspace /some/path
    new_path="${inline_path/#\~/$HOME}"
  else
    # No path — prompt with read -e for tab completion
    # Reset terminal state — Node's raw mode capture may leave it dirty
    stty sane </dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
    printf '  %sCurrent workspace:%s %s\n' "$T_DIM" "$T_RESET" "$WORKSPACE_DIR" >/dev/tty
    printf '  %sNew path:%s ' "$T_BOLD" "$T_RESET" >/dev/tty
    read -r -e new_path </dev/tty 2>/dev/null || new_path=""
    new_path="${new_path/#\~/$HOME}"
  fi

  if [[ -z "$new_path" ]]; then
    printf '  %sNo path entered, workspace unchanged.%s\n\n' "$T_DIM" "$T_RESET" >/dev/tty
    return
  fi

  if [[ ! -d "$new_path" ]]; then
    printf '  %s%sDirectory does not exist: %s%s\n\n' "$T_BOLD" "$T_RED" "$new_path" "$T_RESET" >/dev/tty
    return
  fi

  WORKSPACE_DIR="$(cd "$new_path" && pwd)"
  load_settings
  generate_workspace_context
  ensure_categories

  printf '  %s✓ Workspace set to %s%s\n' "$T_GREEN" "$WORKSPACE_DIR" "$T_RESET" >/dev/tty
  if ! git -C "$WORKSPACE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '  %s%sWarning: not a git repository%s\n' "$T_BOLD" "$T_YELLOW" "$T_RESET" >/dev/tty
  fi
  printf '\n' >/dev/tty
}

# ---------------------------------------------------------------------------
# Auto-context generation
# ---------------------------------------------------------------------------
generate_workspace_context() {
  WORKSPACE_CONTEXT="$(python3 - "$WORKSPACE_DIR" <<'PY'
import json, os, subprocess, sys

workspace = sys.argv[1]
sections = []

# ---- Project identity ----
manifests = {
    'package.json': lambda d: f"{d.get('name', '?')} — {d.get('description', 'Node.js project')}",
    'Cargo.toml': lambda d: 'Rust project',
    'go.mod': lambda d: 'Go project',
    'pyproject.toml': lambda d: 'Python project',
    'pom.xml': lambda d: 'Java/Maven project',
    'build.gradle': lambda d: 'Java/Gradle project',
    'Gemfile': lambda d: 'Ruby project',
    'composer.json': lambda d: f"{d.get('name', '?')} — PHP project",
    'CMakeLists.txt': lambda d: 'C/C++ project',
}

identity_lines = []
for manifest, describe in manifests.items():
    path = os.path.join(workspace, manifest)
    if os.path.isfile(path):
        try:
            if manifest.endswith('.json'):
                with open(path) as f:
                    data = json.load(f)
                identity_lines.append(f"  {manifest}: {describe(data)}")
            else:
                identity_lines.append(f"  {manifest}: {describe({})}")
        except Exception:
            identity_lines.append(f"  {manifest}: (found)")

if identity_lines:
    sections.append("Project:\n" + "\n".join(identity_lines))

# ---- Directory tree ----
default_ignore = {'.git', 'node_modules', 'dist', 'build', '__pycache__', '.venv', 'target', 'vendor', '.next', '.nuxt', 'coverage', '.tox', 'eggs', '*.egg-info'}
project_ignore = set()

prompter_config = os.path.join(workspace, '.prompter.json')
if os.path.isfile(prompter_config):
    try:
        with open(prompter_config) as f:
            pcfg = json.load(f)
        project_ignore = set(pcfg.get('ignore', []))
    except Exception:
        pass

ignore_set = default_ignore | project_ignore

src_like = {'src', 'lib', 'app', 'packages', 'cmd', 'internal', 'crates', 'apps'}

tree_lines = []
try:
    entries = sorted(os.listdir(workspace))
    for entry in entries:
        if entry in ignore_set or entry.startswith('.'):
            continue
        full = os.path.join(workspace, entry)
        if os.path.isfile(full):
            tree_lines.append(f"  {entry}")
        elif os.path.isdir(full):
            tree_lines.append(f"  {entry}/")
            if entry in src_like:
                try:
                    sub_entries = sorted(os.listdir(full))
                    for sub in sub_entries[:30]:
                        if sub in ignore_set or sub.startswith('.'):
                            continue
                        sub_full = os.path.join(full, sub)
                        suffix = '/' if os.path.isdir(sub_full) else ''
                        tree_lines.append(f"    {sub}{suffix}")
                except PermissionError:
                    pass
except Exception:
    pass

if tree_lines:
    sections.append("Directory structure:\n" + "\n".join(tree_lines))

# ---- README excerpt ----
for readme_name in ['README.md', 'README.rst', 'README.txt', 'README']:
    readme_path = os.path.join(workspace, readme_name)
    if os.path.isfile(readme_path):
        try:
            with open(readme_path, encoding='utf-8', errors='replace') as f:
                lines = []
                for i, line in enumerate(f):
                    if i >= 80:
                        break
                    lines.append(line.rstrip())
            if lines:
                sections.append(f"README excerpt ({readme_name}, first {len(lines)} lines):\n" + "\n".join(lines))
        except Exception:
            pass
        break

# ---- Git info ----
try:
    branch = subprocess.check_output(
        ['git', '-C', workspace, 'rev-parse', '--abbrev-ref', 'HEAD'],
        stderr=subprocess.DEVNULL, text=True
    ).strip()
    log = subprocess.check_output(
        ['git', '-C', workspace, 'log', '--oneline', '-5'],
        stderr=subprocess.DEVNULL, text=True
    ).strip()
    git_lines = [f"  Branch: {branch}"]
    if log:
        git_lines.append("  Recent commits:")
        for line in log.splitlines():
            git_lines.append(f"    {line}")
    sections.append("Git:\n" + "\n".join(git_lines))
except Exception:
    pass

# ---- Custom context from .prompter.json ----
if os.path.isfile(prompter_config):
    try:
        with open(prompter_config) as f:
            pcfg = json.load(f)
        ctx = pcfg.get('context', '')
        if ctx:
            sections.append(f"Project context:\n  {ctx}")
    except Exception:
        pass

print("\n\n".join(sections))
PY
  )"
}

# ---------------------------------------------------------------------------
# Category discovery & management
# ---------------------------------------------------------------------------
PROMPTER_DATA_DIR=""  # set to $WORKSPACE_DIR/.prompter by ensure_categories
CATEGORIES_FILE=""    # resolved path to categories.json

# Resolve which categories file to use.
# Priority: .prompter.json categories > .prompter/categories.json
resolve_categories_file() {
  PROMPTER_DATA_DIR="$WORKSPACE_DIR/.prompter"
  CATEGORIES_FILE="$PROMPTER_DATA_DIR/categories.json"

  # .prompter.json manual categories take priority
  local project_config="$WORKSPACE_DIR/.prompter.json"
  if [[ -f "$project_config" ]]; then
    local has_cats
    has_cats="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print('yes' if d.get('categories') else 'no')
" "$project_config" 2>/dev/null || echo no)"
    if [[ "$has_cats" == "yes" ]]; then
      CATEGORIES_FILE="$project_config"
      return 0
    fi
  fi
}

# Run agent-powered category discovery and write .prompter/categories.json
discover_categories() {
  if ! check_agent_cli; then
    return 1
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/prompter-discover.XXXXXX")"
  local discover_prompt="$tmp_dir/discover_prompt.txt"
  local discover_schema="$tmp_dir/discover_schema.json"
  local discover_output="$tmp_dir/discover_output.json"
  local discover_log="$tmp_dir/discover.log"

  cat > "$discover_schema" <<'JSON'
{
  "type": "object",
  "required": ["categories"],
  "additionalProperties": false,
  "properties": {
    "categories": {
      "type": "array",
      "minItems": 3,
      "maxItems": 12,
      "items": {
        "type": "object",
        "required": ["name", "description", "paths", "expertPromptHint"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string", "minLength": 1 },
          "description": { "type": "string", "minLength": 10 },
          "paths": {
            "type": "array",
            "items": { "type": "string" },
            "minItems": 1
          },
          "expertPromptHint": { "type": "string", "minLength": 10 }
        }
      }
    }
  }
}
JSON

  cat > "$discover_prompt" <<DISCOVER_PROMPT
Based on the project structure below, identify 4-10 high-level expertise categories. Do NOT read any files — use only what is shown here.

${WORKSPACE_CONTEXT}

For each category return: name (2-4 words), description (1 sentence), paths (top-level dirs/files), expertPromptHint (starts with "Focus:").

Output JSON: { "categories": [ { "name", "description", "paths", "expertPromptHint" } ] }
DISCOVER_PROMPT

  start_spinner "Discovering expertise categories"

  set +e
  agent_run_generate "$discover_prompt" "$discover_schema" "$discover_output" "$discover_log"
  local discover_exit=$?
  set -e

  stop_spinner

  if [[ $discover_exit -ne 0 ]]; then
    printf '  %s%sCategory discovery failed.%s\n' "$T_BOLD" "$T_RED" "$T_RESET" >&2
    printf '  Log: %s\n' "$discover_log" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  # Extract and validate the JSON
  local parsed_ok=false
  if python3 - "$discover_output" "$PROMPTER_DATA_DIR/categories.json" <<'PY'
import json, re, sys, os

input_path = sys.argv[1]
output_path = sys.argv[2]

with open(input_path, 'r', encoding='utf-8') as f:
    raw = f.read().strip()

data = None
for attempt in [
    lambda: json.loads(raw),
    lambda: json.loads(re.search(r'```json\s*\n(.*?)\n\s*```', raw, re.DOTALL).group(1)),
    lambda: json.loads(re.search(r'\{.*\}', raw, re.DOTALL).group(0)),
]:
    try:
        data = attempt()
        break
    except Exception:
        continue

if data is None:
    print("ERROR: Could not parse discovery output as JSON", file=sys.stderr)
    sys.exit(1)

cats = data.get('categories', [])
if not cats:
    print("ERROR: No categories found in discovery output", file=sys.stderr)
    sys.exit(1)

# Validate structure
for cat in cats:
    for key in ('name', 'description', 'paths', 'expertPromptHint'):
        if key not in cat:
            print(f"ERROR: Category missing key '{key}': {cat}", file=sys.stderr)
            sys.exit(1)

os.makedirs(os.path.dirname(output_path), exist_ok=True)
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump({"categories": cats}, f, indent=2)
    f.write('\n')

print(f"Discovered {len(cats)} categories", file=sys.stderr)
PY
  then
    parsed_ok=true
  fi

  rm -rf "$tmp_dir"

  if [[ "$parsed_ok" != "true" ]]; then
    printf '  %s%sCategory discovery output was invalid.%s\n' "$T_BOLD" "$T_RED" "$T_RESET" >&2
    return 1
  fi

  # Reload
  resolve_categories_file

  # Show results
  printf '\n'
  printf '  %s%sDiscovered categories:%s\n' "$T_BOLD" "$T_GREEN" "$T_RESET"
  python3 - "$CATEGORIES_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for cat in data.get('categories', []):
    name = cat.get('name', '?')
    desc = cat.get('description', '')
    paths = ', '.join(cat.get('paths', []))
    print(f"    {name}: {desc}")
    if paths:
        print(f"      paths: {paths}")
PY
  printf '\n'
  printf '  %sStored in:%s %s\n\n' "$T_DIM" "$T_RESET" "$PROMPTER_DATA_DIR/categories.json"
}

# Ensure categories exist — discover if missing (non-fatal)
ensure_categories() {
  resolve_categories_file

  # If we already have a categories file (manual or discovered), we're good
  if [[ -f "$CATEGORIES_FILE" ]]; then
    return 0
  fi

  # No categories yet — ask the user (interactive only)
  if [[ -t 0 ]]; then
    printf '\n'
    printf '  %sNo expertise categories found for this workspace.%s\n' "$T_YELLOW" "$T_RESET"
    printf '  %sDiscovery uses the configured agent to analyze the project structure.%s\n' "$T_DIM" "$T_RESET"
    printf '\n'
    printf '  %s[d]%s Discover now    %s[s]%s Skip (use dynamic categorization)\n' \
      "$T_BOLD" "$T_RESET" "$T_BOLD" "$T_RESET"
    printf '\n'
    printf '  %sChoice%s [d/S]: ' "$T_BOLD" "$T_RESET"

    local choice
    read -r -n 1 choice </dev/tty 2>/dev/null || choice=""
    printf '\n'

    case "$choice" in
      d|D)
        if ! discover_categories; then
          printf '  %sSkipping — will use dynamic categorization instead.%s\n' "$T_DIM" "$T_RESET"
          printf '  %sRun /discover later to retry.%s\n\n' "$T_DIM" "$T_RESET"
        fi
        ;;
      *)
        printf '  %sSkipped. Run /discover anytime to set up categories.%s\n\n' "$T_DIM" "$T_RESET"
        ;;
    esac
  fi
  # Non-interactive: silently continue without categories
}

# ---------------------------------------------------------------------------
# Category section for Phase 1 prompt (reads from resolved categories file)
# ---------------------------------------------------------------------------
generate_category_section() {
  if [[ -f "$CATEGORIES_FILE" ]]; then
    python3 - "$CATEGORIES_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
cats = data.get('categories', [])
if not cats:
    print("Analyze the project structure and create an appropriate category name and description for this task.")
    sys.exit(0)
print("Choose from these categories:")
for cat in cats:
    name = cat.get('name', '?')
    desc = cat.get('description', '')
    paths = ', '.join(cat.get('paths', []))
    hint = cat.get('expertPromptHint', '')
    line = f"- {name}: {desc}"
    if paths:
        line += f" (paths: {paths})"
    if hint:
        line += f"\n  {hint}"
    print(line)
PY
  else
    echo "Analyze the project structure and create an appropriate category name and description for this task."
  fi
}

# ---------------------------------------------------------------------------
# Phase 1 JSON schema (reads from resolved categories file)
# ---------------------------------------------------------------------------
generate_phase1_schema() {
  if [[ -f "$CATEGORIES_FILE" ]]; then
    python3 - "$CATEGORIES_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
cats = data.get('categories', [])
schema = {
    "type": "object",
    "required": ["category", "expertName", "expertPrompt"],
    "additionalProperties": False,
    "properties": {
        "category": {"type": "string"},
        "expertName": {"type": "string", "minLength": 1},
        "expertPrompt": {"type": "string", "minLength": 1}
    }
}
if cats:
    schema["properties"]["category"]["enum"] = [c["name"] for c in cats]
print(json.dumps(schema, indent=2))
PY
  else
    cat <<'JSON'
{
  "type": "object",
  "required": ["category", "expertName", "expertPrompt"],
  "additionalProperties": false,
  "properties": {
    "category": {
      "type": "string"
    },
    "expertName": {
      "type": "string",
      "minLength": 1
    },
    "expertPrompt": {
      "type": "string",
      "minLength": 1
    }
  }
}
JSON
  fi
}

# ---------------------------------------------------------------------------
# Category paths lookup (reads from resolved categories file)
# ---------------------------------------------------------------------------
get_category_paths() {
  local category="$1"
  if [[ -f "$CATEGORIES_FILE" ]]; then
    python3 - "$CATEGORIES_FILE" "$category" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
category = sys.argv[2]
for cat in data.get('categories', []):
    if cat.get('name') == category:
        paths = cat.get('paths', [])
        hint = cat.get('expertPromptHint', '')
        if hint:
            print(hint)
            print()
        if paths:
            print("Key paths for this category:")
            for p in paths:
                print(f"  - {p}")
        break
PY
  fi
}

# ---------------------------------------------------------------------------
# Validation command detection
# ---------------------------------------------------------------------------
detect_validation_command() {
  local project_config="$WORKSPACE_DIR/.prompter.json"

  # Check .prompter.json first
  if [[ -f "$project_config" ]]; then
    local val
    val="$(python3 - "$project_config" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
v = data.get('validation', '')
if v:
    print(v)
PY
    )"
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
  fi

  # Heuristic based on manifests
  if [[ -f "$WORKSPACE_DIR/package.json" ]]; then
    echo "npm test"
  elif [[ -f "$WORKSPACE_DIR/Cargo.toml" ]]; then
    echo "cargo test"
  elif [[ -f "$WORKSPACE_DIR/go.mod" ]]; then
    echo "go test ./..."
  elif [[ -f "$WORKSPACE_DIR/pyproject.toml" ]] || [[ -f "$WORKSPACE_DIR/setup.py" ]]; then
    echo "pytest"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Agent CLI check — lazy, only when needed
# ---------------------------------------------------------------------------
check_agent_cli() {
  case "$SETTING_AGENT" in
    codex)
      if ! command -v codex >/dev/null 2>&1; then
        echo "Error: codex CLI is not installed or not in PATH." >&2
        echo "Install: npm install -g @openai/codex" >&2
        return 1
      fi
      ;;
    claude)
      if ! command -v claude >/dev/null 2>&1; then
        echo "Error: claude CLI is not installed or not in PATH." >&2
        echo "Install: npm install -g @anthropic-ai/claude-code" >&2
        return 1
      fi
      ;;
    gemini)
      if ! command -v gemini >/dev/null 2>&1; then
        echo "Error: gemini CLI is not installed or not in PATH." >&2
        return 1
      fi
      ;;
    *)
      echo "Error: unknown agent '$SETTING_AGENT'." >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent backend — Phase 1 (categorization + expert prompt generation)
# ---------------------------------------------------------------------------
agent_run_phase1() {
  local prompt_file="$1" schema_file="$2" output_file="$3" log_file="$4"

  case "$SETTING_AGENT" in
    codex)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      codex exec \
        --full-auto \
        --sandbox "$SETTING_CODEX_SANDBOX" \
        --cd "$WORKSPACE_DIR" \
        ${model_args[@]+"${model_args[@]}"} \
        --output-schema "$schema_file" \
        --output-last-message "$output_file" \
        - < "$prompt_file" > "$log_file" 2>&1
      ;;
    claude)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      claude -p "$(cat "$prompt_file")" \
        --print \
        --output-format json \
        ${model_args[@]+"${model_args[@]}"} \
        --allowedTools Bash,Read,Glob,Grep \
        --dangerously-skip-permissions > "$output_file" 2>"$log_file"
      ;;
    gemini)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      gemini ${model_args[@]+"${model_args[@]}"} \
        --sandbox \
        -p "$(cat "$prompt_file")" > "$output_file" 2>"$log_file"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent backend — lightweight generation (no tools, no sandbox)
# Used for discovery and other pure text→JSON tasks.
# ---------------------------------------------------------------------------
agent_run_generate() {
  local prompt_file="$1" schema_file="$2" output_file="$3" log_file="$4"

  case "$SETTING_AGENT" in
    codex)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      codex exec \
        --full-auto \
        --sandbox none \
        ${model_args[@]+"${model_args[@]}"} \
        --output-schema "$schema_file" \
        --output-last-message "$output_file" \
        - < "$prompt_file" > "$log_file" 2>&1
      ;;
    claude)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      claude -p "$(cat "$prompt_file")" \
        --print \
        --output-format json \
        ${model_args[@]+"${model_args[@]}"} \
        --dangerously-skip-permissions > "$output_file" 2>"$log_file"
      ;;
    gemini)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      gemini ${model_args[@]+"${model_args[@]}"} \
        -p "$(cat "$prompt_file")" > "$output_file" 2>"$log_file"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent backend — Phase 2 (expert execution)
# ---------------------------------------------------------------------------
agent_run_phase2() {
  local prompt_file="$1" log_file="$2"

  case "$SETTING_AGENT" in
    codex)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      codex exec \
        --full-auto \
        --sandbox "$SETTING_CODEX_SANDBOX" \
        --cd "$WORKSPACE_DIR" \
        ${model_args[@]+"${model_args[@]}"} \
        - < "$prompt_file" 2>&1 | tee "$log_file" | colorize_output
      ;;
    claude)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      claude -p "$(cat "$prompt_file")" \
        --print \
        ${model_args[@]+"${model_args[@]}"} \
        --allowedTools Edit,Write,Bash,Read,Glob,Grep \
        --dangerously-skip-permissions 2>&1 | tee "$log_file" | colorize_output
      ;;
    gemini)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      gemini ${model_args[@]+"${model_args[@]}"} \
        --sandbox \
        -p "$(cat "$prompt_file")" 2>&1 | tee "$log_file" | colorize_output
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Agent backend — Phase 2 to file (all output to log, nothing to terminal)
# Used with windowed output mode.
# ---------------------------------------------------------------------------
agent_run_phase2_to_file() {
  local prompt_file="$1" log_file="$2"

  case "$SETTING_AGENT" in
    codex)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      codex exec \
        --full-auto \
        --sandbox "$SETTING_CODEX_SANDBOX" \
        --cd "$WORKSPACE_DIR" \
        ${model_args[@]+"${model_args[@]}"} \
        - < "$prompt_file" > "$log_file" 2>&1
      ;;
    claude)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      claude -p "$(cat "$prompt_file")" \
        --print \
        ${model_args[@]+"${model_args[@]}"} \
        --allowedTools Edit,Write,Bash,Read,Glob,Grep \
        --dangerously-skip-permissions > "$log_file" 2>&1
      ;;
    gemini)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      gemini ${model_args[@]+"${model_args[@]}"} \
        --sandbox \
        -p "$(cat "$prompt_file")" > "$log_file" 2>&1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Rate-limit detection — parses agent output for limit messages
# Returns 0 if rate-limited (sets RATE_LIMIT_SLEEP_SECONDS), 1 otherwise.
# ---------------------------------------------------------------------------
detect_rate_limit() {
  local output_text="$1"

  # Check for rate limit indicators
  if [[ "$output_text" != *"hit your limit"* && \
        "$output_text" != *"rate limit"* && \
        "$output_text" != *"usage limit"* && \
        "$output_text" != *"Rate limit"* && \
        "$output_text" != *"too many requests"* ]]; then
    return 1
  fi

  # Try to parse reset time
  RATE_LIMIT_SLEEP_SECONDS=""
  local sleep_info
  set +e
  sleep_info="$(AGENT_OUTPUT="$output_text" python3 - <<'PY'
import os, sys, re
from datetime import datetime, timedelta

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

text = os.environ.get("AGENT_OUTPUT", "")
text = re.sub(r"\x1b\[[0-9;]*m", "", text)

m = None
patterns = [
    r"resets\s+(?:[A-Za-z]{3}\s+\d{1,2}\s+)?(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?",
    r"at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?",
]
for pat in patterns:
    m = re.search(pat, text, re.I)
    if m:
        break
if not m:
    print("300")
    sys.exit(0)

hour = int(m.group(1))
minute = int(m.group(2) or 0)
ampm = m.group(3).lower()
tz_name = m.group(4)

if ampm == "pm" and hour != 12:
    hour += 12
if ampm == "am" and hour == 12:
    hour = 0

if tz_name and ZoneInfo is not None:
    tz = ZoneInfo(tz_name)
else:
    tz = datetime.now().astimezone().tzinfo

now = datetime.now(tz)
reset = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if reset <= now:
    reset += timedelta(days=1)

seconds = int((reset - now).total_seconds()) + 60
print(f"{seconds}|{reset.isoformat()}")
PY
  )"
  set -e

  local seconds="${sleep_info%%|*}"
  local reset_iso=""
  if [[ "$sleep_info" == *"|"* ]]; then
    reset_iso="${sleep_info#*|}"
  fi

  if [[ -n "$seconds" && "$seconds" =~ ^[0-9]+$ ]]; then
    RATE_LIMIT_SLEEP_SECONDS="$seconds"
  else
    RATE_LIMIT_SLEEP_SECONDS="300"
  fi

  RATE_LIMIT_RESET_ISO="${reset_iso:-}"
  return 0
}

# ---------------------------------------------------------------------------
# Loop mode — split work into tasks, execute one-by-one, commit each
# ---------------------------------------------------------------------------
LOOP_MAX_ITERATIONS="${LOOP_MAX_ITERATIONS:-20}"

run_loop() {
  local expert_prompt="$1"
  local expert_name="$2"
  local cat_paths="$3"
  local validation_cmd="$4"

  local progress_file="$WORKSPACE_DIR/.prompter/progress.txt"
  mkdir -p "$WORKSPACE_DIR/.prompter"
  touch "$progress_file"

  local validation_block=""
  if [[ -n "$validation_cmd" ]]; then
    validation_block="Validation: Run \`$validation_cmd\` after making changes to verify correctness."
  fi

  local loop_tmp_dir
  loop_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/prompter-loop.XXXXXX")"

  # ------ Phase L1: Generate task breakdown ------
  local plan_prompt="$loop_tmp_dir/plan_prompt.txt"
  local plan_schema="$loop_tmp_dir/plan_schema.json"
  local plan_output="$loop_tmp_dir/plan_output.json"
  local plan_log="$loop_tmp_dir/plan.log"

  cat > "$plan_schema" <<'JSON'
{
  "type": "object",
  "required": ["tasks"],
  "additionalProperties": false,
  "properties": {
    "tasks": {
      "type": "array",
      "minItems": 1,
      "maxItems": 20,
      "items": {
        "type": "object",
        "required": ["id", "title", "description"],
        "additionalProperties": false,
        "properties": {
          "id": { "type": "integer" },
          "title": { "type": "string", "minLength": 1 },
          "description": { "type": "string", "minLength": 10 }
        }
      }
    }
  }
}
JSON

  local progress_content=""
  if [[ -s "$progress_file" ]]; then
    progress_content="$(cat "$progress_file")"
  fi

  cat > "$plan_prompt" <<PLAN_PROMPT
You are a task planner. Break the following work into discrete, independently committable tasks.

${expert_prompt}

${cat_paths}

${IMAGE_CONTEXT}

${progress_content:+Previous progress (from earlier loop iterations):
$progress_content
}
Rules:
- Each task should be a single logical unit of work that can be committed on its own.
- Order tasks by dependency — earlier tasks should not depend on later ones.
- Each task title should be short (under 80 chars) and describe what changes.
- Each task description should include: what to change, which files, and acceptance criteria.
- Aim for 3-8 tasks. Don't over-split trivial work.
- If previous progress shows some tasks are done, only include remaining work.

Output: JSON with key "tasks" containing an array of { id, title, description }.
PLAN_PROMPT

  printf '\n'
  start_spinner "Loop  planning task breakdown"

  if ! agent_run_phase1 "$plan_prompt" "$plan_schema" "$plan_output" "$plan_log"; then
    stop_spinner
    printf '  %s%sTask planning failed.%s\n' "$T_BOLD" "$T_RED" "$T_RESET" >&2
    rm -rf "$loop_tmp_dir"
    return 1
  fi

  stop_spinner

  # Parse task list
  local tasks_json
  tasks_json="$(python3 - "$plan_output" <<'PY'
import json, re, sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    raw = f.read().strip()

data = None
for attempt in [
    lambda: json.loads(raw),
    lambda: json.loads(re.search(r'```json\s*\n(.*?)\n\s*```', raw, re.DOTALL).group(1)),
    lambda: json.loads(re.search(r'\{.*\}', raw, re.DOTALL).group(0)),
]:
    try:
        data = attempt()
        break
    except Exception:
        continue

if data is None or 'tasks' not in data:
    print("ERROR: Could not parse task plan", file=sys.stderr)
    sys.exit(1)

# Normalize and output
print(json.dumps(data['tasks']))
PY
  )"

  if [[ -z "$tasks_json" ]]; then
    printf '  %s%sTask planning produced no tasks.%s\n' "$T_BOLD" "$T_RED" "$T_RESET" >&2
    rm -rf "$loop_tmp_dir"
    return 1
  fi

  local task_count
  task_count="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$tasks_json")"

  # Display task plan
  printf '\n'
  print_separator
  printf '  %s%sLoop plan: %s tasks%s\n' "$T_BOLD" "$T_MAGENTA" "$task_count" "$T_RESET"
  print_separator
  python3 - "$tasks_json" <<'PY'
import json, sys
tasks = json.loads(sys.argv[1])
for t in tasks:
    print(f"  [{t['id']}] {t['title']}")
PY
  print_separator
  printf '\n'

  # Write initial plan to progress file
  python3 - "$tasks_json" "$progress_file" <<'PY'
import json, sys
from datetime import datetime

tasks = json.loads(sys.argv[1])
path = sys.argv[2]

with open(path, 'a', encoding='utf-8') as f:
    f.write(f"\n--- Loop started {datetime.now().isoformat(timespec='seconds')} ---\n")
    for t in tasks:
        f.write(f"[ ] {t['id']}. {t['title']}\n")
    f.write("\n")
PY

  # ------ Phase L2: Execute each task ------
  local completed=0
  local failed=0
  local iteration=0

  for task_idx in $(seq 0 $((task_count - 1))); do
    iteration=$((iteration + 1))

    if [[ $iteration -gt $LOOP_MAX_ITERATIONS ]]; then
      printf '  %s%sMax iterations (%s) reached. Stopping loop.%s\n' \
        "$T_BOLD" "$T_YELLOW" "$LOOP_MAX_ITERATIONS" "$T_RESET"
      break
    fi

    local task_id task_title task_desc
    eval "$(python3 - "$tasks_json" "$task_idx" <<'PY'
import json, sys, shlex
tasks = json.loads(sys.argv[1])
idx = int(sys.argv[2])
t = tasks[idx]
print(f"task_id={shlex.quote(str(t['id']))}")
print(f"task_title={shlex.quote(t['title'])}")
print(f"task_desc={shlex.quote(t['description'])}")
PY
    )"

    printf '  %s%s[%s/%s]%s %s\n' "$T_BOLD" "$T_MAGENTA" "$iteration" "$task_count" "$T_RESET" "$task_title"

    # Build task prompt
    local task_prompt_file="$loop_tmp_dir/task_${task_id}_prompt.txt"
    local task_log_file="$loop_tmp_dir/task_${task_id}.log"

    local current_progress=""
    if [[ -s "$progress_file" ]]; then
      current_progress="$(cat "$progress_file")"
    fi

    cat > "$task_prompt_file" <<TASK_PROMPT
${expert_prompt}

${cat_paths}

${IMAGE_CONTEXT}

You are executing task ${task_id} of ${task_count} in a sequential loop.

Current task:
  Title: ${task_title}
  Description: ${task_desc}

Progress so far:
${current_progress}

Instructions:
1. Complete ONLY this single task. Do not work on other tasks.
2. ${validation_block:-Verify your changes work correctly.}
3. After completing the task, make a git commit with a clear message describing what changed.
4. IMPORTANT: If you complete the task successfully, include <promise>TASK_DONE</promise> in your final output.
5. If you determine ALL tasks in the plan are now complete, include <promise>COMPLETE</promise> instead.

Response requirements:
- What you changed and why
- Files changed
- Validation results
TASK_PROMPT

    start_spinner "Task $task_id  $task_title"

    set +e
    agent_run_phase2 "$task_prompt_file" "$task_log_file"
    local task_exit=${PIPESTATUS[0]}
    set -e

    stop_spinner

    # Read the log to check for signals
    local task_output=""
    if [[ -f "$task_log_file" ]]; then
      task_output="$(cat "$task_log_file")"
    fi

    # Check for rate limit
    if detect_rate_limit "$task_output"; then
      printf '\n'
      printf '  %s%sRate limit hit.%s' "$T_BOLD" "$T_YELLOW" "$T_RESET"
      if [[ -n "${RATE_LIMIT_RESET_ISO:-}" ]]; then
        printf ' Resets at %s.' "$RATE_LIMIT_RESET_ISO"
      fi
      printf ' Sleeping %ss...\n' "$RATE_LIMIT_SLEEP_SECONDS"

      sleep "$RATE_LIMIT_SLEEP_SECONDS"

      # Retry this task
      printf '  %sRetrying task %s...%s\n' "$T_DIM" "$task_id" "$T_RESET"
      task_idx=$((task_idx - 1))
      continue
    fi

    # Update progress file
    local task_status="done"
    if [[ $task_exit -ne 0 ]]; then
      task_status="failed (exit $task_exit)"
      failed=$((failed + 1))
    else
      completed=$((completed + 1))
    fi

    python3 - "$progress_file" "$task_id" "$task_title" "$task_status" <<'PY'
import sys
from datetime import datetime

path, task_id, title, status = sys.argv[1:5]

# Update the checkbox in progress file
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

old = f"[ ] {task_id}. {title}"
new = f"[{'x' if status == 'done' else '!'}] {task_id}. {title} — {status}"
content = content.replace(old, new)

with open(path, 'a', encoding='utf-8') as f:
    f.write(f"  Task {task_id} {status} at {datetime.now().isoformat(timespec='seconds')}\n")

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
PY

    # Show task result
    if [[ "$task_status" == "done" ]]; then
      printf '  %s%s  ✓ Task %s done%s\n\n' "$T_BOLD" "$T_GREEN" "$task_id" "$T_RESET"
    else
      printf '  %s%s  ✗ Task %s %s%s\n\n' "$T_BOLD" "$T_RED" "$task_id" "$task_status" "$T_RESET"
    fi

    # Check for all-complete signal
    if [[ "$task_output" == *"<promise>COMPLETE</promise>"* ]]; then
      printf '  %s%sAll tasks complete!%s\n' "$T_BOLD" "$T_GREEN" "$T_RESET"
      break
    fi

    # If task failed, ask whether to continue
    if [[ $task_exit -ne 0 && -t 0 ]]; then
      printf '  %sContinue with next task?%s [Y/n]: ' "$T_BOLD" "$T_RESET" >/dev/tty
      local cont_choice
      read -r -n 1 cont_choice </dev/tty 2>/dev/null || cont_choice=""
      printf '\n' >/dev/tty
      if [[ "$cont_choice" == "n" || "$cont_choice" == "N" ]]; then
        printf '  %sStopping loop.%s\n' "$T_DIM" "$T_RESET"
        break
      fi
    fi
  done

  # ------ Summary ------
  printf '\n'
  print_separator
  printf '  %s%sLoop complete%s\n' "$T_BOLD" "$T_MAGENTA" "$T_RESET"
  printf '  %sCompleted:%s %s%s%s  %sFailed:%s %s%s%s  %sTotal:%s %s\n' \
    "$T_DIM" "$T_RESET" "$T_GREEN" "$completed" "$T_RESET" \
    "$T_DIM" "$T_RESET" "$T_RED" "$failed" "$T_RESET" \
    "$T_DIM" "$T_RESET" "$task_count"
  printf '  %sProgress:%s  %s\n' "$T_DIM" "$T_RESET" "$progress_file"
  print_separator
  printf '\n'

  rm -rf "$loop_tmp_dir"

  if [[ $failed -gt 0 ]]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Phase 1 JSON extraction (shared across all agents)
# ---------------------------------------------------------------------------
extract_phase1_json() {
  local input_file="$1" category_file="$2" expert_name_file="$3" expert_prompt_file="$4"

  python3 - "$input_file" "$category_file" "$expert_name_file" "$expert_prompt_file" <<'PY'
import json, re, sys

input_path, category_path, expert_name_path, expert_prompt_path = sys.argv[1:5]

with open(input_path, 'r', encoding='utf-8') as f:
    raw = f.read().strip()

data = None

# Try 1: direct JSON parse
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    pass

# Try 2: extract from ```json ... ``` fences
if data is None:
    m = re.search(r'```json\s*\n(.*?)\n\s*```', raw, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(1))
        except json.JSONDecodeError:
            pass

# Try 3: find first { ... } block
if data is None:
    m = re.search(r'\{.*\}', raw, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(0))
        except json.JSONDecodeError:
            pass

if data is None:
    print("ERROR: Could not extract JSON from Phase 1 output", file=sys.stderr)
    sys.exit(1)

for key in ('category', 'expertName', 'expertPrompt'):
    if key not in data:
        print(f"ERROR: Missing required key '{key}' in Phase 1 output", file=sys.stderr)
        sys.exit(1)

with open(category_path, 'w', encoding='utf-8') as f:
    f.write(data['category'])
with open(expert_name_path, 'w', encoding='utf-8') as f:
    f.write(data['expertName'])
with open(expert_prompt_path, 'w', encoding='utf-8') as f:
    f.write(data['expertPrompt'])
PY
}

# ---------------------------------------------------------------------------
# Image extraction — detect dragged/pasted image paths in input
# ---------------------------------------------------------------------------
# Sets: EXTRACTED_IMAGES (bash array of resolved paths)
#       CLEANED_PROMPT  (input with image paths removed)
#       IMAGE_CONTEXT   (prompt fragment describing attached images)
extract_images_from_prompt() {
  local raw_prompt="$1"
  local result_file="$2"

  python3 - "$raw_prompt" "$result_file" <<'PY'
import re, os, sys, shlex

raw = sys.argv[1]
result_file = sys.argv[2]

IMAGE_EXTS = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg',
    '.bmp', '.tiff', '.tif', '.ico', '.heic', '.heif', '.avif',
}

def has_image_ext(p):
    return os.path.splitext(p.lower())[1] in IMAGE_EXTS

def normalize_path(p):
    """Resolve escaped spaces, ~ expansion, file:// prefix."""
    p = p.strip()
    if p.startswith('file://'):
        p = p[7:]
    # Unescape backslash-space (drag-and-drop on macOS Terminal)
    p = p.replace('\\ ', ' ')
    # Expand ~
    p = os.path.expanduser(p)
    return p

found = []
# Track spans to remove from text
remove_spans = []

# Pattern 1: single-quoted paths — '/path/to/image.png'
for m in re.finditer(r"'([^']+)'", raw):
    p = normalize_path(m.group(1))
    if has_image_ext(p) and os.path.isfile(p):
        found.append(os.path.abspath(p))
        remove_spans.append((m.start(), m.end()))

# Pattern 2: double-quoted paths — "/path/to/image.png"
for m in re.finditer(r'"([^"]+)"', raw):
    p = normalize_path(m.group(1))
    if has_image_ext(p) and os.path.isfile(p):
        found.append(os.path.abspath(p))
        remove_spans.append((m.start(), m.end()))

# Pattern 3: file:// URLs (unquoted) — file:///path/to/image.png
for m in re.finditer(r'file://(/\S+)', raw):
    p = normalize_path(m.group(0))
    if has_image_ext(p) and os.path.isfile(p):
        found.append(os.path.abspath(p))
        remove_spans.append((m.start(), m.end()))

# Pattern 4: unquoted paths with escaped spaces — /path/to/my\ image.png
# Match sequences of (non-whitespace | backslash-space)
for m in re.finditer(r'(?:(?:/|~/)(?:[^\s]|\\ )+)', raw):
    # Skip if this span overlaps with an already-matched span
    if any(s <= m.start() < e or s < m.end() <= e for s, e in remove_spans):
        continue
    p = normalize_path(m.group(0))
    if has_image_ext(p) and os.path.isfile(p):
        found.append(os.path.abspath(p))
        remove_spans.append((m.start(), m.end()))

# Deduplicate preserving order
seen = set()
unique = []
for p in found:
    if p not in seen:
        seen.add(p)
        unique.append(p)

# Build cleaned prompt — remove image paths, collapse whitespace
if remove_spans:
    remove_spans.sort(key=lambda s: s[0])
    parts = []
    prev_end = 0
    for start, end in remove_spans:
        parts.append(raw[prev_end:start])
        prev_end = end
    parts.append(raw[prev_end:])
    cleaned = ' '.join(parts).strip()
    cleaned = re.sub(r'  +', ' ', cleaned)
else:
    cleaned = raw

# Write results as bash-eval-able output
with open(result_file, 'w') as f:
    # Array of paths
    arr = ' '.join(shlex.quote(p) for p in unique)
    f.write(f'EXTRACTED_IMAGES=({arr})\n')
    f.write(f'CLEANED_PROMPT={shlex.quote(cleaned)}\n')
PY
}

# Build a prompt fragment describing attached images.
build_image_context() {
  local -a images=("$@")
  if [[ ${#images[@]} -eq 0 ]]; then
    IMAGE_CONTEXT=""
    return
  fi

  IMAGE_CONTEXT="Attached images (${#images[@]}):"
  for img in "${images[@]}"; do
    local basename
    basename="$(basename "$img")"
    IMAGE_CONTEXT="${IMAGE_CONTEXT}
  - ${img}  (${basename})"
  done
  IMAGE_CONTEXT="${IMAGE_CONTEXT}
IMPORTANT: Read and analyze each attached image file using your file-reading tools. These are visual assets the user wants you to see."
}

# ---------------------------------------------------------------------------
# Mode picker — ask the user to choose execute or plan-first
# ---------------------------------------------------------------------------
ask_execution_mode() {
  # Non-interactive callers default to configured mode.
  if [[ ! -t 0 ]]; then
    echo "$SETTING_DEFAULT_MODE"
    return
  fi

  local default_hint
  case "$SETTING_DEFAULT_MODE" in
    plan)   default_hint="e/P/l" ;;
    loop)   default_hint="e/p/L" ;;
    *)      default_hint="E/p/l" ;;
  esac

  printf '\n' >/dev/tty
  printf '  %s%s[E]%s Execute %s(execute directly)%s\n' "$T_BOLD" "$T_GREEN" "$T_RESET" "$T_DIM" "$T_RESET" >/dev/tty
  printf '  %s%s[P]%s Plan    %s(research + plan, then execute)%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET" "$T_DIM" "$T_RESET" >/dev/tty
  printf '  %s%s[L]%s Loop    %s(split into tasks, execute one-by-one, commit each)%s\n' "$T_BOLD" "$T_MAGENTA" "$T_RESET" "$T_DIM" "$T_RESET" >/dev/tty
  printf '\n' >/dev/tty
  printf '  %sMode%s [%s]: ' "$T_BOLD" "$T_RESET" "$default_hint" >/dev/tty

  local choice
  read -r -n 1 choice </dev/tty 2>/dev/null || choice=""
  printf '\n' >/dev/tty

  case "$choice" in
    p|P) echo "plan" ;;
    l|L) echo "loop" ;;
    e|E) echo "execute" ;;
    *)   echo "$SETTING_DEFAULT_MODE" ;;
  esac
}

# ---------------------------------------------------------------------------
# Core execution
# ---------------------------------------------------------------------------
run_once() {
  local user_prompt="$1"

  if [[ -z "${user_prompt// }" ]]; then
    echo "Error: empty prompt." >&2
    return 1
  fi

  if ! check_agent_cli; then
    return 1
  fi

  # Extract image paths from input (handles drag-and-drop, file:// URLs, etc.)
  local img_result_file
  img_result_file="$(mktemp "${TMPDIR:-/tmp}/prompter-img.XXXXXX")"
  extract_images_from_prompt "$user_prompt" "$img_result_file"
  eval "$(cat "$img_result_file")"
  rm -f "$img_result_file"

  # Build image context fragment for prompts
  IMAGE_CONTEXT=""
  build_image_context "${EXTRACTED_IMAGES[@]+"${EXTRACTED_IMAGES[@]}"}"

  # Use cleaned prompt (image paths stripped) for display metrics
  local effective_prompt="${CLEANED_PROMPT:-$user_prompt}"

  local input_chars input_lines input_sha
  input_chars=$(printf '%s' "$effective_prompt" | wc -c | tr -d ' ')
  input_lines=$(count_lines "$effective_prompt")
  input_sha=$(sha256_of_text "$effective_prompt")

  if [[ "${PROMPTER_DRY_RUN:-0}" == "1" ]]; then
    printf '=== Dry Run Prompt Summary ===\n'
    printf 'Input payload: %s chars, %s lines, sha256=%s\n' "$input_chars" "$input_lines" "${input_sha:0:16}"
    printf 'Agent: %s\n' "$SETTING_AGENT"
    if [[ ${#EXTRACTED_IMAGES[@]} -gt 0 ]]; then
      printf 'Images: %s\n' "${#EXTRACTED_IMAGES[@]}"
      for img in "${EXTRACTED_IMAGES[@]}"; do
        printf '  - %s\n' "$img"
      done
    fi
    return 0
  fi

  # Immediate feedback after Enter.
  local image_hint=""
  if [[ ${#EXTRACTED_IMAGES[@]} -gt 0 ]]; then
    image_hint=", ${#EXTRACTED_IMAGES[@]} image(s)"
  fi
  start_spinner "Phase 1  generating expert prompt ($input_chars chars, $input_lines lines${image_hint})"

  local tmp_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/prompter.XXXXXX")"

  local phase1_schema_file phase1_prompt_file phase1_output_file phase1_log_file
  local category_file expert_name_file expert_prompt_file
  local phase2_prompt_file phase2_log_file

  phase1_schema_file="$tmp_dir/phase1_schema.json"
  phase1_prompt_file="$tmp_dir/phase1_prompt.txt"
  phase1_output_file="$tmp_dir/phase1_output.json"
  phase1_log_file="$tmp_dir/phase1.log"

  category_file="$tmp_dir/category.txt"
  expert_name_file="$tmp_dir/expert_name.txt"
  expert_prompt_file="$tmp_dir/expert_prompt.txt"

  phase2_prompt_file="$tmp_dir/phase2_prompt.txt"
  phase2_log_file="$tmp_dir/phase2.log"

  # Generate Phase 1 schema dynamically
  generate_phase1_schema > "$phase1_schema_file"

  # Generate workspace context and category section
  local category_section
  category_section="$(generate_category_section)"

  cat > "$phase1_prompt_file" <<PHASE1_PROMPT
You are a prompt routing expert.

${WORKSPACE_CONTEXT}

${category_section}

Task:
1. Determine which ONE category best fits the input.
2. Write a high-quality execution prompt for an expert in that category.
3. Reference concrete file paths from the project structure above.
4. Include any logs, errors, or details from the user input.
${IMAGE_CONTEXT:+5. The user has attached images — include instructions in the expert prompt to read and analyze them.}

Output: JSON with keys: category, expertName, expertPrompt.

${IMAGE_CONTEXT}

Input prompt:
${effective_prompt}
PHASE1_PROMPT

  if ! agent_run_phase1 "$phase1_prompt_file" "$phase1_schema_file" "$phase1_output_file" "$phase1_log_file"; then
    stop_spinner
    echo "Phase 1 failed while generating expert prompt." >&2
    echo "See log file: $phase1_log_file" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  stop_spinner

  if ! extract_phase1_json "$phase1_output_file" "$category_file" "$expert_name_file" "$expert_prompt_file"; then
    echo "Phase 1 output parse failed." >&2
    echo "Raw output:" >&2
    head -20 "$phase1_output_file" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  local category expert_name expert_prompt
  category="$(cat "$category_file")"
  expert_name="$(cat "$expert_name_file")"
  expert_prompt="$(cat "$expert_prompt_file")"

  # Look up category-specific paths from .prompter.json
  local cat_paths
  cat_paths="$(get_category_paths "$category")"

  # Detect validation command
  local validation_cmd
  validation_cmd="$(detect_validation_command)"

  # Show Phase 1 results, then ask for mode
  printf '\n'
  print_separator
  printf '  %sCategory:%s  %s\n' "$T_DIM" "$T_RESET" "$category"
  printf '  %sExpert:%s    %s%s%s\n' "$T_DIM" "$T_RESET" "$T_YELLOW" "$expert_name" "$T_RESET"
  printf '  %sInput:%s     %s chars, %s lines\n' "$T_DIM" "$T_RESET" "$input_chars" "$input_lines"
  if [[ ${#EXTRACTED_IMAGES[@]} -gt 0 ]]; then
    printf '  %sImages:%s    %s attached\n' "$T_DIM" "$T_RESET" "${#EXTRACTED_IMAGES[@]}"
    for img in "${EXTRACTED_IMAGES[@]}"; do
      printf '             %s%s%s\n' "$T_CYAN" "$(basename "$img")" "$T_RESET"
    done
  fi
  printf '  %sAgent:%s     %s\n' "$T_DIM" "$T_RESET" "$SETTING_AGENT"
  print_separator

  local execution_mode
  execution_mode="$(ask_execution_mode)"

  # --- Loop mode: hand off to run_loop() ---
  if [[ "$execution_mode" == "loop" ]]; then
    local mode_label="${T_MAGENTA}Loop${T_RESET}"
    printf '  %sMode:%s      %s\n' "$T_DIM" "$T_RESET" "$mode_label"
    printf '\n'

    local loop_exit
    set +e
    run_loop "$expert_prompt" "$expert_name" "$cat_paths" "$validation_cmd"
    loop_exit=$?
    set -e

    rm -rf "$tmp_dir"
    return "$loop_exit"
  fi

  # --- Execute / Plan mode: ask about commit & push ---
  local commit_push="none"
  if [[ -t 0 ]]; then
    printf '\n' >/dev/tty
    printf '  %sAfter completion:%s\n' "$T_BOLD" "$T_RESET" >/dev/tty
    printf '  %s[n]%s No commit     %s[c]%s Commit     %s[p]%s Commit & push\n' \
      "$T_BOLD" "$T_RESET" "$T_BOLD" "$T_RESET" "$T_BOLD" "$T_RESET" >/dev/tty
    printf '\n' >/dev/tty
    printf '  %sGit%s [N/c/p]: ' "$T_BOLD" "$T_RESET" >/dev/tty

    local git_choice
    read -r -n 1 git_choice </dev/tty 2>/dev/null || git_choice=""
    printf '\n' >/dev/tty

    case "$git_choice" in
      c|C) commit_push="commit" ;;
      p|P) commit_push="push" ;;
      *)   commit_push="none" ;;
    esac
  fi

  local mode_instructions validation_block git_block
  if [[ -n "$validation_cmd" ]]; then
    validation_block="Validation: Run \`$validation_cmd\` after making changes to verify correctness."
  else
    validation_block="Validation: No standard test command detected. Verify changes manually if possible."
  fi

  case "$commit_push" in
    commit)
      git_block="Git: After all changes pass validation, create a git commit with a clear, descriptive message summarizing what changed and why. Do NOT push."
      ;;
    push)
      git_block="Git: After all changes pass validation, create a git commit with a clear, descriptive message summarizing what changed and why, then push to the remote."
      ;;
    *)
      git_block=""
      ;;
  esac

  if [[ "$execution_mode" == "plan" ]]; then
    mode_instructions="Execution mode: PLAN THEN EXECUTE
1. First, investigate the codebase thoroughly — read files, search for patterns, trace call chains.
2. Produce a detailed, actionable plan with root cause analysis, specific files and line ranges to change, exact code changes, test strategy, and risk assessment.
3. Once the plan is complete, execute the plan end-to-end.
4. If your planning workflow presents recommended/default planning question answers, accept the defaults and proceed without waiting for user follow-up.
5. After making changes, validate.
6. If tests fail, fix the failures before finishing.

${validation_block}
${git_block}"
  else
    mode_instructions="Execution mode: DIRECT EXECUTION
1. Build a concrete plan before executing any changes.
2. If your planning workflow presents recommended/default planning question answers, accept the defaults and proceed without waiting for user follow-up.
3. Execute the work end-to-end.
4. After making changes, validate.
5. If tests fail, fix the failures before finishing.

${validation_block}
${git_block}"
  fi

  cat > "$phase2_prompt_file" <<PHASE2_PROMPT
${expert_prompt}

${cat_paths}

${IMAGE_CONTEXT}

${mode_instructions}

Response requirements:
- The plan you produced and executed
- What changed and why
- Files changed
- Validation results
PHASE2_PROMPT

  local phase2_chars phase2_lines
  phase2_chars=$(wc -c < "$phase2_prompt_file" | tr -d ' ')
  phase2_lines=$(wc -l < "$phase2_prompt_file" | tr -d ' ')

  local mode_label git_label=""
  if [[ "$execution_mode" == "plan" ]]; then
    mode_label="${T_CYAN}Plan + Execute${T_RESET}"
  else
    mode_label="${T_GREEN}Execute${T_RESET}"
  fi
  case "$commit_push" in
    commit) git_label="  ${T_DIM}→ commit${T_RESET}" ;;
    push)   git_label="  ${T_DIM}→ commit & push${T_RESET}" ;;
  esac

  local sub_info="Mode: ${execution_mode}${commit_push:+  |  git: $commit_push}  |  ${phase2_chars} chars prompt"

  local phase2_exit
  if setup_output_window "Phase 2  $expert_name" "$sub_info"; then
    # Windowed mode: agent writes to file, renderer displays tail in window
    _start_window_renderer "$phase2_log_file"
    set +e
    agent_run_phase2_to_file "$phase2_prompt_file" "$phase2_log_file"
    phase2_exit=$?
    set -e
    teardown_output_window "$phase2_exit"
  else
    # Fallback: no window support — scroll as before
    printf '  %sMode:%s      %s%s  %s(%s chars prompt)%s\n' "$T_DIM" "$T_RESET" "$mode_label" "$git_label" "$T_DIM" "$phase2_chars" "$T_RESET"
    printf '\n'
    start_spinner "Phase 2  $expert_name working"
    set +e
    agent_run_phase2 "$phase2_prompt_file" "$phase2_log_file"
    phase2_exit=${PIPESTATUS[0]}
    set -e
    stop_spinner
    print_done_banner "$phase2_exit"
  fi

  rm -rf "$tmp_dir"
  return "$phase2_exit"
}

# ---------------------------------------------------------------------------
# Interactive loop
# ---------------------------------------------------------------------------
interactive_loop() {
  print_startup_banner

  local capture_tmp_dir capture_file
  capture_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/prompter-input.XXXXXX")"
  capture_file="$capture_tmp_dir/input.txt"
  trap 'stop_spinner; rm -rf "$capture_tmp_dir"' EXIT

  while true; do
    : > "$capture_file"

    set +e
    node "$INPUT_CAPTURE_SCRIPT" \
      --output "$capture_file" \
      --idle-ms 250 \
      --paste-timeout-ms 30000 \
      --max-bytes 2000000 \
      --prompt "❯ "
    local capture_exit=$?
    set -e

    case "$capture_exit" in
      0)
        local input
        input="$(cat "$capture_file")"
        if [[ -z "${input// }" ]]; then
          continue
        fi

        if ! run_once "$input"; then
          printf '  %s%sRun failed.%s\n\n' "$T_BOLD" "$T_RED" "$T_RESET"
        fi
        ;;
      20)
        printf '%sGoodbye.%s\n' "$T_DIM" "$T_RESET"
        break
        ;;
      21)
        print_help
        ;;
      22)
        ;;
      23)
        echo "Interactive capture is unavailable in this terminal. Use one-shot input or stdin pipe." >&2
        return 1
        ;;
      24)
        interactive_settings_menu
        ;;
      25)
        local ws_arg
        ws_arg="$(cat "$capture_file")"
        change_workspace "$ws_arg"
        ;;
      26)
        discover_categories
        ;;
      *)
        echo "Input capture failed (exit $capture_exit)." >&2
        return "$capture_exit"
        ;;
    esac
  done

  rm -rf "$capture_tmp_dir"
  trap - EXIT
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  # Parse flags before positional args
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        print_help
        exit 0
        ;;
      --workspace|-w)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --workspace requires a directory path." >&2
          exit 1
        fi
        local ws_path="${2/#\~/$HOME}"
        if [[ ! -d "$ws_path" ]]; then
          echo "Error: directory does not exist: $ws_path" >&2
          exit 1
        fi
        WORKSPACE_DIR="$(cd "$ws_path" && pwd)"
        shift 2
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  set -- "${positional[@]+"${positional[@]}"}"

  # Load settings and detect workspace
  load_settings
  detect_workspace
  # Reload settings in case workspace changed (picks up .prompter.json)
  load_settings
  # Generate workspace context once
  generate_workspace_context
  # Ensure expertise categories exist (discovers if missing)
  ensure_categories

  if [[ $# -gt 0 ]]; then
    run_once "$*"
    exit $?
  fi

  if [[ -t 0 ]]; then
    interactive_loop
    exit 0
  fi

  local stdin_prompt
  stdin_prompt="$(cat)"
  run_once "$stdin_prompt"
}

main "$@"
