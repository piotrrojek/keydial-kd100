#!/usr/bin/env bash
# Thin client for the keypad-kd100-ctrader cTrader plugin's local HTTP API.
# The KD100's cTrader profile binds keys to `ctrader.sh <METHOD> <path>`.
#
#   ctrader.sh POST chart/tf/M5
#   ctrader.sh POST order/buy/0.01
#   ctrader.sh GET  state
#
# The plugin (running inside cTrader) writes its auth token to
#   ~/cAlgo/LocalStorage/keypad-kd100/token
# on first start; we read it from there. Localhost only.
set -euo pipefail

BASE="${KD100_CTRADER_URL:-http://127.0.0.1:9100}"
TOKFILE="${KD100_CTRADER_TOKEN:-$HOME/cAlgo/LocalStorage/keypad-kd100/token}"

method="${1:-GET}"
path="${2:-state}"
tok="$(cat "$TOKFILE" 2>/dev/null || true)"

curl -fsS --max-time 5 -X "$method" -H "X-KD100-Token: $tok" "$BASE/$path"
