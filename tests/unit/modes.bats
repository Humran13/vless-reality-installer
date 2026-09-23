#!/usr/bin/env bats
# Mode profiles: TCP / gRPC / XHTTP config generation, flows, share-link parsing/validation.

setup() {
    load helpers
    vri_test_env
    load_libs
    PORT=443 SERVER_ADDR=203.0.113.7 R_TARGET=www.microsoft.com:443 R_SNI=www.microsoft.com
    R_PRIV=cE0v7gU-1sXJp1c9bWm6b0Zk4h3v5jQ2n8yL7tDaR1A R_PUB=8Deg1F2LwEHKlZRX-Ba9SaC5PJZwqjvBWm1kxtfETVo
    R_SID=f101ca7165f664c6 R_FINGERPRINT=chrome
}

use_mode() { MODE="$1"; mode_call "$MODE" defaults; }

@test "registry contains exactly the validated REALITY transports" {
    [ "${VRI_MODES[*]}" = "tcp grpc xhttp" ]
}

@test "TCP: network, flow and stream settings" {
    use_mode tcp
    [ "$(mode_call tcp flow)" = "xtls-rprx-vision" ]
    run mode_call tcp stream_json
    [ "$(jq -r .network <<<"$output")" = "tcp" ]
    [ "$(jq -r .tcpSettings.header.type <<<"$output")" = "none" ]
}

@test "gRPC: random service name, NO flow, grpcSettings" {
    use_mode grpc
    svc="$(jq -r .service_name <<<"$MODE_OPTS_JSON")"
    valid_grpc_service "$svc"
    [ "$(mode_call grpc flow)" = "" ]
    run mode_call grpc stream_json
    [ "$(jq -r .network <<<"$output")" = "grpc" ]
    [ "$(jq -r .grpcSettings.serviceName <<<"$output")" = "$svc" ]
    [ "$(jq -r .grpcSettings.multiMode <<<"$output")" = "false" ]
}

@test "gRPC: --grpc-service-name override and validation" {
    OPT_GRPC_SERVICE_NAME=my.svc_1 use_mode grpc
    [ "$(jq -r .service_name <<<"$MODE_OPTS_JSON")" = "my.svc_1" ]
    mode_call grpc validate
    OPT_GRPC_SERVICE_NAME='bad name;id' use_mode grpc
    run mode_call grpc validate
    [ "$status" -ne 0 ]
}

@test "gRPC service names are random per run" {
    use_mode grpc; a="$MODE_OPTS_JSON"; use_mode grpc; b="$MODE_OPTS_JSON"
    [ "$a" != "$b" ]
}

@test "XHTTP: random path, mode auto, NO flow, xhttpSettings" {
    use_mode xhttp
    path="$(jq -r .path <<<"$MODE_OPTS_JSON")"
    valid_xhttp_path "$path"
    [ "$(mode_call xhttp flow)" = "" ]
    run mode_call xhttp stream_json
    [ "$(jq -r .network <<<"$output")" = "xhttp" ]
    [ "$(jq -r .xhttpSettings.path <<<"$output")" = "$path" ]
    [ "$(jq -r .xhttpSettings.mode <<<"$output")" = "auto" ]
    # no vless encryption / vision knobs are injected
    [ "$(jq -r 'has("vlessEncryption")' <<<"$output")" = "false" ]
}

@test "XHTTP: --xhttp-path override and malformed path rejected" {
    OPT_XHTTP_PATH=/my-path use_mode xhttp; mode_call xhttp validate
    OPT_XHTTP_PATH='/a b' use_mode xhttp
    run mode_call xhttp validate; [ "$status" -ne 0 ]
    OPT_XHTTP_PATH='nopath' use_mode xhttp
    run mode_call xhttp validate; [ "$status" -ne 0 ]
}

@test "inbound JSON: REALITY, vless, custom share address, private key only server-side settings" {
    for m in tcp grpc xhttp; do
        use_mode "$m"
        run inbound_build_json
        [ "$status" -eq 0 ]
        j="$output"
        [ "$(jq -r .protocol <<<"$j")" = "vless" ]
        [ "$(jq -r .streamSettings.security <<<"$j")" = "reality" ]
        [ "$(jq -r .shareAddr <<<"$j")" = "203.0.113.7" ]
        [ "$(jq -r .shareAddrStrategy <<<"$j")" = "custom" ]
        [ "$(jq -r .settings.decryption <<<"$j")" = "none" ]
        [ "$(jq -r '.streamSettings.realitySettings.shortIds[0]' <<<"$j")" = "$R_SID" ]
        [ "$(jq -r '.streamSettings.realitySettings.target' <<<"$j")" = "$R_TARGET" ]
        [ "$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$j")" = "$R_PRIV" ]
        [ "$(jq -r '.streamSettings.realitySettings.settings.publicKey' <<<"$j")" = "$R_PUB" ]
        [ "$(jq -r .remark <<<"$j")" = "BlueSoftKeys-Reality-$(tr a-z A-Z <<<"$m")" ]
    done
}

