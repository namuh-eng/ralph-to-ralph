# ralph-to-ralph-onboard skill

Interactive onboarding for ralph-to-ralph — runs inside a Claude Code session instead of the terminal.

## Install

Run once from the repo root:

**Claude Code:**
```bash
ln -s "$(pwd)/skills/ralph-to-ralph-onboard" ~/.claude/skills/ralph-to-ralph-onboard
```

**Codex:**
```bash
ln -s "$(pwd)/skills/ralph-to-ralph-onboard" ~/.codex/skills/ralph-to-ralph-onboard
```

## Use

**Claude Code** — in any Claude Code session inside this repo:
```
/ralph-to-ralph-onboard
```

**Codex** — in any Codex session inside this repo:
```
/ralph-to-ralph-onboard
```

Claude will ask what you want to clone, research the product, explain the required stack in plain English, and set everything up.

## vs onboard.sh

| | `/ralph-to-ralph-onboard` skill | `./onboard.sh` |
|---|---|---|
| Interface | Conversational, inside Claude Code | Interactive terminal script |
| Research | Live web search | Claude research in pipe mode |
| Stack explanation | Plain English, service-by-service | Summary at end |
| Best for | First-time users, exploring options | Power users, CI/automation |

Both produce the same `ralph-config.json` and project setup. Use whichever fits your workflow.
