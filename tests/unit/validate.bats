#!/usr/bin/env bats
# Input validation: every value that reaches JSON / URLs / the shell / the panel passes through these.

setup() {
    load helpers
    vri_test_env
    load_libs
}

@test "valid_port accepts 1..65535 only" {
    run valid_port 1; [ "$status" -eq 0 ]
    run valid_port 443; [ "$status" -eq 0 ]
    run valid_port 65535; [ "$status" -eq 0 ]
    for bad in 0 65536 99999 -1 "" abc 44a "4 4" "443;id" "\$(id)" 1e3 0x1bb; do
        run valid_port "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

@test "valid_server_address: IPv4 and hostnames only" {
    for good in 203.0.113.7 example.com vpn.example.co.uk a-b.example.org; do run valid_server_address "$good"; [ "$status" -eq 0 ] || { echo "rejected $good"; return 1; }; done
    for bad in 999.1.1.1 "1.2.3" "exa mple.com" "-bad.com" "bad-.com" "a..b.com" "" 'x;rm -rf /' '$(id)' 'a.com/path' 'http://a.com' "a.com:443" "$(printf 'a%.0s' {1..70}).com"; do
        run valid_server_address "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

@test "valid_sni requires a dotted DNS name (no IP literals)" {
    run valid_sni www.microsoft.com; [ "$status" -eq 0 ]
    for bad in 1.2.3.4 localhost "www.mi crosoft.com" "a_b.com" ".com" "" 'a.com;id'; do run valid_sni "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }; done
}

@test "valid_target requires HOST:PORT" {
    run valid_target www.microsoft.com:443; [ "$status" -eq 0 ]
    for bad in www.microsoft.com "www.microsoft.com:" ":443" "www.microsoft.com:99999" "1.2.3.4:443" "a b.com:443" 'a.com:443;id' "a.com:4 43" "https://a.com:443"; do
        run valid_target "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

@test "valid_client_name: safe charset, blocks injection" {
    for good in BlueSoftKeys-Client-1 alice a.b_c-d Z9; do run valid_client_name "$good"; [ "$status" -eq 0 ] || { echo "rejected $good"; return 1; }; done
    for bad in "" "-x" ".x" "a b" 'a;id' '$(id)' '`id`' "a'b" 'a"b' "a/b" "../x" "a|b" "a&b" "a>b" "$(printf 'a%.0s' {1..65})" $'a\nb' "é"; do
        run valid_client_name "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }
    done
}

@test "valid_grpc_service" {
    for good in svc123 my.service_name-1 _x; do run valid_grpc_service "$good"; [ "$status" -eq 0 ] || { echo "rejected $good"; return 1; }; done
    for bad in "" "a b" "/svc" 'a;id' '$(id)' "a/b" "-x" "$(printf 'a%.0s' {1..65})" 'a"b'; do run valid_grpc_service "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }; done
}

@test "valid_xhttp_path" {
    for good in / /abc /a/b-c_d.e~f /xh123; do run valid_xhttp_path "$good"; [ "$status" -eq 0 ] || { echo "rejected $good"; return 1; }; done
    for bad in "" abc "/a b" "//a" "/a//b" "/../x" "/a?x=1" "/a#f" '/a;id' '/$(id)' '/a"b' "/$(printf 'a%.0s' {1..130})"; do run valid_xhttp_path "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }; done
}

@test "valid_mode accepts only implemented REALITY transports" {
    for good in tcp grpc xhttp; do run valid_mode "$good"; [ "$status" -eq 0 ]; done
    # WebSocket / HTTPUpgrade / mKCP are NOT REALITY transports and must never be offered
    for bad in ws websocket httpupgrade kcp mkcp h2 http quic TCP "" "tcp;id"; do run valid_mode "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }; done
}

@test "valid_stable_tag rejects dev-latest and pre-releases" {
    run valid_stable_tag v3.8.5; [ "$status" -eq 0 ]
    for bad in dev-latest dev latest main v3.8 3.8.5 v3.8.5-rc1 v3.8.5+x "v3.8.5;id" ""; do run valid_stable_tag "$bad"; [ "$status" -ne 0 ] || { echo "accepted: $bad"; return 1; }; done
}

@test "valid_shortid / valid_reality_key / valid_uuid" {
    run valid_shortid f101ca7165f664c6; [ "$status" -eq 0 ]
    run valid_shortid abc; [ "$status" -ne 0 ]
    run valid_shortid f101ca7165f664c6aa; [ "$status" -ne 0 ]
    run valid_reality_key 8Deg1F2LwEHKlZRX-Ba9SaC5PJZwqjvBWm1kxtfETVo; [ "$status" -eq 0 ]
    run valid_reality_key short; [ "$status" -ne 0 ]
    run valid_uuid 7e1b4bbc-9e1a-411f-aa38-0838b4d4f020; [ "$status" -eq 0 ]
    run valid_uuid not-a-uuid; [ "$status" -ne 0 ]
}
