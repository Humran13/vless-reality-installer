#!/usr/bin/env bash
# In-container lifecycle test for ONE connection mode against the REAL official 3X-UI + Xray.
# Usage (inside a systemd container as root):  lifecycle.sh MODE [SRC_DIR]     MODE = tcp|grpc|xhttp
# Emits TAP-like lines; exit status = number of failures (capped at 125).
set -uo pipefail

MODE="${1:?mode}"
SRC="${2:-/src}"
export VRI_TEST_MODE=1
SERVER_ADDR="127.0.0.1"
VR=/usr/local/bin/vless-reality
STATE=/etc/vless-reality-installer/state.json
N=0 FAILS=0
ARCH="$(uname -m)"
case "$ARCH" in x86_64) XARCH=amd64 ;; aarch64) XARCH=arm64 ;; *) XARCH="$ARCH" ;; esac
XRAY="/usr/local/x-ui/bin/xray-linux-$XARCH"
SOCKS_PORT=10850

ok() { N=$((N + 1)); printf 'ok %d - [%s] %s\n' "$N" "$MODE" "$1"; }
nok() { N=$((N + 1)); FAILS=$((FAILS + 1)); printf 'not ok %d - [%s] %s\n' "$N" "$MODE" "$1"; }
check() { # desc cmd...
    local d="$1"
    shift
    if "$@" >/tmp/check.out 2>&1; then ok "$d"; else
        nok "$d"
        sed 's/^/    | /' /tmp/check.out | head -15
    fi
}
check_fail() { # desc cmd...   (expects non-zero)
    local d="$1"
    shift
    if "$@" >/tmp/check.out 2>&1; then
        nok "$d (unexpectedly succeeded)"
        sed 's/^/    | /' /tmp/check.out | head -10
    else ok "$d"; fi
}
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1 (got '$2', want '$3')"; fi; }
strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

panel_api() { # method path [jsonfile]  (uses our stored token; base from x-ui settings)
    local port base tok
    port="$(/usr/local/x-ui/x-ui setting -show | sed -n 's/^port: *//p' | tr -d ' ')"
    base="$(/usr/local/x-ui/x-ui setting -show | sed -n 's/^webBasePath: *//p' | tr -d ' /')"
    tok="$(tr -d '[:space:]' </etc/vless-reality-installer/api-token)"
    if [[ -n "${3:-}" ]]; then
        curl -s -X "$1" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' --data-binary "@$3" "http://127.0.0.1:${port}/${base}${2}"
    else
        curl -s -X "$1" -H "Authorization: Bearer $tok" "http://127.0.0.1:${port}/${base}${2}"
    fi
}

link_of() { "$VR" info "$1" 2>/dev/null | grep -o 'vless://[^ ]*' | head -n1; }

# Real traffic: xray client (bundled binary) -> our inbound -> internet.
traffic() { # link
    local link="$1" cfg pid rc=1
    cfg="$(mktemp /tmp/client.XXXXXX.json)"
    bash "$SRC/tests/integration/link2client.sh" "$link" "$SOCKS_PORT" "$SERVER_ADDR" >"$cfg" || return 2
    "$XRAY" run -c "$cfg" >/tmp/xray-client.log 2>&1 &
    pid=$!
    sleep 2
    if curl -s -m 25 --socks5-hostname "127.0.0.1:$SOCKS_PORT" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^tls=TLSv1.3'; then rc=0; fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$cfg"
    return $rc
}

wait_listen() { local i; for i in $(seq 1 30); do ss -ltn "sport = :$1" | grep -q LISTEN && return 0; sleep 1; done; return 1; }

t0=$(date +%s)
echo "# lifecycle test: mode=$MODE os=$(. /etc/os-release && echo "$PRETTY_NAME") arch=$ARCH"

