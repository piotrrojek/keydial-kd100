#!/usr/bin/env bash
# Build, wrap in a minimal .app bundle, code-sign (stable Developer ID so the
# Input Monitoring grant survives rebuilds), and install.
#
# Why a bundle: macOS TCC "Input Monitoring" (kTCCServiceListenEvent) is
# unreliable for bare Mach-O CLI tools — it attributes/persists grants reliably
# only for .app bundles. So we ship kd100 as kd100.app.
#
# Modes:
#   scripts/install.sh            install the menu-bar (tray) app and launch it.
#                                 This is the normal install. "Open at Login" is
#                                 a toggle inside the app's menu.
#   scripts/install.sh run        install a headless LaunchAgent (seize+dispatch,
#                                 no UI) — for debugging or a server-style setup.
#   scripts/install.sh capture    install a headless LaunchAgent in capture mode
#                                 (observe-only HID logging) — for debugging.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$REPO/.build/release/kd100"
APP="$HOME/Applications/kd100.app"
EXEC="$APP/Contents/MacOS/kd100"
LABEL="dev.otherlandlabs.kd100"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MODE="${1:-app}"
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
  <key>CFBundleDisplayName</key><string>KD100</string>
  <key>CFBundleExecutable</key><string>kd100</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST_EOF

echo "==> sign ($IDENTITY)"
codesign --force --sign "$IDENTITY" "$EXEC"
codesign --force --sign "$IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier' || true

# Always tear down any previously-installed headless agent first so it can't
# fight the freshly-installed instance for the device (kIOReturnExclusiveAccess).
echo "==> stop any existing LaunchAgent"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true

if [ "$MODE" = "app" ]; then
  rm -f "$PLIST"   # the tray app is launched directly / via Open-at-Login, not launchd
  echo "==> launch tray app"
  # Quit a running instance, then relaunch the rebuilt bundle.
  osascript -e 'tell application "kd100" to quit' 2>/dev/null || true
  pkill -x kd100 2>/dev/null || true
  open "$APP"
  cat <<EOF

==> done. kd100 is now in your menu bar (look for the dial icon).

   First run needs Input Monitoring:
     System Settings > Privacy & Security > Input Monitoring > enable "kd100",
     then relaunch from the menu (Quit) and reopen, or rerun this script.

   Map keys via the menu: kd100 (menu bar) > Settings…
   Run at boot:           kd100 (menu bar) > Open at Login
EOF
  exit 0
fi

# Headless debug modes: run | capture
echo "==> write $PLIST (headless mode=$MODE)"
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
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "==> done (headless $MODE). log: $REPO/kd100.log"
