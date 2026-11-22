#!/bin/zsh
# kyro-build-lock.sh — Shared host-wide Xcode build lock
# Ensures only one heavy xcodebuild operation runs at a time.
# Safe, non-destructive, with PID liveliness + start-time verification,
# atomic directory acquisition, and race-free stale lock recovery.

set -e

LOCK_DIR="/tmp/kyro_xcodebuild.lock.d"
META_FILE="$LOCK_DIR/metadata.json"
TIMEOUT_SECS=${KYRO_BUILD_LOCK_TIMEOUT:-600}
POLL_INTERVAL=5

# Fetch start time of a PID to prevent false liveliness on PID reuse
get_pid_lstart() {
    local target_pid="$1"
    ps -p "$target_pid" -o lstart= 2>/dev/null || echo ""
}

cleanup() {
    if [ -d "$LOCK_DIR" ]; then
        local lock_pid=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('pid', 0))" 2>/dev/null || echo "0")
        if [ "$lock_pid" -eq "$$" ]; then
            rm -rf "$LOCK_DIR"
            echo "[kyro-build-lock] Released lock for PID $$."
        fi
    fi
}

trap cleanup EXIT INT TERM HUP

acquire_lock() {
    local start_time=$(date +%s)
    local caller_desc="${1:-Xcode Build}"
    local my_lstart=$(get_pid_lstart "$$")

    echo "[kyro-build-lock] Requesting lock for: $caller_desc (PID $$)..."

    while true; do
        # 1. Detect external independently running Xcode operations on the host
        local external_xcode_pids=$(pgrep -f "xcodebuild" | grep -v "$$" || true)
        if [ -n "$external_xcode_pids" ]; then
            echo "[kyro-build-lock] Independent Xcode process detected running on host (PIDs: $external_xcode_pids). Waiting for completion..."
            sleep "$POLL_INTERVAL"
            continue
        fi

        # 2. Try atomic acquisition via mkdir
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "{\"pid\": $$, \"desc\": \"$caller_desc\", \"timestamp\": $(date +%s), \"lstart\": \"$my_lstart\"}" > "$META_FILE"
            echo "[kyro-build-lock] Lock acquired successfully for: $caller_desc (PID $$)."
            return 0
        fi

        # 3. Check existing lock for staleness or PID reuse
        if [ -f "$META_FILE" ]; then
            local lock_pid=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('pid', 0))" 2>/dev/null || echo "0")
            local lock_desc=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('desc', 'Unknown'))" 2>/dev/null || echo "Unknown")
            local recorded_lstart=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('lstart', ''))" 2>/dev/null || echo "")

            local is_stale=0
            if [ "$lock_pid" -le 0 ] || ! kill -0 "$lock_pid" 2>/dev/null; then
                # Target process is dead
                is_stale=1
            else
                # Process exists; check if PID was reused after original lockholder died
                local current_lstart=$(get_pid_lstart "$lock_pid")
                if [ -n "$recorded_lstart" ] && [ "$recorded_lstart" != "$current_lstart" ]; then
                    echo "[kyro-build-lock] PID $lock_pid was recycled by OS (start time mismatch). Marking stale."
                    is_stale=1
                fi
            fi

            if [ "$is_stale" -eq 1 ]; then
                echo "[kyro-build-lock] Stale lock detected (Owner PID $lock_pid [$lock_desc]). Attempting race-free recovery..."
                # Race-free recovery: atomically rename before removing so concurrent cleaners never race
                local recovery_dir="${LOCK_DIR}.stale.$$.${RANDOM}"
                if mv "$LOCK_DIR" "$recovery_dir" 2>/dev/null; then
                    rm -rf "$recovery_dir"
                    echo "[kyro-build-lock] Recovered stale lock successfully."
                    continue
                fi
            fi
        fi

        # 4. Check timeout
        local elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -ge "$TIMEOUT_SECS" ]; then
            echo "[kyro-build-lock] ERROR: Timed out waiting for build lock after ${TIMEOUT_SECS}s." >&2
            exit 1
        fi

        echo "[kyro-build-lock] Lock held by another process. Waiting ${POLL_INTERVAL}s... (${elapsed}s elapsed)"
        sleep "$POLL_INTERVAL"
    done
}

# If executed directly with arguments, acquire lock, run command, and release
if [[ "${(%):-%N}" == "$0" ]]; then
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <command to run...>" >&2
        echo "Example: $0 xcodebuild archive -project Silo.xcodeproj ..." >&2
        exit 1
    fi
    acquire_lock "$*"
    echo "[kyro-build-lock] Executing command under build lock: $*"
    "$@"
fi