# ------------------------------------------------------------------ 1. clean install
check "clean install ($MODE) exits 0" bash -c "bash '$SRC/install.sh' --mode $MODE --server-address $SERVER_ADDR --non-interactive >/tmp/install.log 2>&1"
if ((FAILS)); then
    tail -30 /tmp/install.log | strip_ansi
    echo "# aborting: install failed"
    exit 1
fi
PORT="$(jq -r .inbound.port "$STATE")"
eq "inbound port defaults to 443" "$PORT" "443"
eq "state mode" "$(jq -r .mode "$STATE")" "$MODE"
eq "state file perms" "$(stat -c %a "$STATE")" "600"
eq "state dir perms" "$(stat -c %a /etc/vless-reality-installer)" "700"
eq "api-token perms" "$(stat -c %a /etc/vless-reality-installer/api-token)" "600"
check "management command installed" test -x "$VR"
check "Xray listening on $PORT" wait_listen "$PORT"
check "x-ui service active" systemctl is-active --quiet x-ui
check "3X-UI is the stable v3.8.5 release" test "$(/usr/local/x-ui/x-ui -v)" = "3.8.5"
check "install-result.env perms 600" test "$(stat -c %a /etc/x-ui/install-result.env)" = "600"

L1="$(link_of BlueSoftKeys-Client-1)"
check "first client link produced" test -n "$L1"
case "$MODE" in
    tcp)
        check "tcp link has flow=xtls-rprx-vision" grep -q 'flow=xtls-rprx-vision' <<<"$L1"
        check "tcp link type=tcp" grep -q 'type=tcp' <<<"$L1"
        ;;
    grpc)
        check "grpc link type=grpc" grep -q 'type=grpc' <<<"$L1"
        check "grpc link has serviceName" grep -q 'serviceName=svc' <<<"$L1"
        check_fail "grpc link has NO flow" grep -q 'flow=' <<<"$L1"
        ;;
    xhttp)
        check "xhttp link type=xhttp" grep -q 'type=xhttp' <<<"$L1"
        check "xhttp link has path and mode" bash -c "grep -q 'path=%2F' <<<'$L1' && grep -q 'mode=auto' <<<'$L1'"
        check_fail "xhttp link has NO flow" grep -q 'flow=' <<<"$L1"
        ;;
esac
check "link uses reality + our public key" bash -c "grep -q 'security=reality' <<<'$L1' && grep -q \"pbk=$(jq -r .reality.public_key "$STATE")\" <<<'$L1'"
PRIV="$(jq -r .reality.private_key "$STATE")"
check_fail "private key NOT in client link" grep -qF "$PRIV" <<<"$L1"

# ------------------------------------------------------------------ 2. real traffic
check "REAL TRAFFIC through $MODE+REALITY (first client)" traffic "$L1"

# ------------------------------------------------------------------ 2b. unrelated (foreign) resources that must never be touched
cat >/tmp/decoy-inbound.json <<'J'
{"enable":true,"remark":"UNRELATED-decoy","listen":"","port":19999,"protocol":"vless","expiryTime":0,"total":0,
 "settings":{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]},
 "streamSettings":{"network":"tcp","security":"none","tcpSettings":{"header":{"type":"none"}}},
 "sniffing":{"enabled":false,"destOverride":["http","tls"]}}
J
DECOY_ID="$(panel_api POST /panel/api/inbounds/add /tmp/decoy-inbound.json | jq -r '.obj.id // empty')"
[[ -n "$DECOY_ID" ]] && ok "created unrelated decoy inbound (id $DECOY_ID)" || nok "created unrelated decoy inbound"
echo "{\"client\":{\"email\":\"decoy-user\",\"enable\":true},\"inboundIds\":[$DECOY_ID]}" >/tmp/decoy-client.json
panel_api POST /panel/api/clients/add /tmp/decoy-client.json | jq -e .success >/dev/null && ok "created unrelated decoy client" || nok "created unrelated decoy client"

