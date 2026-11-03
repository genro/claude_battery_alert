---
name: battery-alert
description: Loud low-battery alert for macOS — a launchd agent samples the battery every minute in mAh, forecasts the shutdown time by linear regression, and alerts with sound, voice, a modal dialog and a screen overlay (border, red tint, final full-screen banner) before the Mac dies. Use to install, remove, configure, test or check the battery alert, or to ask when the Mac will shut down — "installa l'avviso batteria", "metti la soglia al 20%", "prova l'avviso", "quando si spegne il mac", "togli l'avviso batteria", "battery alert status".
---

# battery-alert

The alert runs outside Claude, as two launchd agents: `battery_check.sh`
every minute for sound, voice and dialog, and `BatteryAlertBar` (compiled
with `swiftc` at install) for the screen overlay. This skill only drives
`scripts/manage.sh` (path relative to this skill's base directory). Run it
with `/bin/bash`. Report its output to the user as it is.

## Commands

| User request | Command |
|---|---|
| install the alert | `manage.sh install` |
| remove the alert | `manage.sh uninstall` (add `--purge` only if the user asks to delete config and samples too) |
| state, thresholds, forecast, "when will it shut down" | `manage.sh status` |
| show the configuration | `manage.sh config` |
| change a setting | `manage.sh config KEY VALUE` |
| see and hear the alert now | `manage.sh test warn`, `manage.sh test critical` or `manage.sh test final` |

`test` shows the screen overlay for 20 seconds, then plays the alert.
`test critical` and `test final` play the sound three times and speak.
Tell the user before running them.

## Configuration keys

| Key | Default | Meaning |
|---|---|---|
| `CHECK_INTERVAL` | 60 | seconds between checks (reloads the agent) |
| `WARN_PERCENT` | 15 | first alert at this charge |
| `CRITICAL_PERCENT` | 7 | alert repeated at every check at this charge |
| `WARN_MINUTES` | 20 | first alert when the forecast reaches this |
| `CRITICAL_MINUTES` | 8 | repeated alert when the forecast reaches this |
| `FINAL_PERCENT` | 3 | full-screen banner at this charge |
| `FINAL_MINUTES` | 3 | full-screen banner when the forecast reaches this |
| `WINDOW_MINUTES` | 15 | discharge history used by the regression |
| `RETENTION_DAYS` | 7 | samples kept |
| `VOICE` | 1 | spoken message |
| `SOUND` | 1 | play `SOUND_FILE` |
| `SOUND_FILE` | `/System/Library/Sounds/Sosumi.aiff` | any file in `/System/Library/Sounds/` |
| `RAISE_VOLUME` | 1 | raise the volume during the alert, then restore it |
| `ALERT_VOLUME` | 80 | 0-100; a higher volume is not lowered |
| `SCREEN_BORDER` | 1 | orange border on warn, pulsing red border on critical |
| `SCREEN_TINT` | 1 | red tint on critical, growing from `TINT_MIN` to `TINT_MAX` towards shutdown |
| `TINT_MIN` | 4 | tint opacity in % at the critical threshold |
| `TINT_MAX` | 12 | tint opacity in % at shutdown |
| `FINAL_BANNER` | 1 | full-screen banner with an OK button in the last minutes |
| `BORDER_WIDTH` | 12 | critical border width in points |
| `LANGUAGE` | `it` | `it` or `en` |

Values contain no spaces.

## How the forecast works

- Each check appends `epoch,mAh,full mAh,mA,percent,charger` to
  `~/.local/share/battery-alert/samples.csv`.
- The forecast is a linear regression of mAh over time on the discharge
  samples of the last `WINDOW_MINUTES`, after the last sample on charger.
- With fewer than 3 samples spanning 2 minutes it uses remaining mAh divided by
  the instant current.
- When the Mac reboots after a low sample on battery, that sample's mAh is saved
  in `shutdown_floor` and used as zero from then on.

## Files

- Agents: `~/Library/LaunchAgents/com.github.genro.battery-alert.plist` and `com.github.genro.battery-alert.bar.plist`
- Config: `~/.config/battery-alert/config`
- Data: `~/.local/share/battery-alert/`
- Log: `~/Library/Logs/battery-alert.log`
