#!/usr/bin/env bash
# Closing Time — a Claude Code "Stop" hook that won't let a session end until it has left
# durable artifacts behind: all work committed AND pushed, with a nudge to write a
# session-log note and update your issue tracker.
#
# Why: the valuable end-of-session artifacts — a short written digest of what changed, and
# actually pushing your commits — are the easiest things to skip when they're just a habit.
# The bill lands on the NEXT session: it opens with nothing durable to read and has to
# re-derive the whole context from transcripts and code (an expensive re-read). This hook
# turns "leave a clean trail" from a habit into a gate.
#
# The hook itself spends ZERO tokens — it is plain git + find, no LLM, no API calls.
#
# Contract (Claude Code Stop hook):
#   exit 2  -> BLOCK the stop; stderr is fed back to the assistant, which keeps working.
#   exit 0  -> allow the stop; stdout is shown as an advisory.
#
# Policy:
#   HARD BLOCK on any of:
#     - UNPUSHED commits in any repo under the workspace — self-clears once you push.
#     - uncommitted changes in a repo THIS session edited (see mark-work.py, its
#       companion PostToolUse hook) — self-clears on commit+push. Old, unrelated WIP
#       in a repo this session never touched stays a SOFT NUDGE, unchanged — so this
#       can't lock you out over work you left dirty on purpose.
#     - real work happened this session (a commit landed today, or an in-scope file
#       was edited — see mark-work.py) with no fresh session-log note yet, IF you've
#       configured CLOSING_TIME_VAULT_DIR. Self-clears once you write the note.
#   The block message carries the full checklist either way.
#   SOFT NUDGE on uncommitted changes in a repo NOT touched this session.
#   SILENT PASS otherwise.
#
# Safety valves (a hook should never trap you — but a bypass must be LOUD, not silent):
#   - scoped: only acts when the session's working dir is inside the workspace.
#   - escape hatch: `touch ~/.claude/.skip-closing-time` or export CLOSING_TIME_SKIP=1.
#     Every use is appended to a bypass ledger (~/.claude/closing-time-bypass.log), and
#     reset-markers.sh announces an armed skip-file at every session start and deletes
#     it once it's older than 24h — a disaster hatch, not a standing off-switch.
#   - loop cap: after 3 consecutive hard blocks (any reason above), downgrades to advisory.
#
# Configure (all optional; sane defaults):
#   CLOSING_TIME_WORKSPACE   root dir holding your git repos        (default: $HOME/code)
#   CLOSING_TIME_VAULT_DIR   dir where you keep dated session-log notes — e.g. a folder in
#                            an Obsidian vault. Leave unset to skip the note check entirely
#                            (no soft nudge, no hard block for a missing note).
#   CLOSING_TIME_SKIP=1      bypass entirely (logged to the bypass ledger)
#   CLOSING_TIME_SKIP_FILE   the escape-hatch touch-file
#                            (default: $HOME/.claude/.skip-closing-time)
#   CLOSING_TIME_BYPASS_LOG  the bypass ledger
#                            (default: $HOME/.claude/closing-time-bypass.log)
#   CLOSING_TIME_MARKERS_DIR per-session work-marker directory (default:
#                            $HOME/.claude/closing-time-markers; set the same
#                            value for mark-work.py and reset-markers.sh)
#   CLOSING_TIME_SESSION_ID  session-id override (default: parsed from the
#                            hook's stdin JSON envelope; mainly for testing)
#
# It auto-discovers every git repo under the workspace — no repo list to maintain.
#
# Pairs with two companion hooks (same folder) that give it the two signals above:
#   mark-work.py       PostToolUse hook (Edit|Write|NotebookEdit) — records "did work
#                      happen" + "which repo" as edits land.
#   reset-markers.sh   SessionStart hook — clears that state fresh each session.
# closing-time.sh runs fine without them (falls back to the git-only signals: unpushed
# commits stay a hard block, but uncommitted changes and a missing note both stay soft,
# same as before) — install both for the hardened behavior.

