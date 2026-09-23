#!/usr/bin/env bash
# shellcheck shell=bash
# modes.sh - connection-mode (transport profile) registry + shared inbound/link builders.
#
# Adding a new VLESS+REALITY transport = add lib/mode_<name>.sh implementing the mode_<name>_* functions below and
# append <name> to VRI_MODES. Only combinations validated against the current stable 3X-UI/Xray belong here
# (see docs/upstream-research.md). WebSocket / HTTPUpgrade / mKCP are NOT REALITY transports and must not be added.
#
# Per-mode contract (all called via mode_call <mode> <fn> ...):
#   label                 human name
#   note                  one-line description for the menu
#   flow                  client flow ("" when the transport does not support one)
#   defaults              set MODE_OPTS_JSON (object) from OPT_* overrides, generating secure random values
#   prompt                interactive questions (may be empty)
#   validate              validate MODE_OPTS_JSON, return non-zero + message on failure
#   stream_json           streamSettings fragment for the inbound (network + <network>Settings, no security)
#   check_stream FILE     print mismatch lines if inbound streamSettings JSON in FILE deviates from MODE_OPTS_JSON
#   check_link            print mismatch lines if the parsed share link (LINK_P[]) lacks mode-specific params

VRI_MODES=(tcp grpc xhttp)
MODE_OPTS_JSON='{}'
INBOUND_REMARK_PREFIX="BlueSoftKeys-Reality"
DEFAULT_CLIENT_NAME="BlueSoftKeys-Client-1"

# shellcheck source=lib/mode_tcp.sh
. "$VRI_LIB_DIR/mode_tcp.sh"
# shellcheck source=lib/mode_grpc.sh
. "$VRI_LIB_DIR/mode_grpc.sh"
# shellcheck source=lib/mode_xhttp.sh
. "$VRI_LIB_DIR/mode_xhttp.sh"

mode_call() {
    local m="$1" fn="$2"
    shift 2
    valid_mode "$m" || die "unknown connection mode '$m' (valid: ${VRI_MODES[*]})" "$VRI_EX_USAGE"
    "mode_${m}_${fn}" "$@"
}

mode_remark() { # mode -> inbound remark used as our resource tag
    printf '%s-%s' "$INBOUND_REMARK_PREFIX" "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}

modes_menu_text() {
    local i=1 m
    printf 'Select VLESS REALITY connection mode:\n\n'
    for m in "${VRI_MODES[@]}"; do
        printf '  %d) %s%s\n' "$i" "$(mode_call "$m" label)" "$([[ "$m" == "tcp" ]] && printf '  [Recommended]')"
        printf '     %s\n\n' "$(mode_call "$m" note)"
        i=$((i + 1))
    done
}

# Interactive mode selection; sets OPT_MODE.
modes_choose() {
    local sel n=${#VRI_MODES[@]}
    modes_menu_text >&2
    vri_ask sel "Choose [1]" "1"
    if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= n)); then
        OPT_MODE="${VRI_MODES[sel - 1]}"
    elif valid_mode "$sel"; then
        OPT_MODE="$sel"
    else
        die "invalid selection '$sel'" "$VRI_EX_USAGE"
    fi
}

# Build the complete inbound JSON (stdout). Inputs are plain variables; all values pass through jq --arg (no injection).
#   MODE PORT SERVER_ADDR R_TARGET R_SNI R_PRIV R_PUB R_SID R_FINGERPRINT MODE_OPTS_JSON
inbound_build_json() {
    local stream
    stream="$(mode_call "$MODE" stream_json)"
    jq -n \
        --arg remark "$(mode_remark "$MODE")" --argjson port "$PORT" --arg addr "$SERVER_ADDR" \
        --argjson stream "$stream" --arg target "$R_TARGET" --arg sni "$R_SNI" \
        --arg priv "$R_PRIV" --arg pub "$R_PUB" --arg sid "$R_SID" --arg fp "$R_FINGERPRINT" '
    {
      enable: true, remark: $remark, listen: "", port: $port, protocol: "vless",
      expiryTime: 0, total: 0,
      shareAddrStrategy: "custom", shareAddr: $addr,
      settings: {clients: [], decryption: "none", encryption: "none", fallbacks: []},
      streamSettings: ($stream + {
        security: "reality",
        realitySettings: {
          show: false, xver: 0, target: $target, serverNames: [$sni],
          privateKey: $priv, minClientVer: "", maxClientVer: "", maxTimediff: 0,
          shortIds: [$sid], mldsa65Seed: "",
          settings: {publicKey: $pub, fingerprint: $fp, serverName: "", spiderX: "/", mldsa65Verify: ""}
        }
      }),
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], metadataOnly: false, routeOnly: false}
    }'
}

