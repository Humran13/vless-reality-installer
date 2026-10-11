#!/usr/bin/env bats
# End-to-end installer orchestration against the mock panel + fake upstream release (no root, no network):
# clean install for every mode, re-run idempotency, interrupted install, existing panel, port conflicts, target
# validation, contract drift, repair, uninstall levels, secret hygiene.

setup() {
    load helpers
    vri_test_env
    start_mock
    printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04"\n' >"$T/os-release"
    export VRI_OS_RELEASE_FILE="$T/os-release" VRI_UNAME_M=x86_64 VRI_SELF_TARBALL_URL=""
    VR="$REPO/bin/vless-reality"
    prepare_uninstalled_panel
}
teardown() { stop_mock; }

inst() { run bash "$VR" install --non-interactive --server-address 203.0.113.7 "$@"; }
vr() { run bash "$VR" "$@"; }
inbounds() { mock_state | jq -r '.inbounds | length'; }
clients() { mock_state | jq -r '.clients | keys | length'; }
state() { jq -r "$@" "$VRI_STATE_DIR/state.json"; }

@test "clean install (tcp): everything is created, link printed, no secrets leaked" {
    inst --mode tcp
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "1" ]
    [ "$(clients)" = "1" ]
    [ "$(state .mode)" = "tcp" ]
    [ "$(state .inbound.port)" = "443" ]
    [ "$(state '.clients[0].email')" = "BlueSoftKeys-Client-1" ]
    [ "$(state '.clients[0].flow')" = "xtls-rprx-vision" ]
    [ "$(state .panel.installed_by_us)" = "true" ]
    [[ "$output" == *"vless://"* ]]
    [[ "$output" == *"flow=xtls-rprx-vision"* ]]
    priv="$(state .reality.private_key)"
    [ -n "$priv" ]
    # secrets: private key, panel password, upstream token, our token
    tok="$(cat "$VRI_STATE_DIR/api-token")"
    for s in "$priv" "hunter2-secret-pass" "admin-secret-user" "leaked-token-value" "$tok" "$MOCK_TOKEN"; do
        [[ "$output" != *"$s"* ]] || { echo "LEAK of ${s:0:6}... in output"; return 1; }
    done
    ! grep -rqF "$priv" "$VRI_LOG_DIR" 2>/dev/null
    ! grep -rqF "$tok" "$VRI_LOG_DIR" 2>/dev/null
    [ ! -e "$MOCK_DIR/getApiToken.called" ]
    # permissions
    [ "$(stat -c %a "$VRI_STATE_DIR")" = "700" ]
    [ "$(stat -c %a "$VRI_STATE_DIR/state.json")" = "600" ]
    [ "$(stat -c %a "$VRI_STATE_DIR/api-token")" = "600" ]
    # management command installed
    [ -L "$VRI_BIN_LINK" ]
    [ -x "$VRI_HOME/bin/vless-reality" ]
    [ ! -e "$MOCK_DIR/qrencode.log" ]
    [[ "$output" != *"MOCK-QR-OUTPUT"* ]]
    [[ "$output" != *"Scan this with your client app"* ]]
}

@test "clean install works for grpc and xhttp with the correct flow behaviour" {
    inst --mode grpc
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(state .mode)" = "grpc" ]
    [ "$(state '.clients[0].flow')" = "" ]
    [[ "$output" == *"type=grpc"* ]]
    [[ "$output" == *"serviceName=svc"* ]]
    [[ "$output" != *"flow="* ]]
    stop_mock; rm -rf "$VRI_STATE_DIR"; start_mock; prepare_uninstalled_panel; rm -f "$XUI_MAIN_FOLDER/x-ui" "$XUI_MAIN_FOLDER/.installed"
    inst --mode xhttp --xhttp-path /my-x_path
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(state .mode)" = "xhttp" ]
    [[ "$output" == *"type=xhttp"* ]]
    [[ "$output" == *"path=%2Fmy-x_path"* ]]
    [[ "$output" != *"flow="* ]]
}

@test "non-interactive default mode is tcp" {
    inst
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(state .mode)" = "tcp" ]
}

@test "second run is idempotent: no new inbound/client/token/keys" {
    inst --mode tcp; [ "$status" -eq 0 ]
    keys="$(state -c .reality)"; toks="$(mock_state >/dev/null; curl -s http://127.0.0.1:$MOCK_PORT/__state | jq '.next_token')"
    inst --mode tcp
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "1" ]
    [ "$(clients)" = "1" ]
    [ "$(state -c .reality)" = "$keys" ]
    [ "$(curl -s http://127.0.0.1:$MOCK_PORT/__state | jq '.next_token')" = "$toks" ]
    [[ "$output" == *"already exists"* ]]
}

