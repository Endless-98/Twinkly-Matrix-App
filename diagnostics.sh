#!/usr/bin/env bash

set -uo pipefail

MODEL_NAME="Light Wall"
WIDTH=90
HEIGHT=50
DDP_PORT=4049
API_PORT=5000
FIX_OVERLAY_STATE=0
FIX_CHANNEL_OUTPUTS=0
VERBOSE=1
RUN_LIVE_FLOW_TEST=1
REQUIRE_VISUAL_CONFIRM=0
LIVE_TEST_SECONDS=1.5

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

CHANNEL_OUTPUTS_ENABLED="unknown"

usage() {
    cat <<'EOF'
Usage: diagnostics.sh [options]

Comprehensive FPP diagnostics for TwinklyWall + Pixel Overlay.
Checks:
  - FPP services, API, and process health
  - Overlay Models and overlay state
  - /dev/shm Pixel Overlay memory buffer
  - FPP settings/config files (enumerates all discovered settings)
  - TwinklyWall service/ports integration checks

Options:
  --model NAME           Overlay model name (default: Light Wall)
  --width N              Matrix width (default: 90)
  --height N             Matrix height (default: 50)
  --ddp-port N           DDP UDP listen port (default: 4049)
  --api-port N           TwinklyWall API port (default: 5000)
  --fix-overlay-state    Attempt to set overlay state to 3 (always on)
  --fix-channel-outputs  Enable output in co-universes.json if off (restarts fppd)
    --skip-live-flow-test  Skip active live pixel flow probe
    --require-visual-confirm  Prompt for visual LED confirmation (interactive)
    --live-test-seconds N  Hold each test frame N seconds (default: 1.5)
  --quiet                Less verbose output
  -h, --help             Show this help

Examples:
  ./diagnostics.sh
  ./diagnostics.sh --model "Light Wall" --width 90 --height 50
  ./diagnostics.sh --fix-overlay-state
    ./diagnostics.sh --require-visual-confirm --live-test-seconds 2
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL_NAME="${2:-}"
            shift 2
            ;;
        --width)
            WIDTH="${2:-}"
            shift 2
            ;;
        --height)
            HEIGHT="${2:-}"
            shift 2
            ;;
        --ddp-port)
            DDP_PORT="${2:-}"
            shift 2
            ;;
        --api-port)
            API_PORT="${2:-}"
            shift 2
            ;;
        --fix-overlay-state)
            FIX_OVERLAY_STATE=1
            shift
            ;;
        --fix-channel-outputs)
            FIX_CHANNEL_OUTPUTS=1
            shift
            ;;
        --quiet)
            VERBOSE=0
            shift
            ;;
        --skip-live-flow-test)
            RUN_LIVE_FLOW_TEST=0
            shift
            ;;
        --require-visual-confirm)
            REQUIRE_VISUAL_CONFIRM=1
            shift
            ;;
        --live-test-seconds)
            LIVE_TEST_SECONDS="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

SAFE_MODEL_NAME="${MODEL_NAME// /_}"
EXPECTED_BUFFER_SIZE=$((WIDTH * HEIGHT * 3))
MMAP_FILE="/dev/shm/FPP-Model-Data-${SAFE_MODEL_NAME}"

section() {
    echo
    echo "==== $1 ===="
}

info() {
    echo "[INFO] $1"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "[PASS] $1"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo "[WARN] $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[FAIL] $1"
}

