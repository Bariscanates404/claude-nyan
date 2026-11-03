#!/bin/bash
# Turns the nyan rainbow in one tab's title for as long as Claude is working.
#
# Started detached by mark-done.sh on UserPromptSubmit, killed by it on Stop.
# Only possible because CLAUDE_CODE_DISABLE_TERMINAL_TITLE is set: with Claude
# Code also writing the title, two writers a second apart would just make the
# pill flicker.
#
#   $1  the tty device to paint, e.g. /dev/ttys011
#   $2  the tab's name
#   $3  the owning claude pid, so the spinner dies with its session
#
# One circle whose colour turns, the way Claude's own spinner reads.
#
# Green is deliberately absent from the cycle. Done is a green square check, and
# colour is what the eye catches first across fifty grey pills , a green circle
# a fifth of the time would blunt exactly the signal this exists for.

set -u
trap '' HUP        # outlive the hook process that launched us

STATE="${XDG_DATA_HOME:-$HOME/.local/share}/claude-nyan"
. "$STATE/lib.sh"

DEV="${1:-}"
NAME="${2:-}"
OWNER="${3:-}"

[ -n "$NAME" ] || exit 0
[ -n "$DEV" ] && [ -c "$DEV" ] && [ -w "$DEV" ] || exit 0

FRAMES=("🔴" "🟠" "🟡" "🔵" "🟣")
NFRAMES=${#FRAMES[@]}
DELAY=0.25

# The cap is WALL CLOCK, not a count of sleeps.
#
# Counting iterations made "two hours" a lie: close the lid and the countdown
# closes with it, so the cap could span most of a day of real time. That whole
# span is the window in which this daemon can outlive its tab and , tty numbers
# being reissued , paint its frames into a stranger's title bar.
#
# No resolvable owner means the liveness check below cannot run at all, and the
# cap is the ONLY thing left. Then it has to be short: a few minutes of a stuck
# spinner is a nuisance, hours of one writing to a recycled tty is a bug.
START="$(date +%s)"
if [ -n "$OWNER" ]; then LIFE=7200; else LIFE=180; fi

i=0
while :; do
  [ -c "$DEV" ] || exit 0

  # Every tick, because a killed Claude never fires Stop and a spinner left
  # turning on a dead tab is a lie. `kill -0` is a shell builtin, so asking
  # four times a second costs nothing , the old two-second gate bought no speed
  # and just widened the window.
  if [ -n "$OWNER" ]; then
    kill -0 "$OWNER" 2>/dev/null || exit 0
  fi

  # Twice a second is too often to fork ps or date, but every two seconds is
  # cheap, and both answers matter: a pid alone can have been recycled onto
  # something that is not our session at all.
  if [ $(( i % 8 )) -eq 0 ]; then
    [ -n "$OWNER" ] && { nyan_is_claude "$OWNER" || exit 0; }
    [ $(( $(date +%s) - START )) -lt "$LIFE" ] || exit 0
  fi

  nyan_title "$DEV" "${FRAMES[$(( i % NFRAMES ))]} $NAME"

  i=$(( i + 1 ))
  sleep "$DELAY"
done
exit 0
