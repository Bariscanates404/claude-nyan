#!/bin/bash
# Wires the nyan signal into Claude Code's user settings.
#
# All changes are idempotent , re-running replaces rather than duplicates:
#   1. statusLine points at the new bar
#   2. CLAUDE_CODE_DISABLE_TERMINAL_TITLE, so Claude Code stops writing the
#      title. Without it Claude Code overwrites a name set with `nyan` the
#      moment it starts working. Verified in the binary: the guard is a plain
#      truthy check, `return vt() || a.CLAUDE_CODE_DISABLE_TERMINAL_TITLE`.
#   3. SessionStart names the tab straight away. Needed BECAUSE of 2: with
#      Claude Code silenced, a tab nothing has written to yet falls back to the
#      raw process line, "caffeinate < claude --permission-m...".
#   4. UserPromptSubmit turns the rainbow
#   5. Stop writes the done marker
#   6. SessionEnd takes the marker back off
#   7. ~/.local/bin/nyan links to the tab naming command
#
# Every nyan hook goes into its own matcher-less group, which runs for every
# matcher. Appending into somebody else's group inherits their matcher.
#
# The original file is backed up first, and the result is parsed before it
# replaces anything. A broken settings file is never written.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOME_DIR="$HOME/.local/share/claude-nyan"

# `|| true` is not decoration. Under `set -e` a command substitution that is the
# last component of an `A || B` list is NOT exempt, so a missing jq made this
# script exit right here with no output at all , the one failure of the four it
# checks for that said nothing.
JQ=/opt/homebrew/bin/jq
[ -x "$JQ" ] || JQ="$(command -v jq || true)"
[ -n "$JQ" ] && [ -x "$JQ" ] || { echo "install: jq not found, install it first (brew install jq)" >&2; exit 1; }

[ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
"$JQ" -e . "$SETTINGS" >/dev/null || { echo "install: settings.json is not valid JSON, leaving it alone" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$SETTINGS.bak-nyan-$STAMP"
cp "$SETTINGS" "$BACKUP"
echo "install: backup -> $BACKUP"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

"$JQ" \
  --arg sl "bash $HOME_DIR/statusline.sh" \
  --arg mw "bash $HOME_DIR/mark-done.sh work" \
  --arg md "bash $HOME_DIR/mark-done.sh done" \
  --arg mc "bash $HOME_DIR/mark-done.sh clear" '
  # Drop every hook this installer has ever added, then drop any group left
  # holding nothing, so re-running never stacks duplicates.
  def strip_nyan:
      [ .[]? | .hooks = [ .hooks[]? | select(((.command // "") | test("claude-nyan")) | not) ] ]
    | [ .[]? | select((.hooks | length) > 0) ];
  # refreshInterval is in SECONDS , measured, not guessed: three idle tabs each
  # refreshed exactly 3 times across 45s at the default of 15. The scrolling
  # project and branch names need 1, or they move twice a minute and read as
  # frozen. The bar was cut from 74ms to 30ms a refresh to pay for it.
  .statusLine = { type: "command", command: $sl, refreshInterval: 1 }
  | .env = ((.env // {}) + { CLAUDE_CODE_DISABLE_TERMINAL_TITLE: "1" })
  | .hooks = (.hooks // {})

  | .hooks.SessionStart = ((.hooks.SessionStart // []) | strip_nyan)
      + [{ hooks: [{ type: "command", command: $mc, timeout: 10 }] }]

  # Its own matcher-less group, exactly like SessionStart and SessionEnd here.
  # Appending into group [0] assumed that group carried no matcher; if anything
  # else had already claimed the slot with one, the nyan hook quietly inherited
  # it and then fired for only some prompts, which looks exactly like the hook
  # being broken. (No apostrophes in this block: it lives inside the single
  # quotes that carry the whole jq program.)
  | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | strip_nyan)
      + [{ hooks: [{ type: "command", command: $mw, timeout: 10 }] }]

  | .hooks.Stop = ((.hooks.Stop // []) | strip_nyan)
      + [{ hooks: [{ type: "command", command: $md, timeout: 10 }] }]

  | .hooks.SessionEnd = ((.hooks.SessionEnd // []) | strip_nyan)
      + [{ hooks: [{ type: "command", command: $mc, timeout: 10 }] }]
' "$SETTINGS" > "$TMP"

"$JQ" -e . "$TMP" >/dev/null || { echo "install: the result is broken, nothing changed" >&2; exit 1; }

cat "$TMP" > "$SETTINGS"
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME_DIR/nyan" "$HOME/.local/bin/nyan"
echo "install: done"
echo

show() { printf '  %-17s: %s\n' "$1" "$("$JQ" -r "$2" "$SETTINGS")"; }
show "statusLine"       '.statusLine.command'
show "title disabled" '.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE // "MISSING"'
show "SessionStart"     '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(test("claude-nyan"))) | .[0] // "MISSING"'
show "UserPromptSubmit" '[.hooks.UserPromptSubmit[]?.hooks[]?.command] | map(select(test("claude-nyan"))) | .[0] // "MISSING"'
show "Stop"             '[.hooks.Stop[]?.hooks[]?.command] | map(select(test("claude-nyan"))) | .[0] // "MISSING"'
show "SessionEnd"       '[.hooks.SessionEnd[]?.hooks[]?.command] | map(select(test("claude-nyan"))) | .[0] // "MISSING"'
echo
echo "  other hooks kept: $("$JQ" -r '[.hooks | to_entries[] | .value[]? | .hooks[]? | .command] | map(select(test("claude-nyan") | not)) | length' "$SETTINGS")"
echo
echo "To undo:  cp \"$BACKUP\" \"$SETTINGS\""
