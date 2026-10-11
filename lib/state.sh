#!/usr/bin/env bash
# shellcheck shell=bash
# state.sh - wrapper state under /etc/vless-reality-installer (root:root, dir 0700, files 0600). Atomic writes.
# State identifies OUR resources (inbound id/tag/remark, clients, firewall rules) so we never touch anything else.

# Globals populated by state_load
MODE="" PORT="" SERVER_ADDR="" INBOUND_ID="" INBOUND_TAG=""
PANEL_BY_US="false" STATE_API_TOKEN_ID=""

state_file() { printf '%s/state.json' "$VRI_STATE_DIR"; }

state_dir_init() {
    if [[ ! -d "$VRI_STATE_DIR" ]]; then
        (umask 077 && mkdir -p "$VRI_STATE_DIR") || die "cannot create $VRI_STATE_DIR" "$VRI_EX_ENV"
    fi
    chmod 700 "$VRI_STATE_DIR"
}

state_exists() {
    local f
    f="$(state_file)"
    [[ -s "$f" ]] && jq -e 'type == "object"' "$f" >/dev/null 2>&1
}

# A state file is proof of this project only when it has the complete schema
# needed to reconstruct the managed VLESS REALITY inbound safely.
state_is_complete() {
    local f
    f="$(state_file)"
    state_exists && jq -e '
        .schema == 1
        and (.wrapper_version | type == "string" and length > 0)
        and (.mode == "tcp" or .mode == "grpc" or .mode == "xhttp")
        and (.server_address | type == "string" and length > 0)
        and (.panel | type == "object")
        and (.inbound | type == "object")
        and (.inbound.id | type == "number")
        and (.inbound.port | type == "number")
        and (.inbound.tag | type == "string" and length > 0)
        and (.inbound.remark | type == "string" and startswith("BlueSoftKeys-Reality-"))
        and (.reality | type == "object")
        and (.reality.target | type == "string" and length > 0)
        and (.reality.sni | type == "string" and length > 0)
        and (.reality.private_key | type == "string" and length > 0)
        and (.reality.public_key | type == "string" and length > 0)
        and (.reality.short_id | type == "string" and length > 0)
        and (.mode_opts | type == "object")
        and (.clients | type == "array")
    ' "$f" >/dev/null 2>&1
}

state_require() {
    state_exists || die "no BlueSoftKeys-managed VLESS REALITY setup found (state: $(state_file)). Run: sudo vless-reality install" "$VRI_EX_STATE"
    state_load
}

# state_get '<jq filter>'  -> raw string
state_get() { jq -r "$1" "$(state_file)"; }

# Atomically replace the state with the output of a jq program applied to the current state (or to `null` if none).
# usage: state_update '<jq program>' [jq args...]
state_update() {
    local prog="$1" f tmp
    shift
    state_dir_init
    f="$(state_file)"
    tmp="$(mktemp "$VRI_STATE_DIR/.state.XXXXXX")" || return 1
    if [[ -s "$f" ]]; then
        jq "$@" "$prog" "$f" >"$tmp"
    else
        jq -n "$@" "null | $prog" >"$tmp"
    fi || {
        rm -f "$tmp"
        return 1
    }
    chmod 600 "$tmp"
    mv -f "$tmp" "$f"
}

# Load the well-known fields into shell globals.
state_load() {
    local -a v=()
    mapfile -t v < <(jq -r '
        (.mode // ""), (.inbound.port // ""), (.server_address // ""), (.inbound.id // ""), (.inbound.tag // ""),
        (.reality.target // ""), (.reality.sni // ""), (.reality.private_key // ""), (.reality.public_key // ""),
        (.reality.short_id // ""), (.reality.fingerprint // "chrome"), (.mode_opts // {} | tojson),
        (.panel.installed_by_us // false | tostring), (.api_token_id // "" | tostring)' "$(state_file)")
    MODE="${v[0]}" PORT="${v[1]}" SERVER_ADDR="${v[2]}" INBOUND_ID="${v[3]}" INBOUND_TAG="${v[4]}"
    R_TARGET="${v[5]}" R_SNI="${v[6]}" R_PRIV="${v[7]}" R_PUB="${v[8]}" R_SID="${v[9]}" R_FINGERPRINT="${v[10]}"
    MODE_OPTS_JSON="${v[11]}" PANEL_BY_US="${v[12]}" STATE_API_TOKEN_ID="${v[13]}"
    [[ -n "$R_PRIV" ]] && vri_secret_add "$R_PRIV"
    return 0
}

# Write the complete initial state after a successful provisioning.
state_create() {
    local upstream_ver xray_ver
    upstream_ver="$(upstream_version || echo unknown)"
    xray_ver="$(upstream_xray_version || echo unknown)"
    state_update '{
        schema: 1, wrapper_version: $wv, installed_at: $now, updated_at: $now,
        panel: {installed_by_us: ($by_us == "true"), version: $uv, xray_version: $xv},
        mode: $mode, server_address: $addr, api_token_id: $tid,
        inbound: {id: $iid, tag: $itag, remark: $remark, port: $port},
        reality: {target: $target, sni: $sni, private_key: $priv, public_key: $pub, short_id: $sid, fingerprint: $fp},
        mode_opts: $opts, clients: [], firewall: {ufw_rules: []}
    }' \
        --arg wv "$VRI_VERSION" --arg now "$(vri_now_iso)" --arg by_us "$PANEL_BY_US" --arg uv "$upstream_ver" --arg xv "$xray_ver" \
        --arg mode "$MODE" --arg addr "$SERVER_ADDR" --arg tid "${API_TOKEN_ID:-}" \
        --argjson iid "$INBOUND_ID" --arg itag "$INBOUND_TAG" --arg remark "$(mode_remark "$MODE")" --argjson port "$PORT" \
        --arg target "$R_TARGET" --arg sni "$R_SNI" --arg priv "$R_PRIV" --arg pub "$R_PUB" --arg sid "$R_SID" --arg fp "$R_FINGERPRINT" \
        --argjson opts "$MODE_OPTS_JSON"
}

state_touch() { state_update '.updated_at = $now | .wrapper_version = $wv' --arg now "$(vri_now_iso)" --arg wv "$VRI_VERSION"; }

state_client_upsert() { # email uuid flow enabled(true|false)
    state_update '
        .clients = ((.clients // []) | map(select(.email != $e)) + [{email: $e, uuid: $u, flow: $f, enabled: ($en == "true")}])
        | .updated_at = $now' \
        --arg e "$1" --arg u "$2" --arg f "$3" --arg en "$4" --arg now "$(vri_now_iso)"
}

state_client_remove() {
    state_update '.clients = ((.clients // []) | map(select(.email != $e))) | .updated_at = $now' \
        --arg e "$1" --arg now "$(vri_now_iso)"
}

state_has_client() { # email
    [[ "$(jq -r --arg e "$1" '[(.clients // [])[] | select(.email == $e)] | length' "$(state_file)")" != "0" ]]
}

state_fw_record() { # rule e.g. 443/tcp
    state_update '.firewall.ufw_rules = (((.firewall.ufw_rules // []) + [$r]) | unique)' --arg r "$1"
}

state_fw_forget() {
    state_update '.firewall.ufw_rules = ((.firewall.ufw_rules // []) | map(select(. != $r)))' --arg r "$1"
}