kv() {
    printf "  - %-36s %s\n" "$1" "$2"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

url_encode_spaces() {
    echo "$1" | sed 's/ /%20/g'
}

api_get() {
    local endpoint="$1"
    local body
    local code
    body="$(curl -sS -m 5 -w $'\n%{http_code}' "http://localhost${endpoint}" 2>/dev/null || true)"
    code="$(echo "$body" | tail -n1)"
    echo "$body"
    return 0
}

check_service() {
    local svc="$1"
    if ! have_cmd systemctl; then
        warn "systemctl not available; cannot validate service ${svc}"
        return
    fi

    if systemctl list-unit-files "${svc}.service" --no-pager 2>/dev/null | grep -q "${svc}.service"; then
        if systemctl is-active --quiet "$svc"; then
            pass "Service ${svc} is active"
        else
            fail "Service ${svc} is installed but not active"
        fi

        if systemctl is-enabled --quiet "$svc"; then
            pass "Service ${svc} is enabled"
        else
            warn "Service ${svc} is not enabled"
        fi
    else
        warn "Service ${svc} not installed"
    fi
}

check_port_listen() {
    local protocol="$1"
    local port="$2"
    local label="$3"

    if ! have_cmd ss; then
        warn "ss command not available; cannot verify ${label} on ${protocol}/${port}"
        return
    fi

    if [[ "$protocol" == "udp" ]]; then
        if ss -lun | awk '{print $5}' | grep -qE "(^|:)${port}$"; then
            pass "${label} listening on UDP ${port}"
        else
            fail "${label} not listening on UDP ${port}"
        fi
    else
        if ss -ltn | awk '{print $4}' | grep -qE "(^|:)${port}$"; then
            pass "${label} listening on TCP ${port}"
        else
            fail "${label} not listening on TCP ${port}"
        fi
    fi
}

parse_overlay_state() {
    local body="$1"
    local state=""

    if have_cmd jq; then
        state="$(echo "$body" | jq -r 'if type=="object" then (.State // .state // empty) elif type=="number" then tostring elif type=="string" then . else empty end' 2>/dev/null || true)"
    fi

    if [[ -z "$state" ]]; then
        state="$(echo "$body" | tr -d '[:space:]' | grep -oE '^[0-9]+$' | head -n1 || true)"
    fi

    if [[ -z "$state" ]]; then
        state="$(echo "$body" | grep -oE '"(State|state)"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
    fi

    echo "$state"
}

run_live_flow_test() {
    local mmap_file="$1"
    local width="$2"
    local height="$3"
    local hold_seconds="$4"

    if [[ ! -e "$mmap_file" ]]; then
        fail "Live flow test: mmap file missing (${mmap_file})"
        return 1
    fi

    if ! have_cmd python3; then
        fail "Live flow test requires python3"
        return 1
    fi

    local before_hash=""
    if have_cmd sha256sum; then
        before_hash="$(sha256sum "$mmap_file" | awk '{print $1}')"
    fi

    local py_out
    py_out="$(python3 - "$mmap_file" "$width" "$height" "$hold_seconds" <<'PY'
import hashlib
import os
import sys
import time

path = sys.argv[1]
width = int(sys.argv[2])
height = int(sys.argv[3])
hold = float(sys.argv[4])
size = width * height * 3

with open(path, 'r+b') as f:
    original = f.read(size)
    if len(original) != size:
        raise RuntimeError(f"mmap size mismatch: expected {size}, got {len(original)}")

    frame1 = bytearray(size)
    frame2 = bytearray(size)

    for px in range(width * height):
        base = px * 3
        x = px % width
        y = px // width

        # Frame 1: strong red/blue diagonal test pattern
        frame1[base] = (x * 255) // max(1, (width - 1))
        frame1[base + 1] = 0
        frame1[base + 2] = (y * 255) // max(1, (height - 1))

        # Frame 2: strong green checker pattern
        frame2[base] = 0
        frame2[base + 1] = 255 if ((x + y) % 2 == 0) else 20
        frame2[base + 2] = 0

    f.seek(0)
    f.write(frame1)
    f.flush()
    os.fsync(f.fileno())
    h1 = hashlib.sha256(frame1).hexdigest()
    print(f"HASH_FRAME1={h1}")
    time.sleep(hold)

    f.seek(0)
    f.write(frame2)
    f.flush()
    os.fsync(f.fileno())
    h2 = hashlib.sha256(frame2).hexdigest()
    print(f"HASH_FRAME2={h2}")
    time.sleep(hold)

    f.seek(0)
    f.write(original)
    f.flush()
    os.fsync(f.fileno())
    print("RESTORE_OK=1")
PY
    )"

    local py_code=$?
    if [[ $py_code -ne 0 ]]; then
        fail "Live flow test failed while writing probe frames to mmap"
        [[ -n "$py_out" ]] && echo "$py_out"
        return 1
    fi

    local hash1 hash2 restore_ok
    hash1="$(echo "$py_out" | awk -F= '/^HASH_FRAME1=/{print $2}' | head -n1)"
    hash2="$(echo "$py_out" | awk -F= '/^HASH_FRAME2=/{print $2}' | head -n1)"
    restore_ok="$(echo "$py_out" | awk -F= '/^RESTORE_OK=/{print $2}' | head -n1)"

    if [[ -n "$hash1" && -n "$hash2" && "$hash1" != "$hash2" ]]; then
        pass "Live flow test wrote two distinct probe frames into mmap"
    else
        fail "Live flow test did not produce distinct frame writes"
        return 1
    fi

    if [[ "$restore_ok" == "1" ]]; then
        pass "Live flow test restored original mmap frame"
    else
        warn "Live flow test may not have restored original mmap frame"
    fi

    if [[ -n "$before_hash" ]] && have_cmd sha256sum; then
        local after_hash
        after_hash="$(sha256sum "$mmap_file" | awk '{print $1}')"
        if [[ "$before_hash" == "$after_hash" ]]; then
            pass "mmap hash returned to original after probe"
        else
            warn "mmap hash differs after probe (live writer may have updated frame concurrently)"
        fi
    fi

    return 0
}