@test "second run with a different mode is refused with instructions" {
    inst --mode tcp; [ "$status" -eq 0 ]
    inst --mode grpc
    [ "$status" -eq 6 ]
    [[ "$output" == *"already configured for mode 'tcp'"* ]]
    [ "$(inbounds)" = "1" ]
}

@test "interrupted install (client creation failed) is completed by the next run" {
    mock_ctl '{"fail":{"clients/add":"500"}}'
    inst --mode tcp
    [ "$status" -ne 0 ]
    [ "$(inbounds)" = "1" ]
    [ "$(clients)" = "0" ]
    mock_ctl '{"reset":true}'
    inst --mode tcp
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "1" ]
    [ "$(clients)" = "1" ]
}

@test "lost state with an existing managed inbound: adopted, no duplicate, keys preserved" {
    inst --mode grpc; [ "$status" -eq 0 ]
    pub="$(state .reality.public_key)"; svc="$(state .mode_opts.service_name)"
    rm -f "$VRI_STATE_DIR/state.json" "$VRI_STATE_DIR/api-token"
    inst --mode grpc
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "1" ]
    [ "$(clients)" = "1" ]
    [ "$(state .reality.public_key)" = "$pub" ]
    [ "$(state .mode_opts.service_name)" = "$svc" ]
    [[ "$output" == *"Adopted the existing"* ]]
}

@test "existing 3X-UI without a usable token: stops with instructions, changes nothing, never resets credentials" {
    cp "$T/xui/x-ui.template" "$XUI_MAIN_FOLDER/x-ui"
    rm -f "$VRI_XUI_ETC/install-result.env"
    inst --mode tcp
    [ "$status" -eq 5 ]
    [[ "$output" == *"I will NOT reset credentials"* ]]
    [[ "$output" == *"VRI_XUI_API_TOKEN"* ]]
    [ "$(inbounds)" = "0" ]
    [ ! -e "$MOCK_DIR/getApiToken.called" ]
}

@test "existing 3X-UI + user-supplied token: works, keeps foreign inbounds, records installed_by_us=false" {
    cp "$T/xui/x-ui.template" "$XUI_MAIN_FOLDER/x-ui"
    jq -n '{enable:true,remark:"MY-OWN",listen:"",port:9000,protocol:"vless",settings:{clients:[]},streamSettings:{network:"tcp",security:"none"}}' >"$T/own.json"
    curl -s -H "Authorization: Bearer $MOCK_TOKEN" -H 'Content-Type: application/json' --data-binary "@$T/own.json" "$VRI_PANEL_URL/panel/api/inbounds/add" >/dev/null
    VRI_XUI_API_TOKEN="$MOCK_TOKEN" inst --mode tcp
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "2" ]
    [ "$(state .panel.installed_by_us)" = "false" ]
    [[ "$output" == *"will not be reinstalled, reset or modified"* ]]
    mock_state | jq -e '.inbounds[] | select(.remark=="MY-OWN")' >/dev/null
}

@test "occupied port 443: reports the owner, does NOT stop it, fails non-interactively; --port works" {
    echo "443:nginx:812" >"$MOCK_DIR/listening"
    inst --mode tcp
    [ "$status" -eq 3 ]
    [[ "$output" == *"nginx(812)"* ]]
    [[ "$output" == *"--port"* ]]
    ! grep -q 'stop nginx\|stop apache\|stop caddy\|docker' "$MOCK_DIR/systemctl.log" 2>/dev/null
    [ "$(inbounds)" = "0" ]
    inst --mode tcp --port 8443
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(state .inbound.port)" = "8443" ]
    [[ "$output" == *":8443?"* ]]
}

@test "explicit --port that is occupied is refused" {
    echo "8443:caddy:77" >"$MOCK_DIR/listening"
    inst --mode tcp --port 8443
    [ "$status" -eq 3 ]
    [[ "$output" == *"caddy(77)"* ]]
}

@test "REALITY target that is not suitable is rejected before anything is created" {
    inst --mode tcp --reality-target infeasible.example.com:443
    [ "$status" -eq 2 ]
    [[ "$output" == *"TLS 1.3 not supported"* ]]
    [ "$(inbounds)" = "0" ]
}

