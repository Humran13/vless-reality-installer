#!/usr/bin/env bats
# CLI behaviour of bin/vless-reality install: argument validation, port handling, exit codes (mock panel, fake systemctl/ss).

setup() {
    load helpers
    vri_test_env
    start_mock
    export PATH="$T/shims:$PATH"
    VR="$REPO/bin/vless-reality"
}
teardown() { stop_mock; }

run_install() { run bash "$VR" install --non-interactive "$@"; }

@test "help and version work without root or state" {
    run bash "$VR" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: vless-reality"* ]]
    [[ "$output" == *"--mode tcp|grpc|xhttp"* ]]
    run bash "$VR" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"BlueSoftKeys VLESS Reality Installer"* ]]
    run bash "$VR" version
    [ "$status" -eq 0 ]
}

@test "unknown command / unknown option / missing option value -> usage error (exit 2)" {
    run bash "$VR" frobnicate; [ "$status" -eq 2 ]
    run bash "$VR" install --bogus; [ "$status" -eq 2 ]
    run bash "$VR" install --mode; [ "$status" -eq 2 ]
    run bash "$VR" install --port --mode tcp; [ "$status" -eq 2 ]
}

@test "install: invalid mode is rejected before touching anything (exit 2)" {
    printf '%s' "ID=ubuntu
VERSION_ID=\"24.04\"" >"$T/os-release"; export VRI_OS_RELEASE_FILE="$T/os-release"
    for bad in ws websocket kcp httpupgrade h2 "tcp;id" "" "TCP"; do
        run_install --mode "$bad"
        [ "$status" -eq 2 ] || { echo "mode '$bad' => $status: $output"; return 1; }
    done
    [ ! -e "$VRI_STATE_DIR/state.json" ]
}

@test "install: invalid port / hostname / target / SNI / client name / paths are rejected (exit 2)" {
    printf '%s' "ID=ubuntu
VERSION_ID=\"24.04\"" >"$T/os-release"; export VRI_OS_RELEASE_FILE="$T/os-release"
    prepare_uninstalled_panel
    export XUI_MAIN_FOLDER="$T/xui"
    cases=(
        "--port 0" "--port 65536" "--port abc" "--port 44a" "--port 443;id"
        "--server-address bad_host!" "--server-address 999.1.1.1" "--server-address a.com;id"
        "--reality-target nohostport" "--reality-target a.com:99999" "--reality-target a.com;id:443"
        "--sni 1.2.3.4" "--sni a_b.com" "--sni a.com;id"
        "--client-name a;id" "--client-name a\$(id)" "--client-name -x" "--client-name a/b"
        "--grpc-service-name a;b" "--grpc-service-name /x"
        "--xhttp-path nopath" "--xhttp-path /a\ b" "--xhttp-path //x"
    )
    for c in "${cases[@]}"; do
        mode=grpc
        [[ "$c" == --xhttp-path* ]] && mode=xhttp
        # shellcheck disable=SC2086
        run_install --mode $mode $c
        [ "$status" -ne 0 ] || { echo "accepted: $c"; return 1; }
        [ ! -e "$XUI_MAIN_FOLDER/.installed" ] || { echo "panel install started for: $c"; return 1; }
    done
}

@test "install: no command injection through option values" {
    printf '%s' "ID=ubuntu
VERSION_ID=\"24.04\"" >"$T/os-release"; export VRI_OS_RELEASE_FILE="$T/os-release"
    prepare_uninstalled_panel
    run_install --mode tcp --client-name 'x;touch /tmp/vri-pwned'
    run_install --mode tcp --sni '$(touch /tmp/vri-pwned2).com'
    run_install --mode tcp --port '1;touch /tmp/vri-pwned3'
    [ ! -e /tmp/vri-pwned ] && [ ! -e /tmp/vri-pwned2 ] && [ ! -e /tmp/vri-pwned3 ]
}

@test "install: unsupported OS fails with exit 3 and a reason" {
    printf 'ID=fedora\nVERSION_ID="40"\n' >"$T/os-release"; export VRI_OS_RELEASE_FILE="$T/os-release"
    run_install --mode tcp
    [ "$status" -eq 3 ]
    [[ "$output" == *"unsupported OS"* ]]
}

@test "install: unsupported architecture fails with exit 3" {
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$T/os-release"; export VRI_OS_RELEASE_FILE="$T/os-release" VRI_UNAME_M=armv7l
    run_install --mode tcp
    [ "$status" -eq 3 ]
    [[ "$output" == *"unsupported CPU architecture"* ]]
}

@test "commands that need a setup fail clearly when nothing is installed" {
    for c in status info clients diagnostics backup "remove-client x" "enable-client x" "disable-client x" repair; do
        # shellcheck disable=SC2086
        run bash "$VR" $c
        [ "$status" -eq 6 ] || { echo "$c => $status: $output"; return 1; }
        [[ "$output" == *"no BlueSoftKeys-managed"* ]]
    done
}

@test "uninstall non-interactive requires an explicit --level" {
    run bash "$VR" uninstall --non-interactive
    [ "$status" -eq 2 ]
    [[ "$output" == *"--level"* ]]
    run bash "$VR" uninstall --level 9 --yes
    [ "$status" -eq 2 ]
}

@test "root is required for real commands" {
    unset VRI_SKIP_ROOT_CHECK
    if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
    run bash "$VR" status
    [ "$status" -eq 3 ]
    [[ "$output" == *"must be run as root"* ]]
}
