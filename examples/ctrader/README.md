# KD100 → cTrader integration

Drive **cTrader for Mac** from the Huion KD100 keypad — change timeframe/symbol,
scroll/zoom the chart, place/close/modify trades, and glance at live P&L — through a
proper cTrader Automate **Plugin**, not synthetic keystrokes or disk-file scraping.

## How it works

```
 KD100 device ──HID──> kd100 tray app ──curl(localhost:9100)──> cTrader Plugin
                       (profile: cTrader,                       (keypad-kd100-ctrader,
                        match com.spotware.ctmac)                FullAccess, HTTP API)
                                                                        │
                                                          cTrader Automate API
                                                       (orders, charts, account)
```

- The **kd100 tray app** owns the HID device. You cycle to its **cTrader profile**
  with the **knob press** (the active profile shows next to the menu-bar icon); the
  profile binds each control to a `curl` against the plugin. (Profiles are switched
  manually by the knob — there is no automatic frontmost-app switching.)
- The **plugin** (`keypad-kd100-ctrader.plugin.cs`) runs inside cTrader with
  `AccessRights.FullAccess` and serves a token-authenticated **local HTTP API** on
  `127.0.0.1:9100`. It executes the action via the Automate API and returns JSON.

No Accessibility permission (no keystrokes). No JSON-on-disk (the `/state` endpoint
is the live replacement for the `OtherlandSketchybarExporter` file — same JSON shape,
so sketchybar can be re-pointed at it later).

## Files

| File | Where it goes | What it is |
|---|---|---|
| `keypad-kd100-ctrader.plugin.cs` | `~/cAlgo/Sources/Plugins/keypad-kd100-ctrader/…` (canonical copy here) | the cTrader Plugin |
| `ctrader.sh` | `~/.config/kd100/scripts/` | thin HTTP client (`ctrader.sh POST chart/tf/M5`) |
| `ctrader-pl.py` | `~/.config/kd100/scripts/` | P&L-glance → macOS notification |
| `install-profile.py` | run once | injects the `cTrader` profile into `~/.config/kd100/mapping.json` |

## Setup

1. **Build + run the plugin** (one-time, in the cTrader UI — cTrader compiles it):
   cTrader → **Automate** → open the `keypad-kd100-ctrader` Plugin → **Build** → add
   the Plugin and **Start** it. On start it logs the listen URL and writes its auth
   token to `~/cAlgo/LocalStorage/keypad-kd100/token`. Leave it running.
2. **Install the KD100 side** (already done by the assistant, idempotent to re-run):
   ```bash
   cp examples/ctrader/ctrader.sh examples/ctrader/ctrader-pl.py ~/.config/kd100/scripts/
   chmod +x ~/.config/kd100/scripts/ctrader.sh ~/.config/kd100/scripts/ctrader-pl.py
   python3 examples/ctrader/install-profile.py
   ```
3. **Test:** **press the knob** to cycle to the `cTrader` profile (its name appears
   next to the menu-bar dial icon), then press a timeframe key or `dot` (P&L glance).
   Press the knob again to cycle back to `default`.

## HTTP API

All `POST` unless noted. Every endpoint except `/ping` needs `X-KD100-Token: <token>`.

| Endpoint | Action |
|---|---|
| `GET /ping` | liveness (no auth) |
| `GET /state` | account + positions + quotes JSON |
| `/chart/tf/{M1,M5,M15,M30,H1,H4,D1}` | change active chart timeframe |
| `/chart/symbol/{NAME}` | change active chart symbol |
| `/chart/zoom/{in,out}` | zoom ±5 (clamped 5–500) |
| `/chart/scroll/{back,fwd,now}` | scroll the chart |
| `/order/buy[/{lots}]` `?symbol=&slPips=&tpPips=` | market buy (default 0.01 lot, XAUUSD) |
| `/order/sell[/{lots}]` | market sell |
| `/position/flat[/{SYMBOL}]` | close all (optionally one symbol) |
| `/position/close-last[/{SYMBOL}]` | close the newest position |
| `/position/breakeven[/{SYMBOL}]` | move every position's SL to its entry |

## Default profile layout

```
 tf M1     tf M5     tf M15    tf H1
 tf H4     sym XAU   scroll→now zoom +
 BUY 0.01  SELL 0.01 breakeven  zoom −
 close-last  —        —         —
 —         P&L
 knob:  ccw = scroll back · cw = scroll fwd · press = CYCLE PROFILE (reserved)
```

The **knob press is reserved app-wide to cycle profiles** (so it can't be bound per
profile); the P&L glance lives on `dot`. Rebind anything else in the kd100 Settings
window (select the **cTrader** profile).

## Safety

- The plugin **binds to loopback only** and requires the token header — a web page
  can't set that header cross-origin (no CORS preflight is answered), so local CSRF
  is blocked.
- `MaxLot` hard cap + one-order-per-call; `TradingEnabled=false` makes it read-only.
- **FLAT (close-all) is intentionally NOT on a key** in the default profile — it's a
  single-press fat-finger risk. The endpoint exists; bind it yourself if you want it.
- Live order entry on a keypad is inherently risky. The ARM-gated, risk-revalidated
  Open-API design (`ctrader-bridge`) in the vault's AeroPad spec remains the
  longer-term home for serious order management; this plugin is the pragmatic
  in-cTrader version.
