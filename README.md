# aerospace-kd100

Turn a **Huion Keydial Mini (KD100)** — 18 keys + a rotary knob with center press —
into an [AeroSpace](https://github.com/nikitabobko/AeroSpace) controller on macOS,
**without installing Huion's driver**. A tiny userspace daemon opens the device over
IOKit, **seizes** it (so the factory keystrokes never leak into focused apps), reads
every control including the **knob**, and runs `aerospace` commands you configure.

## Why this exists

- The 18 buttons emit standard HID keyboard/consumer keycodes (Karabiner can see those).
- The **knob emits nothing on any standard HID page** — it reports only on a
  vendor-defined interface (`UsagePage 0xFF00`) that needs raw IOKit access to read.

So mapping the knob *and* suppressing the factory keystrokes both require seizing the
raw device — which is exactly what this daemon does. No Karabiner, no Huion software.

## Install

### Homebrew

```bash
brew install piotrrojek/tap/aerospace-kd100
brew services start aerospace-kd100
```

Then complete the two one-time grants below.

### From source

```bash
git clone https://github.com/piotrrojek/aerospace-kd100
cd aerospace-kd100
./scripts/install.sh run      # build, sign, install + start the LaunchAgent
```

### Two one-time manual steps (any install method)

1. **Input Monitoring.** macOS requires it to read the device. After first start,
   enable **kd100** in *System Settings → Privacy & Security → Input Monitoring*, then
   restart the daemon (`launchctl kickstart -k gui/$(id -u)/dev.otherlandlabs.kd100`,
   or `brew services restart aerospace-kd100`).
2. **Karabiner-Elements (if installed).** Its grabber seizes all keyboards/pointers by
   default, which collides with us (`kIOReturnExclusiveAccess`). Set the KD100
   (vendor `0x256c` / product `0x6d`) to **"ignore"** in Karabiner's *Devices* tab.

## Configure

Bindings live in `~/.config/kd100/mapping.json` (created on first run), keyed by
**human key names** → shell command:

```jsonc
"bindings": {
  "1": "aerospace workspace 1",
  "knob-cw":  "aerospace resize smart +50",
  "knob-press": "aerospace balance-sizes",
  "minus": "aerospace move-node-to-monitor --wrap-around next --focus-follows-window"
}
```

Valid key names (physical layout, rows 4/4/4/4/2 — column 4 is the split-`+`):

```
numlock  slash    star     minus
7        8        9        plus-upper
4        5        6        plus-lower
1        2        3        enter
0        dot
knob-cw   knob-ccw   knob-press
```

Each value is a raw shell line, so it isn't limited to `aerospace` — `open -a …`,
`osascript`, scripts, anything. After editing, reload:

```bash
launchctl kickstart -k gui/$(id -u)/dev.otherlandlabs.kd100
```

## How it works

- **Swift + IOKit `IOHIDManager`.** One binary, two modes:
  - `kd100 capture` — observe-only; logs decoded values + raw HID reports (used to
    reverse-engineer a device).
  - `kd100 run` — opens with `kIOHIDOptionsTypeSeizeDevice`, reads raw reports,
    dispatches each control to its shell command.
- **Two mapping layers:** a fixed in-code `layout` table translates raw HID ids
  (`kb:MM:KK` keyboard / `cc:UU` consumer / `dial:*` knob) → human names; the JSON
  maps those names → commands. The cryptic ids never reach the config file.
- **HID protocol:** buttons = report id 3 (keyboard) + id 1 (consumer); knob = vendor
  report id 17 — `byte2` is a signed delta (`+1` CW / `0xff` CCW), press = `byte1`
  bit `0x01`.
- **Packaging:** ships as a signed, notarized `kd100.app` launched by a LaunchAgent,
  so the Input Monitoring grant attaches to a stable code signature.

## Layout

- `Sources/kd100/main.swift` — entry / arg parsing (`capture` | `run`).
- `Sources/kd100/KD100.swift` — IOKit HID open/seize, callbacks, edge-detected dispatch.
- `Sources/kd100/Mapping.swift` — layout table, config load, command dispatch.
- `scripts/install.sh` — build + sign + (re)install the LaunchAgent locally.
- `release.sh` + `.github/workflows/release.yml` — tag `v*` → universal build, sign,
  notarize, package `.pkg` + `.tar.gz`, GitHub release.
- `packaging/aerospace-kd100.rb` — Homebrew formula template.

## Troubleshooting

- **Pad silent / AeroSpace not reacting?** Check the **side power button** — it's a
  power toggle, not a wake button; when off, the LED is dark and there's no device to
  read. The daemon re-grabs automatically on reconnect.
- **`kIOReturnExclusiveAccess` (`0xE00002C5`)** in the log → another process holds the
  device (Karabiner etc.).
- **`kIOReturnNotPermitted` (`0xE00002E2`)** → Input Monitoring not granted yet.

## License

MIT — see [LICENSE](LICENSE).