section "Input Parameters"
kv "Model" "$MODEL_NAME"
kv "Safe model" "$SAFE_MODEL_NAME"
kv "Width x Height" "${WIDTH} x ${HEIGHT}"
kv "Expected mmap bytes" "$EXPECTED_BUFFER_SIZE"
kv "Expected mmap path" "$MMAP_FILE"

section "Core Environment"
if have_cmd uname; then kv "Kernel" "$(uname -a)"; fi
if have_cmd hostname; then kv "Hostname" "$(hostname)"; fi
if have_cmd uptime; then kv "Uptime" "$(uptime -p 2>/dev/null || uptime)"; fi

if have_cmd timedatectl; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [[ -n "$tz" ]] && kv "Timezone" "$tz"
    [[ -n "$ntp" ]] && kv "NTP synchronized" "$ntp"
fi

if have_cmd free; then
    echo "Memory (free -h):"
    free -h || true
fi

echo "Disk (/ and /home/fpp/media if present):"
df -h / 2>/dev/null || true
df -h /home/fpp/media 2>/dev/null || true
df -h /dev/shm 2>/dev/null || true

section "FPP Services"
check_service "fppd"
check_service "apache2"
check_service "nginx"
check_service "twinklywall"

section "FPP API Reachability"
if have_cmd curl; then
    if curl -sS -m 5 "http://localhost/" >/dev/null 2>&1; then
        pass "FPP web server responds on localhost"
    else
        fail "Cannot reach localhost web server"
    fi

    endpoints=(
        "/api/system/status"
        "/api/settings"
        "/api/fppd/status"
        "/api/channel/output"
        "/api/channel/output/processors"
        "/api/overlays/model"
    )

    for ep in "${endpoints[@]}"; do
        raw="$(api_get "$ep")"
        code="$(echo "$raw" | tail -n1)"
        body="$(echo "$raw" | sed '$d')"

        if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
            pass "API ${ep} returned HTTP ${code}"
            if [[ "$ep" == "/api/system/status" ]]; then
                if have_cmd jq && echo "$body" | jq . >/dev/null 2>&1; then
                    channel_out="$(echo "$body" | jq -r '.channelOutputsEnabled // empty' 2>/dev/null || true)"
                    if [[ -n "$channel_out" ]]; then
                        kv "system/status channelOutputsEnabled" "$channel_out"
                    fi
                fi
            fi
            if [[ $VERBOSE -eq 1 ]]; then
                if have_cmd jq && echo "$body" | jq . >/dev/null 2>&1; then
                    echo "$body" | jq . 2>/dev/null | head -n 20
                else
                    echo "$body" | head -n 5
                fi
            fi
        elif [[ "$code" == "404" ]]; then
            warn "API ${ep} not present on this FPP version (HTTP 404)"
        else
            warn "API ${ep} returned HTTP ${code:-unknown}"
        fi
    done
else
    fail "curl is required for API checks"
fi

