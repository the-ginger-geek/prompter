#!/usr/bin/env bash
set -euo pipefail

PROMPTER_VERSION="0.0.3"

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

# When true, loop mode skips interactive pauses between tasks.
_LOOP_AUTO_CONTINUE=false

# ---------------------------------------------------------------------------
# Update check — compares local HEAD with remote, with 24h cooldown
# ---------------------------------------------------------------------------
UPDATE_CHECK_FILE="$SETTINGS_DIR/.last_update_check"
UPDATE_AVAILABLE_FILE="$SETTINGS_DIR/.update_available"
_UPDATE_AVAILABLE=false

check_for_updates() {
  # Only check if we're in a git repo (installed via git clone)
  if [[ ! -d "$PROMPTER_DIR/.git" ]]; then
    return
  fi

  local local_head
  local_head="$(git -C "$PROMPTER_DIR" rev-parse HEAD 2>/dev/null)" || return

  # If a previous check flagged an update, keep showing it until the user updates
  if [[ -f "$UPDATE_AVAILABLE_FILE" ]]; then
    local cached_head
    cached_head="$(cat "$UPDATE_AVAILABLE_FILE" 2>/dev/null || echo "")"
    # If local HEAD still matches what was cached, update hasn't been applied
    if [[ "$cached_head" == "$local_head" ]]; then
      _UPDATE_AVAILABLE=true
      return
    else
      # User updated — clear the flag
      rm -f "$UPDATE_AVAILABLE_FILE" 2>/dev/null || true
    fi
  fi

  # Cooldown: only hit the network once every 24 hours
  if [[ -f "$UPDATE_CHECK_FILE" ]]; then
    local last_check
    last_check=$(cat "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local elapsed=$(( now - last_check ))
    if [[ $elapsed -lt 86400 ]]; then
      return
    fi
  fi

  # Record check time (even if the check fails, avoid retrying every launch)
  mkdir -p "$SETTINGS_DIR" 2>/dev/null || true
  date +%s > "$UPDATE_CHECK_FILE" 2>/dev/null || true

  # Compare local and remote HEAD
  local remote_head
  remote_head="$(git -C "$PROMPTER_DIR" ls-remote --heads origin main 2>/dev/null | awk '{print $1}')" || return

  if [[ -n "$remote_head" && "$local_head" != "$remote_head" ]]; then
    _UPDATE_AVAILABLE=true
    # Cache the local HEAD so we keep showing the notice until they update
    printf '%s' "$local_head" > "$UPDATE_AVAILABLE_FILE" 2>/dev/null || true
  fi
}

do_self_update() {
  if [[ ! -d "$PROMPTER_DIR/.git" ]]; then
    printf '  %s%sError:%s Not a git install — cannot self-update.\n' "$T_BOLD" "$T_RED" "$T_RESET" >&2
    printf '  Reinstall with: curl -fsSL https://prompter-7fe6d.web.app/get.sh | bash\n'
    exit 1
  fi

  printf '\n'
  printf '  %sUpdating prompter...%s\n' "$T_DIM" "$T_RESET"

  if git -C "$PROMPTER_DIR" pull --ff-only 2>&1 | while IFS= read -r line; do
    printf '  %s%s%s\n' "$T_DIM" "$line" "$T_RESET"
  done; then
    # Read the new version from the updated script
    local new_version
    new_version="$(grep -m1 'PROMPTER_VERSION=' "$PROMPTER_DIR/prompter.sh" | sed 's/.*"\(.*\)"/\1/')"
    printf '\n  %s%s✓ Updated to v%s%s\n\n' "$T_BOLD" "$T_GREEN" "$new_version" "$T_RESET"

    # Clear update state so next launch doesn't show stale notice
    rm -f "$UPDATE_CHECK_FILE" "$UPDATE_AVAILABLE_FILE" 2>/dev/null || true
  else
    printf '\n  %s%s✗ Update failed.%s Try manually: cd %s && git pull\n\n' \
      "$T_BOLD" "$T_RED" "$T_RESET" "$PROMPTER_DIR"
  fi
}

ensure_settings_dir() {
  [[ -d "$SETTINGS_DIR" ]] || mkdir -p "$SETTINGS_DIR"
}

load_settings() {
  ensure_settings_dir

  # First launch — ask which agent to use
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    local chosen_agent="codex"
    if [[ -t 0 ]]; then
      printf '\n'
      printf '  %s%sWelcome to prompter!%s\n\n' "$T_BOLD" "$T_CYAN" "$T_RESET"
      printf '  Which AI agent would you like to use?\n\n'
      printf '  %s%s[1]%s codex   %sOpenAI Codex CLI%s\n' "$T_BOLD" "$T_GREEN" "$T_RESET" "$T_DIM" "$T_RESET"
      printf '  %s%s[2]%s claude  %sAnthropic Claude Code CLI%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET" "$T_DIM" "$T_RESET"
      printf '  %s%s[3]%s gemini  %sGoogle Gemini CLI%s\n\n' "$T_BOLD" "$T_YELLOW" "$T_RESET" "$T_DIM" "$T_RESET"
      printf '  %sAgent%s [1/2/3]: ' "$T_BOLD" "$T_RESET"

      local agent_choice
      read -r -n 1 agent_choice </dev/tty 2>/dev/null || agent_choice=""
      printf '\n'

      case "$agent_choice" in
        2) chosen_agent="claude" ;;
        3) chosen_agent="gemini" ;;
        *) chosen_agent="codex" ;;
      esac

      printf '\n  %s%s✓ Using %s%s\n\n' "$T_BOLD" "$T_GREEN" "$chosen_agent" "$T_RESET"
    fi

    cat > "$SETTINGS_FILE" <<JSON
{
  "agent": "${chosen_agent}",
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
# renderer redraws the full frame + tails the log every 0.1s. Re-reads terminal
# dimensions each tick so resize is handled automatically.
# ---------------------------------------------------------------------------
_WINDOW_ACTIVE=false
_WINDOW_START_TIME=0
_WINDOW_RENDER_PID=""
_WINDOW_LOG_FILE=""
_WINDOW_HEADER=""
_WINDOW_SUB_HEADER=""
_WINDOW_AGENT=""
_WINDOW_CATEGORY=""
_WINDOW_PROMPT_FILE=""

setup_output_window() {
  local header="$1"
  local sub_header="${2:-}"
  local agent="${3:-$SETTING_AGENT}"
  local category="${4:-}"
  local prompt_file="${5:-}"

  if [[ -z "$T_RESET" ]] || ! command -v tput >/dev/null 2>&1; then
    printf '\n  %s\n\n' "$header"
    return 1
  fi

  local rows
  rows=$(tput lines 2>/dev/null) || rows=24
  if [[ $rows -lt 10 ]]; then
    printf '\n  %s\n\n' "$header"
    return 1
  fi

  # Switch to alternate screen buffer
  printf '\e[?1049h'
  printf '\e[?25l'

  _WINDOW_ACTIVE=true
  _WINDOW_START_TIME=$(date +%s)
  _WINDOW_HEADER="$header"
  _WINDOW_SUB_HEADER="$sub_header"
  _WINDOW_AGENT="$agent"
  _WINDOW_CATEGORY="$category"
  _WINDOW_PROMPT_FILE="$prompt_file"

  return 0
}

_start_window_renderer() {
  local log_file="$1"
  _WINDOW_LOG_FILE="$log_file"

  _window_render_loop "$log_file" \
    "$_WINDOW_START_TIME" "$_WINDOW_HEADER" "$_WINDOW_SUB_HEADER" \
    "$_WINDOW_AGENT" "$_WINDOW_CATEGORY" "$_WINDOW_PROMPT_FILE" &
  _WINDOW_RENDER_PID=$!
  disown "$_WINDOW_RENDER_PID" 2>/dev/null || true
}

_window_render_loop() {
  local log_file="$1"
  local start_time="$2"
  local header="$3"
  local sub_header="$4"
  local agent="$5"
  local category="$6"
  local prompt_file="${7:-}"

  # Pre-load prompt lines (truncated to max 5 lines)
  # Load prompt lines (capped to 8 for display — full prompt shown in summary)
  local max_prompt_lines=8
  local -a prompt_lines=()
  local prompt_truncated=false
  if [[ -n "$prompt_file" ]] && [[ -f "$prompt_file" ]]; then
    local _pl _total=0
    while IFS= read -r _pl; do
      _total=$((_total + 1))
      if [[ ${#prompt_lines[@]} -lt $max_prompt_lines ]]; then
        prompt_lines+=("$_pl")
      fi
    done < "$prompt_file"
    if [[ $_total -gt $max_prompt_lines ]]; then
      prompt_truncated=true
    fi
  fi
  local prompt_line_count=${#prompt_lines[@]}
  # Add truncation indicator line
  if [[ "$prompt_truncated" == "true" ]]; then
    prompt_line_count=$((prompt_line_count + 1))
  fi

  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local frame_i=0

  while true; do
    sleep 0.1

    # Re-read terminal size every tick — handles resize
    local rows cols
    rows=$(tput lines 2>/dev/null) || rows=24
    cols=$(tput cols 2>/dev/null) || cols=80

    # Hide cursor during redraw to prevent flicker
    printf '\e[?25l'

    # Layout:
    #   row 1        = header
    #   row 2        = metadata
    #   row 3..3+N-1 = prompt (up to 5 lines, white)
    #   row 3+N      = border ────
    #   row 3+N+1..(R-2) = content
    #   row R-1      = border ────
    #   row R        = status
    local prompt_start=3
    local border_row=$((prompt_start + prompt_line_count))
    local content_top=$((border_row + 1))
    local content_bottom=$((rows - 2))
    local visible_lines=$((content_bottom - content_top + 1))
    if [[ $visible_lines -lt 1 ]]; then
      visible_lines=1
      content_bottom=$content_top
    fi

    local border
    border="$(printf '%.0s─' $(seq 1 "$cols"))"

    # Elapsed
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

    # Log line count
    local total_lines=0
    if [[ -f "$log_file" ]]; then
      total_lines=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')
    fi

    # ---- Row 1: Header ----
    printf '\e[1;1H\e[2K'
    printf '  %s%s%s%s  %s%s' "$T_BOLD" "$T_CYAN" "$header" "$T_RESET" "$T_DIM" "$T_RESET"

    # ---- Row 2: Sub-header with metadata ----
    printf '\e[2;1H\e[2K'
    local meta=""
    if [[ -n "$agent" ]]; then
      meta="${T_MAGENTA}${agent}${T_RESET}"
    fi
    if [[ -n "$category" ]]; then
      meta="${meta}  ${T_DIM}│${T_RESET}  ${T_YELLOW}${category}${T_RESET}"
    fi
    if [[ -n "$sub_header" ]]; then
      meta="${meta}  ${T_DIM}│  ${sub_header}${T_RESET}"
    fi
    printf '  %s' "$meta"

    # ---- Prompt lines (white text, max 8 + truncation indicator) ----
    local pi=0
    while [[ $pi -lt ${#prompt_lines[@]} ]]; do
      local prow=$((prompt_start + pi))
      local ptext="${prompt_lines[$pi]}"
      ptext="${ptext:0:$((cols - 4))}"
      printf '\e[%d;1H\e[2K  %s%s%s' "$prow" "$T_WHITE" "$ptext" "$T_RESET"
      pi=$((pi + 1))
    done
    if [[ "$prompt_truncated" == "true" ]]; then
      local trow=$((prompt_start + ${#prompt_lines[@]}))
      printf '\e[%d;1H\e[2K  %s… (truncated — full prompt in summary)%s' "$trow" "$T_DIM" "$T_RESET"
    fi

    # ---- Top border ----
    printf '\e[%d;1H\e[2K' "$border_row"
    printf '%s%s%s' "$T_DIM" "$border" "$T_RESET"

    # ---- Content area (bottom-anchored) ----
    if [[ -f "$log_file" ]] && [[ $total_lines -gt 0 ]]; then
      local content
      content="$(tail -n "$visible_lines" "$log_file" 2>/dev/null | \
        sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | \
        cut -c1-"$((cols - 4))")"

      local line_count=0
      local lines_arr=()
      while IFS= read -r _cline; do
        lines_arr+=("$_cline")
        line_count=$((line_count + 1))
      done <<< "$content"

      local start_row=$((content_bottom - line_count + 1))
      if [[ $start_row -lt $content_top ]]; then
        start_row=$content_top
      fi

      # Clear empty rows above content
      local row=$content_top
      while [[ $row -lt $start_row ]]; do
        printf '\e[%d;1H\e[2K' "$row"
        row=$((row + 1))
      done

      # Render content lines
      local arr_i=$(( line_count - (content_bottom - start_row + 1) ))
      if [[ $arr_i -lt 0 ]]; then arr_i=0; fi
      row=$start_row
      while [[ $arr_i -lt $line_count ]] && [[ $row -le $content_bottom ]]; do
        printf '\e[%d;1H\e[2K  %s%s%s' "$row" "$T_DIM" "${lines_arr[$arr_i]}" "$T_RESET"
        row=$((row + 1))
        arr_i=$((arr_i + 1))
      done
    else
      # Empty — clear content area
      local row=$content_top
      while [[ $row -le $content_bottom ]]; do
        printf '\e[%d;1H\e[2K' "$row"
        row=$((row + 1))
      done
    fi

    # ---- Bottom border ----
    printf '\e[%d;1H\e[2K' "$((rows - 1))"
    printf '%s%s%s' "$T_DIM" "$border" "$T_RESET"

    # ---- Status bar ----
    printf '\e[%d;1H\e[2K' "$rows"
    printf '  %s%s%s %sRunning%s  %s%s%s%s' \
      "$T_CYAN" "${frames[$frame_i]}" "$T_RESET" \
      "$T_BOLD" "$T_RESET" \
      "$T_DIM" "$elapsed_str" \
      "  │  ${total_lines} lines output" \
      "$T_RESET"

    frame_i=$(( (frame_i + 1) % ${#frames[@]} ))

    # Show cursor after redraw
    printf '\e[?25h'
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

  # Re-read terminal size for final render
  local rows cols
  rows=$(tput lines 2>/dev/null) || rows=24
  cols=$(tput cols 2>/dev/null) || cols=80

  # Load prompt lines for layout calculation
  local max_prompt_lines=8
  local -a prompt_lines=()
  local prompt_truncated=false
  if [[ -n "${_WINDOW_PROMPT_FILE:-}" ]] && [[ -f "$_WINDOW_PROMPT_FILE" ]]; then
    local _pl _total=0
    while IFS= read -r _pl; do
      _total=$((_total + 1))
      if [[ ${#prompt_lines[@]} -lt $max_prompt_lines ]]; then
        prompt_lines+=("$_pl")
      fi
    done < "$_WINDOW_PROMPT_FILE"
    if [[ $_total -gt $max_prompt_lines ]]; then
      prompt_truncated=true
    fi
  fi
  local prompt_line_count=${#prompt_lines[@]}
  if [[ "$prompt_truncated" == "true" ]]; then
    prompt_line_count=$((prompt_line_count + 1))
  fi
  local prompt_start=3
  local border_row=$((prompt_start + prompt_line_count))
  local content_top=$((border_row + 1))
  local content_bottom=$((rows - 2))
  local visible_lines=$((content_bottom - content_top + 1))

  # Elapsed
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

  local total_lines=0
  if [[ -f "${_WINDOW_LOG_FILE:-}" ]]; then
    total_lines=$(wc -l < "$_WINDOW_LOG_FILE" 2>/dev/null | tr -d ' ')
  fi

  local border
  border="$(printf '%.0s─' $(seq 1 "$cols"))"

  # ---- Final frame ----
  printf '\e[2J'

  # Header
  printf '\e[1;1H\e[2K'
  printf '  %s%s%s%s' "$T_BOLD" "$T_CYAN" "$_WINDOW_HEADER" "$T_RESET"

  # Sub-header
  printf '\e[2;1H\e[2K'
  local meta=""
  [[ -n "$_WINDOW_AGENT" ]] && meta="${T_MAGENTA}${_WINDOW_AGENT}${T_RESET}"
  [[ -n "$_WINDOW_CATEGORY" ]] && meta="${meta}  ${T_DIM}│${T_RESET}  ${T_YELLOW}${_WINDOW_CATEGORY}${T_RESET}"
  [[ -n "$_WINDOW_SUB_HEADER" ]] && meta="${meta}  ${T_DIM}│  ${_WINDOW_SUB_HEADER}${T_RESET}"
  printf '  %s' "$meta"

  # Prompt lines (white, max 8 + truncation)
  local pi=0
  while [[ $pi -lt ${#prompt_lines[@]} ]]; do
    local prow=$((prompt_start + pi))
    local ptext="${prompt_lines[$pi]:0:$((cols - 4))}"
    printf '\e[%d;1H\e[2K  %s%s%s' "$prow" "$T_WHITE" "$ptext" "$T_RESET"
    pi=$((pi + 1))
  done
  if [[ "$prompt_truncated" == "true" ]]; then
    local trow=$((prompt_start + ${#prompt_lines[@]}))
    printf '\e[%d;1H\e[2K  %s… (truncated — full prompt in summary)%s' "$trow" "$T_DIM" "$T_RESET"
  fi

  # Top border
  printf '\e[%d;1H\e[2K%s%s%s' "$border_row" "$T_DIM" "$border" "$T_RESET"

  # Final content render (bottom-anchored)
  if [[ -f "${_WINDOW_LOG_FILE:-}" ]] && [[ $total_lines -gt 0 ]]; then
    local content
    content="$(tail -n "$visible_lines" "$_WINDOW_LOG_FILE" 2>/dev/null | \
      sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | \
      cut -c1-"$((cols - 4))")"
    local lines_arr=()
    local line_count=0
    while IFS= read -r _cline; do
      lines_arr+=("$_cline")
      line_count=$((line_count + 1))
    done <<< "$content"
    local start_row=$((content_bottom - line_count + 1))
    [[ $start_row -lt $content_top ]] && start_row=$content_top
    local row=$content_top
    while [[ $row -lt $start_row ]]; do
      printf '\e[%d;1H\e[2K' "$row"
      row=$((row + 1))
    done
    local arr_i=$(( line_count - (content_bottom - start_row + 1) ))
    [[ $arr_i -lt 0 ]] && arr_i=0
    row=$start_row
    while [[ $arr_i -lt $line_count ]] && [[ $row -le $content_bottom ]]; do
      printf '\e[%d;1H\e[2K  %s%s%s' "$row" "$T_DIM" "${lines_arr[$arr_i]}" "$T_RESET"
      row=$((row + 1))
      arr_i=$((arr_i + 1))
    done
  fi

  # Bottom border
  printf '\e[%d;1H\e[2K%s%s%s' "$((rows - 1))" "$T_DIM" "$border" "$T_RESET"

  # Final status bar
  printf '\e[%d;1H\e[2K' "$rows"
  if [[ "$exit_code" -eq 0 ]]; then
    printf '  %s%s✓ Done%s  %s%s  │  %s lines output%s' \
      "$T_BOLD" "$T_GREEN" "$T_RESET" "$T_DIM" "$elapsed_str" "$total_lines" "$T_RESET"
  else
    printf '  %s%s✗ Failed%s %s(exit %s)%s  %s%s  │  %s lines output%s' \
      "$T_BOLD" "$T_RED" "$T_RESET" "$T_DIM" "$exit_code" "$T_RESET" \
      "$T_DIM" "$elapsed_str" "$total_lines" "$T_RESET"
  fi

  # Show cursor, wait for keypress (skip in auto-continue loop mode)
  printf '\e[?25h'

  if [[ -t 0 ]] && ! $_LOOP_AUTO_CONTINUE; then
    printf '\e[%d;1H' "$rows"
    printf '  %s%s│  Hit enter to continue%s' "$T_BOLD" "$T_GREEN" "$T_RESET"
    read -r -n 1 -s </dev/tty 2>/dev/null || true
  fi

  # Leave alternate screen
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
  /experts          List discovered expertise categories
  /discover         Re-discover expertise categories
  /quit             Exit the CLI

${T_BOLD}Usage${T_RESET}
  ${T_DIM}Interactive:${T_RESET}   ./prompter.sh
  ${T_DIM}One-shot:${T_RESET}     ./prompter.sh "your prompt"
  ${T_DIM}Pipe:${T_RESET}         echo "your prompt" | ./prompter.sh

${T_BOLD}Agents${T_RESET}
  codex      OpenAI Codex CLI (default)
  claude     Anthropic Claude Code CLI
  gemini     Google Gemini CLI

${T_BOLD}Flags${T_RESET}
  --version, -v    Show version
  --update         Update to latest version
  --help, -h       Show this help

${T_BOLD}Configuration${T_RESET}
  Global:   ~/.config/prompter/settings.json
  Project:  .prompter.json (in workspace root)
HELP
}

print_experts() {
  resolve_categories_file

  if [[ ! -f "$CATEGORIES_FILE" ]]; then
    printf '\n  %sNo expertise categories discovered yet.%s\n' "$T_YELLOW" "$T_RESET"
    printf '  %sRun /discover to analyze this workspace.%s\n\n' "$T_DIM" "$T_RESET"
    return
  fi

  printf '\n'
  printf '  %s%sExpertise Categories%s  %s(%s)%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET" "$T_DIM" "$CATEGORIES_FILE" "$T_RESET"
  printf '  %s%s%s\n' "$T_DIM" "$(printf '%.0s─' {1..50})" "$T_RESET"
  python3 - "$CATEGORIES_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for i, cat in enumerate(data.get('categories', []), 1):
    name = cat.get('name', '?')
    desc = cat.get('description', '')
    hint = cat.get('expertPromptHint', '')
    paths = cat.get('paths', [])
    print(f"  \033[1m\033[33m{i}. {name}\033[0m")
    print(f"     {desc}")
    if paths:
        print(f"     \033[2mPaths: {', '.join(paths)}\033[0m")
    if hint:
        print(f"     \033[2m{hint}\033[0m")
    print()
PY
}

print_startup_banner() {
  local config_status
  if [[ "$HAS_PROJECT_CONFIG" == "true" ]]; then
    config_status="${T_GREEN}.prompter.json found${T_RESET}"
  else
    config_status="${T_DIM}global only${T_RESET}"
  fi

  printf '\n'
  printf '  %s%sprompter%s  %sv%s%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET" "$T_DIM" "$PROMPTER_VERSION" "$T_RESET"
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
  if $_UPDATE_AVAILABLE; then
    printf '  %s%sUpdate available!%s  Run %sprompter --update%s to upgrade.\n' \
      "$T_BOLD" "$T_YELLOW" "$T_RESET" "$T_CYAN" "$T_RESET"
  fi
  printf '\n'
  printf '  %s/help%s for commands, %s/settings%s to configure, %s/discover%s for categories.\n\n' \
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

print_execution_summary() {
  local exit_code="$1"
  local expert_name="$2"
  local category="$3"
  local summary_file="$4"
  local log_file="$5"

  # Elapsed time
  local elapsed_str=""
  if [[ "${_WINDOW_START_TIME:-0}" -gt 0 ]]; then
    local now elapsed_s mins secs
    now=$(date +%s)
    elapsed_s=$((now - _WINDOW_START_TIME))
    mins=$((elapsed_s / 60))
    secs=$((elapsed_s % 60))
    if [[ $mins -gt 0 ]]; then
      elapsed_str="${mins}m ${secs}s"
    else
      elapsed_str="${secs}s"
    fi
  fi

  local total_lines=0
  if [[ -f "$log_file" ]]; then
    total_lines=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')
  fi

  printf '\n'

  # ═══════ Header bar ═══════
  local cols
  cols=$(tput cols 2>/dev/null) || cols=60
  local wide_sep
  wide_sep="$(printf '%.0s═' $(seq 1 "$cols"))"

  if [[ "$exit_code" -eq 0 ]]; then
    printf '%s%s%s\n' "$T_GREEN" "$wide_sep" "$T_RESET"
    printf '  %s%s✓ Complete%s' "$T_BOLD" "$T_GREEN" "$T_RESET"
  else
    printf '%s%s%s\n' "$T_RED" "$wide_sep" "$T_RESET"
    printf '  %s%s✗ Failed%s %s(exit %s)%s' "$T_BOLD" "$T_RED" "$T_RESET" "$T_DIM" "$exit_code" "$T_RESET"
  fi

  # Metadata line
  printf '  %s│%s  %s%s%s' "$T_DIM" "$T_RESET" "$T_YELLOW" "$expert_name" "$T_RESET"
  [[ -n "$category" ]] && printf '  %s│%s  %s%s%s' "$T_DIM" "$T_RESET" "$T_MAGENTA" "$category" "$T_RESET"
  [[ -n "$elapsed_str" ]] && printf '  %s│%s  %s%s%s' "$T_DIM" "$T_RESET" "$T_CYAN" "$elapsed_str" "$T_RESET"
  printf '  %s│%s  %s%s lines%s' "$T_DIM" "$T_RESET" "$T_DIM" "$total_lines" "$T_RESET"
  printf '\n'

  if [[ "$exit_code" -eq 0 ]]; then
    printf '%s%s%s\n' "$T_GREEN" "$wide_sep" "$T_RESET"
  else
    printf '%s%s%s\n' "$T_RED" "$wide_sep" "$T_RESET"
  fi

  # ═══════ Summary body ═══════
  local summary=""
  if [[ -f "$summary_file" ]] && [[ -s "$summary_file" ]]; then
    summary="$(sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' "$summary_file")"
  elif [[ -f "$log_file" ]] && [[ -s "$log_file" ]]; then
    summary="$(tail -n 80 "$log_file" | sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g')"
  fi

  if [[ -n "$summary" ]]; then
    printf '\n'
    # Colorized rendering with markdown-aware highlighting
    local in_code_block=false
    while IFS= read -r line; do
      # Code block fences
      if [[ "$line" == '```'* ]]; then
        if $in_code_block; then
          in_code_block=false
          printf '  %s%s%s\n' "$T_DIM" "$line" "$T_RESET"
        else
          in_code_block=true
          printf '  %s%s%s\n' "$T_DIM" "$line" "$T_RESET"
        fi
        continue
      fi

      # Inside code block — cyan
      if $in_code_block; then
        printf '  %s%s%s\n' "$T_CYAN" "$line" "$T_RESET"
        continue
      fi

      case "$line" in
        '# '*|'## '*|'### '*)
          # Markdown headings — bold cyan
          printf '  %s%s%s%s\n' "$T_BOLD" "$T_CYAN" "$line" "$T_RESET"
          ;;
        '- '*)
          # Bullet points — green bullet, white text
          printf '  %s%s-%s %s\n' "$T_GREEN" "$T_BOLD" "$T_RESET" "${line:2}"
          ;;
        [0-9]*'. '*)
          # Numbered lists — yellow number, white text
          local num="${line%%.*}"
          local rest="${line#*.}"
          printf '  %s%s%s.%s%s\n' "$T_YELLOW" "$T_BOLD" "$num" "$T_RESET" "$rest"
          ;;
        '  - '*)
          # Nested bullets — dim bullet
          printf '    %s•%s %s\n' "$T_DIM" "$T_RESET" "${line:4}"
          ;;
        *'✓'*|*'✅'*|*'PASS'*|*'pass'*|*' ok'*)
          # Success indicators — green
          printf '  %s%s%s\n' "$T_GREEN" "$line" "$T_RESET"
          ;;
        *'✗'*|*'❌'*|*'FAIL'*|*'Error'*|*'error'*)
          # Failure indicators — red
          printf '  %s%s%s\n' "$T_RED" "$line" "$T_RESET"
          ;;
        *'/'*'.'[a-z]*)
          # Lines containing file paths — yellow
          printf '  %s%s%s\n' "$T_YELLOW" "$line" "$T_RESET"
          ;;
        '')
          # Blank lines
          printf '\n'
          ;;
        *)
          # Default — white
          printf '  %s\n' "$line"
          ;;
      esac
    done <<< "$summary"
    printf '\n'
  fi

  # ═══════ Footer ═══════
  printf '%s%s%s\n' "$T_DIM" "$(printf '%.0s─' $(seq 1 "$cols"))" "$T_RESET"
  if [[ -f "$log_file" ]]; then
    printf '  %sLog:%s %s  %s(%s lines)%s\n' "$T_DIM" "$T_RESET" "$log_file" "$T_DIM" "$total_lines" "$T_RESET"
  fi
  if [[ -f "$summary_file" ]] && [[ -s "$summary_file" ]]; then
    printf '  %sSummary:%s %s\n' "$T_DIM" "$T_RESET" "$summary_file"
  fi
  printf '%s%s%s\n\n' "$T_DIM" "$(printf '%.0s─' $(seq 1 "$cols"))" "$T_RESET"
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
        --sandbox read-only \
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
  local prompt_file="$1" log_file="$2" summary_file="$3"

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
        --output-last-message "$summary_file" \
        - < "$prompt_file" > "$log_file" 2>&1
      ;;
    claude)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      # stdout = final response (summary), stderr = tool logs
      claude -p "$(cat "$prompt_file")" \
        --print \
        ${model_args[@]+"${model_args[@]}"} \
        --allowedTools Edit,Write,Bash,Read,Glob,Grep \
        --dangerously-skip-permissions > "$summary_file" 2>"$log_file"
      # Append summary to log so the window renderer sees it too
      cat "$summary_file" >> "$log_file"
      ;;
    gemini)
      local model_args=()
      if [[ -n "$SETTING_MODEL" ]]; then
        model_args=(--model "$SETTING_MODEL")
      fi
      gemini ${model_args[@]+"${model_args[@]}"} \
        --sandbox \
        -p "$(cat "$prompt_file")" > "$summary_file" 2>"$log_file"
      cat "$summary_file" >> "$log_file"
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
LOOP_MAX_ITERATIONS="${LOOP_MAX_ITERATIONS:-50}"

run_loop() {
  local expert_prompt="$1"
  local expert_name="$2"
  local cat_paths="$3"
  local validation_cmd="$4"

  local progress_file="$WORKSPACE_DIR/.prompter/progress.txt"
  mkdir -p "$WORKSPACE_DIR/.prompter"

  local validation_block=""
  if [[ -n "$validation_cmd" ]]; then
    validation_block="Run \`$validation_cmd\` after making changes to verify correctness."
  fi

  local loop_tmp_dir
  loop_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/prompter-loop.XXXXXX")"
  local loop_start_time
  loop_start_time=$(date +%s)

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
      "maxItems": 50,
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
- Each task should be a single logical unit of work that can be committed and pushed on its own.
- Order tasks by dependency — earlier tasks should not depend on later ones.
- Each task title should be short (under 80 chars) and describe what changes.
- Each task description should include: what to change, which files, and acceptance criteria.
- Size tasks appropriately — don't over-split trivial work, but don't combine unrelated changes.
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

  # Parse task list — handle agent envelope unwrapping
  local tasks_json
  tasks_json="$(python3 - "$plan_output" <<'PY'
import json, re, sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    raw = f.read().strip()

def extract(text):
    for fn in [
        lambda: json.loads(text),
        lambda: json.loads(re.search(r'```json\s*\n(.*?)\n\s*```', text, re.DOTALL).group(1)),
        lambda: json.loads(re.search(r'\{.*\}', text, re.DOTALL).group(0)),
    ]:
        try:
            return fn()
        except Exception:
            pass
    return None

data = extract(raw)

# Unwrap agent envelope (claude --output-format json)
if data is not None and 'result' in data and 'tasks' not in data:
    inner = data['result']
    if isinstance(inner, str):
        data = extract(inner)
    elif isinstance(inner, dict):
        data = inner

if data is None or 'tasks' not in data:
    print("ERROR: Could not parse task plan", file=sys.stderr)
    sys.exit(1)

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
  printf '  %s%sLoop plan: %s tasks%s  %s(agent restarts between each task)%s\n' \
    "$T_BOLD" "$T_MAGENTA" "$task_count" "$T_RESET" "$T_DIM" "$T_RESET"
  print_separator
  python3 - "$tasks_json" <<'PY'
import json, sys
tasks = json.loads(sys.argv[1])
for t in tasks:
    print(f"  \033[2m[\033[0m{t['id']}\033[2m]\033[0m {t['title']}")
PY
  print_separator
  printf '\n'

  # Pause so the user can review the plan before execution begins.
  if [[ -t 0 ]]; then
    printf '  %s%s▶  Hit enter to start with the tasks%s\n' "$T_BOLD" "$T_GREEN" "$T_RESET" >/dev/tty
    read -r -s </dev/tty 2>/dev/null || true
    printf '\n'
  fi

  # Enable auto-continue so task windows don't pause between iterations.
  _LOOP_AUTO_CONTINUE=true

  # Write initial progress file (overwrite — fresh for this loop run)
  python3 - "$tasks_json" "$progress_file" "$expert_name" <<'PY'
import json, sys
from datetime import datetime

tasks = json.loads(sys.argv[1])
path = sys.argv[2]
expert = sys.argv[3]

with open(path, 'w', encoding='utf-8') as f:
    f.write(f"# Loop: {expert}\n")
    f.write(f"# Started: {datetime.now().isoformat(timespec='seconds')}\n")
    f.write(f"# Tasks: {len(tasks)}\n\n")
    for t in tasks:
        f.write(f"[ ] {t['id']}. {t['title']}\n")
    f.write("\n## Log\n\n")
PY

  # ------ Phase L2: Execute each task ------
  local completed=0
  local failed=0

  for task_idx in $(seq 0 $((task_count - 1))); do
    local iteration=$((task_idx + 1))

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

    # Build task prompt
    local task_prompt_file="$loop_tmp_dir/task_${task_id}_prompt.txt"
    local task_log_file="$loop_tmp_dir/task_${task_id}.log"
    local task_summary_file="$loop_tmp_dir/task_${task_id}_summary.txt"

    local current_progress=""
    if [[ -s "$progress_file" ]]; then
      current_progress="$(cat "$progress_file")"
    fi

    cat > "$task_prompt_file" <<TASK_PROMPT
${expert_prompt}

CATEGORY-SPECIFIC CONTEXT:
${cat_paths}

${IMAGE_CONTEXT}

TASK ${task_id} of ${task_count} — This is a loop: the agent restarts between each task. Complete ONLY this task.

Current task:
  Title: ${task_title}
  Description: ${task_desc}

Progress so far:
${current_progress}

INSTRUCTIONS:
1. Complete ONLY this single task. Do not work on other tasks.
2. Read the key files listed above before making changes.
3. Follow existing code style and patterns in the project.
4. ${validation_block:-Verify your changes work correctly.}
5. If tests fail, fix the failures before finishing.
6. After completing the task, create a git commit with a clear message describing what changed, then push to the remote.

IMPORTANT RULES:
- Do NOT refactor, rename, or "improve" code not directly related to this task.
- Do NOT add comments, docstrings, or type annotations to code you didn't change.
- Preserve backward compatibility unless explicitly asked to break it.

RESPONSE FORMAT:
- What you changed and why
- Files changed
- Validation results
TASK_PROMPT

    # Run task in windowed output
    local task_sub_info="task ${iteration}/${task_count}  │  commit & push"
    local task_exit

    if setup_output_window "Task ${iteration}/${task_count}: ${task_title}" \
         "$task_sub_info" "$SETTING_AGENT" "$expert_name" "$task_prompt_file"; then
      _start_window_renderer "$task_log_file"
      set +e
      agent_run_phase2_to_file "$task_prompt_file" "$task_log_file" "$task_summary_file"
      task_exit=$?
      set -e
      teardown_output_window "$task_exit"
    else
      # Fallback: no window
      start_spinner "Task $iteration/$task_count  $task_title"
      set +e
      agent_run_phase2 "$task_prompt_file" "$task_log_file"
      task_exit=${PIPESTATUS[0]}
      set -e
      stop_spinner
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

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Update checkbox
mark = 'x' if status == 'done' else '!'
old = f"[ ] {task_id}. {title}"
new = f"[{mark}] {task_id}. {title}"
content = content.replace(old, new)

# Append log entry
log_line = f"### Task {task_id} — {status} ({datetime.now().strftime('%H:%M:%S')})\n"
content += log_line

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
PY

    # Show task result between windows
    if [[ "$task_status" == "done" ]]; then
      printf '  %s%s✓ Task %s/%s done%s  %s\n' "$T_BOLD" "$T_GREEN" "$iteration" "$task_count" "$T_RESET" "$task_title"
    else
      printf '  %s%s✗ Task %s/%s %s%s  %s\n' "$T_BOLD" "$T_RED" "$iteration" "$task_count" "$task_status" "$T_RESET" "$task_title"
    fi

    # Check for all-complete signal
    local task_output=""
    if [[ -f "$task_log_file" ]]; then
      task_output="$(cat "$task_log_file")"
    fi
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
  local now loop_elapsed mins secs elapsed_str
  now=$(date +%s)
  loop_elapsed=$((now - loop_start_time))
  mins=$((loop_elapsed / 60))
  secs=$((loop_elapsed % 60))
  if [[ $mins -gt 0 ]]; then
    elapsed_str="${mins}m ${secs}s"
  else
    elapsed_str="${secs}s"
  fi

  local cols
  cols=$(tput cols 2>/dev/null) || cols=60
  local wide_sep
  wide_sep="$(printf '%.0s═' $(seq 1 "$cols"))"

  printf '\n'
  if [[ $failed -eq 0 ]]; then
    printf '%s%s%s\n' "$T_GREEN" "$wide_sep" "$T_RESET"
    printf '  %s%s✓ Loop Complete%s' "$T_BOLD" "$T_GREEN" "$T_RESET"
  else
    printf '%s%s%s\n' "$T_YELLOW" "$wide_sep" "$T_RESET"
    printf '  %s%s⚠ Loop Finished with Failures%s' "$T_BOLD" "$T_YELLOW" "$T_RESET"
  fi
  printf '  %s│%s  %s%s%s' "$T_DIM" "$T_RESET" "$T_YELLOW" "$expert_name" "$T_RESET"
  printf '  %s│%s  %s%s%s' "$T_DIM" "$T_RESET" "$T_CYAN" "$elapsed_str" "$T_RESET"
  printf '  %s│%s  %s%s%s/%s%s%s/%s%s%s tasks' \
    "$T_DIM" "$T_RESET" \
    "$T_GREEN" "$completed" "$T_RESET" \
    "$T_RED" "$failed" "$T_RESET" \
    "$T_DIM" "$task_count" "$T_RESET"
  printf '\n'
  if [[ $failed -eq 0 ]]; then
    printf '%s%s%s\n' "$T_GREEN" "$wide_sep" "$T_RESET"
  else
    printf '%s%s%s\n' "$T_YELLOW" "$wide_sep" "$T_RESET"
  fi

  # Show progress file contents
  if [[ -f "$progress_file" ]]; then
    printf '\n'
    while IFS= read -r line; do
      case "$line" in
        '#'*)
          printf '  %s%s%s\n' "$T_DIM" "$line" "$T_RESET"
          ;;
        '### Task'*done*)
          printf '  %s%s%s\n' "$T_GREEN" "$line" "$T_RESET"
          ;;
        '### Task'*failed*)
          printf '  %s%s%s\n' "$T_RED" "$line" "$T_RESET"
          ;;
        '[x]'*)
          printf '  %s%s✓%s %s\n' "$T_GREEN" "$T_BOLD" "$T_RESET" "${line:4}"
          ;;
        '[!]'*)
          printf '  %s%s✗%s %s\n' "$T_RED" "$T_BOLD" "$T_RESET" "${line:4}"
          ;;
        '[ ]'*)
          printf '  %s○%s %s\n' "$T_DIM" "$T_RESET" "${line:4}"
          ;;
        *)
          printf '  %s\n' "$line"
          ;;
      esac
    done < "$progress_file"
    printf '\n'
    printf '  %sProgress file:%s %s\n' "$T_DIM" "$T_RESET" "$progress_file"
  fi

  printf '%s%s%s\n\n' "$T_DIM" "$(printf '%.0s─' $(seq 1 "$cols"))" "$T_RESET"

  _LOOP_AUTO_CONTINUE=false
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

def extract_json(text):
    """Try multiple strategies to extract a JSON object from text."""
    # Try direct parse
    try:
        return json.loads(text)
    except (json.JSONDecodeError, ValueError):
        pass
    # Try ```json fences
    m = re.search(r'```json\s*\n(.*?)\n\s*```', text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(1))
        except (json.JSONDecodeError, ValueError):
            pass
    # Try first { ... } block
    m = re.search(r'\{.*\}', text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(0))
        except (json.JSONDecodeError, ValueError):
            pass
    return None

data = extract_json(raw)

# Unwrap agent envelope formats (claude --output-format json, etc.)
# These have a "result" field containing the model's actual text response.
if data is not None and 'result' in data and 'category' not in data:
    inner = data['result']
    if isinstance(inner, str):
        data = extract_json(inner)
    elif isinstance(inner, dict):
        data = inner

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
You are a prompt routing expert. Your job is to analyze a user's request, select the right expertise category, and write a detailed execution prompt that a coding agent will use to complete the work autonomously.

PROJECT CONTEXT:
${WORKSPACE_CONTEXT}

CATEGORIES:
${category_section}

STEP 1 — INVESTIGATE THE CODEBASE (scoped to the user's request only):
Before writing the expert prompt, use your tools to read the source files that are directly related to what the user is asking for. Do NOT explore broadly or read unrelated code — only investigate what the user's request touches.
- Search for files, functions, or constants that the user's request specifically mentions or clearly implies.
- Read those files to understand the current implementation and conventions in that area.
- If the request mentions an error or bug, trace that specific code path.
- Check for existing tests related to the area the user is asking about.
Do NOT read files outside the scope of the user's request. The goal is to ground the expert prompt in the real code for the specific area being changed, not to survey the whole project.

STEP 2 — SELECT CATEGORY AND WRITE THE EXPERT PROMPT:
1. Select the ONE category that best fits the user's request.
2. Write expertPrompt — a comprehensive, self-contained prompt for a coding agent who is an expert in that category. This prompt must include EVERYTHING the agent needs to work autonomously. Ground it in what you actually found in the code, not guesses:

   REQUIRED in expertPrompt:
   a) PROBLEM STATEMENT — What exactly needs to change and why. Include all relevant details, error messages, logs, or requirements from the user's input verbatim.
   b) ROOT CAUSE HYPOTHESIS — If this is a bug, state your best hypothesis based on the actual code you read. If a feature, describe where it fits based on the real architecture you observed.
   c) KEY FILES — List the specific files the agent should work with, using exact paths you confirmed exist. Include relevant line numbers or function names you found.
   d) APPROACH — A concrete step-by-step approach grounded in the actual code patterns, naming conventions, and architecture you observed during investigation.
   e) CONSTRAINTS — What NOT to change. Adjacent code to preserve. Breaking changes to avoid. Style conventions you observed in the codebase.
   f) TESTING — Which test files to update or create, based on the existing test patterns you found. What scenarios to cover. Include the test command if known.
   g) ACCEPTANCE CRITERIA — How to verify the work is complete and correct.
${IMAGE_CONTEXT:+   h) IMAGES — The user has attached images. Instruct the agent to read and analyze each one using file-reading tools, and reference what the images show.}

   The expertPrompt should start with: "You are the {expertName} for this project."

3. Set expertName to a clear role (e.g. "Auth & Security Expert", "API Layer Specialist").

Output: JSON with exactly these keys: category, expertName, expertPrompt
${IMAGE_CONTEXT:+
ATTACHED IMAGES:
${IMAGE_CONTEXT}}

USER REQUEST:
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

  # --- Optional prompt validation ---
  if [[ -t 0 ]]; then
    printf '\n' >/dev/tty
    printf '  %sWould you like to review the generated prompt?%s\n' "$T_BOLD" "$T_RESET" >/dev/tty
    printf '  %s[v]%s View prompt     %s[enter]%s Skip & continue\n\n' \
      "$T_BOLD" "$T_RESET" "$T_DIM" "$T_RESET" >/dev/tty
    printf '  %sReview%s [v/Enter]: ' "$T_BOLD" "$T_RESET" >/dev/tty

    local review_choice
    read -r -n 1 review_choice </dev/tty 2>/dev/null || review_choice=""
    printf '\n' >/dev/tty

    if [[ "$review_choice" == "v" || "$review_choice" == "V" ]]; then
      printf '\n' >/dev/tty
      print_separator >/dev/tty
      printf '  %s%sGenerated Expert Prompt:%s\n' "$T_BOLD" "$T_CYAN" "$T_RESET" >/dev/tty
      print_separator >/dev/tty
      printf '%s\n' "$expert_prompt" | while IFS= read -r line; do
        printf '  %s%s%s\n' "$T_DIM" "$line" "$T_RESET"
      done >/dev/tty
      print_separator >/dev/tty
      printf '\n' >/dev/tty
      printf '  %s[enter]%s Continue     %s[r]%s Regenerate     %s[q]%s Abort\n\n' \
        "$T_BOLD" "$T_RESET" "$T_BOLD" "$T_RESET" "$T_BOLD" "$T_RESET" >/dev/tty
      printf '  %sAction%s [Enter/r/q]: ' "$T_BOLD" "$T_RESET" >/dev/tty

      local validate_choice
      read -r -n 1 validate_choice </dev/tty 2>/dev/null || validate_choice=""
      printf '\n' >/dev/tty

      if [[ "$validate_choice" == "q" || "$validate_choice" == "Q" ]]; then
        printf '  %sAborted.%s\n' "$T_DIM" "$T_RESET"
        rm -rf "$tmp_dir"
        return 0
      elif [[ "$validate_choice" == "r" || "$validate_choice" == "R" ]]; then
        printf '\n'
        start_spinner "Phase 1  regenerating expert prompt"
        if ! agent_run_phase1 "$phase1_prompt_file" "$phase1_schema_file" "$phase1_output_file" "$phase1_log_file"; then
          stop_spinner
          echo "Phase 1 regeneration failed." >&2
          rm -rf "$tmp_dir"
          return 1
        fi
        stop_spinner
        if ! extract_phase1_json "$phase1_output_file" "$category_file" "$expert_name_file" "$expert_prompt_file"; then
          echo "Phase 1 output parse failed on regeneration." >&2
          rm -rf "$tmp_dir"
          return 1
        fi
        category="$(cat "$category_file")"
        expert_name="$(cat "$expert_name_file")"
        expert_prompt="$(cat "$expert_prompt_file")"
        cat_paths="$(get_category_paths "$category")"

        printf '\n'
        print_separator
        printf '  %sCategory:%s  %s\n' "$T_DIM" "$T_RESET" "$category"
        printf '  %sExpert:%s    %s%s%s\n' "$T_DIM" "$T_RESET" "$T_YELLOW" "$expert_name" "$T_RESET"
        print_separator
        printf '  %s%sRegenerated — continuing.%s\n\n' "$T_BOLD" "$T_GREEN" "$T_RESET"
      fi
    fi
  fi

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
    mode_instructions="EXECUTION MODE: PLAN THEN EXECUTE

Phase A — Investigation:
1. Read the key files listed above. Trace imports, call chains, and data flow.
2. Search for related patterns (tests, config, types) to understand the full picture.
3. Identify every file that needs to change and every file that could break.

Phase B — Plan:
4. Write a detailed plan: root cause analysis, each file + line range to change, exact changes, test strategy, risk assessment.
5. If your planning workflow presents default answers, accept them and proceed — do not wait for user input.

Phase C — Execute:
6. Implement the plan end-to-end. Make minimal, focused changes — do not refactor unrelated code.
7. Follow existing code style and patterns in the project. Match naming conventions, indentation, and architecture patterns you observe.
8. Update or create tests for every behavioral change.

Phase D — Validate:
9. ${validation_block}
10. If tests fail, fix the failures before finishing. Do not leave broken tests.
${git_block:+11. ${git_block}}"
  else
    mode_instructions="EXECUTION MODE: DIRECT EXECUTION

1. Read the key files listed above to confirm your understanding before making any changes.
2. Build a concrete plan, then execute it end-to-end.
3. Make minimal, focused changes — do not refactor unrelated code.
4. Follow existing code style and patterns in the project. Match naming conventions, indentation, and architecture patterns you observe.
5. Update or create tests for every behavioral change.
6. If your planning workflow presents default answers, accept them and proceed — do not wait for user input.
7. ${validation_block}
8. If tests fail, fix the failures before finishing. Do not leave broken tests.
${git_block:+9. ${git_block}}"
  fi

  cat > "$phase2_prompt_file" <<PHASE2_PROMPT
${expert_prompt}

CATEGORY-SPECIFIC CONTEXT:
${cat_paths}

${IMAGE_CONTEXT}

${mode_instructions}

IMPORTANT RULES:
- Do NOT refactor, rename, or "improve" code that is not directly related to the task.
- Do NOT add comments, docstrings, or type annotations to code you didn't change.
- Do NOT introduce new dependencies unless absolutely necessary.
- Preserve backward compatibility unless explicitly asked to break it.
- If you are unsure about something, read the relevant code first — do not guess.

RESPONSE FORMAT:
When complete, provide a summary including:
- What you changed and why (be specific — file names, function names, line numbers)
- Your root cause analysis (for bugs) or architectural rationale (for features)
- Files changed (full paths)
- Tests added or updated
- Validation results (test output, type-check output)
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

  local sub_info="${execution_mode}${commit_push:+  →  git $commit_push}  │  ${phase2_chars} chars"

  local phase2_summary_file="$tmp_dir/phase2_summary.txt"
  local phase2_exit
  if setup_output_window "$expert_name" "$sub_info" "$SETTING_AGENT" "$category" "$expert_prompt_file"; then
    # Windowed mode: agent writes to file, renderer displays tail in window
    _start_window_renderer "$phase2_log_file"
    set +e
    agent_run_phase2_to_file "$phase2_prompt_file" "$phase2_log_file" "$phase2_summary_file"
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
  fi

  # Show summary after execution
  print_execution_summary "$phase2_exit" "$expert_name" "$category" "$phase2_summary_file" "$phase2_log_file"

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
        print_experts
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
      --version|-v)
        printf 'prompter %s\n' "$PROMPTER_VERSION"
        exit 0
        ;;
      --update)
        do_self_update
        exit 0
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

  # Load settings
  load_settings
  # Check for updates (24h cooldown, non-blocking)
  check_for_updates
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
