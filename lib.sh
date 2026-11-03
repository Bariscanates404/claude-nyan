# Shared helpers for the nyan tab signal.
#
# This file exists because the tty walk was copy-pasted into three scripts and
# a parse bug then had to be found in each of them. One home, one fix.

nyan_state() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/claude-nyan"; }

# One field of one process, unambiguously.
#
# Asking ps for several columns at once and splitting on whitespace is what
# produced a tty of "go": a blank or shifted column moves every field after it,
# and the old code trusted field 2 blindly. Single-field queries cannot shift.
_nyan_ps1() { ps -o "$1"= -p "$2" 2>/dev/null | tr -d ' '; }

# The nearest ancestor that owns a terminal. A hook process has none of its own,
# and this is also what keeps tabs independent: writes go to a device path.
#
# The result is checked against the shape of a real tty name, so a bad parse can
# never again be handed on as a device path.
nyan_tty() {
  local p="${1:-$PPID}" t i
  for i in 1 2 3 4 5 6 7 8; do
    [ -n "$p" ] && [ "$p" != "0" ] || return 1
    t="$(_nyan_ps1 tty "$p")"
    case "$t" in
      ttys*|ttyp*|console) echo "$t"; return 0 ;;
    esac
    p="$(_nyan_ps1 ppid "$p")"
  done
  return 1
}

# The claude process this hook belongs to, so a spinner can die with its session.
nyan_claude_pid() {
  local p="${1:-$PPID}" cm i
  for i in 1 2 3 4 5 6 7 8; do
    [ -n "$p" ] && [ "$p" != "0" ] || return 1
    cm="$(ps -o comm= -p "$p" 2>/dev/null)"
    case "${cm##*/}" in claude*) echo "$p"; return 0 ;; esac
    p="$(_nyan_ps1 ppid "$p")"
  done
  return 1
}

# Identity, not just a number.
#
# A pid read back out of a file is a claim about the past: the process it named
# can be long gone and the number recycled onto something unrelated. Every kill
# in this tool is silenced with 2>/dev/null, so acting on that claim alone means
# SIGTERM to a stranger with nothing printed anywhere. Check what the pid IS
# before touching it. The same applies in reverse to the liveness test that
# reaps orphans: a recycled pid looks alive and keeps a dead session's spinner
# turning forever.
nyan_is_spinner() {
  [ -n "${1:-}" ] || return 1
  case "$(ps -o args= -p "$1" 2>/dev/null)" in
    *nyan-spin.sh*) return 0 ;;
  esac
  return 1
}

nyan_is_claude() {
  local cm
  [ -n "${1:-}" ] || return 1
  cm="$(ps -o comm= -p "$1" 2>/dev/null)"
  case "${cm##*/}" in claude*) return 0 ;; esac
  return 1
}

# A per-tty mutex around the spinner's read-kill-write sequence.
#
# Two writers genuinely exist: the Stop hook, and an interactive `nyan name`
# typed while Claude is mid-answer , which the help text invites. Interleave
# their three steps and one daemon's pid gets clobbered out of the file before
# anyone can kill it, so it turns on untracked until its own safety cap.
# mkdir is the atomic primitive; macOS ships no flock.
#
# It must never cost a turn: the wait is capped at about half a second, a lock
# older than NYAN_LOCK_STALE seconds is assumed abandoned and broken, and a lock
# that still will not come is ignored rather than waited on. Losing the race
# costs a stray spinner for a few seconds; blocking costs the user their answer.
NYAN_LOCK_STALE=5

nyan_lock() {
  local dir="$1" i=0 now mt
  while [ "$i" -lt 20 ]; do
    if mkdir "$dir" 2>/dev/null; then
      { printf '%s\n' "$$" > "$dir/owner"; } 2>/dev/null
      return 0
    fi
    now="$(date +%s)"
    mt="$(stat -f %m "$dir" 2>/dev/null)"
    case "$mt" in ''|*[!0-9]*) mt="$now" ;; esac
    if [ $(( now - mt )) -ge "$NYAN_LOCK_STALE" ]; then
      # Moved aside, then deleted , never deleted in place. Two contenders can
      # read the same mtime in the same 50ms window and both rule the lock
      # stale; with a plain rm the slower one then deletes the FRESH lock the
      # faster one has already taken, and both walk away holding "the" mutex.
      # Only one rename can succeed, so the loser's removal hits nothing.
      if mv "$dir" "$dir.stale.$$" 2>/dev/null; then
        rm -rf "$dir.stale.$$" 2>/dev/null
      fi
    else
      sleep 0.05
    fi
    i=$(( i + 1 ))
  done
  return 1
}

