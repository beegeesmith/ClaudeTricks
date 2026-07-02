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
  ~/.claude/closing-time-markers/<session_id>.did-work
      touched the first time any in-scope file is edited this session
  ~/.claude/closing-time-markers/<session_id>.touched-repos
      newline-separated, de-duped names of any repo (under the workspace)
      edited this session

Markers are PER-SESSION (keyed by the session_id every hook envelope carries):
two concurrent sessions must not share them, or session A's stop hard-blocks
on session B's in-flight work, and any new session start wipes the state of
sessions still open. If an envelope has no usable session_id, we fall back to
the legacy global files (~/.claude/.closing-time-did-work / -touched-repos) so
the signal degrades to the old behavior rather than disappearing.

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
import re
import sys

EDIT_TOOLS = {"Edit", "Write", "NotebookEdit"}

WORKSPACE = os.path.realpath(os.path.expanduser(
    os.environ.get("CLOSING_TIME_WORKSPACE", "~/code")
))
MARKERS_DIR = os.path.expanduser(
    os.environ.get("CLOSING_TIME_MARKERS_DIR", "~/.claude/closing-time-markers")
)
LEGACY_DID_WORK = os.path.expanduser("~/.claude/.closing-time-did-work")
LEGACY_TOUCHED_REPOS = os.path.expanduser("~/.claude/.closing-time-touched-repos")

# session_id becomes a filename component — accept only safe characters
# (anything else, including traversal attempts, falls back to legacy).
SAFE_SID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def marker_paths(session_id):
    """(did_work, touched_repos) for this session; legacy globals if no sid."""
    if session_id and SAFE_SID.match(session_id):
        os.makedirs(MARKERS_DIR, exist_ok=True)
        base = os.path.join(MARKERS_DIR, session_id)
        return base + ".did-work", base + ".touched-repos"
    return LEGACY_DID_WORK, LEGACY_TOUCHED_REPOS


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


def mark_did_work(did_work):
    if not os.path.exists(did_work):
        open(did_work, "a").close()


def mark_touched_repo(touched_repos, repo):
    existing = set()
    if os.path.exists(touched_repos):
        with open(touched_repos) as f:
            existing = {line.strip() for line in f if line.strip()}
    if repo in existing:
        return
    with open(touched_repos, "a") as f:
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

    did_work, touched_repos = marker_paths(event.get("session_id") or "")
    mark_did_work(did_work)

    repo = repo_for_path(path)
    if repo:
        mark_touched_repo(touched_repos, repo)


if __name__ == "__main__":
    main()
    sys.exit(0)
