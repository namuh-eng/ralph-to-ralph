#!/bin/bash
# agent-runner.sh — shared helper so each loop phase (inspect / build / qa /
# architecture) can be backed by either codex or claude, with a single
# reasoning_effort knob for codex.
#
# Call `load_agent_config <phase>` to populate RALPH_AGENT and
# RALPH_REASONING_EFFORT from ralph-config.json, then call
# `agent_invoke <timeout_seconds> <prompt>` to actually run the agent.
#
# Per-phase keys in ralph-config.json:
#   inspectAgent, buildAgent, qaAgent, architectureAgent  (enum: codex | claude)
#   reasoningEffort                                       (enum: minimal | low | medium | high)
#
# Defaults: codex, reasoningEffort=low (best across loops, per onboarding).

# Resolve Python the same way the loop scripts do.
if command -v uv &>/dev/null; then
  _AGENT_PY="uv run python3"
else
  _AGENT_PY="python3"
fi

# Read a single key from ralph-config.json. Falls back to $2 if missing.
_agent_cfg_get() {
  local key="$1" default="$2"
  $_AGENT_PY -c "
import json
try:
    cfg = json.load(open('ralph-config.json'))
    val = cfg.get('$key')
    print(val if val else '$default')
except Exception:
    print('$default')
" 2>/dev/null || echo "$default"
}

# load_agent_config <phase>
# Sets:
#   RALPH_AGENT             — codex | claude
#   RALPH_REASONING_EFFORT  — minimal | low | medium | high (codex-only)
load_agent_config() {
  local phase="$1"
  local key
  case "$phase" in
    inspect)      key="inspectAgent" ;;
    build)        key="buildAgent" ;;
    qa)           key="qaAgent" ;;
    architecture) key="architectureAgent" ;;
    *)            key="" ;;
  esac

  local agent="codex"
  if [ -n "$key" ]; then
    agent=$(_agent_cfg_get "$key" "codex")
  fi
  case "$agent" in
    codex|claude) ;;
    *) agent="codex" ;;
  esac

  local effort
  effort=$(_agent_cfg_get "reasoningEffort" "low")
  case "$effort" in
    minimal|low|medium|high) ;;
    *) effort="low" ;;
  esac

  export RALPH_AGENT="$agent"
  export RALPH_REASONING_EFFORT="$effort"
}

# agent_invoke <timeout_seconds> <prompt>
# Runs the configured agent with the given prompt and prints its stdout.
agent_invoke() {
  local timeout_s="$1"
  local prompt="$2"
  local agent="${RALPH_AGENT:-codex}"
  local effort="${RALPH_REASONING_EFFORT:-low}"

  if [ "$agent" = "codex" ]; then
    timeout "$timeout_s" codex exec --dangerously-bypass-approvals-and-sandbox \
      -c model_reasoning_effort="$effort" \
      "$prompt"
  else
    timeout "$timeout_s" claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
      "$prompt"
  fi
}

# agent_label — short human-readable label like "codex (low)" or "claude".
agent_label() {
  local agent="${RALPH_AGENT:-codex}"
  if [ "$agent" = "codex" ]; then
    echo "codex (reasoning_effort=${RALPH_REASONING_EFFORT:-low})"
  else
    echo "claude"
  fi
}