set -u

WORKSPACE="${CLOSING_TIME_WORKSPACE:-$HOME/code}"
VAULT_LOG_DIR="${CLOSING_TIME_VAULT_DIR:-}"
COUNTER="${CLOSING_TIME_COUNTER:-$HOME/.claude/.closing-time-block-count}"

# --- session identity: work-markers are PER-SESSION ---
# They used to be two global files shared by every concurrent session, which
# cross-blocked (session A's stop hard-blocked on session B's in-flight WIP)
# and cross-wiped (a new session's SessionStart erased open sessions' state).
# The Stop hook's stdin JSON envelope carries session_id; parse it defensively —
# on any failure fall back to the legacy global files rather than breaking.
# Override with CLOSING_TIME_SESSION_ID (stdin is only read when it's unset).
SID="${CLOSING_TIME_SESSION_ID:-$(python3 -c '
import json, re, sys
try:
    sid = json.load(sys.stdin).get("session_id") or ""
except Exception:
    sid = ""
print(sid if re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", sid) else "")
' 2>/dev/null || true)}"
MARKERS_DIR="${CLOSING_TIME_MARKERS_DIR:-$HOME/.claude/closing-time-markers}"
if [ -n "$SID" ]; then
  DID_WORK_DEFAULT="$MARKERS_DIR/$SID.did-work"
  TOUCHED_DEFAULT="$MARKERS_DIR/$SID.touched-repos"
else
  DID_WORK_DEFAULT="$HOME/.claude/.closing-time-did-work"
  TOUCHED_DEFAULT="$HOME/.claude/.closing-time-touched-repos"
fi
DID_WORK_FILE="${CLOSING_TIME_DID_WORK:-$DID_WORK_DEFAULT}"
TOUCHED_REPOS_FILE="${CLOSING_TIME_TOUCHED_REPOS:-$TOUCHED_DEFAULT}"

touched_repos=()
if [ -f "$TOUCHED_REPOS_FILE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && touched_repos+=("$line")
  done < "$TOUCHED_REPOS_FILE"
fi
is_touched() {
  local r="$1" t
  for t in "${touched_repos[@]:-}"; do
    [ "$t" = "$r" ] && return 0
  done
  return 1
}

# --- escape hatch (every consumption is written to the bypass ledger — a used
# bypass must leave a trace, not just an effect; reset-markers.sh announces an
# armed skip-file at session start and expires it after 24h) ---
SKIP_FILE="${CLOSING_TIME_SKIP_FILE:-$HOME/.claude/.skip-closing-time}"
BYPASS_LOG="${CLOSING_TIME_BYPASS_LOG:-$HOME/.claude/closing-time-bypass.log}"
ledger() { # ledger <event> <file> <mtime-epoch|->
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" "$3" >> "$BYPASS_LOG"
}
if [ -n "${CLOSING_TIME_SKIP:-}" ]; then
  ledger "used-env" "CLOSING_TIME_SKIP" "-"
  exit 0
fi
if [ -f "$SKIP_FILE" ]; then
  ledger "used-skip" "$SKIP_FILE" "$(stat -f %m "$SKIP_FILE" 2>/dev/null || stat -c %Y "$SKIP_FILE" 2>/dev/null || echo -)"
  exit 0
fi

# --- scope: only inside the workspace ---
case "$PWD" in
  "$WORKSPACE"*) ;;
  *) exit 0 ;;
esac

TODAY="$(date +%F)"
unpushed=""
uncommitted=""    # soft-only: dirty repos NOT touched by this session
hard_dirty=""     # hard-block: dirty repos this session itself edited
shipped_today=0