@test "SNI not covered by the target certificate is rejected" {
    inst --mode tcp --reality-target wild.example.net:443
    [ "$status" -eq 2 ]
    [[ "$output" == *"not covered"* ]]
    inst --mode tcp --reality-target www.example.com:443 --sni www.example.com
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(state .reality.sni)" = "www.example.com" ]
}

@test "API contract drift aborts before any change" {
    mock_ctl '{"opt":{"openapi_missing":true}}'
    inst --mode tcp
    [ "$status" -eq 4 ]
    [[ "$output" == *"incompatible 3X-UI API"* ]]
    [ "$(inbounds)" = "0" ]
}

@test "upstream download failure (no release files) fails cleanly" {
    rm -rf "$T/upstream"
    inst --mode tcp
    [ "$status" -eq 4 ]
    [ ! -e "$VRI_STATE_DIR/state.json" ]
}

@test "upstream installer failure: nothing else is changed, no credential leak" {
    FAKE_INSTALL_FAIL=1 inst --mode tcp
    [ "$status" -eq 4 ]
    [[ "$output" != *"hunter2-secret-pass"* ]]
    [ "$(inbounds)" = "0" ]
}

@test "installed but install-result.env missing: refuses to regenerate tokens" {
    FAKE_NO_RESULT=1 inst --mode tcp
    [ "$status" -eq 4 ]
    [[ "$output" == *"missing or malformed"* ]]
    [ ! -e "$MOCK_DIR/getApiToken.called" ]
}

@test "pinning a dev build is impossible" {
    inst --mode tcp --panel-version dev-latest
    [ "$status" -eq 2 ]
    inst --mode tcp --panel-version v3.8
    [ "$status" -eq 2 ]
}

@test "status / info / clients / diagnostics run and never print the private key" {
    inst --mode tcp; [ "$status" -eq 0 ]
    priv="$(state .reality.private_key)"
    for c in status info clients diagnostics; do
        vr "$c"
        [ "$status" -eq 0 ] || { echo "$c: $output"; return 1; }
        [[ "$output" != *"$priv"* ]]
        [[ "$output" != *"$MOCK_TOKEN"* ]]
    done
    vr status
    [[ "$output" == *"Wrapper version"* && "$output" == *"3X-UI version"* && "$output" == *"Connection mode"* && "$output" == *"Client count"* && "$output" == *"Listening state"* ]]
}

@test "client commands via the CLI: add / disable / enable / qr fallback / remove" {
    inst --mode tcp; [ "$status" -eq 0 ]
    vr add-client Alice --quota-gb 2 --expire-days 10; [ "$status" -eq 0 ]
    vr disable-client Alice; [ "$status" -eq 0 ]
    [ "$(mock_state | jq -r '.clients.Alice.enable')" = "false" ]
    [ "$(mock_state | jq -r '.clients.Alice.flow')" = "xtls-rprx-vision" ]
    vr enable-client Alice; [ "$status" -eq 0 ]
    vr qr Alice; [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK-QR-OUTPUT"* ]]
    grep -q -- '-t ANSIUTF8' "$MOCK_DIR/qrencode.log"
    vr --yes remove-client Alice; [ "$status" -eq 0 ]
    [ "$(clients)" = "1" ]
    vr add-client 'bad;name'; [ "$status" -eq 2 ]
}

@test "diagnostics detects a tampered inbound; repair fixes it (same keys)" {
    inst --mode tcp; [ "$status" -eq 0 ]
    pub="$(state .reality.public_key)"
    id="$(state .inbound.id)"
    curl -s -H "Authorization: Bearer $MOCK_TOKEN" "$VRI_PANEL_URL/panel/api/inbounds/get/$id" | jq '.obj | .streamSettings.realitySettings.shortIds=["deadbeef"] | .port=9443' >"$T/t.json"
    curl -s -H "Authorization: Bearer $MOCK_TOKEN" -H 'Content-Type: application/json' --data-binary "@$T/t.json" "$VRI_PANEL_URL/panel/api/inbounds/update/$id" >/dev/null
    vr diagnostics
    [ "$status" -ne 0 ]
    [[ "$output" == *"[FAIL]"* ]]
    vr repair; [ "$status" -eq 0 ]
    [[ "$output" == *"repaired"* ]]
    vr diagnostics
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(state .reality.public_key)" = "$pub" ]
}

@test "repair recreates a deleted inbound + orphaned clients with the same keys/uuid/flow" {
    inst --mode tcp; [ "$status" -eq 0 ]
    uuid="$(state '.clients[0].uuid')"; pub="$(state .reality.public_key)"
    curl -s -X POST -H "Authorization: Bearer $MOCK_TOKEN" "$VRI_PANEL_URL/panel/api/inbounds/del/$(state .inbound.id)" >/dev/null
    [ "$(inbounds)" = "0" ]
    vr repair; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "1" ]
    [ "$(mock_state | jq -r '.clients["BlueSoftKeys-Client-1"].uuid')" = "$uuid" ]
    [ "$(mock_state | jq -r '.clients["BlueSoftKeys-Client-1"].flow')" = "xtls-rprx-vision" ]
    [ "$(state .reality.public_key)" = "$pub" ]
}