section "Channel Outputs Master Switch"
# The "Enable Output" toggle lives inside co-universes.json, NOT in /api/settings/
CO_CONFIG="/home/fpp/media/config/co-universes.json"
if [[ -f "$CO_CONFIG" ]] && have_cmd jq; then
    co_enabled="$(jq -r '.channelOutputs[0].enabled // 0' "$CO_CONFIG" 2>/dev/null || echo '0')"
    co_type="$(jq -r '.channelOutputs[0].type // "unknown"' "$CO_CONFIG" 2>/dev/null || echo 'unknown')"
    co_count="$(jq -r '.channelOutputs[0].universes | length // 0' "$CO_CONFIG" 2>/dev/null || echo '0')"
    kv "co-universes enabled" "$co_enabled"
    kv "co-universes type" "$co_type"
    kv "co-universes count" "$co_count"
    if [[ "$co_enabled" == "1" ]]; then
        CHANNEL_OUTPUTS_ENABLED="true"
        pass "Channel outputs master switch is ON (co-universes.json)"
    else
        CHANNEL_OUTPUTS_ENABLED="false"
        fail "Channel outputs master switch is OFF in co-universes.json (enabled=${co_enabled})"
        echo "       FPP will NOT send any data to controllers until this is enabled."
        echo "       Fix:  --fix-channel-outputs  or FPP UI → Input/Output Setup → Channel Outputs → Enable Output"
        if [[ "$FIX_CHANNEL_OUTPUTS" -eq 1 ]]; then
            info "Enabling channel outputs in co-universes.json..."
            if jq '.channelOutputs[0].enabled = 1' "$CO_CONFIG" > "${CO_CONFIG}.tmp" 2>/dev/null && \
               mv "${CO_CONFIG}.tmp" "$CO_CONFIG"; then
                pass "Set enabled=1 in co-universes.json"
                info "Restarting fppd to apply channel output changes..."
                if have_cmd systemctl; then
                    sudo systemctl restart fppd 2>/dev/null || true
                    sleep 3
                    if systemctl is-active --quiet fppd; then
                        pass "fppd restarted successfully after enabling channel outputs"
                        CHANNEL_OUTPUTS_ENABLED="true"
                    else
                        fail "fppd did not restart cleanly"
                    fi
                fi
            else
                fail "Could not update co-universes.json"
                rm -f "${CO_CONFIG}.tmp" 2>/dev/null || true
            fi
        fi
    fi
elif [[ ! -f "$CO_CONFIG" ]]; then
    warn "co-universes.json not found at ${CO_CONFIG} — no E1.31/ArtNet/DDP outputs configured"
else
    warn "jq not available; cannot parse co-universes.json"
fi

section "Overlay Model + State"
OVERLAY_ENDPOINT=""
MODEL_ENCODED="$(url_encode_spaces "$MODEL_NAME")"
OVERLAY_STATE=""
STATE_ENDPOINTS=(
    "/api/overlays/model/${SAFE_MODEL_NAME}/state"
    "/api/overlays/model/${MODEL_ENCODED}/state"
)

if have_cmd curl; then
    for ep in "${STATE_ENDPOINTS[@]}"; do
        raw="$(api_get "$ep")"
        code="$(echo "$raw" | tail -n1)"
        body="$(echo "$raw" | sed '$d')"
        if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
            OVERLAY_ENDPOINT="$ep"
            pass "Overlay state endpoint available: ${ep}"

            state="$(parse_overlay_state "$body")"

            if [[ -n "$state" ]]; then
                OVERLAY_STATE="$state"
                kv "Detected overlay state" "$state"
                if [[ "$state" == "3" ]]; then
                    pass "Overlay state is 3 (always transmitting)"
                else
                    warn "Overlay state is ${state}, expected 3 for continuous output"
                fi
            else
                warn "Could not parse overlay state response"
            fi
            break
        fi
    done

    if [[ -z "$OVERLAY_ENDPOINT" ]]; then
        fail "Could not find a working overlay state API endpoint for model ${MODEL_NAME}"
    elif [[ "$FIX_OVERLAY_STATE" -eq 1 ]]; then
        put_code="$(curl -sS -m 5 -o /tmp/fpp_overlay_put.out -w '%{http_code}' \
            -X PUT "http://localhost${OVERLAY_ENDPOINT}" \
            -H 'Content-Type: application/json' \
            -d '{"State":3}' 2>/dev/null || true)"
        if [[ "$put_code" =~ ^2[0-9][0-9]$ ]]; then
            pass "Overlay state set to 3 via ${OVERLAY_ENDPOINT}"
        else
            warn "Failed to set overlay state to 3 (HTTP ${put_code:-unknown})"
        fi
        rm -f /tmp/fpp_overlay_put.out
    fi
fi

section "Shared Memory Buffer"
if mount | grep -qE 'on /dev/shm '; then
    pass "/dev/shm is mounted"