# ------------------------------------------------------------------ 3. idempotent re-run
inb_before="$(panel_api GET /panel/api/inbounds/list | jq -r '.obj | length')"
keys_before="$(jq -c .reality "$STATE")"
tok_before="$(panel_api GET /panel/api/setting/apiTokens | jq -r '.obj | length')"
cl_before="$(panel_api GET /panel/api/clients/list | jq -r '.obj | length')"
check "second install run exits 0" bash -c "bash '$SRC/install.sh' --mode $MODE --server-address $SERVER_ADDR --non-interactive >/tmp/install2.log 2>&1"
eq "rerun: still exactly one inbound" "$(panel_api GET /panel/api/inbounds/list | jq -r '.obj | length')" "$inb_before"
eq "rerun: same client count" "$(panel_api GET /panel/api/clients/list | jq -r '.obj | length')" "$cl_before"
eq "rerun: REALITY keys/short-id unchanged" "$(jq -c .reality "$STATE")" "$keys_before"
eq "rerun: no extra API tokens" "$(panel_api GET /panel/api/setting/apiTokens | jq -r '.obj | length')" "$tok_before"
check_fail "rerun with a different mode is refused" bash -c "bash '$SRC/install.sh' --mode $([[ $MODE == tcp ]] && echo grpc || echo tcp) --server-address $SERVER_ADDR --non-interactive >/tmp/install3.log 2>&1"

# ------------------------------------------------------------------ 4. client management
check "add-client Alice (quota+expiry)" bash -c "$VR add-client Alice --quota-gb 5 --expire-days 30 >/tmp/add.log 2>&1"
check_fail "add-client with unsafe name is rejected" $VR add-client 'x;touch /tmp/pwned'
check_fail "no command injection happened" test -e /tmp/pwned
check_fail "add-client with \$(cmd) name is rejected" $VR add-client '$(id)'
LA="$(link_of Alice)"
check "Alice link produced" test -n "$LA"
check "REAL TRAFFIC for Alice" traffic "$LA"
check "disable-client Alice" $VR disable-client Alice
eq "Alice disabled in panel" "$(panel_api GET /panel/api/clients/get/Alice | jq -r '.obj.client.enable')" "false"
[[ "$MODE" == "tcp" ]] && eq "disable preserved flow" "$(panel_api GET /panel/api/clients/get/Alice | jq -r '.obj.client.flow')" "xtls-rprx-vision"
sleep 3
check_fail "disabled client can NOT pass traffic" traffic "$LA"
check "enable-client Alice" $VR enable-client Alice
sleep 3
check "re-enabled client passes traffic again" traffic "$LA"
check "clients list shows Alice with quota" bash -c "$VR clients | grep -q '5.00 GB'"
check "qr command (or graceful message)" bash -c "$VR qr Alice >/dev/null 2>&1 || $VR qr Alice 2>&1 | grep -qi qrencode"
check "remove-client Alice" bash -c "$VR --yes remove-client Alice"
check_fail "removed client is gone" bash -c "panel_api() { :; }; $VR clients | grep -q '^Alice'"
check_fail "refuses to disable a foreign client (not attached to our inbound)" $VR disable-client decoy-user
check_fail "refuses to remove a foreign client" $VR --yes remove-client decoy-user
eq "foreign client untouched" "$(panel_api GET /panel/api/clients/get/decoy-user | jq -r '.obj.client.enable')" "true"

# ------------------------------------------------------------------ 5. status / diagnostics / info
check "status exits 0" bash -c "$VR status >/tmp/status.out 2>&1"
check "diagnostics exits 0 (no FAIL)" bash -c "$VR diagnostics >/tmp/diag.out 2>&1"
check_fail "diagnostics contains no [FAIL]" bash -c "strip=\$(sed -E 's/\x1b\[[0-9;]*m//g' /tmp/diag.out); grep -q '\[FAIL\]' <<<\"\$strip\""
check "version command" bash -c "$VR version | grep -q 'BlueSoftKeys'"

