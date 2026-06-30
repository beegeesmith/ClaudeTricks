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
#   HARD BLOCK on UNPUSHED commits in any repo under the workspace (the unambiguous
#     "ending dirty" signal; self-clears once you push). The block message carries the
#     full checklist.
#   SOFT NUDGE when work was committed today but no session-log note exists yet, or when
#     there are uncommitted changes.
#   SILENT PASS otherwise.
#
# Safety valves (a hook should never trap you):
#   - scoped: only acts when the session's working dir is inside the workspace.
#   - escape hatch: `touch ~/.claude/.skip-closing-time` or export CLOSING_TIME_SKIP=1.
#   - loop cap: after 3 consecutive hard blocks, it downgrades to advisory.
#
# Configure (all optional; sane defaults):
#   CLOSING_TIME_WORKSPACE   root dir holding your git repos        (default: $HOME/code)
#   CLOSING_TIME_VAULT_DIR   dir where you keep dated session-log notes — e.g. a folder in
#                            an Obsidian vault. Leave unset to skip the note nudge.
#   CLOSING_TIME_SKIP=1      bypass entirely
#
# It auto-discovers every git repo under the workspace — no repo list to maintain.

set -u

WORKSPACE="${CLOSING_TIME_WORKSPACE:-$HOME/code}"
VAULT_LOG_DIR="${CLOSING_TIME_VAULT_DIR:-}"
COUNTER="${CLOSING_TIME_COUNTER:-$HOME/.claude/.closing-time-block-count}"

# --- escape hatch ---
[ -n "${CLOSING_TIME_SKIP:-}" ] && exit 0
[ -f "$HOME/.claude/.skip-closing-time" ] && exit 0

# --- scope: only inside the workspace ---
case "$PWD" in
  "$WORKSPACE"*) ;;
  *) exit 0 ;;
esac

TODAY="$(date +%F)"
unpushed=""
uncommitted=""
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
  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    uncommitted="${uncommitted}  - ${name}\n"
  fi
  if [ -n "$(git -C "$d" log --since="${TODAY} 00:00" --oneline 2>/dev/null)" ]; then
    shipped_today=1
  fi
done < <(find "$WORKSPACE" -maxdepth 2 -name .git -type d 2>/dev/null)

# --- HARD BLOCK: unpushed commits = ending dirty ---
if [ -n "$unpushed" ]; then
  c=$(cat "$COUNTER" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$COUNTER"
  if [ "$c" -le 3 ]; then
    {
      echo "⛔ CLOSING TIME — you're ending with unpushed commits:"
      printf "%b" "$unpushed"
      echo "Before you stop:"
      echo "  1. Update your issue tracker with current state + evidence."
      echo "  2. Write a short session-log note for today (so resuming is cheap)."
      echo "  3. Commit + push every repo."
      echo "Then stopping is safe. (Escape hatch: touch ~/.claude/.skip-closing-time)"
    } >&2
    exit 2
  fi
  # loop cap reached — downgrade to advisory so a failing push can't trap the session
  echo "⚠️  Closing Time has blocked ${c}× — downgrading to advisory to avoid a loop."
  echo "    Resolve the unpushed commits manually, then it resets."
fi

# reached only when there are no unpushed commits, or the loop cap tripped — reset
rm -f "$COUNTER"

# --- vault session-log for today present & fresh? (only if a vault dir is configured) ---
vault_log=0
if [ -n "$VAULT_LOG_DIR" ] && [ -d "$VAULT_LOG_DIR" ]; then
  if find "$VAULT_LOG_DIR" -maxdepth 1 -name "*Session Log ${TODAY}*.md" -mtime -1 2>/dev/null | grep -q .; then
    vault_log=1
  fi
fi

# --- SOFT NUDGE: work shipped today but no session-log note ---
if [ "$shipped_today" -eq 1 ] && [ -n "$VAULT_LOG_DIR" ] && [ "$vault_log" -eq 0 ]; then
  echo "📓 Closing Time reminder: work shipped today but no session-log note yet."
  echo "   Jot the digest now so the next session resumes cheaply (avoids a full re-read):"
  echo "   \"${VAULT_LOG_DIR}/<name> Session Log ${TODAY}.md\""
fi

# --- SOFT NUDGE: uncommitted changes ---
if [ -n "$uncommitted" ]; then
  echo "🔄 Uncommitted changes — sync before ending:"
  printf "%b" "$uncommitted"
fi

exit 0
