# keydial-kd100

Turn a **Huion Keydial Mini (KD100)** — 18 keys + a rotary knob with center press —
into a macOS **shortcut pad** that runs any shell command, **without installing
Huion's driver**. A small menu-bar app opens the device over IOKit, **seizes** it
(so the factory keystrokes never leak into focused apps), reads every control
including the **knob**, and runs the command you bound to it.

It ships with [AeroSpace](https://github.com/nikitabobko/AeroSpace) window-manager
bindings as the **default example**, but each binding is just a shell command run
through your **login shell** (`$SHELL -ilc`, so it sees the same `PATH`/tools a
Terminal does) — rebind any key to `open -a …`, `osascript`, a `uv`/mise-managed
script, anything — from the Settings window. A failing command's exit code and
stderr surface in the menu instead of vanishing.

## Why this exists

- The 18 buttons emit standard HID keyboard/consumer keycodes (Karabiner can see those).
- The **knob emits nothing on any standard HID page** — it reports only on a
  vendor-defined interface (`UsagePage 0xFF00`) that needs raw IOKit access to read.

So mapping the knob *and* suppressing the factory keystrokes both require seizing the
raw device — which is exactly what this app does. No Karabiner, no Huion software.

## Install

### Homebrew

```bash
brew install piotrrojek/tap/keydial-kd100
open "$(brew --prefix)/opt/keydial-kd100/kd100.app"
```

### From source

```bash
git clone https://github.com/piotrrojek/keydial-kd100
cd keydial-kd100
./scripts/install.sh        # build, sign, install to ~/Applications, and launch
```

After it launches, look for the **dial icon in the menu bar**. There's no dock icon —
it's a menu-bar (accessory) app.

### Two one-time manual steps (any install method)

1. **Input Monitoring.** macOS requires it to read the device. After first launch,
   enable **kd100** in *System Settings → Privacy & Security → Input Monitoring*, then
   **Quit** from the menu and relaunch (or rerun `./scripts/install.sh`). The menu
   shows `⚠ Input Monitoring not granted` until this is done, with a shortcut to the
   settings pane.
2. **Karabiner-Elements (if installed).** Its grabber seizes all keyboards/pointers by
   default, which collides with us (`kIOReturnExclusiveAccess`). Set the KD100
   (vendor `0x256c` / product `0x6d`) to **"ignore"** in Karabiner's *Devices* tab.
   The menu shows `⚠ Device busy (Karabiner?)` in this case.

## Use

The menu bar icon's menu shows:

- **Live status** — `● Keypad connected` / `○ Waiting for keypad…` / a permission or
  busy warning, plus the last control you pressed and the command it ran (or
  `→ failed (code)` with the error if it didn't).
- **Settings…** (⌘,) — a window with:
  - a **visual device map** of the pad (rows 4/4/4/4/2 + knob) — click a key to jump to
    its command field;
  - a **Listen** toggle — flip it on and press a key on the pad to locate it in the list
    (commands are paused while listening, so you won't trigger anything);
  - one editable field per physical key + knob action, each with a **▶ test** button that
    runs the current command immediately and reports the result;
  - **Save** applies everything live (no restart); blank = disabled key; **Reset to
    Defaults** restores the AeroSpace example set.
- **Open at Login** — register/unregister as a login item (macOS 13+).
- **Quit KD100**.

Bindings are stored in `~/.config/kd100/mapping.json` (created on first run), keyed by
**human key names** → shell command. You can edit it by hand too — the app watches the
file and **picks up hand edits live** (no relaunch):

```jsonc
"bindings": {
  "1": "aerospace workspace 1",
  "knob-cw":  "aerospace resize smart +50",
  "knob-press": "open -a 'Mission Control'",
  "minus": "osascript -e 'display notification \"hi\"'"
}
```

Key names (physical layout, rows 4/4/4/4/2 — column 4 is the split-`+`):

```
numlock  slash    star     minus
7        8        9        plus-upper
4        5        6        plus-lower
1        2        3        enter
0        dot
knob-cw   knob-ccw   knob-press
```

## How it works

- **Swift + IOKit `IOHIDManager`.** One binary, three entry points:
  - `kd100` (no args) — the **menu-bar app**: status, Settings editor, Open at Login,
    Quit. Runs the engine in seize mode in-process, so Settings edits apply live.
  - `kd100 run` — headless: seize + dispatch with no UI (for a LaunchAgent / debugging).
  - `kd100 capture` — observe-only; logs decoded values + raw HID reports (used to
    reverse-engineer a device).
- **Two mapping layers:** a fixed in-code `layout` table translates raw HID ids
  (`kb:MM:KK` keyboard / `cc:UU` consumer / `dial:*` knob) → human names; the JSON
  maps those names → commands. The cryptic ids never reach the config file.
- **HID protocol:** buttons = report id 3 (keyboard) + id 1 (consumer); knob = vendor
  report id 17 — `byte2` is a signed delta (`+1` CW / `0xff` CCW), press = `byte1`
  bit `0x01`. Decoding + press edge-detection live in a pure `ReportDecoder`
  (`Decode.swift`) with no IOKit dependency, so they're unit-tested without hardware.
- **Execution:** commands run via `$SHELL -ilc` on a background queue; a
  `terminationHandler` captures exit status + stderr (filtering the harmless
  interactive-zsh `zle` warnings) without blocking, so failures surface and a
  backgrounded command can't pin a thread.
- **Live config:** a `DispatchSource` file watcher (`FileWatcher.swift`, re-arms across
  atomic-write inode swaps) reloads `mapping.json` when it changes on disk.
- **Packaging:** ships as a signed, notarized `kd100.app` with `LSUIElement` so it
  runs as a menu-bar accessory; the Input Monitoring grant attaches to the stable code
  signature.

## Layout

- `Sources/kd100/main.swift` — entry / arg parsing (`app` | `run` | `capture`).
- `Sources/kd100/KD100.swift` — IOKit HID open/seize, callbacks, connection-health hooks.
- `Sources/kd100/Decode.swift` — pure `ReportDecoder` (HID report → control id + press
  edge-detection); no IOKit, fully unit-tested.
- `Sources/kd100/Mapping.swift` — layout table, config load/save + live file watch,
  login-shell command dispatch with exit/stderr capture.
- `Sources/kd100/FileWatcher.swift` — `DispatchSource` config-file watcher.
- `Sources/kd100/AppDelegate.swift` — menu-bar status item, menu, engine wiring.
- `Sources/kd100/SettingsWindow.swift` — the editor window: device map, Listen mode,
  per-key test-fire.
- `Sources/kd100/StatusIcon.swift` — the menu-bar dial icon.
- `Tests/kd100Tests/` — decoder, config round-trip, shell-execution, and Settings-build
  tests (`swift test`).
- `scripts/install.sh` — build + sign + install the app (or a headless agent for
  `run`/`capture`).
- `release.sh` + `.github/workflows/release.yml` — tag `v*` → universal build, sign,
  notarize, package `.pkg` + `.tar.gz`, GitHub release.
- `packaging/keydial-kd100.rb` — Homebrew formula template.

## Troubleshooting

- **Pad silent / nothing reacting?** Check the **side power button** — it's a power
  toggle, not a wake button; when off, the LED is dark and there's no device to read.
  The app re-grabs automatically on reconnect (`○ Waiting…` → `● Connected`).
- **`kIOReturnExclusiveAccess` (`0xE00002C5`)** → another process holds the device
  (Karabiner etc.). Menu shows `⚠ Device busy`.
- **`kIOReturnNotPermitted` (`0xE00002E2`)** → Input Monitoring not granted yet. Menu
  shows `⚠ Input Monitoring not granted`.

## License

MIT — see [LICENSE](LICENSE).