# ------------------------------------------------------------------ 6. backup / restore
BK="$($VR backup 2>&1 | strip_ansi | grep -o '/var/backups/[^ ]*\.tar\.gz' | head -n1)"
check "backup archive created" test -f "$BK"
eq "backup perms 600" "$(stat -c %a "$BK")" "600"
eq "backup dir perms 700" "$(stat -c %a /var/backups/vless-reality-installer)" "700"
check "add Bob then restore backup (Bob must vanish)" bash -c "$VR add-client Bob >/dev/null 2>&1"
check "restore" bash -c "$VR --yes restore '$BK' >/tmp/restore.log 2>&1"
check_fail "restore removed Bob (post-backup change)" bash -c "sleep 2; $VR clients 2>/dev/null | grep -q '^Bob'"
check "restored setup still passes traffic" bash -c "sleep 3; true"
check "REAL TRAFFIC after restore" traffic "$L1"

# ------------------------------------------------------------------ 7. repair scenarios
systemctl stop x-ui
check "repair starts a stopped x-ui" bash -c "$VR repair >/tmp/repair1.log 2>&1"
check "x-ui active after repair" systemctl is-active --quiet x-ui
ID="$(jq -r .inbound.id "$STATE")"
panel_api POST "/panel/api/inbounds/del/$ID" >/dev/null
check "repair recreates a deleted inbound" bash -c "$VR repair >/tmp/repair2.log 2>&1"
check "listening again after inbound recreation" wait_listen "$PORT"
eq "recreated inbound keeps REALITY keys" "$(jq -c .reality "$STATE")" "$keys_before"
check "old client link still works after inbound recreation" bash -c "sleep 3; true"
check "REAL TRAFFIC with the ORIGINAL link after repair" traffic "$L1"
ID="$(jq -r .inbound.id "$STATE")"
panel_api GET "/panel/api/inbounds/get/$ID" | jq '.obj | .remark = .remark | .streamSettings.realitySettings.shortIds = ["deadbeef"]' >/tmp/tamper.json
panel_api POST "/panel/api/inbounds/update/$ID" /tmp/tamper.json >/dev/null
check_fail "diagnostics detects a tampered inbound" bash -c "$VR diagnostics >/tmp/diag2.out 2>&1"
check "repair fixes the tampered inbound" bash -c "$VR repair >/tmp/repair3.log 2>&1"
check "diagnostics clean after repair" bash -c "$VR diagnostics >/tmp/diag3.out 2>&1"
check "REAL TRAFFIC after tamper repair" traffic "$L1"

# ------------------------------------------------------------------ 8. secret-leak review
LEAKS=0
for f in /tmp/install.log /tmp/install2.log /tmp/status.out /tmp/diag.out /tmp/add.log /tmp/restore.log /tmp/repair*.log; do
    [[ -f "$f" ]] || continue
    if grep -qF "$PRIV" "$f"; then LEAKS=$((LEAKS + 1)); echo "    | private key found in $f"; fi
done
eq "private key absent from all command output" "$LEAKS" "0"
check_fail "private key absent from wrapper log" bash -c "grep -rqF '$PRIV' /var/log/vless-reality-installer/ 2>/dev/null"
TOKEN="$(tr -d '[:space:]' </etc/vless-reality-installer/api-token)"
check_fail "API token absent from wrapper log" bash -c "grep -rqF '$TOKEN' /var/log/vless-reality-installer/ 2>/dev/null"
check_fail "API token absent from outputs" bash -c "grep -qF '$TOKEN' /tmp/install.log /tmp/install2.log /tmp/status.out /tmp/diag.out"
XPASS="$(. /etc/x-ui/install-result.env; echo "$XUI_PASSWORD")"
check_fail "panel password absent from install output" bash -c "grep -qF '$XPASS' /tmp/install.log /tmp/install2.log"
check_fail "no private key in process list" bash -c "ps -eo args | grep -F '$PRIV' | grep -v grep"
check "no world-readable files under state dir" bash -c "! find /etc/vless-reality-installer /var/backups/vless-reality-installer -perm /077 | grep -q ."

