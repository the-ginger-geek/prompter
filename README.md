# prompter v0.0.3

Route coding tasks to expert AI agents. Describe what you need, and prompter picks the right specialist, investigates your codebase, and executes.

## Install

```bash
curl -fsSL https://prompter-7fe6d.web.app/get.sh | bash
```

Requires `git`, `node` (18+), and `python3`.

## Usage

```bash
# Interactive mode
prompter

# One-shot
prompter "fix the auth middleware returning 401 for valid tokens"

# Pipe
echo "add input validation to the API routes" | prompter
```

## Execution modes

| Mode | Key | Description |
|------|-----|-------------|
| Execute | `E` | Generates an expert prompt and hands it straight to the agent |
| Plan | `P` | Agent investigates and plans before making changes |
| Loop | `L` | Breaks work into tasks, executes one by one with auto-commit |

## Agents

Prompter supports multiple AI agent backends:

- **codex** — OpenAI Codex CLI (default)
- **claude** — Anthropic Claude Code CLI
- **gemini** — Google Gemini CLI

Switch agents with `/settings` or in `~/.config/prompter/settings.json`.

## Features

- **Expert routing** — Phase 1 reads your codebase and selects a specialist agent
- **Codebase-aware prompts** — investigates source files relevant to your request before generating the execution prompt
- **Prompt review** — optionally inspect, regenerate, or abort the generated prompt before execution
- **Auto-discovery** — scans your project on first run to discover expertise categories
- **Git integration** — optional commit and push after task completion
- **Image support** — drag and drop screenshots into your prompt
- **Self-update** — `prompter --update`

## Commands

| Command | Description |
|---------|-------------|
| `/help` | Show help |
| `/settings` | Configure agent, mode, and model |
| `/experts` | List discovered expertise categories |
| `/discover` | Re-discover expertise categories |
| `/quit` | Exit |

## Flags

```
--version, -v    Show version
--update         Update to latest version
--help, -h       Show help
```

## Configuration

- **Global:** `~/.config/prompter/settings.json`
- **Project:** `.prompter.json` in workspace root

## License

MIT
