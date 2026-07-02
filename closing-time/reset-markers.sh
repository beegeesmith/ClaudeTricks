#!/usr/bin/env bash
# reset-markers.sh — a Claude Code SessionStart hook, the other companion to
# closing-time.sh.
#
# Does two jobs at the start of every session:
#
# 1. Clears the per-session markers written by mark-work.py
#    (.closing-time-did-work, .closing-time-touched-repos) so a fresh session
#    never inherits "did work" / "touched repo" state left over from a previous
#    one. The unpushed-commits loop-cap counter (.closing-time-block-count) is
#    intentionally NOT cleared here — that tracks consecutive hard-block
#    failures within a single stuck session, not per-session state, and
#    closing-time.sh already clears it itself once the underlying condition
#    resolves.
#
# 2. Makes the escape hatch LOUD and SELF-EXPIRING. The `.skip-closing-time`
#    touch-file is a disaster hatch for a stuck loop — but nothing used to
#    announce it or expire it, so once armed it silently no-op'd the whole
#    gate for every later session until someone remembered it existed. Now:
#      - an armed skip-file is announced at session start with its age
#        (SessionStart stdout lands in the assistant's context, so the notice
#        reaches the session that must act on it);
#      - a skip-file older than 24h is deleted automatically, with a notice;
#      - every detection/expiry — and every actual use, see closing-time.sh —
#        is appended to a small ledger (~/.claude/closing-time-bypass.log:
#        timestamp, event, file, file-mtime) so you can always answer "how
#        long was the gate off, and how often was that used?".
#
# Configure (optional; must match closing-time.sh if you override there):
#   CLOSING_TIME_SKIP_FILE    the escape-hatch touch-file
#                             (default: $HOME/.claude/.skip-closing-time)
#   CLOSING_TIME_BYPASS_LOG   the bypass ledger
#                             (default: $HOME/.claude/closing-time-bypass.log)
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

SKIP_FILE="${CLOSING_TIME_SKIP_FILE:-$HOME/.claude/.skip-closing-time}"
BYPASS_LOG="${CLOSING_TIME_BYPASS_LOG:-$HOME/.claude/closing-time-bypass.log}"

ledger() { # ledger <event> <file> <mtime-epoch|->
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" "$3" >> "$BYPASS_LOG"
}

if [ -f "$SKIP_FILE" ]; then
  now=$(date +%s)
  # BSD stat (macOS) first, GNU stat (Linux) fallback
  mt=$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null || echo "$now")
  age=$(( now - mt ))
  age_h=$(( age / 3600 )); age_m=$(( (age % 3600) / 60 ))
  if [ "$age" -gt 86400 ]; then
    rm -f "$SKIP_FILE"
    ledger "expired-removed" "$SKIP_FILE" "$mt"
    echo "🚨 CLOSING TIME BYPASS EXPIRED: $SKIP_FILE was armed for ${age_h}h ${age_m}m (>24h) — removed at session start. The gate is ACTIVE again. (logged to $BYPASS_LOG)"
  else
    ledger "detected-armed" "$SKIP_FILE" "$mt"
    echo "⚠️  CLOSING TIME BYPASS ARMED: $SKIP_FILE exists (age ${age_h}h ${age_m}m) — the gate is currently a NO-OP for every stop. It self-expires at 24h. If this session doesn't need it, delete it now: rm $SKIP_FILE  (logged to $BYPASS_LOG)"
  fi
fi

exit 0