# ---------- share-link parsing & validation ----------

declare -gA LINK_P=()
LINK_UUID="" LINK_HOST="" LINK_PORT="" LINK_NAME=""

# Parse vless://UUID@HOST:PORT?k=v&...#name into LINK_* globals. Returns 1 if not a well-formed vless URI.
link_parse() {
    local link="$1" rest hostport query kv k v
    LINK_P=() LINK_UUID="" LINK_HOST="" LINK_PORT="" LINK_NAME=""
    [[ "$link" == vless://* ]] || return 1
    rest="${link#vless://}"
    [[ "$rest" == *@* ]] || return 1
    LINK_UUID="${rest%%@*}"
    rest="${rest#*@}"
    if [[ "$rest" == *"#"* ]]; then
        LINK_NAME="$(vri_urldecode "${rest#*#}")"
        rest="${rest%%#*}"
    fi
    hostport="${rest%%\?*}"
    query=""
    [[ "$rest" == *\?* ]] && query="${rest#*\?}"
    LINK_HOST="${hostport%:*}"
    LINK_PORT="${hostport##*:}"
    valid_uuid "$LINK_UUID" || return 1
    valid_port "$LINK_PORT" || return 1
    [[ -n "$LINK_HOST" ]] || return 1
    local -a pairs=()
    IFS='&' read -r -a pairs <<<"$query"
    for kv in "${pairs[@]}"; do
        [[ -n "$kv" ]] || continue
        k="${kv%%=*}"
        v=""
        [[ "$kv" == *=* ]] && v="${kv#*=}"
        LINK_P["$k"]="$(vri_urldecode "$v")"
    done
    return 0
}

# Validate a client's share link against the recorded state. Prints one problem per line; returns 0 iff none.
# Needs: MODE PORT SERVER_ADDR R_SNI R_PUB R_SID R_FINGERPRINT MODE_OPTS_JSON; arg1 = link, arg2 = expected uuid (optional)
link_validate() {
    local link="$1" want_uuid="${2:-}" problems=() flow_expected
    if ! link_parse "$link"; then
        echo "not a valid vless:// URI"
        return 1
    fi
    [[ -z "$want_uuid" || "${LINK_UUID,,}" == "${want_uuid,,}" ]] || problems+=("uuid mismatch")
    [[ "$LINK_HOST" == "$SERVER_ADDR" ]] || problems+=("host '$LINK_HOST' != server address '$SERVER_ADDR'")
    [[ "$LINK_PORT" == "$PORT" ]] || problems+=("port '$LINK_PORT' != inbound port '$PORT'")
    [[ "${LINK_P[security]:-}" == "reality" ]] || problems+=("security != reality")
    [[ "${LINK_P[type]:-}" == "$(mode_call "$MODE" network)" ]] || problems+=("type '${LINK_P[type]:-}' != mode network")
    [[ "${LINK_P[pbk]:-}" == "$R_PUB" ]] || problems+=("public key (pbk) mismatch")
    [[ "${LINK_P[sid]:-}" == "$R_SID" ]] || problems+=("short id (sid) mismatch")
    [[ "${LINK_P[sni]:-}" == "$R_SNI" ]] || problems+=("sni '${LINK_P[sni]:-}' != '$R_SNI'")
    [[ "${LINK_P[fp]:-}" == "$R_FINGERPRINT" ]] || problems+=("fingerprint mismatch")
    [[ "${LINK_P[encryption]:-none}" == "none" ]] || problems+=("unexpected encryption '${LINK_P[encryption]}'")
    # the private key must never appear in a client link
    if [[ -n "${R_PRIV:-}" && "$link" == *"$R_PRIV"* ]]; then
        problems+=("LINK CONTAINS THE PRIVATE KEY")
    fi
    flow_expected="$(mode_call "$MODE" flow)"
    if [[ -n "$flow_expected" ]]; then
        [[ "${LINK_P[flow]:-}" == "$flow_expected" ]] || problems+=("flow '${LINK_P[flow]:-}' != '$flow_expected'")
    else
        [[ -z "${LINK_P[flow]:-}" ]] || problems+=("unexpected flow '${LINK_P[flow]}' for mode $MODE")
    fi
    local extra
    extra="$(mode_call "$MODE" check_link || true)"
    [[ -z "$extra" ]] || while IFS= read -r line; do problems+=("$line"); done <<<"$extra"
    if ((${#problems[@]})); then
        printf '%s\n' "${problems[@]}"
        return 1
    fi
    return 0
}
