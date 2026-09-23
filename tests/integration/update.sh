#!/usr/bin/env bash
# In-container update test against REAL upstream releases: install an OLDER stable 3X-UI, then
#   1. inject a verification failure  -> must roll back to the old version with config + traffic intact
#   2. real update to the current stable -> must succeed and verify inbound/clients/port/links
#   3. guard rails: dev-latest / downgrade / already-current
# Usage: update.sh MODE [SRC_DIR] [OLD_TAG]
set -uo pipefail
MODE="${1:?mode}"
SRC="${2:-/src}"
OLD="${3:-v3.8.0}"
export VRI_TEST_MODE=1
VR=/usr/local/bin/vless-reality
STATE=/etc/vless-reality-installer/state.json
N=0 FAILS=0
case "$(uname -m)" in x86_64) XARCH=amd64 ;; aarch64) XARCH=arm64 ;; *) XARCH="$(uname -m)" ;; esac
XRAY="/usr/local/x-ui/bin/xray-linux-$XARCH"

ok() { N=$((N + 1)); printf 'ok %d - [update/%s] %s\n' "$N" "$MODE" "$1"; }
nok() { N=$((N + 1)); FAILS=$((FAILS + 1)); printf 'not ok %d - [update/%s] %s\n' "$N" "$MODE" "$1"; }
check() { local d="$1"; shift; if "$@" >/tmp/check.out 2>&1; then ok "$d"; else nok "$d"; sed 's/^/    | /' /tmp/check.out | head -15; fi; }
check_fail() { local d="$1"; shift; if "$@" >/tmp/check.out 2>&1; then nok "$d (unexpectedly succeeded)"; else ok "$d"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1 (got '$2', want '$3')"; fi; }
link_of() { "$VR" info "$1" 2>/dev/null | grep -o 'vless://[^ ]*' | head -n1; }
traffic() {
    local cfg pid rc=1
    cfg="$(mktemp /tmp/client.XXXXXX.json)"
    bash "$SRC/tests/integration/link2client.sh" "$1" 10851 127.0.0.1 >"$cfg" || return 2
    "$XRAY" run -c "$cfg" >/tmp/xray-client.log 2>&1 &
    pid=$!
    sleep 2
    curl -s -m 25 --socks5-hostname 127.0.0.1:10851 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^tls=TLSv1.3' && rc=0
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$cfg"
    return $rc
}

echo "# update test: mode=$MODE old=$OLD os=$(. /etc/os-release && echo "$PRETTY_NAME")"
check "install with pinned OLD stable $OLD" bash -c "bash '$SRC/install.sh' --mode $MODE --panel-version $OLD --server-address 127.0.0.1 --non-interactive >/tmp/install.log 2>&1"
if ((FAILS)); then tail -20 /tmp/install.log; exit 1; fi
eq "old version installed" "v$(/usr/local/x-ui/x-ui -v)" "$OLD"
check "add a second client before updating" $VR add-client Alice
L1="$(link_of BlueSoftKeys-Client-1)"
LA="$(link_of Alice)"
keys="$(jq -c .reality "$STATE")"
check "traffic works on the old version" traffic "$L1"

# ---- guard rails
check_fail "update to dev-latest is refused" $VR --yes update --panel-version dev-latest
check_fail "downgrade is refused" $VR --yes update --panel-version v3.6.0
check_fail "non-semver tag is refused" $VR --yes update --panel-version v3.8

# ---- 1. failed update -> rollback
check_fail "update with an injected verification failure fails" env VRI_TEST_FORCE_VERIFY_FAIL=1 $VR --yes update
eq "rolled back to the old version" "v$(/usr/local/x-ui/x-ui -v)" "$OLD"
check "x-ui active after rollback" systemctl is-active --quiet x-ui
check "state intact after rollback" test "$(jq -c .reality "$STATE")" = "$keys"
check "diagnostics clean after rollback" bash -c "$VR diagnostics >/tmp/diag-rb.out 2>&1"
check "traffic works after rollback (original link)" traffic "$L1"
check "second client survived rollback" traffic "$LA"

# ---- 2. real update
check "real update to current stable succeeds" bash -c "$VR --yes update >/tmp/update.log 2>&1"
NEW="v$(/usr/local/x-ui/x-ui -v)"
[[ "$NEW" != "$OLD" ]] && ok "version changed $OLD -> $NEW" || nok "version did not change"
check "backup archive with program snapshot exists" bash -c "ls /var/backups/vless-reality-installer/vri-backup-pre-update-*.tar.gz >/dev/null"
eq "state records the new panel version" "$(jq -r .panel.version "$STATE")" "$NEW"
eq "REALITY keys unchanged by update" "$(jq -c .reality "$STATE")" "$keys"
eq "both clients still present" "$($VR clients | grep -c -E 'BlueSoftKeys-Client-1|Alice')" "2"
check "diagnostics clean after update" bash -c "$VR diagnostics >/tmp/diag-up.out 2>&1"
check "traffic works after update (original link)" traffic "$L1"
check "traffic works after update (second client)" traffic "$LA"
check "update log never mentions dev-latest" bash -c "! grep -qi 'dev-latest' /tmp/update.log"

# ---- 3. already current
check "second update is a no-op" bash -c "$VR --yes update 2>&1 | grep -q 'already at'"

# ---- 4. wrapper self-update from a local (test) tarball: atomic, state preserved
mkdir -p /tmp/selfsrc && cp -a "$SRC/." /tmp/selfsrc/ && echo "9.9.9-test" >/tmp/selfsrc/VERSION
(cd /tmp/selfsrc && bash tools/gen-sums.sh >/dev/null && tar -czf /tmp/self.tgz --transform 's,^\./,vri-9.9.9/,' --exclude=tests/results .)
check "self-update installs the new wrapper" bash -c "VRI_SELF_TARBALL_URL=file:///tmp/self.tgz $VR update --self >/tmp/self.log 2>&1"
eq "wrapper version updated" "$(tr -d '[:space:]' </opt/vless-reality-installer/VERSION)" "9.9.9-test"
check "state untouched by self-update" test "$(jq -c .reality "$STATE")" = "$keys"
check "command still works after self-update" bash -c "$VR status >/dev/null 2>&1"
# corrupted download: checksum mismatch must keep the installed version
(cd /tmp/selfsrc && echo "# tampered" >>lib/common.sh && tar -czf /tmp/self-bad.tgz --transform 's,^\./,vri-bad/,' --exclude=tests/results .)
check_fail "tampered self-update is rejected" bash -c "VRI_SELF_TARBALL_URL=file:///tmp/self-bad.tgz $VR update --self --force >/tmp/self-bad.log 2>&1"
eq "wrapper unchanged after rejected update" "$(tr -d '[:space:]' </opt/vless-reality-installer/VERSION)" "9.9.9-test"

echo "# tests: $N, failures: $FAILS"
exit $((FAILS > 125 ? 125 : FAILS))
