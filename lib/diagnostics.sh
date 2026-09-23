#!/usr/bin/env bash
# shellcheck shell=bash
# diagnostics.sh - read-only health checks with PASS/WARN/FAIL lines. Never prints secrets.

DIAG_FAILS=0 DIAG_WARNS=0

_d_pass() { printf '  %s[PASS]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
_d_warn() {
    DIAG_WARNS=$((DIAG_WARNS + 1))
    printf '  %s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*"
}
_d_fail() {
    DIAG_FAILS=$((DIAG_FAILS + 1))
    printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"
}

diagnostics_run() {
    state_require
    DIAG_FAILS=0 DIAG_WARNS=0
    local f problems host ip pub n uuid link p mode_flow

    printf '%s diagnostics (wrapper %s, mode %s)\n' "$VRI_PRODUCT" "$VRI_VERSION" "$MODE"

    printf '\n3X-UI / Xray\n'
    if upstream_service_active; then _d_pass "x-ui service is active"; else
        _d_fail "x-ui service is not active (sudo systemctl status x-ui; sudo vless-reality repair)"
    fi
    local have_api=0
    if api_session_init_quiet; then
        have_api=1
        _d_pass "panel API reachable, token accepted"
        if [[ "$(panel_xray_state)" == "running" ]]; then _d_pass "Xray is running ($(upstream_xray_version || echo '?'))"; else
            _d_fail "Xray is not running (sudo vless-reality repair)"
        fi
    else
        _d_fail "panel API unavailable: $API_MSG"
    fi

    printf '\nInbound\n'
    if ((have_api)); then
        f="$(vri_mktemp dinb)"
        if panel_inbound_get "$INBOUND_ID"; then
            jq '.obj' "$API_OUT" >"$f"
            _d_pass "inbound exists (id $INBOUND_ID, tag $(jq -r .tag "$f"), remark $(jq -r .remark "$f"))"
            problems="$(repair_inbound_problems "$f")"
            if [[ -z "$problems" ]]; then
                _d_pass "inbound matches the recorded $(mode_call "$MODE" label) configuration"
            else
                while IFS= read -r p; do _d_fail "config mismatch: $p"; done <<<"$problems"
                printf '         -> run: sudo vless-reality repair\n'
            fi
        else
            _d_fail "managed inbound (id $INBOUND_ID) is missing from the panel (sudo vless-reality repair)"
        fi
    fi

    printf '\nNetwork\n'
    if net_port_listening "$PORT"; then
        _d_pass "TCP $PORT is listening ($(net_port_listeners "$PORT"))"
    else
        _d_fail "nothing is listening on TCP $PORT"
    fi
    if fw_ufw_present; then
        if fw_ufw_active; then
            if fw_rule_exists "$PORT"; then _d_pass "UFW active and allows TCP $PORT"; else
                _d_fail "UFW is active but does not allow TCP $PORT (sudo vless-reality repair)"
            fi
        else
            _d_pass "UFW installed but inactive (not managed by us)"
        fi
    else
        _d_pass "UFW not installed"
    fi
    _d_warn "cloud/provider firewalls cannot be checked from inside the VPS - make sure TCP $PORT is allowed there"

    host="${R_TARGET%:*}"
    if [[ -n "$(net_resolve_ipv4 "$host")" ]]; then _d_pass "DNS: REALITY target $host resolves"; else
        _d_fail "DNS: cannot resolve REALITY target $host"
    fi
    if valid_ipv4 "$SERVER_ADDR"; then
        if ip="$(net_detect_public_ip)"; then
            if [[ "$ip" == "$SERVER_ADDR" ]]; then _d_pass "server address $SERVER_ADDR matches this VPS's public IP"; else
                _d_warn "server address $SERVER_ADDR differs from the detected public IP $ip (NAT / floating IP?)"
            fi
        fi
    else
        ip="$(net_resolve_ipv4 "$SERVER_ADDR")"
        if [[ -n "$ip" ]]; then _d_pass "DNS: server address $SERVER_ADDR resolves to $ip"; else
            _d_fail "DNS: server address $SERVER_ADDR does not resolve"
        fi
    fi
    if net_tcp_open "$host" "${R_TARGET##*:}" 6; then _d_pass "REALITY target $R_TARGET is reachable"; else
        _d_fail "REALITY target $R_TARGET is not reachable from this server"
    fi
    if ((have_api)); then
        if reality_scan "$R_TARGET" "$R_SNI"; then _d_pass "REALITY target passes the TLS 1.3 / h2 / X25519 check for SNI $R_SNI"; else
            _d_warn "REALITY target check: $SCAN_REASON"
        fi
    fi

    printf '\nTransport (%s)\n' "$(mode_call "$MODE" label)"
    mode_flow="$(mode_call "$MODE" flow)"
    _d_pass "expected flow: ${mode_flow:-none}; network: $(mode_call "$MODE" network)"

    printf '\nClients and share links\n'
    if ((have_api)); then
        n=0
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            n=$((n + 1))
            if ! panel_client_get "$p"; then
                _d_fail "client $p is recorded but missing from the panel"
                continue
            fi
            uuid="$(api_obj '.obj.client.uuid')"
            if ! panel_client_links "$p"; then
                _d_fail "client $p: no share link ($API_MSG)"
                continue
            fi
            link="$(api_obj '(.obj // [])[0] // empty')"
            if [[ -z "$link" ]]; then
                _d_fail "client $p: the panel returned no share link (client not attached to an enabled inbound? try: sudo vless-reality repair)"
                continue
            fi
            problems="$(link_validate "$link" "$uuid" || true)"
            if [[ -z "$problems" ]]; then _d_pass "client $p: share link consistent"; else
                while IFS= read -r q; do _d_fail "client $p: $q"; done <<<"$problems"
            fi
        done < <(jq -r '(.clients // [])[].email' "$(state_file)")
        ((n > 0)) || _d_warn "no clients recorded"
    fi

    printf '\nSecurity hygiene\n'
    local perm
    perm="$(stat -c '%a' "$(state_file)" 2>/dev/null || echo '?')"
    if [[ "$perm" == "600" ]]; then _d_pass "state file permissions 600"; else _d_fail "state file permissions are $perm (expected 600)"; fi
    perm="$(stat -c '%a' "$VRI_STATE_DIR" 2>/dev/null || echo '?')"
    if [[ "$perm" == "700" ]]; then _d_pass "state directory permissions 700"; else _d_fail "state directory permissions are $perm (expected 700)"; fi
    if [[ -e "$VRI_STATE_DIR/api-token" ]]; then
        perm="$(stat -c '%a' "$VRI_STATE_DIR/api-token")"
        if [[ "$perm" == "600" ]]; then _d_pass "API token file permissions 600"; else _d_fail "API token file permissions are $perm (expected 600)"; fi
    fi

    printf '\nSummary: %d failure(s), %d warning(s)\n' "$DIAG_FAILS" "$DIAG_WARNS"
    ((DIAG_FAILS == 0))
}
