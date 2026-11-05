#!/bin/bash
# Battery check, run every CHECK_INTERVAL seconds by launchd.
# Appends one sample to samples.csv, forecasts the shutdown time by linear
# regression on the recent discharge samples, and raises a loud alert
# (sound, voice, modal dialog) when the charge or the forecast crosses a threshold.
#
# Usage:
#   battery_check.sh            one check (what launchd runs)
#   battery_check.sh --status   print reading and forecast, no sample, no alert
#   battery_check.sh --test warn|critical   fire the alert now
#
# Environment (tests only):
#   BATTERY_ALERT_CONFIG  config file path
#   BATTERY_ALERT_DATA    data directory
#   BATTERY_ALERT_FAKE    "mah full amp pct ac" instead of reading ioreg
#   BATTERY_ALERT_NOW     epoch seconds instead of the clock
#   BATTERY_ALERT_DRY=1   print the alert instead of playing it

set -u

CONFIG_FILE="${BATTERY_ALERT_CONFIG:-$HOME/.config/battery-alert/config}"
DATA_DIR="${BATTERY_ALERT_DATA:-$HOME/.local/share/battery-alert}"
SAMPLES="$DATA_DIR/samples.csv"
STATE_FILE="$DATA_DIR/state"
STATUS_FILE="$DATA_DIR/status"
FLOOR_FILE="$DATA_DIR/shutdown_floor"

WARN_PERCENT=15
CRITICAL_PERCENT=7
WARN_MINUTES=20
CRITICAL_MINUTES=8
WINDOW_MINUTES=15
RETENTION_DAYS=7
VOICE=1
SOUND=1
SOUND_FILE=/System/Library/Sounds/Sosumi.aiff
DRAIN_MA=-50
RAISE_VOLUME=1
ALERT_VOLUME=80
LANGUAGE=it
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

mkdir -p "$DATA_DIR"
touch "$SAMPLES"
NOW="${BATTERY_ALERT_NOW:-$(date +%s)}"

