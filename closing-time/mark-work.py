#!/usr/bin/env python3
"""
mark-work.py — a Claude Code PostToolUse hook (Edit | Write | NotebookEdit),
the companion to closing-time.sh.

Why: closing-time.sh originally judged "did real work happen this session"
purely from git commit activity in repos under the workspace. That signal is
blind to work done in files git never sees — a scratch note, a config file
sitting directly under the workspace root, anything outside a repo entirely.
It also only ever tracked "uncommitted changes" as an advisory nudge, with no
way to tell freshly-dirtied files (from THIS session) apart from long-running
WIP you left dirty on purpose — so it could never safely turn that nudge into
a hard block without also locking you out of ending a session over unrelated,
pre-existing work.

This hook fixes both gaps by recording, as edits happen:
  ~/.claude/.closing-time-did-work        touched the first time any in-scope
                                           file is edited this session
  ~/.claude/.closing-time-touched-repos   newline-separated, de-duped names of
                                           any repo (under the workspace) edited
                                           this session

closing-time.sh reads both to hard-block on:
  - a repo THIS session left dirty (old unrelated WIP elsewhere stays a soft
    nudge), and
  - real work happened (a git commit today OR this marker) with no fresh
    session-log note yet, if you've configured CLOSING_TIME_VAULT_DIR.

Scope: only file_path/notebook_path values under CLOSING_TIME_WORKSPACE count.
An edit to an unrelated project elsewhere on disk sets neither marker.

This hook never blocks anything — it only records state. Always exits 0, even
on a parse failure or a tool it doesn't recognize.

Wire it (settings.json) alongside closing-time.sh's own Stop-hook wiring:
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit|Write|NotebookEdit",
        "hooks": [ { "type": "command",
                     "command": "/absolute/path/to/mark-work.py" } ] }
    ]
  }
"""

import json
import os
import sys

EDIT_TOOLS = {"Edit", "Write", "NotebookEdit"}

WORKSPACE = os.path.realpath(os.path.expanduser(
    os.environ.get("CLOSING_TIME_WORKSPACE", "~/code")
))
DID_WORK = os.path.expanduser("~/.claude/.closing-time-did-work")
TOUCHED_REPOS = os.path.expanduser("~/.claude/.closing-time-touched-repos")


def in_scope(path):
    try:
        real = os.path.realpath(path)
    except Exception:
        return False
    return real.startswith(WORKSPACE + os.sep)


def repo_for_path(path):
    """Return the top-level directory name directly under WORKSPACE, or
    None. Matches closing-time.sh's own assumption that repos live one level
    below the workspace root (its `find "$WORKSPACE" -maxdepth 2 -name .git`
    discovery)."""
    real = os.path.realpath(path)
    rest = real[len(WORKSPACE) + 1:]
    if not rest:
        return None
    return rest.split(os.sep, 1)[0]


def mark_did_work():
    if not os.path.exists(DID_WORK):
        open(DID_WORK, "a").close()


def mark_touched_repo(repo):
    existing = set()
    if os.path.exists(TOUCHED_REPOS):
        with open(TOUCHED_REPOS) as f:
            existing = {line.strip() for line in f if line.strip()}
    if repo in existing:
        return
    with open(TOUCHED_REPOS, "a") as f:
        f.write(repo + "\n")


def main():
    raw = sys.stdin.read()
    try:
        event = json.loads(raw)
    except Exception:
        return

    if event.get("tool_name") not in EDIT_TOOLS:
        return

    tool_input = event.get("tool_input") or {}
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not path or not in_scope(path):
        return

    mark_did_work()

    repo = repo_for_path(path)
    if repo:
        mark_touched_repo(repo)


if __name__ == "__main__":
    main()
    sys.exit(0)
