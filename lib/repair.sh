#!/usr/bin/env bash
# shellcheck shell=bash
# repair.sh - repair ONLY what belongs to this wrapper and is demonstrably broken. Never reinstalls or resets 3X-UI.
# Requires: state_load done, API session initialised.

REPAIR_ACTIONS=0

_repair_note() {
    REPAIR_ACTIONS=$((REPAIR_ACTIONS + 1))
    log_ok "repaired: $*"
}

# Print one problem per line when the panel's inbound JSON (file $1) deviates from recorded state.
repair_inbound_problems() {
    local f="$1" sf want got
    sf="$(vri_mktemp rstream)"
    jq -c '.streamSettings | if type == "string" then fromjson else . end' "$f" >"$sf"
    [[ "$(jq -r '.enable' "$f")" == "true" ]] || echo "inbound is disabled"
    [[ "$(jq -r '.protocol' "$f")" == "vless" ]] || echo "inbound protocol is not vless"
    [[ "$(jq -r '.port' "$f")" == "$PORT" ]] || echo "inbound port $(jq -r '.port' "$f") != recorded $PORT"
    [[ "$(jq -r '.shareAddr // ""' "$f")" == "$SERVER_ADDR" ]] || echo "share address differs from recorded server address"
    [[ "$(jq -r '.security // ""' "$sf")" == "reality" ]] || echo "stream security is not reality"
    got="$(jq -r '.realitySettings.target // .realitySettings.dest // ""' "$sf")"
    [[ "$got" == "$R_TARGET" ]] || echo "REALITY target differs"
    [[ "$(jq -r '.realitySettings.serverNames[0] // ""' "$sf")" == "$R_SNI" ]] || echo "REALITY serverNames differ"
    [[ "$(jq -r '.realitySettings.privateKey // ""' "$sf")" == "$R_PRIV" ]] || echo "REALITY private key differs from recorded key"
    [[ "$(jq -r '.realitySettings.settings.publicKey // ""' "$sf")" == "$R_PUB" ]] || echo "REALITY public key differs"
    [[ "$(jq -r '.realitySettings.shortIds[0] // ""' "$sf")" == "$R_SID" ]] || echo "REALITY short id differs"
    want="$(mode_call "$MODE" check_stream "$sf" || true)"
    [[ -z "$want" ]] || printf '%s\n' "$want"
}

# Recreate the inbound (and its clients) from state when it vanished from the panel.
_repair_recreate_inbound() {
    local body
    body="$(vri_mktemp rinbound)"
    inbound_build_json >"$body"
    panel_inbound_add "$body" || die "cannot recreate the inbound: $API_MSG" "$VRI_EX_API"
    INBOUND_ID="$(api_obj '.obj.id')"
    INBOUND_TAG="$(api_obj '.obj.tag')"
    state_update '.inbound.id = $id | .inbound.tag = $tag' --argjson id "$INBOUND_ID" --arg tag "$INBOUND_TAG"
    _repair_note "recreated the managed inbound (id $INBOUND_ID) from saved state"
}

# Add any recorded client that is missing from the panel (same UUID, so existing client links keep working).
_repair_clients() {
    local row email uuid flow en body
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        email="$(jq -r '.email' <<<"$row")"
        uuid="$(jq -r '.uuid' <<<"$row")"
        flow="$(jq -r '.flow // ""' <<<"$row")"
        en="$(jq -r '.enabled' <<<"$row")"
        if panel_client_get "$email"; then
            if jq -e --argjson id "$INBOUND_ID" '.obj.inboundIds // [] | index($id) != null' "$API_OUT" >/dev/null; then
                if [[ "$(api_obj '.obj.client.flow // ""')" != "$(mode_call "$MODE" flow)" ]]; then
                    client_ensure_flow "$email" && _repair_note "restored the flow of client $email"
                fi
                continue
            fi
            # record exists but is not attached to our inbound (typically orphaned by a deleted inbound)
            if jq -e '(.obj.inboundIds // []) | length == 0' "$API_OUT" >/dev/null; then
                if panel_client_attach "$email" "$INBOUND_ID"; then
                    client_ensure_flow "$email" || true
                    _repair_note "re-attached client $email"
                else
                    log_warn "could not re-attach client $email: $API_MSG"
                fi
            else
                log_warn "client $email exists on other inbounds only; leaving it alone"
            fi
            continue
        fi
        body="$(vri_mktemp rclient)"
        jq -n --arg e "$email" --arg u "$uuid" --arg f "$flow" --argjson en "$en" --argjson iid "$INBOUND_ID" \
            '{client: {id: $u, email: $e, flow: $f, enable: $en, totalGB: 0, expiryTime: 0, limitIp: 0, tgId: 0, comment: "BlueSoftKeys"}, inboundIds: [$iid]}' >"$body"
        if panel_client_add "$body"; then
            _repair_note "re-created client $email"
        else
            log_warn "could not re-create client $email: $API_MSG"
        fi
    done < <(jq -c '(.clients // [])[]' "$(state_file)")
}

