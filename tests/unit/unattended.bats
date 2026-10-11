#!/usr/bin/env bats
# Regression coverage for unattended apt/dpkg/upstream execution and needrestart.

setup() {
    load helpers
    vri_test_env
    load_libs
}

@test "unattended runner scopes apt, debconf and needrestart settings and closes stdin" {
    probe="$T/probe.sh"
    cat >"$probe" <<'EOS'
#!/bin/bash
set -eu
[[ "$DEBIAN_FRONTEND" == noninteractive ]]
[[ "$DEBCONF_NONINTERACTIVE_SEEN" == true ]]
[[ "$DEBIAN_PRIORITY" == critical ]]
[[ "$NEEDRESTART_MODE" == a ]]
[[ "$APT_LISTCHANGES_FRONTEND" == none ]]
[[ "$UCF_FORCE_CONFFOLD" == 1 ]]
[[ -r "$APT_CONFIG" ]]
[[ "$(stat -c %a "$APT_CONFIG")" == 600 ]]
grep -q 'APT::Get::Assume-Yes "true"' "$APT_CONFIG"
grep -q -- '--force-confdef' "$APT_CONFIG"
grep -q -- '--force-confold' "$APT_CONFIG"
if IFS= read -r unexpected; then exit 91; fi
printf 'unattended-ok\n'
EOS
    chmod +x "$probe"

    run vri_unattended_run "$probe"
    [ "$status" -eq 0 ]
    [[ "$output" == *unattended-ok* ]]
    [[ -f "$VRI_TMP/apt-unattended.conf" ]]
    old_tmp="$VRI_TMP"
    vri_tmp_cleanup
    [[ ! -e "$old_tmp" ]]
}

@test "unattended environment is process scoped" {
    unset DEBIAN_FRONTEND DEBCONF_NONINTERACTIVE_SEEN DEBIAN_PRIORITY NEEDRESTART_MODE APT_LISTCHANGES_FRONTEND UCF_FORCE_CONFFOLD APT_CONFIG
    vri_unattended_run true
    [[ -z "${DEBIAN_FRONTEND:-}${DEBCONF_NONINTERACTIVE_SEEN:-}${DEBIAN_PRIORITY:-}${NEEDRESTART_MODE:-}${APT_LISTCHANGES_FRONTEND:-}${UCF_FORCE_CONFFOLD:-}${APT_CONFIG:-}" ]]
}

@test "watchdog streams output and preserves command failures" {
    run vri_watchdog_run bash -c 'printf "first line\n"; exit 37'
    [ "$status" -eq 37 ]
    [[ "$output" == *"first line"* ]]
}

@test "watchdog allows long commands that keep producing output" {
    VRI_INACTIVITY_TIMEOUT=2 run vri_watchdog_run bash -c 'for n in 1 2 3 4; do echo "tick-$n"; sleep 1; done'
    [ "$status" -eq 0 ]
    [[ "$output" == *tick-1* && "$output" == *tick-4* ]]
}

@test "watchdog returns 124 for a genuinely inactive command" {
    VRI_INACTIVITY_TIMEOUT=1 run vri_watchdog_run bash -c 'sleep 10'
    [ "$status" -eq 124 ]
    [[ "$output" == *"produced no output"* ]]
}

@test "newer installed kernel recommends a manual reboot without rebooting" {
    mkdir -p "$T/modules/6.8.0-139-generic" "$T/modules/6.8.0-146-generic"
    VRI_MODULES_DIR="$T/modules" VRI_RUNNING_KERNEL=6.8.0-139-generic run os_warn_reboot_if_kernel_changed
    [ "$status" -eq 0 ]
    [[ "$output" == *"newer kernel is installed"* ]]
    [[ "$output" == *"reboot the VPS manually"* ]]
    [[ "$output" == *"without rebooting"* ]]
}

@test "no package path performs an OS upgrade or uses unsupported awk interactive mode" {
    run grep -RInE 'apt(-get)?[[:space:]]+(full-upgrade|upgrade)|awk[[:space:]]+-W[[:space:]]*interactive' install.sh lib bin
    [ "$status" -ne 0 ]
}

@test "bootstrap apt path has the same noninteractive safeguards" {
    grep -q 'DEBIAN_FRONTEND=noninteractive' install.sh
    grep -q 'NEEDRESTART_MODE=a' install.sh
    grep -q 'APT_CONFIG=' install.sh
    grep -q -- '--force-confdef' install.sh
    grep -q -- '--force-confold' install.sh
    grep -q '</dev/null' install.sh
    grep -q 'bootstrap_watchdog_run.*apt-get install' install.sh
}