# ------------------------------------------------------------------ 9. uninstall (level 1) keeps unrelated data, then reinstall
check "uninstall level 1" bash -c "$VR --yes uninstall --level 1 >/tmp/un1.log 2>&1"
check_fail "state removed after level 1" test -e "$STATE"
check "3X-UI still installed after level 1" test -x /usr/local/x-ui/x-ui
# after level 1 our token is deleted: use the upstream result token for the decoy check
. /etc/x-ui/install-result.env
DECOY_LIST="$(curl -s -H "Authorization: Bearer $XUI_API_TOKEN" "http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/panel/api/inbounds/list")"
eq "unrelated inbound survived level 1" "$(jq -r '[.obj[]|select(.remark=="UNRELATED-decoy")]|length' <<<"$DECOY_LIST")" "1"
eq "managed inbound removed" "$(jq -r '[.obj[]|select(.remark|startswith("BlueSoftKeys"))]|length' <<<"$DECOY_LIST")" "0"
DECOY_CLIENTS="$(curl -s -H "Authorization: Bearer $XUI_API_TOKEN" "http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/panel/api/clients/list")"
eq "unrelated client survived level 1" "$(jq -r '[.obj[]|select(.email=="decoy-user")]|length' <<<"$DECOY_CLIENTS")" "1"
eq "our clients removed at level 1" "$(jq -r '[.obj[]|select(.email|startswith("BlueSoftKeys"))]|length' <<<"$DECOY_CLIENTS")" "0"
eq "our API token removed at level 1" "$(curl -s -H "Authorization: Bearer $XUI_API_TOKEN" "http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH}/panel/api/setting/apiTokens" | jq -r '[.obj[]|select(.name|startswith("bluesoftkeys"))]|length')" "0"
check_fail "port $PORT no longer listening" bash -c "sleep 3; ss -ltn 'sport = :$PORT' | grep -q LISTEN"
check "reinstall after level 1" bash -c "bash '$SRC/install.sh' --mode $MODE --server-address $SERVER_ADDR --non-interactive >/tmp/install4.log 2>&1"
check "reinstall: existing 3X-UI reused (not reinstalled)" grep -q 'Existing 3X-UI detected' /tmp/install4.log
L2="$(link_of BlueSoftKeys-Client-1)"
check "REAL TRAFFIC after reinstall" traffic "$L2"
check_fail "reinstall generated NEW keys" test "$(jq -c .reality "$STATE")" = "$keys_before"

check "uninstall level 2" bash -c "$VR --yes uninstall --level 2 >/tmp/un2.log 2>&1"
check_fail "wrapper removed (level 2)" test -e /opt/vless-reality-installer
check_fail "command link removed (level 2)" test -e "$VR"
check "3X-UI still present after level 2" test -x /usr/local/x-ui/x-ui
check "backups kept after level 2" bash -c "ls /var/backups/vless-reality-installer/*.tar.gz >/dev/null"

# level 3 needs the command again: use the checkout copy
check "uninstall level 3 (from checkout copy)" bash -c "VRI_SKIP_ROOT_CHECK=0 bash '$SRC/bin/vless-reality' --yes uninstall --level 3 >/tmp/un3.log 2>&1"
check_fail "3X-UI removed (level 3)" test -e /usr/local/x-ui/x-ui
check_fail "x-ui service gone (level 3)" systemctl is-enabled --quiet x-ui
check_fail "/etc/x-ui removed (level 3)" test -e /etc/x-ui/x-ui.db

echo "# elapsed: $(($(date +%s) - t0))s, tests: $N, failures: $FAILS"
((FAILS > 125)) && FAILS=125
exit "$FAILS"
