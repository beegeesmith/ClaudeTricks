#!/usr/bin/env bash
# reset-markers.sh — a Claude Code SessionStart hook, the other companion to
# closing-time.sh.
#
# Clears the per-session markers written by mark-work.py
# (.closing-time-did-work, .closing-time-touched-repos) so a fresh session
# never inherits "did work" / "touched repo" state left over from a previous
# one. The unpushed-commits loop-cap counter (.closing-time-block-count) is
# intentionally NOT cleared here — that tracks consecutive hard-block
# failures within a single stuck session, not per-session state, and
# closing-time.sh already clears it itself once the underlying condition
# resolves.
#
# Wire it (settings.json) alongside closing-time.sh's own Stop-hook wiring:
#   "hooks": {
#     "SessionStart": [
#       { "hooks": [ { "type": "command",
#                      "command": "/absolute/path/to/reset-markers.sh" } ] }
#     ]
#   }
set -u
rm -f "$HOME/.claude/.closing-time-did-work" "$HOME/.claude/.closing-time-touched-repos"
exit 0