else
    fail "/dev/shm is not mounted"
fi

if [[ -e "$MMAP_FILE" ]]; then
    pass "Overlay memory file exists: $MMAP_FILE"
    size="$(stat -c '%s' "$MMAP_FILE" 2>/dev/null || echo 0)"
    perms="$(stat -c '%a' "$MMAP_FILE" 2>/dev/null || echo '?')"
    owner="$(stat -c '%U:%G' "$MMAP_FILE" 2>/dev/null || echo '?:?')"
    kv "mmap owner" "$owner"
    kv "mmap perms" "$perms"
    kv "mmap size" "$size"

    if [[ "$size" -eq "$EXPECTED_BUFFER_SIZE" ]]; then
        pass "mmap size matches expected ${EXPECTED_BUFFER_SIZE} bytes"
    else
        fail "mmap size mismatch: expected ${EXPECTED_BUFFER_SIZE}, got ${size}"
    fi

    if [[ -w "$MMAP_FILE" ]]; then
        pass "mmap file is writable by current user"
    else
        fail "mmap file is not writable by current user"
    fi
else
    fail "Overlay memory file missing: $MMAP_FILE"
fi

if have_cmd df; then
    shm_avail="$(df -B1 --output=avail /dev/shm 2>/dev/null | tail -n1 | tr -d '[:space:]' || echo 0)"
    kv "/dev/shm available bytes" "$shm_avail"
    min_needed=$((EXPECTED_BUFFER_SIZE * 2))
    if [[ "$shm_avail" =~ ^[0-9]+$ ]] && [[ "$shm_avail" -gt "$min_needed" ]]; then
        pass "/dev/shm free space looks sufficient"
    else
        warn "/dev/shm free space may be too low (need > ${min_needed} bytes)"
    fi
fi

section "FPP Settings Inventory"
SETTINGS_DIR="/home/fpp/media/settings"
if [[ -d "$SETTINGS_DIR" ]]; then
    pass "Settings directory exists: $SETTINGS_DIR"
    mapfile -t setting_files < <(find "$SETTINGS_DIR" -maxdepth 1 -type f | sort)
    kv "Settings file count" "${#setting_files[@]}"

    for f in "${setting_files[@]}"; do
        name="$(basename "$f")"
        if [[ ! -r "$f" ]]; then
            warn "Unreadable setting: $name"
            continue
        fi
        if file -b "$f" 2>/dev/null | grep -qi 'text'; then
            value="$(tr -d '\r' < "$f" | head -n 1)"
            if [[ -z "$value" ]]; then
                value="<empty>"
            fi
            kv "setting:${name}" "$value"
        else
            kv "setting:${name}" "<non-text/binary>"
        fi
    done
else
    warn "Settings directory missing: $SETTINGS_DIR (common on newer FPP versions using API/config-backed settings)"
fi

section "FPP Config Inventory"
CONFIG_DIR="/home/fpp/media/config"
if [[ -d "$CONFIG_DIR" ]]; then
    pass "Config directory exists: $CONFIG_DIR"
    mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -type f | sort)
    kv "Config file count" "${#config_files[@]}"

    for f in "${config_files[@]}"; do
        name="$(basename "$f")"
        if [[ ! -r "$f" ]]; then
            warn "Unreadable config: $name"
            continue
        fi

        kv "config:${name}" "$(stat -c '%s bytes' "$f" 2>/dev/null || echo '? bytes')"

        if [[ "$name" == *.json ]] && have_cmd jq; then
            if jq . "$f" >/dev/null 2>&1; then
                top_keys="$(jq -r 'if type=="object" then (keys|join(",")) else type end' "$f" 2>/dev/null || true)"
                [[ -n "$top_keys" ]] && kv "json-keys:${name}" "$top_keys"
            else
                warn "Invalid JSON: $name"
            fi
        elif [[ $VERBOSE -eq 1 ]]; then
            head_preview="$(head -n 1 "$f" 2>/dev/null | tr -d '\r')"
            [[ -n "$head_preview" ]] && kv "preview:${name}" "$head_preview"
        fi
    done

    matching_files="$(find "$CONFIG_DIR" -maxdepth 1 -type f | grep -Ei 'overlay|model|channel|output|universe|e131|ddp|pixel' || true)"
    if [[ -n "$matching_files" ]]; then
        pass "Found overlay/channel/output related config files"
        echo "$matching_files" | while IFS= read -r f; do
            kv "related-config" "$f"
        done
    else
        warn "No overlay/channel/output-related config filenames matched heuristics"
    fi
