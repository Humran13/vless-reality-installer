#!/usr/bin/env bash
# shellcheck shell=bash
# reality.sh - REALITY keys, short ids and target/SNI validation. Cryptography is done by the panel's bundled Xray
# (official endpoint); we never implement crypto ourselves.

# Small, fixed list of well-known TLS1.3/h2 sites. Each is *validated from this VPS* before use; nothing is scanned
# beyond these and any user-supplied target.
REALITY_CANDIDATES=(www.microsoft.com:443 www.apple.com:443 dl.google.com:443 www.cloudflare.com:443)

R_PRIV="" R_PUB="" R_SID="" R_TARGET="" R_SNI="" SCAN_REASON=""
R_FINGERPRINT="chrome"

# Generate an X25519 key pair through the official panel endpoint.
reality_generate_keys() {
    panel_new_keys || die "could not generate REALITY keys via the panel: $API_MSG" "$VRI_EX_API"
    R_PRIV="$(api_obj '.obj.privateKey // empty')"
    R_PUB="$(api_obj '.obj.publicKey // empty')"
    if ! { valid_reality_key "$R_PRIV" && valid_reality_key "$R_PUB"; }; then
        die "panel returned malformed REALITY keys" "$VRI_EX_API"
    fi
    vri_secret_add "$R_PRIV"
}

reality_generate_shortid() {
    R_SID="$(vri_random_hex 8)"
    valid_shortid "$R_SID" || die "failed to generate a REALITY short id" "$VRI_EX_ENV"
}

# Does certificate name $2 (possibly wildcard) cover host $1?
_name_covers() {
    local host="${1,,}" name="${2,,}"
    [[ "$host" == "$name" ]] && return 0
    if [[ "$name" == \*.* ]]; then
        local suffix="${name#\*}"
        [[ "$host" == *"$suffix" && "${host%"$suffix"}" != *.* && -n "${host%"$suffix"}" ]] && return 0
    fi
    return 1
}

# reality_scan HOST:PORT SNI -> 0 if feasible. Sets SCAN_REASON. Uses the panel's official scanner; falls back to openssl.
reality_scan() {
    local target="$1" sni="$2" body names n covered=0
    SCAN_REASON=""
    body="$(vri_mktemp scan)"
    printf 'target=%s&sni=%s' "$target" "$sni" >"$body"
    if api_post_form /panel/api/server/scanRealityTarget "$body"; then
        if [[ "$(api_obj '.obj.feasible // false')" != "true" ]]; then
            SCAN_REASON="$(api_obj '.obj.reason // "target is not suitable (needs TLS 1.3, h2, X25519 and a valid certificate)"')"
            return 1
        fi
        # the scanner verified the certificate for this SNI; make sure the SNI is covered by the SAN list
        names="$(api_obj '(.obj.serverNames // [])[]')"
        if [[ -n "$names" ]]; then
            while IFS= read -r n; do
                _name_covers "$sni" "$n" && covered=1
            done <<<"$names"
            if ((!covered)); then
                SCAN_REASON="SNI '$sni' is not covered by the target's certificate (names: $(printf '%s' "$names" | paste -sd, -))"
                return 1
            fi
        fi
        return 0
    fi
    if [[ "$API_HTTP" == "200" || "$API_HTTP" == "" ]]; then
        # scanner refused (e.g. private address) or transport problem
        SCAN_REASON="${API_MSG:-scan failed}"
        return 1
    fi
    # Panel scanner unavailable in this upstream version: fall back to a direct TLS 1.3 + h2 probe.
    log_warn "panel scanner unavailable ($API_MSG); using an openssl probe"
    if net_tls_probe "${target%:*}" "${target##*:}" "$sni" >/dev/null; then
        return 0
    fi
    SCAN_REASON="TLS 1.3 + h2 probe failed"
    return 1
}

# Choose the target/SNI: user-supplied values are validated strictly; otherwise the first validated candidate wins.
# Inputs: OPT_REALITY_TARGET, OPT_SNI. Sets R_TARGET, R_SNI.
reality_choose_target() {
    local cand host
    if [[ -n "${OPT_REALITY_TARGET:-}" ]]; then
        valid_target "$OPT_REALITY_TARGET" || die "invalid --reality-target '$OPT_REALITY_TARGET' (expected HOST:PORT, e.g. www.microsoft.com:443)" "$VRI_EX_USAGE"
        host="${OPT_REALITY_TARGET%:*}"
        R_TARGET="$OPT_REALITY_TARGET"
        R_SNI="${OPT_SNI:-$host}"
        valid_sni "$R_SNI" || die "invalid --sni '$R_SNI'" "$VRI_EX_USAGE"
        log_info "Validating REALITY target $R_TARGET (SNI $R_SNI) from this server..."
        reality_scan "$R_TARGET" "$R_SNI" || die "REALITY target rejected: $SCAN_REASON" "$VRI_EX_USAGE"
        log_ok "REALITY target OK"
        return 0
    fi
    if [[ -n "${OPT_SNI:-}" ]]; then
        valid_sni "$OPT_SNI" || die "invalid --sni '$OPT_SNI'" "$VRI_EX_USAGE"
        cand="${OPT_SNI}:443"
        log_info "Validating REALITY target $cand ..."
        reality_scan "$cand" "$OPT_SNI" || die "REALITY target rejected: $SCAN_REASON" "$VRI_EX_USAGE"
        R_TARGET="$cand" R_SNI="$OPT_SNI"
        return 0
    fi
    log_info "Selecting a REALITY target (validated from this server)..."
    for cand in "${REALITY_CANDIDATES[@]}"; do
        host="${cand%:*}"
        if reality_scan "$cand" "$host"; then
            R_TARGET="$cand" R_SNI="$host"
            log_ok "REALITY target: $R_TARGET"
            return 0
        fi
        log_debug "candidate $cand rejected: $SCAN_REASON"
    done
    die "none of the built-in REALITY targets is usable from this server. Pick one yourself with --reality-target HOST:PORT (a TLS 1.3 + h2 site)." "$VRI_EX_ENV"
}
