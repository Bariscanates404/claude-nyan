#!/bin/bash
# Claude Code status line, nyan edition.
#
#   - the context window is drawn as the cat's rainbow trail, so it reads as a
#     distance rather than a number. Colour is positional, never time-based.
#   - separators each take the next nyan stop, so the line is a rainbow.
#   - the model name drops its parenthetical: "Opus 5 (1M context)" -> "Opus 5".
#   - the project folder and the branch SCROLL when they are too long to fit,
#     which is why refreshInterval has to be 1. Measured at the default 15 a
#     marquee moves twice a minute and just looks frozen.
#
# Cost control, because the bar now runs once a second in every tab:
#   - one jq call, not the nine the old script used
#   - the branch is cached for BRANCH_TTL seconds, so git runs about once every
#     ten refreshes instead of every one

WIN_PROJECT=14     # columns before the project name starts scrolling
WIN_BRANCH=14      # columns before the branch starts scrolling
SCROLL=2           # characters per second
BRANCH_TTL=10      # seconds a cached branch stays good

NOW="$(date +%s)"
STATE="${XDG_DATA_HOME:-$HOME/.local/share}/claude-nyan"
mkdir -p "$STATE" 2>/dev/null || true

payload="$(/bin/cat)"

JQ=/opt/homebrew/bin/jq
[ -x "$JQ" ] || JQ="$(command -v jq 2>/dev/null)"

# Unit separator, not a tab: tab is IFS whitespace and bash would collapse runs
# of it, silently shifting every field after an empty one.
US=$'\x1f'

