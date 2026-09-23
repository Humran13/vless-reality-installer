#!/usr/bin/env bash
# shellcheck shell=bash
# client.sh - client management restricted to OUR managed inbound. All operations go through the official panel API.
# Requires state_load + api configured.

# jq program: whitelisted full-client payload for /clients/update (partial bodies wipe fields such as `flow`; the raw
# record cannot be echoed back either: `id` must be the UUID string and allowedIPs has a different type).
# shellcheck disable=SC2016 # $en is a jq variable, not a shell one
CLIENT_UPDATE_JQ='.obj.client | {id: .uuid, email, subId, flow, limitIp, limitHwid, totalGB, expiryTime, enable: $en, tgId, group, comment, reset, resetDay, resetMax, trafficReset, trafficResetDay}'

# Fetch client NAME (must be attached to our inbound). Leaves the response in $API_OUT.
client_fetch() {
    local name="$1"
    valid_client_name "$name" || die "invalid client name '$name' (allowed: letters, digits, . _ - ; max 64; must start alphanumeric)" "$VRI_EX_USAGE"
    panel_client_get "$name" || die "client '$name' not found ($API_MSG)" "$VRI_EX_STATE"
    jq -e --argjson id "$INBOUND_ID" '.obj.inboundIds // [] | index($id) != null' "$API_OUT" >/dev/null ||
        die "client '$name' exists but is not attached to the BlueSoftKeys inbound; refusing to touch it" "$VRI_EX_STATE"
}

client_next_default_name() {
    local i=1 existing
    panel_clients_list || die "cannot list clients: $API_MSG" "$VRI_EX_API"
    existing="$(api_obj '[.obj[].email] | join("\n")')"
    while grep -qxF "BlueSoftKeys-Client-$i" <<<"$existing"; do i=$((i + 1)); done
    printf 'BlueSoftKeys-Client-%s' "$i"
}

# client_create NAME [EXPIRE_DAYS] [QUOTA_GB]
client_create() {
    local name="$1" days="${2:-0}" gb="${3:-0}" flow body expiry=0 bytes=0 uuid
    valid_client_name "$name" || die "invalid client name '$name' (allowed: letters, digits, . _ - ; max 64; must start alphanumeric)" "$VRI_EX_USAGE"
    valid_nonneg_int "$days" || die "invalid --expire-days '$days'" "$VRI_EX_USAGE"
    valid_nonneg_int "$gb" || die "invalid --quota-gb '$gb'" "$VRI_EX_USAGE"
    ((days > 0)) && expiry=$((($(date +%s) + days * 86400) * 1000))
    ((gb > 0)) && bytes=$((gb * 1073741824))
    flow="$(mode_call "$MODE" flow)"

    # idempotency: a client with this name may already be ours
    if panel_client_get "$name"; then
        uuid="$(api_obj '.obj.client.uuid')"
        if jq -e --argjson id "$INBOUND_ID" '.obj.inboundIds // [] | index($id) != null' "$API_OUT" >/dev/null; then
            log_info "client '$name' already exists; nothing to do"
            state_client_upsert "$name" "$uuid" "$flow" "$(api_obj '.obj.client.enable')" || true
            return 0
        fi
        # An orphan left behind by a deleted inbound that we created earlier: re-attach instead of duplicating.
        if jq -e '(.obj.inboundIds // []) | length == 0' "$API_OUT" >/dev/null &&
            { [[ "$(api_obj '.obj.client.comment // ""')" == "BlueSoftKeys" ]] || state_has_client "$name"; }; then
            panel_client_attach "$name" "$INBOUND_ID" || die "could not re-attach existing client '$name': $API_MSG" "$VRI_EX_API"
            log_ok "Re-attached existing client: $name"
            client_ensure_flow "$name" || true
            state_client_upsert "$name" "$uuid" "$flow" true || true
            return 0
        fi
        die "a panel client named '$name' already exists outside the BlueSoftKeys inbound; choose another name" "$VRI_EX_STATE"
    fi

    body="$(vri_mktemp client)"
    jq -n --arg e "$name" --arg f "$flow" --argjson total "$bytes" --argjson exp "$expiry" --argjson iid "$INBOUND_ID" \
        '{client: {email: $e, flow: $f, enable: true, totalGB: $total, expiryTime: $exp, limitIp: 0, tgId: 0, comment: "BlueSoftKeys"}, inboundIds: [$iid]}' >"$body"
    panel_client_add "$body" || die "could not create client '$name': $API_MSG" "$VRI_EX_API"
    panel_client_get "$name" || die "client '$name' was created but cannot be read back: $API_MSG" "$VRI_EX_API"
    uuid="$(api_obj '.obj.client.uuid')"
    valid_uuid "$uuid" || die "panel returned an invalid UUID for client '$name'" "$VRI_EX_API"
    # the panel applies flow gating itself; make sure it stored what this mode requires
    [[ "$(api_obj '.obj.client.flow // ""')" == "$flow" ]] ||
        log_warn "panel stored flow '$(api_obj '.obj.client.flow // ""')' for '$name' (expected '${flow:-<none>}')"
    state_client_upsert "$name" "$uuid" "$flow" true || log_warn "could not update local state"
    log_ok "Client created: $name"
}

