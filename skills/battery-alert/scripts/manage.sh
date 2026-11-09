#!/bin/bash
# Installs, configures and removes the battery-alert launchd agents:
#   com.github.genro.battery-alert       battery_check.sh every CHECK_INTERVAL seconds
#   com.github.genro.battery-alert.bar   BatteryAlertBar screen overlay, always running
#
# Usage:
#   manage.sh install
#   manage.sh uninstall [--purge]
#   manage.sh status
#   manage.sh config [KEY VALUE]
#   manage.sh test [warn|critical|final]

set -eu

LABEL=com.github.genro.battery-alert
BAR_LABEL=$LABEL.bar
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/battery-alert"
CONFIG_FILE="$CONFIG_DIR/config"
DATA_DIR="$HOME/.local/share/battery-alert"
INSTALLED_SCRIPT="$DATA_DIR/battery_check.sh"
BAR_BIN="$DATA_DIR/BatteryAlertBar"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
BAR_PLIST="$AGENTS_DIR/$BAR_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/battery-alert.log"
DOMAIN="gui/$(id -u)"

KEYS="CHECK_INTERVAL WARN_PERCENT CRITICAL_PERCENT WARN_MINUTES CRITICAL_MINUTES FINAL_PERCENT FINAL_MINUTES WINDOW_MINUTES TREND_MINUTES RETENTION_DAYS VOICE SOUND SOUND_FILE RAISE_VOLUME ALERT_VOLUME SCREEN_BORDER SCREEN_TINT TINT_MIN TINT_MAX FINAL_BANNER BORDER_WIDTH LANGUAGE"

write_default_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<'EOF'
# battery-alert configuration. Change values with: manage.sh config KEY VALUE
CHECK_INTERVAL=60          # seconds between two checks
WARN_PERCENT=15            # first alert at this charge
CRITICAL_PERCENT=7         # repeated alert at this charge
WARN_MINUTES=20            # first alert when the forecast drops to this
CRITICAL_MINUTES=8         # repeated alert when the forecast drops to this
FINAL_PERCENT=3            # full-screen banner at this charge
FINAL_MINUTES=3            # full-screen banner when the forecast drops to this
WINDOW_MINUTES=15          # discharge samples used by the regression
TREND_MINUTES=5            # on charger, falling mAh over these minutes count as discharge
RETENTION_DAYS=7           # samples kept in samples.csv
VOICE=1                    # 1 = spoken minutes left
SOUND=1                    # 1 = play SOUND_FILE
SOUND_FILE=/System/Library/Sounds/Sosumi.aiff
RAISE_VOLUME=1             # 1 = raise the volume to ALERT_VOLUME during the alert, then restore it
ALERT_VOLUME=80            # 0-100
SCREEN_BORDER=1            # 1 = orange border on warn, pulsing red border on critical
SCREEN_TINT=1              # 1 = red tint on critical, growing towards shutdown
TINT_MIN=4                 # tint opacity in % at the critical threshold
TINT_MAX=12                # tint opacity in % at shutdown
FINAL_BANNER=1             # 1 = full-screen banner in the last minutes
BORDER_WIDTH=12            # critical border width in points
LANGUAGE=it                # it | en
EOF
}

config_value() {
    (. "$CONFIG_FILE"; eval "echo \"\${$1:-}\"")
}

plist_header() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$1</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
EOF
}

write_plist() {
    mkdir -p "$AGENTS_DIR"
    {
        plist_header "$LABEL"
        cat <<EOF
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_SCRIPT</string>
    </array>
    <key>StartInterval</key>
    <integer>$(config_value CHECK_INTERVAL)</integer>
</dict>
</plist>
EOF
    } > "$PLIST"
}

write_bar_plist() {
    {
        plist_header "$BAR_LABEL"
        cat <<EOF
    <key>ProgramArguments</key>
    <array>
        <string>$BAR_BIN</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF
    } > "$BAR_PLIST"
}

is_loaded() {
    launchctl print "$DOMAIN/$1" > /dev/null 2>&1
}

load() {
    is_loaded "$1" && launchctl bootout "$DOMAIN/$1"
    launchctl bootstrap "$DOMAIN" "$2"
}

unload() {
    is_loaded "$1" && launchctl bootout "$DOMAIN/$1"
    return 0
}

