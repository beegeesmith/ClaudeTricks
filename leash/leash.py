#!/usr/bin/env python3
"""
Leash — a Claude Code PreToolUse hook that keeps subagents from spawning subagents.

It restricts which subagent types a session may spawn. On each subagent-spawn the hook
reads the PreToolUse event JSON from stdin; if the requested subagent type is not on an
allowlist it returns a "deny" decision, so the spawn never runs.

Fail-closed: an unrecognized, empty, or omitted subagent type is denied, as is an event
the hook cannot parse.

Why restrict spawns:
  Generic, catch-all subagent types inherit the full toolset — including the ability to
  spawn *further* subagents. A cheaper model can then end up orchestrating and
  re-delegating. A nested subagent has no channel back to the human: interactive
  permission prompts and clarifying questions cannot surface from inside it, so it fails
  blind or guesses. Restricting spawns to a known set of single-purpose ("leaf") agents
  keeps delegation one level deep, observable, and answerable.

Configure the allowlist (either works; the env var wins if set):
  - edit DEFAULT_ALLOWED below, or
  - set CLAUDE_ALLOWED_SUBAGENTS to a comma-separated list, e.g.
        CLAUDE_ALLOWED_SUBAGENTS="explorer,researcher,builder,reviewer"

Wire it (settings.json) — the matched tool is the subagent-spawning tool:
  "hooks": {
    "PreToolUse": [
      { "matcher": "Agent",
        "hooks": [ { "type": "command",
                     "command": "/absolute/path/to/leash.py",
                     "timeout": 10 } ] }
    ]
  }

Scope note: this binds the *agent* — a running session cannot disable a configured
PreToolUse hook. It does not restrict the human operator, who owns this configuration.
"""

import json
import os
import sys

# Generic default allowlist. Replace with your own agent names, or override at runtime
# via the CLAUDE_ALLOWED_SUBAGENTS environment variable.
DEFAULT_ALLOWED = {
    "explorer",
    "researcher",
    "builder",
    "reviewer",
    "committer",
}

# The tool name that spawns a subagent, as seen in the PreToolUse event.
SPAWN_TOOL = "Agent"
# The field in tool_input that carries the requested subagent type.
TYPE_FIELD = "subagent_type"


def allowed_set():
    env = os.environ.get("CLAUDE_ALLOWED_SUBAGENTS", "").strip()
    if env:
        return {s.strip() for s in env.split(",") if s.strip()}
    return set(DEFAULT_ALLOWED)


def deny(reason):
    """Emit a PreToolUse deny decision and stop. Exit 2 + stderr is a belt-and-suspenders
    backstop in case the JSON decision is not honored, so the gate fails closed."""
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.stdout.flush()
    sys.stderr.write(reason + "\n")
    sys.exit(2)


def allow():
    sys.exit(0)


def main():
    raw = sys.stdin.read()
    try:
        event = json.loads(raw)
    except Exception:
        deny("subagent-spawn blocked: the hook could not parse the tool event.")
        return

    # Only gate the spawn tool; ignore anything else routed here.
    if event.get("tool_name") != SPAWN_TOOL:
        allow()
        return

    allow_list = allowed_set()
    tool_input = event.get("tool_input") or {}
    sub = tool_input.get(TYPE_FIELD)
    sub = sub.strip() if isinstance(sub, str) else ""

    if sub and sub in allow_list:
        allow()
        return

    requested = sub if sub else "<none specified>"
    listed = ", ".join(sorted(allow_list)) or "(none configured)"
    deny(
        "subagent-spawn blocked: type '{0}' is not on the allowlist. "
        "Allowed: {1}. Spawn one of the allowed single-purpose agents, or break the task "
        "down and run it directly rather than delegating to a general-purpose agent.".format(
            requested, listed)
    )


if __name__ == "__main__":
    main()