# Make sure client NAME carries the flow required by the current mode (re-attaching a client to a new inbound drops it).
client_ensure_flow() {
    local name="$1" want body have en
    want="$(mode_call "$MODE" flow)"
    panel_client_get "$name" || return 1
    have="$(api_obj '.obj.client.flow // ""')"
    [[ "$have" == "$want" ]] && return 0
    en="$(api_obj '.obj.client.enable')"
    body="$(vri_mktemp cflow)"
    jq --argjson en "$en" --arg flow "$want" "$CLIENT_UPDATE_JQ | .flow = \$flow" "$API_OUT" >"$body"
    panel_client_update "$name" "$body" || {
        log_warn "could not set flow on '$name': $API_MSG"
        return 1
    }
    log_debug "restored flow '${want:-<none>}' on client $name"
}

client_set_enabled() { # NAME true|false
    local name="$1" en="$2" body
    client_fetch "$name"
    body="$(vri_mktemp cupd)"
    jq --argjson en "$en" "$CLIENT_UPDATE_JQ" "$API_OUT" >"$body"
    panel_client_update "$name" "$body" || die "could not update client '$name': $API_MSG" "$VRI_EX_API"
    # verify: enable flipped and flow preserved
    panel_client_get "$name" || die "cannot read back client '$name': $API_MSG" "$VRI_EX_API"
    [[ "$(api_obj '.obj.client.enable')" == "$en" ]] || die "panel did not apply enable=$en for '$name'" "$VRI_EX_API"
    state_client_upsert "$name" "$(api_obj '.obj.client.uuid')" "$(api_obj '.obj.client.flow // ""')" "$en" || true
    if [[ "$en" == "true" ]]; then log_ok "Client enabled: $name"; else log_ok "Client disabled: $name"; fi
}

client_remove() {
    local name="$1"
    client_fetch "$name"
    panel_client_del "$name" || die "could not remove client '$name': $API_MSG" "$VRI_EX_API"
    state_client_remove "$name" || true
    log_ok "Client removed: $name"
}

# Print the share link for NAME on stdout. Validation problems (if any) go to stderr; return 1 if invalid.
client_link() {
    local name="$1" link uuid problems rc=0
    client_fetch "$name"
    uuid="$(api_obj '.obj.client.uuid')"
    panel_client_links "$name" || die "could not get share link for '$name': $API_MSG" "$VRI_EX_API"
    link="$(api_obj '(.obj // [])[0] // empty')"
    [[ -n "$link" ]] || die "the panel returned no share link for '$name' (is the inbound enabled?)" "$VRI_EX_API"
    problems="$(link_validate "$link" "$uuid")" || rc=1
    if ((rc)); then
        log_warn "share link for '$name' does not match the recorded configuration:"
        while IFS= read -r p; do log_warn "  - $p"; done <<<"$problems"
    fi
    printf '%s\n' "$link"
    return "$rc"
}

client_qr() {
    local name="$1" link
    if ! vri_have qrencode; then
        log_warn "qrencode is not installed. Install it with: sudo apt-get install -y qrencode"
        return 1
    fi
    link="$(client_link "$name")" || true
    [[ -n "$link" ]] || return 1
    qrencode -t ANSIUTF8 -m 1 "$link" || {
        log_warn "QR rendering failed (the link itself is still valid)"
        return 1
    }
}

human_bytes() {
    local b="${1:-0}"
    if ((b >= 1073741824)); then printf '%d.%02d GB' $((b / 1073741824)) $(((b % 1073741824) * 100 / 1073741824))
    elif ((b >= 1048576)); then printf '%d MB' $((b / 1048576))
    else printf '%d KB' $((b / 1024)); fi
}

client_list() {
    panel_clients_list || die "cannot list clients: $API_MSG" "$VRI_EX_API"
    local rows name en flow uuid used total exp expfmt totfmt
    rows="$(jq -c --argjson id "$INBOUND_ID" '.obj[] | select((.inboundIds // []) | index($id) != null)' "$API_OUT")"
    printf '%-28s %-9s %-18s %-10s %-12s %-12s %s\n' NAME STATUS FLOW USED QUOTA EXPIRES UUID
    [[ -n "$rows" ]] || return 0
    while IFS= read -r row; do
        name="$(jq -r '.email' <<<"$row")"
        en="$(jq -r '.enable' <<<"$row")"
        flow="$(jq -r '.flow // ""' <<<"$row")"
        uuid="$(jq -r '.uuid' <<<"$row")"
        used="$(jq -r '((.traffic.up // 0) + (.traffic.down // 0))' <<<"$row")"
        total="$(jq -r '.totalGB // 0' <<<"$row")"
        exp="$(jq -r '.expiryTime // 0' <<<"$row")"
        totfmt="unlimited"
        ((total > 0)) && totfmt="$(human_bytes "$total")"
        expfmt="never"
        ((exp > 0)) && expfmt="$(date -u -d "@$((exp / 1000))" +%Y-%m-%d 2>/dev/null || echo "$exp")"
        printf '%-28s %-9s %-18s %-10s %-12s %-12s %s\n' "$name" "$([[ "$en" == "true" ]] && echo enabled || echo disabled)" "${flow:--}" "$(human_bytes "$used")" "$totfmt" "$expfmt" "$uuid"
    done <<<"$rows"
}