# Releases only a lock this process actually holds.
#
# The wait above is capped and may give up, so a caller can reach its cleanup
# path WITHOUT the lock , which is precisely the two-writer case the mutex
# exists for. An unconditional rm there deletes the winner's live lock and lets
# a third process mkdir it immediately, so the one moment the mutex matters is
# the one moment it silently stops existing. Checked here rather than left to
# each caller to remember.
nyan_unlock() {
  local dir="${1:-}" owner
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  owner="$(head -n1 "$dir/owner" 2>/dev/null | tr -d ' ')"
  [ "$owner" = "$$" ] || return 0
  rm -rf "$dir" 2>/dev/null
  return 0
}

# Stops this tty's spinner, and does not return until it is really gone.
#
# kill() only queues the signal; it does not wait. The old code painted the done
# marker immediately after it, so a daemon already past its sleep and mid-frame
# could land its write LAST and leave a finished answer showing a turning
# circle, with nothing scheduled to repaint it. Waiting for the exit is what
# makes the marker the final word.
nyan_stop_spinner() {
  local pidfile="${1:-}" old i=0
  [ -n "$pidfile" ] && [ -f "$pidfile" ] || return 0
  old="$(head -n1 "$pidfile" 2>/dev/null | tr -d ' ')"
  rm -f "$pidfile" 2>/dev/null
  case "$old" in ''|*[!0-9]*) return 0 ;; esac
  nyan_is_spinner "$old" || return 0
  kill "$old" 2>/dev/null || return 0
  while [ "$i" -lt 15 ]; do
    kill -0 "$old" 2>/dev/null || return 0
    sleep 0.02
    i=$(( i + 1 ))
  done
  return 0
}

# Writes a tab title.
#
# OSC 1 is the icon title and it is what Terminal.app paints into the TAB PILL,
# which is the surface that matters when scanning many tabs. OSC 2 is the window
# title; AppleScript's `custom title` reads THAT, which is why probing with
# AppleScript looked like OSC 2 owned everything and OSC 1 did nothing.
#
# OSC 2 carries the name as well, and this was measured the hard way. Clearing
# it does NOT hand the window title back to nothing: Terminal composes that bar
# out of four independent parts and only the second one is ours ,
#
#   you  —  <OSC 2>  —  caffeinate ◂ claude …  —  213×53
#   working dir      ours       "active process name"      dimensions
#
# so an empty OSC 2 just drops our part and leaves the window reading
# "caffeinate ◂ claude", which is the noise the tab names exist to replace.
# The cost is that the hover tooltip now prints the name twice, once from the
# pill and once from here. That is the cheaper of the two.
#
# The other three parts are Terminal profile checkboxes (Settings > Profiles >
# Window > Title), NOT escape sequences: no script can turn "caffeinate" off,
# and AppleScript cannot either , it exposes only the custom title, device
# name, shell path, settings name and window size toggles, never the active
# process one. That switch is the owner's to flick.
#
# Two guards, because a bad device path used to leak a shell error into the
# session: the device is verified first, and the write is wrapped in a group.
# A failing redirection reports on the stderr in effect BEFORE it, so the
# obvious `> "$dev" 2>/dev/null` does NOT suppress it , `{ ...; } 2>/dev/null`
# does, in bash and zsh alike.
nyan_title() {
  local dev="$1" title="$2"
  [ -n "$dev" ] && [ -c "$dev" ] && [ -w "$dev" ] || return 0

  # The title is spliced between an OSC opener and its BEL terminator, so a
  # control byte inside it does not print , it ENDS the sequence and whatever
  # follows is parsed as a fresh command to the terminal. The name is not
  # trusted text: `nyan name` takes whatever was typed or pasted, and the
  # derived name is a basename of a directory, which APFS lets carry raw ESC
  # and BEL bytes. A poisoned folder name would be re-injected four times a
  # second for as long as the answer runs.
  #
  # Stripped here rather than at each caller: this is the only place the bytes
  # become an escape sequence, and it is the one door all three callers use.
  # Done with parameter expansion, not `tr`, because a fork four times a second
  # in every working tab is a real cost and this is none.
  title="${title//[[:cntrl:]]/}"

  { printf '\033]2;%s\007\033]1;%s\007' "$title" "$title" > "$dev"; } 2>/dev/null || true
  return 0
}
