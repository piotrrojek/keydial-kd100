#!/usr/bin/env python3
"""KD100 P&L glance — query the keypad-kd100-ctrader plugin's /state endpoint and
pop a macOS notification. Stdlib only; bind a KD100 key to:

    python3 ~/.config/kd100/scripts/ctrader-pl.py

No disk-file reads — it talks to the plugin's live HTTP API.
"""
import json
import os
import subprocess
import urllib.request

BASE = os.environ.get("KD100_CTRADER_URL", "http://127.0.0.1:9100")
TOKFILE = os.environ.get("KD100_CTRADER_TOKEN", os.path.expanduser("~/cAlgo/LocalStorage/keypad-kd100/token"))


def notify(msg: str) -> None:
    # json.dumps gives a properly-escaped, double-quoted AppleScript string literal.
    subprocess.run(
        ["osascript", "-e", f"display notification {json.dumps(msg)} with title \"cTrader P&L\""],
        check=False,
    )


def main() -> None:
    try:
        token = open(TOKFILE).read().strip()
    except OSError:
        token = ""
    req = urllib.request.Request(f"{BASE}/state", headers={"X-KD100-Token": token})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            d = json.load(r)
    except Exception:
        notify("plugin not reachable — is cTrader + the keypad plugin running?")
        return

    # ASCII only: osascript's AppleScript can't parse the \uXXXX escapes json.dumps
    # emits for non-ASCII (·, arrows) — it errors with -2741 "unknown token". Plain
    # ASCII keeps the notification robust across this machine's locale, too.
    parts = [f"{d.get('unrealized', 0):+.2f} {d.get('currency', '')}", f"eq {d.get('equity', 0):.0f}"]
    ml = d.get("margin_level")
    if ml:
        parts.append(f"margin {ml:.0f}%")
    for s in d.get("symbols", []):
        parts.append(f"{s['symbol']} {s['side']} {s['lots']:g}@{s['avg_entry']:.2f} {s['pl']:+.0f}")
    notify(" | ".join(parts))


if __name__ == "__main__":
    main()