fields="$(printf '%s' "$payload" | "$JQ" -r '
  [ (.workspace.current_dir // .cwd // "")
  , (.model.display_name // .model.id // "Claude")
  , (.effort.level // "-")
  # floor throws on a non-number and jq then abandons the WHOLE filter, so one
  # mistyped field used to blank every field on the line, not just its own.
  , ((.context_window.used_percentage // 0) | if type == "number" then floor else 0 end)
  , (.cost.total_lines_added // 0)
  , (.cost.total_lines_removed // 0)
  , (.cost.total_cost_usd // 0)
  , ((.rate_limits.five_hour.used_percentage // -1) | if type == "number" then floor else -1 end)
  , ((.rate_limits.seven_day.used_percentage // -1) | if type == "number" then floor else -1 end)
  ] | map(tostring) | join("\u001f")' 2>/dev/null)"

IFS="$US" read -r cwd model effort used added removed cost five_hour seven_day <<< "$fields"

# Subscription usage, for your own scripts that cannot ask Claude Code. One line: "<epoch> <five_hour %> <seven_day %>"; only numbers are written.
case "$five_hour$seven_day" in
  *[!0-9-]*) ;;
  *) [ "$five_hour" -ge 0 ] 2>/dev/null && { printf '%s %s %s\n' "$NOW" "$five_hour" "$seven_day" > "$STATE/rate-limits.$$" \
       && mv -f "$STATE/rate-limits.$$" "$STATE/rate-limits"; } 2>/dev/null ;;
esac

# This line is printed straight to a terminal that is already being handed raw
# 24-bit colour codes below, so a control byte arriving in the payload is not
# inert text , it is another escape sequence. A directory name is the realistic
# carrier: APFS accepts raw ESC and BEL in one, and the project name here is
# just its basename. Stripped once, at the boundary, before anything is built
# out of these. Spelled out rather than looped through eval, which would be
# three lines shorter and would put this file's only eval on the one path that
# handles exactly the untrusted text it is defending against.
cwd="${cwd//[[:cntrl:]]/}"
model="${model//[[:cntrl:]]/}"
effort="${effort//[[:cntrl:]]/}"
added="${added//[[:cntrl:]]/}"
removed="${removed//[[:cntrl:]]/}"

project="${cwd:-.}"; project="${project%/}"; project="${project##*/}"
[ -n "$project" ] || project="."
model="${model%% (*}"

# --- branch, cached -----------------------------------------------------------
# git rev-parse + branch --show-current is the most expensive thing on this
# line. At one refresh a second across several tabs it is worth not repeating.
branch=""
CACHE=""
if [ -n "$cwd" ]; then
  # Doubling the underscores first is what makes the key injective. Replacing
  # slashes alone does not: /a/aa_bb and /a/aa/bb both became branch-_a_aa_bb,
  # so two unrelated repos shared one cache entry and a tab would show the
  # other one's branch for up to BRANCH_TTL seconds. No attacker needed , one
  # underscore in a project name lined up with a sibling path is enough.
  k="${cwd//_/__}"; k="${k//\//_}"
  [ ${#k} -le 200 ] && CACHE="$STATE/branch-$k"
fi

cached=""
if [ -n "$CACHE" ] && [ -f "$CACHE" ]; then
  ts=""; cb=""
  { read -r ts; read -r cb; } < "$CACHE" 2>/dev/null
  case "$ts" in
    ''|*[!0-9]*) ;;
    *) [ $(( NOW - ts )) -lt "$BRANCH_TTL" ] && cached="yes" && branch="$cb" ;;
  esac
fi

if [ -z "$cached" ] && [ -n "$cwd" ]; then
  if /usr/bin/git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch="$(/usr/bin/git -C "$cwd" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] || branch="detached"
  fi
  # Written aside and renamed, because every tab sharing a project writes this
  # same file. A reader can otherwise catch it half-written; a rename cannot be
  # seen partly done.
  if [ -n "$CACHE" ]; then
    if { printf '%s\n%s\n' "$NOW" "$branch" > "$CACHE.$$"; } 2>/dev/null; then
      mv -f "$CACHE.$$" "$CACHE" 2>/dev/null || rm -f "$CACHE.$$" 2>/dev/null
    else
      rm -f "$CACHE.$$" 2>/dev/null
    fi
  fi
fi
[ "$branch" = "-" ] && branch=""
# git refuses control bytes in a refname, but this value can also come back out
# of the cache file, and that is an ordinary file anything could have written.
branch="${branch//[[:cntrl:]]/}"

# --- marquee ------------------------------------------------------------------
# Anything that fits is printed as is. Anything longer scrolls through a fixed
# window, positioned from the wall clock rather than a frame counter, so the
# text keeps moving at a steady rate even when refreshes arrive unevenly.
marquee() {   # $1 = name of the variable to fill, $2 = text, $3 = window
  local s="$2" w="$3" pad="   ·   " full doubled n off
  if [ ${#s} -le "$w" ]; then printf -v "$1" '%s' "$s"; return; fi
  full="$s$pad"
  n=${#full}
  off=$(( (NOW * SCROLL) % n ))
  doubled="$full$full"
  printf -v "$1" '%s' "${doubled:off:w}"
}

# --- colours ------------------------------------------------------------------
# The six original nyan cat trail stops, as 24-bit ANSI.
C0=$'\033[38;2;255;0;0m'      # kirmizi
C1=$'\033[38;2;255;153;0m'    # turuncu
C2=$'\033[38;2;255;255;0m'    # sari
C3=$'\033[38;2;51;255;0m'     # yesil
C4=$'\033[38;2;0;153;255m'    # mavi
C5=$'\033[38;2;102;51;255m'   # mor
RS=$'\033[0m'
DIM=$'\033[38;2;90;95;115m'
COLS=("$C0" "$C1" "$C2" "$C3" "$C4" "$C5")

# --- context window as the cat's trail ----------------------------------------
CELLS=14
case "$used" in ''|*[!0-9]*) used=0 ;; esac
# The bar was already clamped; the number beside it was not, so a bad payload
# drew a full trail next to "99999%".
[ "$used" -gt 100 ] && used=100
filled=$(( (used * CELLS + 50) / 100 ))
[ "$filled" -lt 0 ] && filled=0
[ "$filled" -gt "$CELLS" ] && filled="$CELLS"

trail=""
i=0
while [ "$i" -lt "$CELLS" ]; do
  if [ "$i" -lt "$filled" ]; then
    trail="${trail}${COLS[$((i % 6))]}█"
  else
    trail="${trail}${DIM}·"
  fi
  i=$((i + 1))
done
trail="${trail}${RS}"

# --- the line -----------------------------------------------------------------
fieldlist=()
marquee proj_s "$project" "$WIN_PROJECT"
fieldlist+=("📁 $proj_s")
if [ -n "$branch" ]; then marquee br_s "$branch" "$WIN_BRANCH"; fieldlist+=("🌿 $br_s"); fi
fieldlist+=("🤖 ${model}")
fieldlist+=("🎚 ${effort}")
fieldlist+=("🧠 ${trail} 🐱 ${used}%")
fieldlist+=("📝 +${added}/-${removed}")
printf -v cost_s '%.2f' "${cost:-0}" 2>/dev/null || cost_s="0.00"
fieldlist+=("💰 \$${cost_s}")

lim=""
case "$five_hour" in ''|-1|*[!0-9]*) ;; *) [ "$five_hour" -gt 100 ] && five_hour=100; lim="5h ${five_hour}%" ;; esac
case "$seven_day" in ''|-1|*[!0-9]*) ;; *) [ "$seven_day" -gt 100 ] && seven_day=100; lim="${lim:+$lim · }7d ${seven_day}%" ;; esac
[ -n "$lim" ] && fieldlist+=("🔋 ${lim}")

# Each separator takes the next stop, so the line reads as a rainbow left to
# right. One character cannot hold six colours; this is what can.
line=""
n=0
for f in "${fieldlist[@]}"; do
  if [ "$n" -gt 0 ]; then
    line="${line}${COLS[$(( (n - 1) % 6 ))]} │ ${RS}"
  fi
  line="${line}${f}"
  n=$((n + 1))
done

printf '%s\n' "$line"