@test "repair on a healthy install changes nothing" {
    inst --mode tcp; [ "$status" -eq 0 ]
    before="$(mock_state | jq -S -c '{inbounds, clients}')"
    vr repair; [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing to repair"* ]]
    [ "$(mock_state | jq -S -c '{inbounds, clients}')" = "$before" ]
}

@test "repair starts a stopped x-ui service" {
    inst --mode tcp; [ "$status" -eq 0 ]
    touch "$MOCK_DIR/svc_inactive"
    vr repair; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q '^start x-ui' "$MOCK_DIR/systemctl.log"
}

@test "uninstall level 1: removes our inbound/clients/token/state, keeps foreign resources and the wrapper" {
    inst --mode tcp; [ "$status" -eq 0 ]
    jq -n '{enable:true,remark:"FOREIGN",listen:"",port:9000,protocol:"vless",settings:{clients:[]},streamSettings:{network:"tcp",security:"none"}}' >"$T/f.json"
    curl -s -H "Authorization: Bearer $MOCK_TOKEN" -H 'Content-Type: application/json' --data-binary "@$T/f.json" "$VRI_PANEL_URL/panel/api/inbounds/add" >/dev/null
    echo '{"client":{"email":"foreign-user"},"inboundIds":[2]}' >"$T/fc.json"
    curl -s -H "Authorization: Bearer $MOCK_TOKEN" -H 'Content-Type: application/json' --data-binary "@$T/fc.json" "$VRI_PANEL_URL/panel/api/clients/add" >/dev/null
    vr --yes uninstall --level 1
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "1" ]
    mock_state | jq -e '.inbounds[0].remark=="FOREIGN"' >/dev/null
    [ "$(mock_state | jq -r '.clients | keys | join(",")')" = "foreign-user" ]
    [ ! -e "$VRI_STATE_DIR/state.json" ]
    [ ! -e "$VRI_STATE_DIR/api-token" ]
    [ -x "$VRI_HOME/bin/vless-reality" ]
    ls "$VRI_BACKUP_DIR"/vri-backup-pre-uninstall-*.tar.gz
    # our API token was revoked
    [ "$(curl -s http://127.0.0.1:$MOCK_PORT/__state >/dev/null; curl -s -H "Authorization: Bearer $MOCK_TOKEN" "$VRI_PANEL_URL/panel/api/setting/apiTokens" | jq -r '[.obj[]|select(.name|startswith("bluesoftkeys"))]|length')" = "0" ]
    # reinstall works and creates NEW keys
    inst --mode tcp; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(inbounds)" = "2" ]
}

@test "uninstall level 2 removes the wrapper too; backups are kept" {
    inst --mode tcp; [ "$status" -eq 0 ]
    vr --yes uninstall --level 2
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$VRI_HOME" ]
    [ ! -e "$VRI_BIN_LINK" ]
    ls "$VRI_BACKUP_DIR"/*.tar.gz
    [ -x "$XUI_MAIN_FOLDER/x-ui" ]   # 3X-UI itself untouched
}

@test "uninstall level 3 needs the typed confirmation and removes 3X-UI via the official uninstaller" {
    inst --mode tcp; [ "$status" -eq 0 ]
    # no tty + no --yes: the destructive level must not proceed
    run bash "$VR" uninstall --level 3 --non-interactive
    [ "$status" -ne 0 ]
    [ -x "$XUI_MAIN_FOLDER/x-ui" ]
    vr --yes uninstall --level 3
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$XUI_MAIN_FOLDER/x-ui" ]
}

@test "level 1 without a working panel API still cleans local state and reports what remains" {
    inst --mode tcp; [ "$status" -eq 0 ]
    stop_mock
    vr --yes uninstall --level 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not be removed automatically"* ]]
    [ ! -e "$VRI_STATE_DIR/state.json" ]
}
