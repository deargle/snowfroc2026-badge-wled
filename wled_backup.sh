#!/usr/bin/env bash
# Save and restore WLED state and hardware config.
#
# Usage:
#   wled_backup.sh save   [state_file] [cfg_file]   -- save state + hardware config
#   wled_backup.sh restore [state_file] [cfg_file]  -- restore state + hardware config
#
# Defaults: wled_state.json, wled_cfg.json

set -euo pipefail

HOST="${WLED_HOST:-4.3.2.1}"
DEFAULT_STATE="wled_state.json"
DEFAULT_CFG="wled_cfg.json"

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
    exit 1
}

[[ $# -lt 1 ]] && usage

CMD="$1"
STATE_FILE="${2:-$DEFAULT_STATE}"
CFG_FILE="${3:-$DEFAULT_CFG}"

case "$CMD" in
    save)
        curl -sf "http://$HOST/json/state" -o "$STATE_FILE"
        echo "Saved state to $STATE_FILE"
        curl -sf "http://$HOST/json/cfg" -o "$CFG_FILE"
        echo "Saved hardware config to $CFG_FILE"
        ;;
    restore)
        [[ -f "$CFG_FILE" ]] || { echo "File not found: $CFG_FILE"; exit 1; }
        [[ -f "$STATE_FILE" ]] || { echo "File not found: $STATE_FILE"; exit 1; }
        # Post cfg with boot preset set to 1 (numbered presets persist more
        # reliably than the sv:true boot-slot approach).
        curl -sf -X POST "http://$HOST/json/cfg" \
            -H 'Content-Type: application/json' \
            -d @"$CFG_FILE" | grep -q '"success":true'
        echo "Restored hardware config from $CFG_FILE"
        # cfg changes can trigger a reboot — wait for WLED to come back before
        # posting state, otherwise the state write is lost.
        echo "Waiting for WLED to come back up..."
        until curl -sf "http://$HOST/json/info" >/dev/null 2>&1; do sleep 1; done
        # Apply the desired state to RAM.
        curl -sf -X POST "http://$HOST/json/state" \
            -H 'Content-Type: application/json' \
            -d @"$STATE_FILE" | grep -q '"success":true'
        # Save current RAM state as preset 1 (the boot preset set above).
        curl -sf -X POST "http://$HOST/json/state" \
            -H 'Content-Type: application/json' \
            -d '{"psave":1,"n":"Startup"}' | grep -q '"success":true'
        echo "Restored state from $STATE_FILE (saved as boot preset 1)"
        ;;
    *)
        usage
        ;;
esac