cmd_install() {
    [ -f "$CONFIG_FILE" ] || write_default_config
    mkdir -p "$DATA_DIR"
    # Copied out of the plugin folder: plugin updates change that path.
    cp "$SCRIPT_DIR/battery_check.sh" "$INSTALLED_SCRIPT"
    chmod +x "$INSTALLED_SCRIPT"
    write_plist
    load "$LABEL" "$PLIST"
    echo "installed: $PLIST"
    if command -v swiftc > /dev/null; then
        echo "compiling BatteryAlertBar..."
        unload "$BAR_LABEL"
        swiftc -O -o "$BAR_BIN" "$SCRIPT_DIR/BatteryAlertBar.swift"
        write_bar_plist
        load "$BAR_LABEL" "$BAR_PLIST"
        echo "installed: $BAR_PLIST"
    else
        echo "swiftc not found: no screen overlay, only sound and voice." >&2
        echo "Install the Command Line Tools with: xcode-select --install, then run install again." >&2
    fi
    echo "config:    $CONFIG_FILE"
    echo "samples:   $DATA_DIR/samples.csv"
    echo "log:       $LOG_FILE"
}

cmd_uninstall() {
    unload "$LABEL"
    unload "$BAR_LABEL"
    rm -f "$PLIST" "$BAR_PLIST" "$INSTALLED_SCRIPT" "$BAR_BIN" "$DATA_DIR/state" "$DATA_DIR/status"
    echo "removed: $PLIST, $BAR_PLIST, $INSTALLED_SCRIPT, $BAR_BIN"
    if [ "${1:-}" = --purge ]; then
        rm -rf "$CONFIG_DIR" "$DATA_DIR"
        rm -f "$LOG_FILE"
        echo "removed: $CONFIG_DIR, $DATA_DIR, $LOG_FILE"
    else
        echo "kept: $CONFIG_FILE and the samples in $DATA_DIR (use --purge to remove them)"
    fi
}

cmd_status() {
    if is_loaded "$LABEL"; then echo "check agent: loaded"; else echo "check agent: not loaded"; fi
    if is_loaded "$BAR_LABEL"; then echo "screen overlay: loaded"; else echo "screen overlay: not loaded"; fi
    [ -f "$CONFIG_FILE" ] || { echo "config: missing (run install)"; return; }
    echo "thresholds: warn $(config_value WARN_PERCENT)% or $(config_value WARN_MINUTES) min," \
         "critical $(config_value CRITICAL_PERCENT)% or $(config_value CRITICAL_MINUTES) min," \
         "check every $(config_value CHECK_INTERVAL) s"
    /bin/bash "$SCRIPT_DIR/battery_check.sh" --status
}

cmd_config() {
    [ -f "$CONFIG_FILE" ] || write_default_config
    if [ $# -eq 0 ]; then
        grep -v '^#' "$CONFIG_FILE"
        return
    fi
    [ $# -eq 2 ] || { echo "usage: manage.sh config KEY VALUE" >&2; exit 2; }
    local key=$1 value=$2
    case " $KEYS " in
        *" $key "*) ;;
        *) echo "unknown key: $key (valid: $KEYS)" >&2; exit 2 ;;
    esac
    # A config written by an older version lacks the newer keys.
    if grep -q "^$key=" "$CONFIG_FILE"; then
        sed -i '' -E "s|^$key=[^ ]*|$key=$value|" "$CONFIG_FILE"
    else
        echo "$key=$value" >> "$CONFIG_FILE"
    fi
    echo "$key=$(config_value "$key")"
    # The interval lives in the plist; every other key is read at each check.
    if [ "$key" = CHECK_INTERVAL ] && [ -f "$PLIST" ]; then
        write_plist
        load "$LABEL" "$PLIST"
        echo "agent reloaded"
    fi
}

# Shows the overlay for 20 s with sample values, then plays the alert.
cmd_test() {
    [ -f "$CONFIG_FILE" ] || write_default_config
    local level=${1:-warn}
    if [ -x "$BAR_BIN" ]; then
        case "$level" in
            warn) "$BAR_BIN" --demo warn 18 14 & ;;
            critical) "$BAR_BIN" --demo critical 6 6 & ;;
            final) "$BAR_BIN" --demo critical 2 3 & ;;
            *) echo "usage: manage.sh test [warn|critical|final]" >&2; exit 2 ;;
        esac
    fi
    [ "$level" = final ] && level=critical
    /bin/bash "$SCRIPT_DIR/battery_check.sh" --test "$level"
    wait
}

case "${1:-}" in
    install) cmd_install ;;
    uninstall) shift; cmd_uninstall "$@" ;;
    status) cmd_status ;;
    config) shift; cmd_config "$@" ;;
    test) shift; cmd_test "$@" ;;
    *) echo "usage: manage.sh install | uninstall [--purge] | status | config [KEY VALUE] | test [warn|critical|final]" >&2; exit 2 ;;
esac