# auto-discover git repos under the workspace (depth<=2 catches repo roots one level down)
while IFS= read -r gitdir; do
  d="$(dirname "$gitdir")"
  name="$(basename "$d")"
  # unpushed commits on the CURRENT branch — genuinely not on any remote (no network used).
  # Count against the branch's OWN upstream; if it has no upstream, count commits on HEAD
  # that are on no remote at all. (Comparing to origin/main would false-positive on a
  # pushed feature branch that's simply ahead of main.)
  if git -C "$d" rev-parse --verify -q '@{u}' >/dev/null 2>&1; then
    n=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  else
    n=$(git -C "$d" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
  fi
  [ "${n:-0}" -gt 0 ] && unpushed="${unpushed}  - ${name}: ${n} unpushed commit(s)\n"
  # uncommitted working-tree changes — split hard vs soft by whether THIS session is
  # the one that dirtied it (mark-work.py's marker, if it's installed).
  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    if is_touched "$name"; then
      hard_dirty="${hard_dirty}  - ${name}: uncommitted changes (edited this session)\n"
    else
      uncommitted="${uncommitted}  - ${name}\n"
    fi
  fi
  if [ -n "$(git -C "$d" log --since="${TODAY} 00:00" --oneline 2>/dev/null)" ]; then
    shipped_today=1
  fi
done < <(find "$WORKSPACE" -maxdepth 2 -name .git -type d 2>/dev/null)

# did_work is broader than shipped_today: it also covers edits to files under the
# workspace that git never tracks (via mark-work.py), not just commits in a repo.
did_work=0
[ -f "$DID_WORK_FILE" ] && did_work=1

# --- session-log note for today present & fresh? (only if a vault dir is configured —
# needed here, before the hard-block decision below, not just for a soft nudge) ---
vault_log=0
if [ -n "$VAULT_LOG_DIR" ] && [ -d "$VAULT_LOG_DIR" ]; then
  if find "$VAULT_LOG_DIR" -maxdepth 1 -name "*Session Log ${TODAY}*.md" -mtime -1 2>/dev/null | grep -q .; then
    vault_log=1
  fi
fi
missing_vault_log=0
if [ -n "$VAULT_LOG_DIR" ] && { [ "$shipped_today" -eq 1 ] || [ "$did_work" -eq 1 ]; } && [ "$vault_log" -eq 0 ]; then
  missing_vault_log=1
fi

# --- HARD BLOCK: unpushed commits, session-dirtied repos, or a missing session-log
# note with real work done = ending without the ceremony actually happening ---
if [ -n "$unpushed" ] || [ -n "$hard_dirty" ] || [ "$missing_vault_log" -eq 1 ]; then
  c=$(cat "$COUNTER" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$COUNTER"
  if [ "$c" -le 3 ]; then
    {
      echo "⛔ CLOSING TIME — not done yet:"
      if [ -n "$unpushed" ]; then
        echo "Unpushed commits:"
        printf "%b" "$unpushed"
      fi
      if [ -n "$hard_dirty" ]; then
        echo "Uncommitted changes in repos edited THIS session:"
        printf "%b" "$hard_dirty"
      fi
      if [ "$missing_vault_log" -eq 1 ]; then
        echo "No session-log note for today yet, and real work happened this session"
        echo "(a commit today, and/or an edit to a file outside any repo)."
      fi
      echo "Before you stop:"
      echo "  1. Update your issue tracker with current state + evidence."
      echo "  2. Write a short session-log note for today (so resuming is cheap)."
      echo "  3. Commit + push every repo."
      echo "Then stopping is safe. (Escape hatch — logged + self-expiring: touch $SKIP_FILE)"
    } >&2
    exit 2
  fi
  # loop cap reached — downgrade to advisory so a stuck condition can't trap the session
  echo "⚠️  Closing Time has blocked ${c}× — downgrading to advisory to avoid a loop."
  echo "    Resolve manually, then it resets."
fi

# reached only when nothing above triggered, or the loop cap tripped — reset
rm -f "$COUNTER"

# --- SOFT NUDGE: uncommitted changes in repos NOT touched this session ---
# (dirty repos this session itself edited are a HARD BLOCK above, not here)
if [ -n "$uncommitted" ]; then
  echo "🔄 Uncommitted changes (not from this session) — sync before ending:"
  printf "%b" "$uncommitted"
fi

exit 0
