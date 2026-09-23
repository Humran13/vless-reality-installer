#!/usr/bin/env bats
# Firewall: only add our own allow rule, never touch/flush anything else, uninstall removes only ours.

setup() {
    load helpers
    vri_test_env
    load_libs
    mkdir -p "$VRI_STATE_DIR"
    MODE=tcp PORT=443 SERVER_ADDR=1.2.3.4 INBOUND_ID=1 INBOUND_TAG=t R_TARGET=a.b.c:443 R_SNI=a.b.c R_PRIV=x R_PUB=y R_SID=aa R_FINGERPRINT=chrome MODE_OPTS_JSON='{}'
    state_create
}

@test "UFW not installed: nothing is run, message explains cloud firewalls" {
    rm -f "$T/shims/ufw"
    # Some CI images preinstall /usr/sbin/ufw. Keep the fixture independent of
    # the host while retaining the ordinary commands needed by the test.
    PATH="$T/shims:/usr/bin:/bin"
    run fw_open_port 443
    [ "$status" -eq 0 ]
    [[ "$output" == *"UFW is not installed"* ]]
}

@test "UFW inactive: we never enable it and add no rule" {
    run fw_open_port 443
    [ "$status" -eq 0 ]
    [[ "$output" == *"inactive"* ]]
    ! grep -q 'allow\|enable' "$MOCK_DIR/ufw.log"
    [ "$(jq -r '.firewall.ufw_rules | length' "$(state_file)")" = "0" ]
}

@test "UFW active: adds exactly one allow rule and records it" {
    touch "$MOCK_DIR/ufw_active"
    fw_open_port 443
    grep -qx '443/tcp' "$MOCK_DIR/ufw_rules"
    [ "$(grep -c '443/tcp' "$MOCK_DIR/ufw_rules")" = "1" ]
    [ "$(jq -r '.firewall.ufw_rules[0]' "$(state_file)")" = "443/tcp" ]
}

@test "duplicate run does not add a second rule" {
    touch "$MOCK_DIR/ufw_active"
    fw_open_port 443
    fw_open_port 443
    [ "$(grep -c '443/tcp' "$MOCK_DIR/ufw_rules")" = "1" ]
    [ "$(jq -r '.firewall.ufw_rules | length' "$(state_file)")" = "1" ]
}

@test "a pre-existing user rule is respected and NOT removed on uninstall" {
    touch "$MOCK_DIR/ufw_active"
    echo "443/tcp" >"$MOCK_DIR/ufw_rules"
    fw_open_port 443
    [ "$(jq -r '.firewall.ufw_rules | length' "$(state_file)")" = "0" ]
    fw_close_ours
    grep -qx '443/tcp' "$MOCK_DIR/ufw_rules"
}

@test "uninstall removes only OUR recorded rule, leaves unrelated rules" {
    touch "$MOCK_DIR/ufw_active"
    printf '22/tcp\n80/tcp\n' >"$MOCK_DIR/ufw_rules"
    fw_open_port 443
    fw_close_ours
    ! grep -qx '443/tcp' "$MOCK_DIR/ufw_rules"
    grep -qx '22/tcp' "$MOCK_DIR/ufw_rules"
    grep -qx '80/tcp' "$MOCK_DIR/ufw_rules"
    [ "$(jq -r '.firewall.ufw_rules | length' "$(state_file)")" = "0" ]
}

@test "destructive UFW/iptables/nft commands are never issued" {
    touch "$MOCK_DIR/ufw_active"
    fw_open_port 443
    fw_close_ours
    ! grep -Eq 'disable|reset|reload|default|--force reset' "$MOCK_DIR/ufw.log"
}

@test "state-recorded rule with a malicious value is ignored" {
    touch "$MOCK_DIR/ufw_active"
    state_update '.firewall.ufw_rules = ["443/tcp; ufw disable", "abc"]'
    fw_close_ours
    ! grep -q 'disable' "$MOCK_DIR/ufw.log"
}
