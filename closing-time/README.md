# 🕛 Closing Time

**A Claude Code Stop-gate: don't let a session end until it's left a clean trail.**

> *"You don't have to go home, but you can't end here."*

## The need

The most valuable things at the end of a coding session are the cheapest to skip: a short
written note of what changed, and actually **pushing** your commits. Skip them and the
bill arrives next session — which opens with nothing durable to read and has to
**re-derive the whole context** from transcripts and code. With an AI assistant that
re-read can burn an enormous number of tokens; with a human it's a confused half-hour
of "where was I?". Closing Time turns "leave a clean trail" from a forgettable habit into
a **gate the assistant can't skip.**

## What it does

A `Stop` hook that runs when the session tries to end:

- **Hard-blocks** the stop on any of:
  - any repo under your workspace has **unpushed commits** — the unambiguous "ending
    dirty" signal.
  - a repo **this session itself edited** has **uncommitted changes** — self-clears on
    commit + push. A repo with old, unrelated WIP you left dirty on purpose is *not*
    affected — see below.
  - real work happened this session (a commit landed today, or a file was edited —
    including files outside any repo) and there's **no fresh session-log note yet**
    (only checked if you've configured `CLOSING_TIME_VAULT_DIR`).
  The block message hands back a checklist (update your tracker, write the note, push),
  so satisfying it pulls the whole ceremony along.
- **Soft-nudges** if there are uncommitted changes in a repo this session did *not* touch
  — old WIP stays visible without blocking you over it.
- **Silent pass** otherwise.

It auto-discovers the git repos under your workspace — no list to maintain.

### Telling "this session's work" from old WIP

The plain `Stop` hook alone can't tell a file you just edited from one that's been sitting
dirty for a week — so on its own it only ever nudges about uncommitted changes, never
blocks on them (blocking on *any* dirty repo would lock you out over work that has nothing
to do with the current session). Two small companion hooks close that gap:

- **`mark-work.py`** (`PostToolUse` on `Edit`/`Write`/`NotebookEdit`) — records, as edits
  land, that real work happened this session and which repo it landed in.
- **`reset-markers.sh`** (`SessionStart`) — clears that state fresh at the start of every
  session, so it never leaks from one session into the next.

Install both (see below) for the hardened behavior above. Without them, `closing-time.sh`
still works — it just falls back to the original behavior: unpushed commits hard-block,
uncommitted changes and a missing note both stay soft nudges.

## It costs nothing to run

The hook is a **plain deterministic shell script** — `git` + `find`, no LLM, no API calls,
**zero tokens**. The only work it *prompts* is cheap: committing/pushing is mechanical, and
the session-log digest is written by the session that already holds the context (a one-time
write, not the expensive re-derivation it prevents). Net: it spends a few seconds of shell
to save the next session a giant re-read.

## Safety valves (a hook should never trap you)

- **Scoped** — only acts when your working dir is inside the configured workspace.
- **Escape hatch** — `touch ~/.claude/.skip-closing-time` or `export CLOSING_TIME_SKIP=1`.
- **Loop cap** — after 3 consecutive blocks it downgrades to advisory, so a genuinely
  failing push can never lock you out.

## Install

1. Copy `closing-time.sh` to e.g. `~/.claude/hooks/closing-time.sh`; `chmod +x` it.
2. Wire it as a `Stop` hook in `settings.json` (see `settings.example.json`).
3. Configure (all optional):
   - `CLOSING_TIME_WORKSPACE` — root folder holding your repos (default `$HOME/code`).
   - `CLOSING_TIME_VAULT_DIR` — where you keep dated session notes. Leave unset to skip the
     note check entirely — no nudge, no hard block for a missing note.
4. **Optional but recommended:** also copy `mark-work.py` and `reset-markers.sh` next to
   `closing-time.sh`, `chmod +x` both, and wire them as `PostToolUse`
   (matcher `Edit|Write|NotebookEdit`) and `SessionStart` hooks respectively (see
   `settings.example.json`). This upgrades "uncommitted changes" and "missing session-log
   note" from soft nudges to hard blocks, scoped to only this session's own work.

## Session notes (optional)

If you keep dated notes in an Obsidian vault (or any plain folder), point
`CLOSING_TIME_VAULT_DIR` at it and name notes like `... Session Log YYYY-MM-DD ....md`.
Closing Time flags it when today's note is missing and real work happened — a nudge on
its own, or a hard block if you've also installed `mark-work.py` + `reset-markers.sh`.
Works with whatever folder convention you use (PARA, a numbered project tree, etc.).

## Caveat

Binds the **assistant**, not you. A running session can't disable a configured Stop hook —
that's what makes it stick. You, the config owner, always can.
