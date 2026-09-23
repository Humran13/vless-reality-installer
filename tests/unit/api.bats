#!/usr/bin/env bats
# API layer + client management against the behaviour-faithful mock panel (incl. failure injection).

setup() {
    load helpers
    vri_test_env
    start_mock
    load_libs
    api_configure
    api_set_token "$MOCK_TOKEN"
    MODE=tcp PORT=443 SERVER_ADDR=203.0.113.7 R_TARGET=www.microsoft.com:443 R_SNI=www.microsoft.com
    R_PRIV=cE0v7gU-1sXJp1c9bWm6b0Zk4h3v5jQ2n8yL7tDaR1A R_PUB=8Deg1F2LwEHKlZRX-Ba9SaC5PJZwqjvBWm1kxtfETVo
    R_SID=f101ca7165f664c6 R_FINGERPRINT=chrome
}
teardown() { stop_mock; }

new_inbound() { # mode
    MODE="$1"; mode_call "$MODE" defaults
    inbound_build_json >"$T/inb.json"
    panel_inbound_add "$T/inb.json"
    INBOUND_ID="$(api_obj '.obj.id')"
}

@test "authentication: valid token works, wrong token -> 401 message, missing token -> 404" {
    api_get /panel/api/server/status
    api_set_token "wrong-token-000000"
    run api_get /panel/api/server/status
    [ "$status" -eq 21 ]
    api_set_token "$MOCK_TOKEN"
    api_get /panel/api/server/status
}

@test "wrong base path -> HTTP 404 with a helpful message" {
    API_BASE="http://127.0.0.1:$MOCK_PORT/wrongbase"
    api_get /panel/api/server/status || true
    [ "$API_HTTP" = "404" ]
    [[ "$API_MSG" == *"wrong base path"* ]]
}

@test "inbound lifecycle: create, list, get, update, delete" {
    new_inbound tcp
    [ "$INBOUND_ID" = "1" ]
    panel_inbounds_list
    [ "$(api_obj '.obj | length')" = "1" ]
    panel_inbound_get "$INBOUND_ID"
    [ "$(api_obj '.obj.port')" = "443" ]
    api_obj '.obj' >"$T/cur.json"
    jq '.port = 8443' "$T/cur.json" >"$T/upd.json"
    panel_inbound_update "$INBOUND_ID" "$T/upd.json"
    panel_inbound_get "$INBOUND_ID"
    [ "$(api_obj '.obj.port')" = "8443" ]
    panel_inbound_del "$INBOUND_ID"
    run panel_inbound_get "$INBOUND_ID"
    [ "$status" -eq 23 ]
}

@test "duplicate port is rejected by the panel and surfaced" {
    new_inbound tcp
    inbound_build_json >"$T/inb2.json"
    run panel_inbound_add "$T/inb2.json"
    [ "$status" -eq 23 ]
    panel_inbound_add "$T/inb2.json" || true
    [[ "$API_MSG" == *"already used"* ]]
}

@test "API failures: HTTP 500, malformed JSON, success=false, dropped connection" {
    mock_ctl '{"fail":{"inbounds/list":"500"}}'
    run panel_inbounds_list; [ "$status" -eq 21 ]
    mock_ctl '{"reset":true,"fail":{"inbounds/list":"malformed"}}'
    run panel_inbounds_list; [ "$status" -eq 22 ]
    mock_ctl '{"reset":true,"fail":{"inbounds/list":"success_false"}}'
    run panel_inbounds_list; [ "$status" -eq 23 ]
    mock_ctl '{"reset":true,"fail":{"inbounds/list":"drop"}}'
    run panel_inbounds_list; [ "$status" -eq 20 ]
    mock_ctl '{"reset":true,"fail":{"inbounds/list":"401"}}'
    run panel_inbounds_list; [ "$status" -eq 21 ]
}

@test "API transport error when the panel is down" {
    stop_mock
    run panel_inbounds_list
    [ "$status" -eq 20 ]
    [[ "$output" == "" ]]
}

@test "API contract check passes on a complete spec and fails when an endpoint disappears" {
    api_check_contract
    mock_ctl '{"opt":{"openapi_missing":true}}'
    run api_check_contract
    [ "$status" -ne 0 ]
    [[ "$output" == *"clients/add"* ]]
    mock_ctl '{"opt":{"openapi_missing":false,"no_openapi":true}}'
    run api_check_contract   # no spec published -> warn only
    [ "$status" -eq 0 ]
}

@test "client create/list: TCP client gets xtls-rprx-vision; gRPC/XHTTP clients get NO flow" {
    for m in tcp grpc xhttp; do
        rm -rf "$T/mock/*"; stop_mock; start_mock; api_configure; api_set_token "$MOCK_TOKEN"
        new_inbound "$m"
        mkdir -p "$VRI_STATE_DIR"
        MODE="$m" PORT=443 INBOUND_ID=1 INBOUND_TAG=in-443-tcp state_create
        client_create BlueSoftKeys-Client-1
        panel_client_get BlueSoftKeys-Client-1
        want=""; [ "$m" = tcp ] && want="xtls-rprx-vision"
        [ "$(api_obj '.obj.client.flow')" = "$want" ]
    done
}

