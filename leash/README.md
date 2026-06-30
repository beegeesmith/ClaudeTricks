# 🐕 Leash

**Keep Claude Code subagents on a short leash — stop agents from spawning agents.**

Claude Code lets an agent spawn subagents (the `Agent` / Task tool). That's useful —
until a *generic* subagent (one with the full toolset) spawns its *own* subagents, which
spawn theirs. Delegation goes from a clean one-level fan-out to an invisible, multiplying
tree. **Leash** is a tiny, dependency-free `PreToolUse` hook that allowlists which
subagent types a session may spawn, so only your named, single-purpose ("leaf") agents
can be launched — and nesting can't happen.

## The symptoms it cures

If you've hit any of these, uncontrolled subagent nesting is a prime suspect:

**(a) Massive usage / token burn.** A generic agent re-delegates; each child can
re-delegate; one request quietly becomes dozens of agents. Token usage and cost spike
with little visible output to show for it — because most of the work is agents talking to
agents, not progress on your task.

**(b) Slow or "hung" sessions that never progress.** The parent blocks waiting on a deep
tree of children. The UI says "an agent is running" but nothing advances for minutes; the
session looks frozen. The deeper the tree, the longer the stall — and a child stuck on
something it can't resolve may never return at all.

**(c) Questions trapped in subagent-of-subagent windows.** The insidious one. Only the
*top-level* session can show you a permission prompt or ask a clarifying question. When a
nested subagent hits one, that prompt renders into a window you never see. The child can't
reach you, so it times out, auto-denies, or just **guesses** — and you get silently wrong
work with no idea a question was ever asked.

## What it does

- Runs as a `PreToolUse` hook on the subagent-spawn tool (`Agent`).
- Reads the requested `subagent_type` and checks it against an allowlist.
- On the list → **allow**. Anything else — a generic/catch-all type, an *omitted* type, or
  any unknown type — is **denied, fail-closed**, before the agent runs.
- Net effect: only your single-purpose leaf agents can be spawned, so delegation stays one
  level deep, observable, and answerable.

## Belt and suspenders

Leash is the *spawn gate*. Pair it with the structural fix: define your subagents
**without** the `Agent`/Task tool, so they're physically incapable of spawning even if a
rule were missing. Leash backstops; tool-omission is the floor. Together, nesting is
impossible from both ends.

## Install

1. Copy `leash.py` somewhere stable, e.g. `~/.claude/hooks/leash.py`, and make it
   executable: `chmod +x ~/.claude/hooks/leash.py`
2. Wire it as a `PreToolUse` hook in your Claude Code `settings.json` (see
   `settings.example.json`).
3. Set your allowlist via `CLAUDE_ALLOWED_SUBAGENTS` (comma-separated), or edit
   `DEFAULT_ALLOWED` in the script.

## Configure

```
CLAUDE_ALLOWED_SUBAGENTS="explorer,researcher,builder,reviewer"
```

Only these types may be spawned; everything else is denied. Add the built-in agents you
actually use (e.g. a read-only explore/plan agent). Leave the generic catch-all types
**off** the list — that's the whole point.

## Test it

Offline:

```bash
echo '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}' | ./leash.py ; echo "exit=$?"  # deny, exit 2
echo '{"tool_name":"Agent","tool_input":{"subagent_type":"researcher"}}'      | ./leash.py ; echo "exit=$?"  # allow, exit 0
```

Live: ask your session to spawn a `general-purpose` agent and watch it get refused.

## How it works (the contract)

- Matches the spawn tool `Agent`; the requested type arrives as `tool_input.subagent_type`.
- Denies via
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}`
  **and** exits non-zero — so it fails *closed* even if the JSON decision isn't honored.

## Scope / caveat

This binds the **agent**, not you. A running session cannot disable a configured
`PreToolUse` hook — that's what makes it enforceable. You, the config owner, can always
change it.
