#!/usr/bin/env bash
# shellcheck shell=bash
# validate.sh - strict input validators. Every function returns 0 (valid) / 1 (invalid) and prints nothing.
# All user-supplied values that reach JSON, URLs, shell or the panel API pass through these first.

valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
    local p=$((10#$1))
    ((p >= 1 && p <= 65535))
}

valid_ipv4() {
    local ip="${1:-}" o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $ip; do
        ((10#$o <= 255)) || return 1
    done
}

# RFC 1123 hostname (labels 1-63 chars, total <= 253), must contain at least one dot unless "localhost"-like single label allowed.
valid_hostname() {
    local h="${1:-}"
    ((${#h} >= 1 && ${#h} <= 253)) || return 1
    [[ "$h" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || return 1
    # an all-numeric dotted string is an IP, not a hostname
    [[ "$h" =~ ^[0-9.]+$ ]] && return 1
    return 0
}

# Address clients connect to: IPv4 or DNS name.
valid_server_address() {
    valid_ipv4 "$1" || valid_hostname "$1"
}

# SNI must be a DNS hostname with a dot (IP literals are not valid SNI values).
valid_sni() {
    valid_hostname "${1:-}" && [[ "$1" == *.* ]]
}

# host:port (default port must be given explicitly here); host is a DNS name with a dot (REALITY targets are real sites).
valid_target() {
    local t="${1:-}" host port
    [[ "$t" =~ ^[^:]+:[0-9]+$ ]] || return 1
    host="${t%:*}"
    port="${t##*:}"
    valid_sni "$host" && valid_port "$port"
}

valid_mode() {
    local m
    for m in "${VRI_MODES[@]}"; do
        [[ "${1:-}" == "$m" ]] && return 0
    done
    return 1
}

# Client display name / panel email. Conservative: starts alnum, then [A-Za-z0-9._-], max 64.
valid_client_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# gRPC serviceName: letters, digits, '_', '.', '-'; 1-64 chars, must start alnum/underscore.
valid_grpc_service() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]
}

# XHTTP path: starts with '/', URL-path-safe characters only, no '//', no query/fragment, <= 128 chars.
valid_xhttp_path() {
    local p="${1:-}"
    ((${#p} >= 1 && ${#p} <= 128)) || return 1
    [[ "$p" =~ ^/[A-Za-z0-9._~/-]*$ ]] || return 1
    [[ "$p" == *//* ]] && return 1
    [[ "$p" == *..* ]] && return 1
    return 0
}

valid_uuid() {
    [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# REALITY short id: even number of hex chars, 2..16
valid_shortid() {
    [[ "${1:-}" =~ ^([0-9a-f]{2}){1,8}$ ]]
}

# X25519 key in unpadded base64url (32 bytes -> 43 chars)
valid_reality_key() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

# Stable upstream tag: vMAJOR.MINOR.PATCH only (rejects dev-latest, dev, pre-release suffixes).
valid_stable_tag() {
    [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

valid_positive_int() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,8}$ ]]
}

valid_nonneg_int() {
    [[ "${1:-}" =~ ^(0|[1-9][0-9]{0,8})$ ]]
}