else
    fail "Config directory missing: $CONFIG_DIR"
fi

section "TwinklyWall Integration"
TW_ROOT="/home/fpp/TwinklyWall_Project"
TW_APP="${TW_ROOT}/TwinklyWall"

if [[ -d "$TW_APP" ]]; then
    pass "TwinklyWall app directory exists"
else
    warn "TwinklyWall app directory not found at ${TW_APP}"
fi

check_port_listen "tcp" "$API_PORT" "TwinklyWall API"

DDP_UDP_LISTENING=0
if have_cmd ss; then
    if ss -lun | awk '{print $5}' | grep -qE "(^|:)${DDP_PORT}$"; then
        DDP_UDP_LISTENING=1
    fi
fi

if [[ "$DDP_UDP_LISTENING" -eq 1 ]]; then
    pass "DDP bridge listening on UDP ${DDP_PORT}"
else
    if have_cmd systemctl && systemctl list-unit-files ddp_bridge.service --no-pager 2>/dev/null | grep -q ddp_bridge.service; then
        if systemctl is-active --quiet ddp_bridge; then
            fail "ddp_bridge service is active but UDP ${DDP_PORT} is not listening"
        else
            warn "ddp_bridge service exists but is not active; UDP ${DDP_PORT} not listening"
        fi
    else
        if [[ -e "$MMAP_FILE" ]] && [[ "$OVERLAY_STATE" == "3" ]]; then
            pass "DDP UDP ${DDP_PORT} not listening, but TwinklyWall/FPP overlay path is ready (embedded bridge mode)"
        else
            warn "DDP UDP ${DDP_PORT} not listening (may be expected if bridge is embedded or idle)"
        fi
    fi
fi

if have_cmd systemctl; then
    if systemctl list-unit-files twinklywall.service --no-pager 2>/dev/null | grep -q twinklywall.service; then
        unit_text="$(systemctl cat twinklywall 2>/dev/null || true)"
        if echo "$unit_text" | grep -q "FPP_MODEL_NAME"; then
            pass "twinklywall service exports FPP_MODEL_NAME"
            model_line="$(echo "$unit_text" | grep -m1 'FPP_MODEL_NAME' | sed 's/^/    /')"
            [[ -n "$model_line" ]] && echo "$model_line"
        else
            warn "twinklywall service does not explicitly set FPP_MODEL_NAME"
        fi
    fi
fi

section "End-to-End Live Pixel Flow"
kv "Live flow test" "$([[ "$RUN_LIVE_FLOW_TEST" -eq 1 ]] && echo enabled || echo skipped)"
kv "Hold seconds" "$LIVE_TEST_SECONDS"

if [[ "$RUN_LIVE_FLOW_TEST" -eq 1 ]]; then
    if [[ "$CHANNEL_OUTPUTS_ENABLED" == "false" ]]; then
        fail "Skipping live flow probe because channel outputs master switch is OFF"
        echo "       Run with --fix-channel-outputs to enable, or enable via FPP UI."
    else
        run_live_flow_test "$MMAP_FILE" "$WIDTH" "$HEIGHT" "$LIVE_TEST_SECONDS"

        if [[ "$REQUIRE_VISUAL_CONFIRM" -eq 1 ]]; then
            if [[ -t 0 ]]; then
                echo "Did the wall visibly show two test frames (red/blue gradient then green checker)? [y/N]"
                read -r visual_ok
                if [[ "$visual_ok" =~ ^[Yy]$ ]]; then
                    pass "Operator confirmed physical LED output"
                else
                    fail "Operator did not confirm physical LED output"
                fi
            else
                warn "Visual confirmation requested, but no interactive TTY available"
            fi
        else
            info "Physical output confirmation not requested (use --require-visual-confirm)"
        fi
    fi
fi

section "Summary"
kv "PASS" "$PASS_COUNT"
kv "WARN" "$WARN_COUNT"
kv "FAIL" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo
    echo "Diagnostics completed with failures."
    exit 1
fi

echo
echo "Diagnostics completed successfully (no hard failures)."
exit 0
