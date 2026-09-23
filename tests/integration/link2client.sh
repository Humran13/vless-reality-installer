#!/usr/bin/env bash
# Convert a vless:// REALITY share link into an Xray client config (SOCKS inbound).
# Usage: link2client.sh 'vless://...' LOCAL_SOCKS_PORT [SERVER_HOST_OVERRIDE] > client.json
# Test helper only. Requires jq.
set -Eeuo pipefail

urldecode() {
    local s="${1//+/ }" out=""
    while [[ "$s" =~ ^([^%]*)%([0-9A-Fa-f]{2})(.*)$ ]]; do
        # shellcheck disable=SC2059
        out+="${BASH_REMATCH[1]}$(printf "\x${BASH_REMATCH[2]}")"
        s="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${s}"
}

link="${1:?vless link required}"
lport="${2:?local socks port required}"
host_override="${3:-}"

rest="${link#vless://}"
uuid="${rest%%@*}"
rest="${rest#*@}"
hostport="${rest%%\?*}"
query="${rest#*\?}"
query="${query%%#*}"
host="${hostport%:*}"
port="${hostport##*:}"
[[ -n "$host_override" ]] && host="$host_override"

declare -A p=()
IFS='&' read -r -a pairs <<< "$query"
for kv in "${pairs[@]}"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    p["$k"]="$(urldecode "$v")"
done

net="${p[type]:-tcp}"
jq -n \
    --arg host "$host" --argjson port "$port" --arg uuid "$uuid" \
    --arg flow "${p[flow]:-}" --arg net "$net" --argjson lport "$lport" \
    --arg sni "${p[sni]:-}" --arg fp "${p[fp]:-chrome}" --arg pbk "${p[pbk]:-}" \
    --arg sid "${p[sid]:-}" --arg spx "${p[spx]:-/}" \
    --arg svc "${p[serviceName]:-}" --arg path "${p[path]:-/}" --arg mode "${p[mode]:-auto}" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{listen: "127.0.0.1", port: $lport, protocol: "socks", settings: {udp: false}}],
      outbounds: [{
        protocol: "vless",
        settings: {vnext: [{address: $host, port: $port, users: [{id: $uuid, encryption: "none", flow: $flow}]}]},
        streamSettings: ({
          network: $net, security: "reality",
          realitySettings: {serverName: $sni, fingerprint: $fp, publicKey: $pbk, shortId: $sid, spiderX: $spx}
        } + (if $net == "grpc" then {grpcSettings: {serviceName: $svc}}
             elif $net == "xhttp" then {xhttpSettings: {path: $path, mode: $mode}}
             else {} end))
      }]
    }'
