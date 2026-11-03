#!/bin/bash
# Owns this tab's title.
#
# Claude Code is told to keep its hands off the title via
# CLAUDE_CODE_DISABLE_TERMINAL_TITLE, so nothing competes with these writes and
# a name set with `nyan` survives a working turn instead of being overwritten a
# second later. In exchange we write the working state ourselves.
#
#   work   turns one nyan circle, 🔴 name
#   done   stops it, ✅ name
#   clear  stops it, name        (also used at SessionStart, so a tab never
#                                 shows the raw "caffeinate < claude ..." line)
#
# Never blocks a response: every path exits 0.

set -u

MODE="${1:-done}"
DONE_MARK="✅"
FIRST_FRAME="🔴"

# The hook gets a budget, not the user's turn.
#
# Every step below is a fork or a filesystem call, and on this machine those
# have stalled for seconds at a time: rm of a one-file lock dir sat in unlinkat
# until the hook timeout killed it, which is what the spin-*.lock.stale.* dirs
# left in $STATE are. Raising the timeout would only make the wait longer. So
# the real work runs in a child and the hook waits about two seconds for it; a
# child still busy after that is told to stop and the hook exits 0 without its
# decoration. The child's output never reaches Claude, so a child that cannot
# die yet (stuck in the kernel) holds nothing Claude is waiting on.
#
# The child walks to the tty and the claude process from the hook's own parent
# (NYAN_FROM), because once this wrapper exits its parent is gone.
if [ -z "${NYAN_WORKER:-}" ]; then
  exec 3<&0
  NYAN_WORKER=1 NYAN_FROM="$PPID" bash "$0" "$MODE" <&3 >/dev/null 2>&1 &
  W=$!
  exec 3<&-
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$W" 2>/dev/null || exit 0
    sleep 0.05
    i=$(( i + 1 ))
  done
  kill "$W" 2>/dev/null
  exit 0
fi
FROM="${NYAN_FROM:-$PPID}"

STATE="${XDG_DATA_HOME:-$HOME/.local/share}/claude-nyan"
. "$STATE/lib.sh"

NAMES="$STATE/names"
mkdir -p "$NAMES" 2>/dev/null || true

TTYNAME="$(nyan_tty "$FROM")" || exit 0
DEV="/dev/$TTYNAME"
KEY="$(echo "$TTYNAME" | tr '/' '_')"
PIDFILE="$STATE/spin-$KEY.pid"
LOCKDIR="$STATE/spin-$KEY.lock"

# A name set with `nyan name` always wins.
NAME=""
[ -f "$NAMES/$KEY" ] && NAME="$(head -n1 "$NAMES/$KEY" 2>/dev/null)"

# Otherwise derive one. Claude Code no longer writes a title for us to read, so
# the name is built here from the same two facts claude-st used: the project
# folder and the branch. The branch keeps only its last two dash-separated
# segments, matching the status bar, because a tab pill has very little room.
if [ -z "$NAME" ]; then
  DIR=""
  if [ ! -t 0 ]; then
    PAYLOAD="$(/bin/cat 2>/dev/null || true)"
    if [ -n "$PAYLOAD" ]; then
      JQ=/opt/homebrew/bin/jq
      [ -x "$JQ" ] || JQ="$(command -v jq 2>/dev/null || true)"
      [ -n "$JQ" ] && DIR="$(printf '%s' "$PAYLOAD" | "$JQ" -r '.cwd // .workspace.current_dir // ""' 2>/dev/null)"
    fi
  fi
  [ -n "$DIR" ] || DIR="$PWD"

  NAME="$(/usr/bin/basename "$DIR" 2>/dev/null)"
  if BR="$(/usr/bin/git -C "$DIR" branch --show-current 2>/dev/null)" && [ -n "$BR" ]; then
    BR="${BR##*/}"
    case "$BR" in
      *-*-*) BR="$(awk -F- '{print $(NF-1)"-"$NF}' <<< "$BR")" ;;
    esac
    NAME="$NAME · $BR"
  fi
fi

[ -n "$NAME" ] || exit 0

# Only the spinner handover below needs the mutex, and it is taken as late as
# possible: the stdin read and the git call above it are the slow parts, and no
# lock should ever be held across them. A lock that does not come is not waited
# on , see lib.sh.
trap 'nyan_unlock "$LOCKDIR"' EXIT
nyan_lock "$LOCKDIR" || true

case "$MODE" in
  work)
    nyan_stop_spinner "$PIDFILE"
    OWNER="$(nyan_claude_pid "$FROM" || true)"
    # Paint frame one straight away, so the tab never sits on the old marker
    # while the spinner starts up.
    nyan_title "$DEV" "$FIRST_FRAME $NAME"
    nohup bash "$STATE/nyan-spin.sh" "$DEV" "$NAME" "$OWNER" >/dev/null 2>&1 &
    { echo $! > "$PIDFILE"; } 2>/dev/null
    ;;
  clear)
    nyan_stop_spinner "$PIDFILE"
    nyan_title "$DEV" "$NAME"
    # Nothing ever removed a branch cache, so every directory ever visited left
    # a file behind for good. Swept here because `clear` runs at session start
    # and end only , the status bar itself runs once a second and must not fork
    # a find. A week is long enough that a swept entry costs one git call.
    # Detached: it deletes, and deletes are what stall here.
    ( find "$STATE" -maxdepth 1 \( -name 'branch-*' -o -name 'rate-limits.*' \) -mtime +7 -delete ) </dev/null >/dev/null 2>&1 &
    ;;
  *)
    nyan_stop_spinner "$PIDFILE"
    nyan_title "$DEV" "$DONE_MARK $NAME"
    ;;
esac

exit 0
