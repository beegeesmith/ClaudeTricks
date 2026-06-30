# ClaudeTricks

Small, battle-tested hooks for [Claude Code](https://docs.claude.com/en/docs/claude-code) — each one turns a good habit into a **gate the assistant can't skip**.

> A Claude Code *hook* is a script the CLI runs at a lifecycle moment — before a tool
> runs, or when a session tries to stop. Because the runtime enforces it, the assistant
> can't route around it mid-session. That's what makes these useful as guardrails.

## Tricks

| Trick | Hook type | What it does |
|---|---|---|
| [🐕 Leash](leash/) | `PreToolUse` | Stops subagents from spawning subagents — allowlist which agent types a session may launch. Cures runaway token burn, "hung" sessions, and questions trapped in nested subagent windows. |
| [🕛 Closing Time](closing-time/) | `Stop` | Won't let a session end with unpushed commits (or no session note) — so the next session resumes cheaply instead of re-deriving everything from scratch. |

## What these bind

Every hook here binds the **assistant**, not you. A running session can't disable a
configured hook; you — the config owner — always can. They're guardrails, not handcuffs.

Each trick is self-contained in its own folder with its own README, script, and an
example `settings.json` snippet. Copy what you need.