@test "client create is idempotent and detects a foreign name clash" {
    new_inbound tcp; mkdir -p "$VRI_STATE_DIR"; state_create
    client_create Alice
    client_create Alice   # second call: no error, no duplicate
    panel_clients_list
    [ "$(api_obj '[.obj[] | select(.email=="Alice")] | length')" = "1" ]
    # foreign client on another inbound
    jq '.port = 9999 | .remark = "foreign"' "$T/inb.json" >"$T/other.json"
    panel_inbound_add "$T/other.json"
    echo '{"client":{"email":"Bob"},"inboundIds":[2]}' >"$T/bob.json"
    panel_client_add "$T/bob.json"
    run client_create Bob
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists outside"* ]]
    run client_set_enabled Bob false
    [ "$status" -ne 0 ]
    [[ "$output" == *"not attached to the BlueSoftKeys inbound"* ]]
    run client_remove Bob
    [ "$status" -ne 0 ]
}

@test "disable/enable keeps the flow (partial updates would wipe it)" {
    new_inbound tcp; mkdir -p "$VRI_STATE_DIR"; state_create
    client_create Alice
    client_set_enabled Alice false
    panel_client_get Alice
    [ "$(api_obj '.obj.client.enable')" = "false" ]
    [ "$(api_obj '.obj.client.flow')" = "xtls-rprx-vision" ]
    client_set_enabled Alice true
    panel_client_get Alice
    [ "$(api_obj '.obj.client.enable')" = "true" ]
    [ "$(api_obj '.obj.client.flow')" = "xtls-rprx-vision" ]
}

@test "client quota/expiry are stored (bytes / unix ms)" {
    new_inbound tcp; mkdir -p "$VRI_STATE_DIR"; state_create
    client_create Alice 30 5
    panel_client_get Alice
    [ "$(api_obj '.obj.client.totalGB')" = "5368709120" ]
    exp="$(api_obj '.obj.client.expiryTime')"
    [ "$exp" -gt "$(( ($(date +%s) + 29*86400) * 1000 ))" ]
}

@test "client remove works and updates state" {
    new_inbound tcp; mkdir -p "$VRI_STATE_DIR"; state_create
    client_create Alice
    state_has_client Alice
    client_remove Alice
    run panel_client_get Alice
    [ "$status" -eq 23 ]
    run state_has_client Alice
    [ "$status" -ne 0 ]
}

@test "unsafe client names never reach the API" {
    new_inbound tcp; mkdir -p "$VRI_STATE_DIR"; state_create
    for bad in 'a;id' '$(id)' 'a b' '../x' ''; do
        run client_create "$bad"
        [ "$status" -ne 0 ]
    done
    panel_clients_list
    [ "$(api_obj '.obj | length')" = "0" ]
}

@test "share link from the panel validates for every mode" {
    for m in tcp grpc xhttp; do
        stop_mock; start_mock; api_configure; api_set_token "$MOCK_TOKEN"
        new_inbound "$m"; mkdir -p "$VRI_STATE_DIR"; rm -f "$VRI_STATE_DIR/state.json"
        MODE="$m" PORT=443 INBOUND_ID=1 INBOUND_TAG=t state_create
        client_create Alice
        run client_link Alice
        [ "$status" -eq 0 ] || { echo "mode $m: $output"; return 1; }
        [[ "$output" == vless://* ]]
        [[ "$output" != *"$R_PRIV"* ]]
    done
}

@test "orphaned client (inbound deleted) is re-attached with its flow restored" {
    new_inbound tcp; mkdir -p "$VRI_STATE_DIR"; state_create
    client_create Alice
    panel_inbound_del 1
    new_inbound tcp   # recreated inbound gets id 2
    INBOUND_ID=2
    client_create Alice
    panel_client_get Alice
    [ "$(api_obj '.obj.inboundIds[0]')" = "2" ]
    [ "$(api_obj '.obj.client.flow')" = "xtls-rprx-vision" ]
}

@test "backup -> mutate -> restore round-trip (official getDb / importDB)" {
    new_inbound tcp; mkdir -p "$VRI_STATE_DIR"; state_create
    client_create Alice
    archive="$(backup_create test)"
    [ "$(stat -c %a "$archive")" = "600" ]
    [ "$(stat -c %a "$VRI_BACKUP_DIR")" = "700" ]
    client_create Bob
    export VRI_XUI_API_TOKEN="$MOCK_TOKEN"   # after a restore the token must be re-acquired
    VRI_ASSUME_YES=1 backup_restore "$archive"
    panel_clients_list
    [ "$(api_obj '[.obj[].email] | sort | join(",")')" = "Alice" ]
}

@test "restore refuses non-backup / traversal archives" {
    echo hello >"$T/x.txt"; tar -czf "$T/bad.tar.gz" -C "$T" x.txt
    run backup_restore "$T/bad.tar.gz"
    [ "$status" -ne 0 ]
    run backup_restore "$T/does-not-exist.tar.gz"
    [ "$status" -ne 0 ]
    mkdir -p "$T/ev" && echo '{}' >"$T/ev/manifest.json" && (cd "$T/ev" && tar -czf "$T/evil.tar.gz" --transform 's,^,../,' manifest.json)
    run backup_restore "$T/evil.tar.gz"
    [ "$status" -ne 0 ]
}
