#!/usr/bin/env bash
# shellcheck shell=bash
# mode_tcp.sh - VLESS + TCP (Raw) + REALITY + XTLS Vision. Recommended default / maximum compatibility.

mode_tcp_label() { echo "TCP / Raw + REALITY"; }
mode_tcp_note() { echo "XTLS Vision flow; best compatibility and performance."; }
mode_tcp_network() { echo "tcp"; }
mode_tcp_flow() { echo "xtls-rprx-vision"; }
mode_tcp_defaults() { MODE_OPTS_JSON='{}'; }
mode_tcp_prompt() { :; }
mode_tcp_validate() { :; }

mode_tcp_stream_json() {
    jq -n '{network: "tcp", tcpSettings: {header: {type: "none"}}}'
}

mode_tcp_check_stream() { # FILE (streamSettings JSON)
    local f="$1"
    [[ "$(jq -r '.network // ""' "$f")" == "tcp" ]] || echo "inbound network is not tcp"
    [[ "$(jq -r '.tcpSettings.header.type // "none"' "$f")" == "none" ]] || echo "tcp header type is not none"
}

mode_tcp_check_link() { :; }

mode_tcp_extract_opts() { echo '{}'; } # FILE -> opts JSON
