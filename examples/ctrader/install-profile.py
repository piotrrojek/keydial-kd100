#!/usr/bin/env python3
"""Install/refresh the KD100 'cTrader' profile in ~/.config/kd100/mapping.json.

Wires the keypad (while cTrader is frontmost) to the keypad-kd100-ctrader plugin's
local HTTP API via the ctrader.sh thin client. Idempotent: re-running replaces the
cTrader profile and leaves the default profile untouched. The running kd100 tray
app hot-reloads the file.

Safety posture of the default layout: BUY/SELL use a small 0.01 lot and CLOSE-LAST /
BREAKEVEN are bound, but FLAT (close-all) is deliberately NOT on a key — it's a
single-press fat-finger risk. The endpoint exists; bind it yourself if you want it.
"""
import json
import os
import sys

CONFIG = os.path.expanduser(os.environ.get("KD100_CONFIG", "~/.config/kd100/mapping.json"))
SCRIPTS = "$HOME/.config/kd100/scripts"          # where install.sh puts the helpers
BUNDLE_ID = "com.spotware.ctmac"                 # cTrader for Mac
PROFILE_NAME = "cTrader"

# Physical KD100 key order (must match Mapping.order in the Swift app).
ORDER = [
    "numlock", "slash", "star", "minus",
    "7", "8", "9", "plus-upper",
    "4", "5", "6", "plus-lower",
    "1", "2", "3", "enter",
    "0", "dot",
    "knob-cw", "knob-ccw", "knob-press",
]

def ct(method, path):
    return f'"{SCRIPTS}/ctrader.sh" {method} {path}'

# The cTrader layout. Anything omitted here is written as "" (disabled in cTrader —
# it will NOT fall through to the AeroSpace default, which would be confusing).
LAYOUT = {
    # Row 1 — timeframes
    "numlock": ct("POST", "chart/tf/M1"),
    "slash":   ct("POST", "chart/tf/M5"),
    "star":    ct("POST", "chart/tf/M15"),
    "minus":   ct("POST", "chart/tf/H1"),
    # Row 2
    "7":          ct("POST", "chart/tf/H4"),
    "8":          ct("POST", "chart/symbol/XAUUSD"),
    "9":          ct("POST", "chart/scroll/now"),
    "plus-upper": ct("POST", "chart/zoom/in"),
    # Row 3 — trading
    "4":          ct("POST", "order/buy/0.01"),
    "5":          ct("POST", "order/sell/0.01"),
    "6":          ct("POST", "position/breakeven"),
    "plus-lower": ct("POST", "chart/zoom/out"),
    # Row 4
    "1":     ct("POST", "position/close-last"),
    "2":     "",   # spare
    "3":     "",   # spare
    "enter": "",   # spare
    # Row 5
    "0":   "",     # spare
    "dot": f'python3 "{SCRIPTS}/ctrader-pl.py"',   # P&L glance (moved off knob-press)
    # Knob — chart navigation. The PRESS is reserved app-wide to cycle profiles
    # (handled by the kd100 app itself), so any value here is ignored.
    "knob-ccw":   ct("POST", "chart/scroll/back"),
    "knob-cw":    ct("POST", "chart/scroll/fwd"),
    "knob-press": "",
}


def main():
    if not os.path.exists(CONFIG):
        sys.exit(f"no config at {CONFIG} — launch the kd100 app once to create it")

    with open(CONFIG) as f:
        data = json.load(f)

    note = data.get("_note", "")

    # Normalise to the profiles format (migrate a legacy flat {bindings:{...}} file).
    if "profiles" in data and isinstance(data["profiles"], list):
        profiles = data["profiles"]
    elif "bindings" in data:
        profiles = [{"name": "default", "bindings": data["bindings"]}]
    else:
        profiles = [{"name": "default", "bindings": {}}]

    # Drop any existing cTrader profile (by name or by match) so this is idempotent.
    profiles = [p for p in profiles
                if p.get("name") != PROFILE_NAME and p.get("match") != BUNDLE_ID]

    bindings = {k: LAYOUT.get(k, "") for k in ORDER}
    profiles.append({"name": PROFILE_NAME, "match": BUNDLE_ID, "bindings": bindings})

    out = {"_note": note, "profiles": profiles}
    with open(CONFIG, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")

    bound = sum(1 for k in ORDER if LAYOUT.get(k))
    print(f"wrote {PROFILE_NAME} profile (match {BUNDLE_ID}, {bound}/{len(ORDER)} controls bound) to {CONFIG}")
    print("the running kd100 app will hot-reload it; focus cTrader and the profile activates.")


if __name__ == "__main__":
    main()