@test "inbound JSON: values are jq-escaped (no JSON injection through the SNI/target)" {
    use_mode tcp
    R_SNI='x","evil":"1' R_TARGET='a.com:443","x":"y'
    run inbound_build_json
    [ "$status" -eq 0 ]
    jq -e '.streamSettings.realitySettings | has("evil") | not' <<<"$output"
    [ "$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<<"$output")" = 'x","evil":"1' ]
}

link() { # mode extra-query
    printf 'vless://7e1b4bbc-9e1a-411f-aa38-0838b4d4f020@203.0.113.7:443?encryption=none%s&fp=chrome&pbk=%s&security=reality&sid=%s&sni=www.microsoft.com&spx=%%2Fabc&type=%s#name' "$2" "$R_PUB" "$R_SID" "$1"
}

@test "link_parse: extracts uuid/host/port/params and decodes percent-escapes" {
    link_parse "$(link tcp '&flow=xtls-rprx-vision&x=a%20b')"
    [ "$LINK_UUID" = "7e1b4bbc-9e1a-411f-aa38-0838b4d4f020" ]
    [ "$LINK_HOST" = "203.0.113.7" ]
    [ "$LINK_PORT" = "443" ]
    [ "${LINK_P[x]}" = "a b" ]
    [ "${LINK_P[spx]}" = "/abc" ]
    run link_parse "http://x"; [ "$status" -ne 0 ]
    run link_parse "vless://notauuid@h:1?a=b"; [ "$status" -ne 0 ]
}

@test "TCP link validation: correct link passes; missing flow / wrong pbk / private key leak are caught" {
    use_mode tcp
    run link_validate "$(link tcp '&flow=xtls-rprx-vision')"
    [ "$status" -eq 0 ]
    run link_validate "$(link tcp '')"; [ "$status" -ne 0 ]; [[ "$output" == *"flow"* ]]
    run link_validate "$(link tcp '&flow=xtls-rprx-vision' | sed 's/pbk=[^&]*/pbk=WRONG/')"; [ "$status" -ne 0 ]; [[ "$output" == *"public key"* ]]
    run link_validate "$(link tcp '&flow=xtls-rprx-vision')&leak=$R_PRIV"; [ "$status" -ne 0 ]; [[ "$output" == *"PRIVATE KEY"* ]]
}

@test "gRPC link validation: serviceName required, flow must be absent" {
    use_mode grpc
    svc="$(jq -r .service_name <<<"$MODE_OPTS_JSON")"
    run link_validate "$(link grpc "&serviceName=$svc&authority=")"; [ "$status" -eq 0 ]
    run link_validate "$(link grpc '&serviceName=other')"; [ "$status" -ne 0 ]; [[ "$output" == *"serviceName"* ]]
    run link_validate "$(link grpc "&serviceName=$svc&flow=xtls-rprx-vision")"; [ "$status" -ne 0 ]; [[ "$output" == *"unexpected flow"* ]]
}

@test "XHTTP link validation: path+mode required, flow must be absent" {
    use_mode xhttp
    path="$(jq -r .path <<<"$MODE_OPTS_JSON")"; enc="${path//\//%2F}"
    run link_validate "$(link xhttp "&path=$enc&mode=auto&host=")"; [ "$status" -eq 0 ]
    run link_validate "$(link xhttp "&path=%2Fwrong&mode=auto")"; [ "$status" -ne 0 ]; [[ "$output" == *"path"* ]]
    run link_validate "$(link xhttp "&mode=auto&flow=xtls-rprx-vision&path=$enc")"; [ "$status" -ne 0 ]
    run link_validate "$(link tcp "&path=$enc&mode=auto")"; [ "$status" -ne 0 ]; [[ "$output" == *"type"* ]]
}

@test "link validation catches host/port/sni mismatches" {
    use_mode tcp
    run link_validate "$(link tcp '&flow=xtls-rprx-vision' | sed 's/203.0.113.7/198.51.100.1/')"; [ "$status" -ne 0 ]; [[ "$output" == *"host"* ]]
    run link_validate "$(link tcp '&flow=xtls-rprx-vision' | sed 's/:443?/:8443?/')"; [ "$status" -ne 0 ]; [[ "$output" == *"port"* ]]
    run link_validate "$(link tcp '&flow=xtls-rprx-vision' | sed 's/sni=www.microsoft.com/sni=evil.com/')"; [ "$status" -ne 0 ]; [[ "$output" == *"sni"* ]]
}
