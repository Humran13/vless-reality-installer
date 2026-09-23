#!/usr/bin/env bash
# shellcheck shell=bash
# mode_xhttp.sh - VLESS + XHTTP + REALITY. Advanced XHTTP knobs stay at upstream defaults. No flow: Vision over XHTTP
# requires VLESS encryption (vlessenc), which this wrapper deliberately does not enable (see docs/upstream-research.md).

mode_xhttp_label() { echo "XHTTP + REALITY"; }
mode_xhttp_note() { echo "XHTTP transport (mode auto) with a random path; no XTLS flow."; }
mode_xhttp_network() { echo "xhttp"; }
mode_xhttp_flow() { echo ""; }

mode_xhttp_defaults() {
    local path="${OPT_XHTTP_PATH:-}"
    [[ -n "$path" ]] || path="/$(vri_random_alnum 12)"
    MODE_OPTS_JSON="$(jq -n --arg p "$path" '{path: $p, mode: "auto"}')"
}

mode_xhttp_prompt() {
    local cur p
    cur="$(jq -r '.path' <<<"$MODE_OPTS_JSON")"
    if [[ -z "${OPT_XHTTP_PATH:-}" ]]; then
        vri_ask p "XHTTP path" "$cur"
        OPT_XHTTP_PATH="$p"
        mode_xhttp_defaults
    fi
}

mode_xhttp_validate() {
    local p
    p="$(jq -r '.path // ""' <<<"$MODE_OPTS_JSON")"
    valid_xhttp_path "$p" || {
        log_err "invalid XHTTP path '$p' (must start with /, only letters, digits, . _ ~ - /, max 128 chars)"
        return 1
    }
}

mode_xhttp_stream_json() {
    jq -n --argjson o "$MODE_OPTS_JSON" \
        '{network: "xhttp", xhttpSettings: {path: $o.path, host: "", mode: $o.mode}}'
}

mode_xhttp_check_stream() {
    local f="$1" want
    want="$(jq -r '.path' <<<"$MODE_OPTS_JSON")"
    [[ "$(jq -r '.network // ""' "$f")" == "xhttp" ]] || echo "inbound network is not xhttp"
    [[ "$(jq -r '.xhttpSettings.path // ""' "$f")" == "$want" ]] || echo "xhttp path differs from recorded value"
}

mode_xhttp_check_link() {
    local want wmode
    want="$(jq -r '.path' <<<"$MODE_OPTS_JSON")"
    wmode="$(jq -r '.mode' <<<"$MODE_OPTS_JSON")"
    [[ "${LINK_P[path]:-}" == "$want" ]] || echo "path '${LINK_P[path]:-}' != '$want'"
    [[ "${LINK_P[mode]:-}" == "$wmode" ]] || echo "mode '${LINK_P[mode]:-}' != '$wmode'"
}

mode_xhttp_extract_opts() { jq -c '{path: (.xhttpSettings.path // "/"), mode: (.xhttpSettings.mode // "auto")}' "$1"; }
