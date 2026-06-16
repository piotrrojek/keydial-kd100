#!/usr/bin/env bash
# keydial-kd100 controller pill for sketchybar (https://github.com/FelixKratz/SketchyBar).
#
# Shows ONLY while the KD100 keypad is connected: the kd100 tray app writes
# ~/.config/kd100/status.json on every health/profile change, and this script
# gates on the live process (pgrep) so a stale file never keeps the pill up after
# the app quits. The bar shows a dial glyph + the active profile name (tinted when
# it's a non-default profile). Click drops a cheat-sheet popup of the *current
# profile's* bindings — read live from ~/.config/kd100/mapping.json in physical-key
# order — a crutch until muscle memory sets in.
#
# Wire it up in your sketchybarrc (see README.md in this directory):
#   sketchybar --add item kd100 right --set kd100 script="…/kd100.sh" …
#   --subscribe kd100 front_app_switched system_woke mouse.clicked mouse.exited.global
#
# Events (same dynamic-popup toggle idiom as sketchybar's stock popup examples):
#   mouse.clicked        -> toggle the cheat-sheet popup
#   mouse.exited.global  -> dismiss the popup
#   <routine/forced/…>   -> refresh: show+label when connected, else hide
#
# Palette: sources your own colors.sh if present, else falls back to Catppuccin
# Frappe defaults so the example works standalone.
source "$HOME/.config/sketchybar/colors.sh" 2>/dev/null || true
: "${BASE:=0xff303446}"; : "${SURFACE0:=0xff414559}"; : "${SURFACE1:=0xff51576d}"
: "${TEXT:=0xffc6d0f5}"; : "${MAUVE:=0xffca9ee6}"; : "${PEACH:=0xffef9f76}"
: "${LAVENDER:=0xffbabbf1}"; : "${F12:=12.0}"

STATUS="$HOME/.config/kd100/status.json"
MAPPING="$HOME/.config/kd100/mapping.json"
DIAL=$(printf '\xef\x86\x92')   # nf-fa-dot_circle_o (U+F192) — reads as a knob/dial
ROW_FONT="JetBrainsMono Nerd Font:Semibold:$F12"
# Literal prefixes to strip from a binding so the cheat-sheet shows the *action*
# (e.g. "ctrader.sh POST chart/tf/M1") rather than a path that truncates away the
# meaningful tail. Quoted in the patterns below so $HOME stays literal text.
SCRIPTS_LIT='$HOME/.config/kd100/scripts/'
SCRIPTS_TILDE='~/.config/kd100/scripts/'

# Physical layout order (rows 4/4/4/4/2 + knob), so the cheat-sheet maps to the pad.
LAYOUT="numlock slash star minus 7 8 9 plus-upper 4 5 6 plus-lower 1 2 3 enter 0 dot knob-ccw knob-cw knob-press"

# --- liveness + state -------------------------------------------------------
# Sets $profile on success. Returns non-zero (=> hide) when the app isn't running
# or the keypad isn't connected.
profile="default"
read_state() {
  pgrep -x kd100 >/dev/null 2>&1 || return 1
  [ -f "$STATUS" ] || return 1
  local health
  health=$(jq -r '.health // ""' "$STATUS" 2>/dev/null)
  [ "$health" = "connected" ] || return 1
  profile=$(jq -r '.profile // "default"' "$STATUS" 2>/dev/null)
  return 0
}

popup_is_open() { [ "$(sketchybar --query "$NAME" | jq -r '.popup.drawing')" = "on" ]; }

clear_popup() {  # tear down rows (drawing=off BEFORE --remove)
  sketchybar --query "$NAME" | jq -r '.popup.items[]?' | while read -r it; do
    [ -n "$it" ] && sketchybar --set "$it" drawing=off --remove "$it"
  done
  sketchybar --set "$NAME" popup.drawing=off
}

# Resolve the active profile's *effective* bindings (profile overrides default;
# an absent key falls through to default; a key set to "" is disabled-here) and
# print one "keyname<TAB>command" line per LAYOUT key. Mirrors Mapping.activeBinding.
effective_rows() {
  local def prof eff
  def=$(jq -c '(.profiles[]? | select(.name=="default") | .bindings) // {}' "$MAPPING" 2>/dev/null)
  prof=$(jq -c --arg p "$profile" '(.profiles[]? | select(.name==$p) | .bindings) // {}' "$MAPPING" 2>/dev/null)
  [ -z "$def" ] && def='{}'
  [ -z "$prof" ] && prof='{}'
  eff=$(jq -cn --argjson d "$def" --argjson p "$prof" '$d + $p' 2>/dev/null)
  local key cmd
  for key in $LAYOUT; do
    cmd=$(printf '%s' "$eff" | jq -r --arg k "$key" '.[$k] // ""' 2>/dev/null)
    printf '%s\t%s\n' "$key" "$cmd"
  done
}

build_popup() {
  # Header: which profile this sheet is for.
  sketchybar --add item "$NAME.row.h" popup."$NAME" \
    --set "$NAME.row.h" icon.drawing=off background.drawing=off \
      label="kd100 · $profile" label.color="$MAUVE" label.font="$ROW_FONT" \
      label.padding_left=14 label.padding_right=18

  local i=0 key cmd disp col row
  while IFS=$'\t' read -r key cmd; do
    if [ "$key" = "knob-press" ]; then
      disp="cycle profile (reserved)"; col=$PEACH
    else
      [ -z "$cmd" ] && continue                 # skip unbound / disabled keys
      disp=$cmd
      disp=${disp//\"/}                          # drop quotes
      disp=${disp//"$SCRIPTS_LIT"/}              # drop the kd100 scripts-dir prefix...
      disp=${disp//"$SCRIPTS_TILDE"/}            # ...in either $HOME or ~ form
      disp=${disp/#$HOME/\~}                     # collapse an expanded $HOME -> ~
      [ ${#disp} -gt 52 ] && disp="${disp:0:51}…"
      col=$TEXT
    fi
    row=$(printf '%-11s  %s' "$key" "$disp")     # mono font => columns align
    sketchybar --add item "$NAME.row.$i" popup."$NAME" \
      --set "$NAME.row.$i" icon.drawing=off background.drawing=off \
        label="$row" label.color="$col" label.font="$ROW_FONT" \
        label.padding_left=14 label.padding_right=18
    i=$((i + 1))
  done < <(effective_rows)

  sketchybar --set "$NAME" popup.drawing=on
}

paint() {
  if read_state; then
    local col=$LAVENDER
    [ "$profile" != "default" ] && col=$PEACH
    sketchybar --set "$NAME" drawing=on icon="$DIAL" icon.color="$col" \
      label="$profile" label.color="$col"
  else
    popup_is_open && clear_popup
    sketchybar --set "$NAME" drawing=off
  fi
}

case "$SENDER" in
  mouse.clicked)
    read_state || exit 0                         # ignore clicks while hidden
    if popup_is_open; then clear_popup; else build_popup; fi ;;
  mouse.exited.global)
    popup_is_open && clear_popup ;;
  *)
    paint ;;
esac
