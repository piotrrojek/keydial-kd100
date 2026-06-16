# sketchybar status pill

A [sketchybar](https://github.com/FelixKratz/SketchyBar) pill for kd100 — useful when
you hide the native macOS menu bar and so lose the tray app's connection dot + active-profile
indicator.

**What it does**

- Appears **only while the keypad is connected** (gated on both `pgrep -x kd100` and
  `status.json.health == "connected"`, so it self-hides the moment the device disconnects or
  the app quits).
- Shows a dial glyph + the **active profile name**, tinted when a non-default profile is active.
- **Click → cheat-sheet popup** of the active profile's effective bindings (profile overrides +
  fall-through to `default`), laid out in the physical 4/4/4/4/2 + knob order — a crutch until
  the muscle memory sets in.

It reads the app's `~/.config/kd100/status.json` (see the main README's *Status file* section)
and `~/.config/kd100/mapping.json`. No app configuration needed — the status file is written
automatically.

## Install

1. Copy the plugin into your sketchybar plugins dir (or point `script=` straight at it):

   ```bash
   cp examples/sketchybar/kd100.sh ~/.config/sketchybar/plugins/kd100.sh
   chmod +x ~/.config/sketchybar/plugins/kd100.sh
   ```

   It sources your `~/.config/sketchybar/colors.sh` for the palette if present, and otherwise
   falls back to Catppuccin Frappe defaults, so it works standalone.

2. Register the item in your `sketchybarrc` (right side shown; `updates=on` keeps it polling
   while hidden so it re-appears within ~2 s of the keypad connecting):

   ```bash
   DIAL=$(printf '\xef\x86\x92')   # nf-fa-dot_circle_o (U+F192)
   sketchybar --add item kd100 right \
     --set kd100 icon="$DIAL" drawing=off update_freq=2 updates=on \
       label.font="JetBrainsMono Nerd Font:Semibold:12.0" \
       popup.align=right popup.y_offset=4 \
       script="$HOME/.config/sketchybar/plugins/kd100.sh" \
     --subscribe kd100 front_app_switched system_woke mouse.clicked mouse.exited.global
   ```

3. `sketchybar --reload`.

Requires `jq` and a Nerd Font (for the dial glyph), both of which a typical sketchybar setup
already has.
