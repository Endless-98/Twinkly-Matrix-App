#!/usr/bin/env bash

set -uo pipefail

MODEL_NAME="Light Wall"
WIDTH=90
HEIGHT=50
DDP_PORT=4049
API_PORT=5000
FIX_OVERLAY_STATE=0
VERBOSE=1

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

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
  --quiet                Less verbose output
  -h, --help             Show this help

Examples:
  ./diagnostics.sh
  ./diagnostics.sh --model "Light Wall" --width 90 --height 50
  ./diagnostics.sh --fix-overlay-state
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
        --quiet)
            VERBOSE=0
            shift
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