# Sets MAH FULL AMP PCT AC DRAIN. ioreg prints a negative current as an
# unsigned 64-bit integer; bash arithmetic wraps it back to the signed value.
# DRAIN is 1 on battery, and also on a charger too weak to cover the load
# (current below DRAIN_MA).
read_battery() {
    local raw
    if [ -n "${BATTERY_ALERT_FAKE:-}" ]; then
        raw="$BATTERY_ALERT_FAKE"
    else
        raw=$(ioreg -rn AppleSmartBattery | awk '
            /"BatteryData" = / {
                if (match($0, /"RemainingCapacity"=[0-9]+/)) mah = substr($0, RSTART + 20, RLENGTH - 20)
                if (match($0, /"FullChargeCapacity"=[0-9]+/)) full = substr($0, RSTART + 21, RLENGTH - 21)
            }
            /"InstantAmperage" = / { amp = $NF }
            /"CurrentCapacity" = / { pct = $NF }
            /"ExternalConnected" = / { ac = ($NF == "Yes") ? 1 : 0 }
            END { print mah, full, amp, pct, ac }')
    fi
    read -r MAH FULL AMP PCT AC <<< "$raw"
    if [ -z "${AC:-}" ]; then
        echo "battery_check: cannot read the battery from ioreg" >&2
        exit 1
    fi
    AMP=$((AMP))
    if [ "$AC" = 0 ] || [ "$AMP" -lt "$DRAIN_MA" ]; then DRAIN=1; else DRAIN=0; fi
}

# A reboot after the last sample, with that sample on battery and low,
# means the Mac ran out of charge: its mAh becomes the shutdown floor.
learn_floor() {
    [ -n "${BATTERY_ALERT_FAKE:-}" ] && return
    [ -s "$SAMPLES" ] || return
    local boot last_ts last_mah last_pct last_ac last_drain
    boot=$(sysctl -n kern.boottime | awk -F'[ ,]+' '{ print $4 }')
    IFS=, read -r last_ts last_mah _ _ last_pct last_ac last_drain <<< "$(tail -n 1 "$SAMPLES")"
    # Samples written before 0.1.1 have no drain column.
    [ -z "$last_drain" ] && last_drain=$((1 - last_ac))
    if [ "$last_ts" -lt "$boot" ] && [ "$last_drain" = 1 ] && [ "$last_pct" -le "$CRITICAL_PERCENT" ]; then
        echo "$last_mah" > "$FLOOR_FILE"
        echo "$(date -r "$NOW" '+%F %T') shutdown floor learned: $last_mah mAh"
    fi
}

floor() {
    if [ -s "$FLOOR_FILE" ]; then cat "$FLOOR_FILE"; else echo 0; fi
}

# Prints minutes left until the floor, or nothing when no forecast is possible.
# Regression uses the discharge samples of the last WINDOW_MINUTES that come
# after the last sample not draining; with fewer than 3 samples spanning
# 2 minutes it falls back to remaining charge / instant current.
forecast_minutes() {
    local fl
    fl=$(floor)
    awk -F, -v now="$NOW" -v win="$((WINDOW_MINUTES * 60))" \
        -v mah="$MAH" -v amp="$AMP" -v drain="$DRAIN" -v fl="$fl" '
        $1 >= now - win {
            sample_drain = ($7 == "") ? ($6 == 0) : $7
            if (sample_drain == 0) { n = 0; sx = sy = sxx = sxy = 0; t0 = ""; next }
            if (t0 == "") t0 = $1
            x = $1 - t0; n++; sx += x; sy += $2; sxx += x * x; sxy += x * $2; last = x
        }
        END {
            if (drain == 0) exit
            if (n >= 3 && last >= 120) {
                slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
                if (slope < 0) { printf "%d\n", (mah - fl) / -slope / 60; exit }
            }
            if (amp < 0) printf "%d\n", (mah - fl) / -amp * 60
        }' "$SAMPLES" 2>/dev/null
}

message() {
    local level=$1 minutes=$2 at action
    if [ "$LANGUAGE" = it ]; then
        if [ "$AC" = 1 ]; then action="L'alimentatore non basta, la batteria si scarica."; else action="Collega l'alimentatore."; fi
    else
        if [ "$AC" = 1 ]; then action="The charger is too weak, the battery is draining."; else action="Plug in the charger."; fi
    fi
    if [ -n "$minutes" ]; then
        at=$(date -r "$((NOW + minutes * 60))" '+%H:%M')
        if [ "$LANGUAGE" = it ]; then
            echo "Batteria: $PCT per cento. Spegnimento previsto alle $at, tra $minutes minuti. $action"
        else
            echo "Battery at $PCT percent. Shutdown expected at $at, in $minutes minutes. $action"
        fi
    elif [ "$LANGUAGE" = it ]; then
        echo "Batteria: $PCT per cento. $action"
    else
        echo "Battery at $PCT percent. $action"
    fi
}

alert() {
    local level=$1 text=$2 title old_volume old_muted repeats=1
    if [ "$LANGUAGE" = it ]; then title="Batteria scarica"; else title="Battery low"; fi
    [ "$level" = critical ] && repeats=3
    if [ "${BATTERY_ALERT_DRY:-0}" = 1 ]; then
        echo "ALERT $level: $text"
        return
    fi
    local raised=0
    if [ "$RAISE_VOLUME" = 1 ]; then
        old_volume=$(osascript -e 'output volume of (get volume settings)')
        old_muted=$(osascript -e 'output muted of (get volume settings)')
        # Only raise: a volume already above ALERT_VOLUME is left as it is.
        if [ "$old_muted" = true ] || [ "$old_volume" -lt "$ALERT_VOLUME" ]; then
            osascript -e "set volume output volume $ALERT_VOLUME without output muted"
            raised=1
        fi
    fi
    if [ "$SOUND" = 1 ]; then
        for _ in $(seq "$repeats"); do afplay "$SOUND_FILE"; done
    fi
    [ "$VOICE" = 1 ] && say "$text"
    if [ "$raised" = 1 ]; then
        if [ "$old_muted" = true ]; then
            osascript -e "set volume output volume $old_volume with output muted"
        else
            osascript -e "set volume output volume $old_volume"
        fi
    fi
    osascript -e "display alert \"$title\" message \"$text\" as critical giving up after 45" > /dev/null
}

level_for() {
    local minutes=$1
    if [ "$PCT" -le "$CRITICAL_PERCENT" ] || { [ -n "$minutes" ] && [ "$minutes" -le "$CRITICAL_MINUTES" ]; }; then
        echo critical
    elif [ "$PCT" -le "$WARN_PERCENT" ] || { [ -n "$minutes" ] && [ "$minutes" -le "$WARN_MINUTES" ]; }; then
        echo warn
    else
        echo none
    fi
}

trim_samples() {
    local first cutoff
    [ -s "$SAMPLES" ] || return
    first=$(head -n 1 "$SAMPLES" | cut -d, -f1)
    cutoff=$((NOW - RETENTION_DAYS * 86400))
    [ "$first" -ge "$((cutoff - 86400))" ] && return
    awk -F, -v c="$cutoff" '$1 >= c' "$SAMPLES" > "$SAMPLES.tmp" && mv "$SAMPLES.tmp" "$SAMPLES"
}

case "${1:-}" in
    --status)
        read_battery
        minutes=$(forecast_minutes)
        echo "charge: $PCT% ($MAH / $FULL mAh), current: $AMP mA, charger: $([ "$AC" = 1 ] && echo yes || echo no), draining: $([ "$DRAIN" = 1 ] && echo yes || echo no)"
        echo "shutdown floor: $(floor) mAh"
        if [ -n "$minutes" ]; then
            echo "forecast: $minutes minutes, shutdown at $(date -r "$((NOW + minutes * 60))" '+%H:%M')"
        else
            echo "forecast: none (not draining or not enough samples)"
        fi
        echo "level now: $(level_for "$minutes")"
        ;;
    --test)
        read_battery
        [ "$DRAIN" = 0 ] && PCT=$WARN_PERCENT
        alert "${2:-warn}" "$(message "${2:-warn}" "$(forecast_minutes)")"
        ;;
    "")
        read_battery
        learn_floor
        echo "$NOW,$MAH,$FULL,$AMP,$PCT,$AC,$DRAIN" >> "$SAMPLES"
        trim_samples
        minutes=$(forecast_minutes)
        level=$(level_for "$minutes")
        [ "$DRAIN" = 0 ] && level=none
        previous=$(cat "$STATE_FILE" 2>/dev/null || echo none)
        echo "$level" > "$STATE_FILE"
        # Read by BatteryAlertBar: epoch level minutes(-1 = none) percent draining charger.
        echo "$NOW $level ${minutes:--1} $PCT $DRAIN $AC" > "$STATUS_FILE"
        if [ "$level" = critical ] || { [ "$level" = warn ] && [ "$previous" = none ]; }; then
            alert "$level" "$(message "$level" "$minutes")"
        fi
        ;;
    *)
        echo "usage: battery_check.sh [--status | --test warn|critical]" >&2
        exit 2
        ;;
esac
