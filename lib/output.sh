#!/usr/bin/env bash
# shellcheck shell=bash
# output.sh - user-facing rendering: info, status, banners. Never prints private keys, API tokens or panel passwords.

_kv() { printf '  %-22s %s\n' "$1" "$2"; }

output_banner() {
    printf '%s\n' "==========================================================" >&2
    printf '%s\n' " ${VRI_PRODUCT}" >&2
    printf '%s\n' "==========================================================" >&2
}

# Connection parameters (public information only).
output_connection_details() {
    local flow
    flow="$(mode_call "$MODE" flow)"
    printf '\nConnection details\n'
    _kv "Protocol" "VLESS + REALITY"
    _kv "Mode" "$(mode_call "$MODE" label)"
    _kv "Server address" "$SERVER_ADDR"
    _kv "Port" "$PORT"
    _kv "Flow" "${flow:-none}"
    _kv "SNI (server name)" "$R_SNI"
    _kv "REALITY target" "$R_TARGET"
    _kv "Fingerprint" "$R_FINGERPRINT"
    _kv "Public key" "$R_PUB"
    _kv "Short ID" "$R_SID"
    case "$MODE" in
        grpc) _kv "gRPC service name" "$(jq -r '.service_name' <<<"$MODE_OPTS_JSON")" ;;
        xhttp)
            _kv "XHTTP path" "$(jq -r '.path' <<<"$MODE_OPTS_JSON")"
            _kv "XHTTP mode" "$(jq -r '.mode' <<<"$MODE_OPTS_JSON")"
            ;;
    esac
}

# output_client_block NAME  (link + QR hint)
output_client_block() {
    local name="$1" link
    link="$(client_link "$name")" || true
    printf '\nClient: %s\n' "$name"
    if [[ -n "$link" ]]; then
        printf '  %s\n' "$link"
        printf '  QR code: sudo vless-reality qr %s\n' "$name"
    else
        printf '  (share link unavailable; run: sudo vless-reality diagnostics)\n'
    fi
}

output_panel_hint() {
    local base=""
    upstream_panel_settings 2>/dev/null || return 0
    base="${PANEL_BASE_PATH:+/$PANEL_BASE_PATH/}"
    printf '\n3X-UI panel (official, not modified)\n'
    _kv "Local URL" "http://127.0.0.1:${PANEL_PORT}${base:-/}"
    _kv "Credentials" "sudo cat ${UPSTREAM_RESULT_FILE}   (root only)"
    _kv "Remote access" "ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${SERVER_ADDR}"
    printf '  The panel is HTTP-only by default (upstream behaviour). The panel port is NOT opened by this tool.\n'
}

output_info() { # [client name]
    state_require
    if (($#)); then
        output_connection_details
        output_client_block "$1"
        return 0
    fi
    output_connection_details
    local names
    names="$(jq -r '(.clients // [])[].email' "$(state_file)")"
    if [[ -z "$names" ]]; then
        printf '\nNo clients recorded. Add one: sudo vless-reality add-client\n'
    else
        while IFS= read -r n; do output_client_block "$n"; done <<<"$names"
    fi
    output_panel_hint
}

# ---------- status ----------

_health() { # ok|warn|bad text
    case "$1" in
        ok) printf '%s%s%s' "$C_GRN" "$2" "$C_OFF" ;;
        warn) printf '%s%s%s' "$C_YEL" "$2" "$C_OFF" ;;
        *) printf '%s%s%s' "$C_RED" "$2" "$C_OFF" ;;
    esac
}

output_status() {
    state_require
    local pv xv svc xs listen inbound clients rc=0
    pv="$(upstream_version || echo unknown)"
    xv="$(upstream_xray_version || echo unknown)"
    printf '%s\n' "${VRI_PRODUCT}"
    _kv "Wrapper version" "$VRI_VERSION"
    _kv "3X-UI version" "$pv (tested with $TESTED_UPSTREAM)"
    _kv "Xray version" "$xv"
    _kv "Connection mode" "$(mode_call "$MODE" label) [$MODE]"

    if upstream_service_active; then svc="$(_health ok running)"; else
        svc="$(_health bad "NOT running")"
        rc=1
    fi
    _kv "3X-UI service" "$svc"

    if api_session_init_quiet; then
        xs="$(panel_xray_state)"
        if [[ "$xs" == "running" ]]; then _kv "Xray" "$(_health ok running)"; else
            _kv "Xray" "$(_health bad "$xs")"
            rc=1
        fi
    else
        _kv "Xray" "$(_health warn "unknown (panel API unreachable: $API_MSG)")"
        rc=1
    fi

    _kv "Inbound port" "$PORT"
    if net_port_listening "$PORT"; then listen="$(_health ok listening)"; else
        listen="$(_health bad "NOT listening")"
        rc=1
    fi
    _kv "Listening state" "$listen"

    if [[ -n "$API_TOKEN" ]] && panel_inbound_get "$INBOUND_ID"; then
        if [[ "$(api_obj '.obj.enable')" == "true" ]]; then inbound="$(_health ok "present (id $INBOUND_ID, enabled)")"; else
            inbound="$(_health warn "present but DISABLED")"
            rc=1
        fi
        clients="$(api_obj '(.obj.clientStats // []) | length')"
    else
        inbound="$(_health bad "MISSING (run: sudo vless-reality repair)")"
        clients="?"
        rc=1
    fi
    _kv "Inbound" "$inbound"
    _kv "Client count" "$clients"
    return "$rc"
}
