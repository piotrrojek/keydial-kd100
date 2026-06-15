#!/usr/bin/env bash
# Build, wrap in a minimal .app bundle, code-sign (stable Developer ID so the
# Input Monitoring grant survives rebuilds), and (re)install the LaunchAgent.
#
# Why a bundle: macOS TCC "Input Monitoring" (kTCCServiceListenEvent) is
# unreliable for bare Mach-O CLI tools — it attributes/persists grants reliably
# only for .app bundles. So we ship the daemon as kd100.app and run its inner
# executable from launchd.
#
#   scripts/install.sh [capture|run]    # default: capture
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$REPO/.build/release/kd100"
APP="$HOME/Applications/kd100.app"
EXEC="$APP/Contents/MacOS/kd100"
LABEL="dev.otherlandlabs.kd100"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MODE="${1:-capture}"
UID_NUM="$(id -u)"

IDENTITY="${KD100_SIGN_IDENTITY:-Developer ID Application: Otherland Labs sp. z o.o. (RE4JN752MW)}"

echo "==> build"
( cd "$REPO" && swift build -c release )

echo "==> bundle -> $APP"
mkdir -p "$APP/Contents/MacOS"
cp -f "$BUILT" "$EXEC"
cat > "$APP/Contents/Info.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.otherlandlabs.kd100</string>
  <key>CFBundleName</key><string>kd100</string>
  <key>CFBundleDisplayName</key><string>KD100 Daemon</string>
  <key>CFBundleExecutable</key><string>kd100</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST_EOF

echo "==> sign ($IDENTITY)"
codesign --force --sign "$IDENTITY" "$EXEC"
codesign --force --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier' || true

echo "==> write $PLIST (mode=$MODE)"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXEC</string>
    <string>$MODE</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$REPO/kd100.log</string>
  <key>StandardErrorPath</key><string>$REPO/kd100.log</string>
</dict>
</plist>
EOF

echo "==> reload agent"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "==> done. log: $REPO/kd100.log"
