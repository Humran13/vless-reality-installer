#!/usr/bin/env bash
# shellcheck shell=bash
# mode_grpc.sh - VLESS + gRPC + REALITY. No XTLS flow (Vision is not supported over gRPC).

mode_grpc_label() { echo "gRPC + REALITY"; }
mode_grpc_note() { echo "gRPC transport with a random service name; no XTLS flow."; }
mode_grpc_network() { echo "grpc"; }
mode_grpc_flow() { echo ""; }

mode_grpc_defaults() {
    local svc="${OPT_GRPC_SERVICE_NAME:-}"
    [[ -n "$svc" ]] || svc="svc$(vri_random_alnum 10)"
    MODE_OPTS_JSON="$(jq -n --arg s "$svc" '{service_name: $s}')"
}

mode_grpc_prompt() {
    local cur svc
    cur="$(jq -r '.service_name' <<<"$MODE_OPTS_JSON")"
    if [[ -z "${OPT_GRPC_SERVICE_NAME:-}" ]]; then
        vri_ask svc "gRPC service name" "$cur"
        OPT_GRPC_SERVICE_NAME="$svc"
        mode_grpc_defaults
    fi
}

mode_grpc_validate() {
    local svc
    svc="$(jq -r '.service_name // ""' <<<"$MODE_OPTS_JSON")"
    valid_grpc_service "$svc" || {
        log_err "invalid gRPC service name '$svc' (allowed: letters, digits, _ . - ; 1-64 chars)"
        return 1
    }
}

mode_grpc_stream_json() {
    jq -n --argjson o "$MODE_OPTS_JSON" \
        '{network: "grpc", grpcSettings: {serviceName: $o.service_name, authority: "", multiMode: false}}'
}

mode_grpc_check_stream() {
    local f="$1" want
    want="$(jq -r '.service_name' <<<"$MODE_OPTS_JSON")"
    [[ "$(jq -r '.network // ""' "$f")" == "grpc" ]] || echo "inbound network is not grpc"
    [[ "$(jq -r '.grpcSettings.serviceName // ""' "$f")" == "$want" ]] || echo "grpc serviceName differs from recorded value"
}

mode_grpc_check_link() {
    local want
    want="$(jq -r '.service_name' <<<"$MODE_OPTS_JSON")"
    [[ "${LINK_P[serviceName]:-}" == "$want" ]] || echo "serviceName '${LINK_P[serviceName]:-}' != '$want'"
}

mode_grpc_extract_opts() { jq -c '{service_name: (.grpcSettings.serviceName // "")}' "$1"; }