# Start x-ui when it is stopped (must happen before we can talk to the API). Counts as a repair action.
repair_ensure_service() {
    if upstream_service_active; then
        return 0
    fi
    log_info "x-ui service is not running; starting it"
    systemctl start "$UPSTREAM_SERVICE" || die "cannot start x-ui (see: journalctl -u x-ui -n 50)" "$VRI_EX_UPSTREAM"
    _repair_note "started the x-ui service"
}

# Full session for `repair`: service first, then wait for the API and a valid token.
repair_session_init() {
    local i
    repair_ensure_service
    api_configure || die "cannot determine the panel URL" "$VRI_EX_API"
    for ((i = 0; i < 60; i++)); do
        api_acquire_token && return 0
        sleep 1
    done
    die "the panel API did not become usable: ${API_MSG:-unknown error}" "$VRI_EX_API"
}

# repair_run [quiet]
repair_run() {
    local quiet="${1:-}" f problems fixbody
    [[ "$quiet" == "quiet" ]] || log_step "Inspecting the BlueSoftKeys installation"
    # REPAIR_ACTIONS may already count a service start done by repair_session_init
    if ! upstream_service_active; then
        repair_ensure_service
        api_wait_ready 60 || die "x-ui started but the API is not ready: $API_MSG" "$VRI_EX_UPSTREAM"
    fi

    # dedicated API token (so we survive install-result.env being removed)
    if [[ "$API_TOKEN_SOURCE" != "file" ]]; then
        api_ensure_own_token
        if [[ -n "$API_TOKEN_ID" ]]; then
            state_update '.api_token_id = $id' --arg id "$API_TOKEN_ID" || true
            _repair_note "created a dedicated API token"
        fi
    fi

    # inbound
    f="$(vri_mktemp rinb)"
    if panel_inbound_get "$INBOUND_ID" && [[ "$(api_obj '.obj.remark // ""')" == "$(mode_remark "$MODE")" ]]; then
        jq '.obj' "$API_OUT" >"$f"
    else
        local found
        found="$(install_find_our_inbound)"
        if [[ -n "$found" ]]; then
            INBOUND_ID="$(jq -r '.id' <<<"$found")"
            INBOUND_TAG="$(jq -r '.tag' <<<"$found")"
            state_update '.inbound.id = $id | .inbound.tag = $tag' --argjson id "$INBOUND_ID" --arg tag "$INBOUND_TAG"
            jq -c . <<<"$found" >"$f"
        else
            _repair_recreate_inbound
            panel_inbound_get "$INBOUND_ID" || die "recreated inbound cannot be read: $API_MSG" "$VRI_EX_API"
            jq '.obj' "$API_OUT" >"$f"
        fi
    fi
    problems="$(repair_inbound_problems "$f")"
    if [[ -n "$problems" ]]; then
        while IFS= read -r p; do log_warn "inbound: $p"; done <<<"$problems"
        fixbody="$(vri_mktemp rfix)"
        # patch only the fields we own; keep everything else (incl. the attached clients) exactly as it is
        jq --argjson new "$(inbound_build_json)" \
            '.enable = true | .port = $new.port | .shareAddrStrategy = "custom" | .shareAddr = $new.shareAddr | .streamSettings = $new.streamSettings' "$f" >"$fixbody"
        if panel_inbound_update "$INBOUND_ID" "$fixbody"; then
            _repair_note "reset the managed inbound to the recorded configuration"
        else
            die "could not repair the inbound: $API_MSG" "$VRI_EX_API"
        fi
    fi

    _repair_clients

    if fw_ufw_active && ! fw_rule_exists "$PORT"; then
        fw_open_port "$PORT"
        _repair_note "restored the UFW rule for $PORT/tcp"
    fi

    if [[ "$(panel_xray_state)" != "running" ]]; then
        log_info "Xray is not running; asking the panel to restart it"
        panel_restart_xray || log_warn "restart failed: $API_MSG"
        _repair_note "restarted Xray"
    fi
    if ! net_port_listening "$PORT"; then
        install_wait_listening || log_warn "Xray still is not listening on TCP $PORT (run: sudo vless-reality diagnostics)"
    fi

    if [[ -x "$VRI_HOME/bin/vless-reality" && "$(readlink "$VRI_BIN_LINK" 2>/dev/null || true)" != "$VRI_HOME/bin/vless-reality" ]]; then
        ln -sfn "$VRI_HOME/bin/vless-reality" "$VRI_BIN_LINK" && _repair_note "restored $VRI_BIN_LINK"
    fi

    if ((REPAIR_ACTIONS == 0)); then
        [[ "$quiet" == "quiet" ]] || log_ok "Nothing to repair - everything managed by this wrapper is healthy"
    else
        state_touch || true
    fi
    return 0
}
