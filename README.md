# battery-alert

Loud low-battery alert for macOS, driven from Claude Code.

macOS shows a small banner around 10% and then shuts down. battery-alert
replaces that with a sound, a spoken message, a modal dialog and signals on
the screen that grow as the shutdown approaches, and tells you when the Mac
is expected to shut down.

## How it works

- A launchd agent runs `battery_check.sh` every 60 seconds.
- Each run reads the charge in mAh and the current in mA from
  `ioreg -rn AppleSmartBattery` and appends a sample to a CSV file.
- The shutdown time is a linear regression of mAh over the last 15 minutes
  of discharge.
- First alert at 15% or 20 minutes left: sound, voice, dialog, thin orange
  border around every screen.
- Critical at 7% or 8 minutes left: the alert repeats at every check, the
  border turns red and pulses, a red tint covers the screen and grows to 12%
  opacity towards shutdown. Clicks go through the tint.
- Last 3 minutes: a full-screen banner with an OK button. It comes back at
  the next check while the Mac is on battery.
- Everything stops when the charger is connected and charging. A charger too
  weak for the load (negative current) counts as discharge: the alert says
  the charger is not enough.
- After a shutdown on battery, the last sample's mAh becomes the zero of the
  forecast.

The screen overlay is a small Swift app, `BatteryAlertBar`, compiled at
install with `swiftc` from the Command Line Tools (`xcode-select --install`).
No third-party software, no administrator rights.

## Install

```bash
claude plugin marketplace add genro/claude_battery_alert
```

```bash
claude plugin install battery-alert@battery-alert
```

Then ask Claude: "install the battery alert".

## Use from Claude

- "install the battery alert" / "remove the battery alert"
- "battery alert status" / "when will the Mac shut down?"
- "set the warning at 20%" / "turn off the voice"
- "test the battery alert"

## Use from the terminal

The commands are in `skills/battery-alert/scripts/manage.sh`:

```
manage.sh install
manage.sh uninstall [--purge]
manage.sh status
manage.sh config [KEY VALUE]
manage.sh test [warn|critical|final]
```

The configuration keys are listed in
[skills/battery-alert/SKILL.md](skills/battery-alert/SKILL.md).

## Files written on your Mac

- `~/Library/LaunchAgents/com.github.genro.battery-alert.plist`
- `~/Library/LaunchAgents/com.github.genro.battery-alert.bar.plist`
- `~/.config/battery-alert/config`
- `~/.local/share/battery-alert/` (installed script, `BatteryAlertBar`, samples, state)
- `~/Library/Logs/battery-alert.log`

`manage.sh uninstall --purge` removes all of them.

## License

Apache-2.0
