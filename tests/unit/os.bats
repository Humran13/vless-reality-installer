#!/usr/bin/env bats
# OS / architecture detection and classification (fake os-release files, no real system needed).

setup() {
    load helpers
    vri_test_env
    load_libs
}

fake_os() { # id version [pretty]
    printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s"\n' "$1" "$2" "${3:-$1 $2}" >"$T/os-release"
    export VRI_OS_RELEASE_FILE="$T/os-release"
    os_detect
    os_classify
}

@test "Ubuntu 22.04 / 24.04 / 26.04 are 'tested'" {
    for v in 22.04 24.04 26.04; do fake_os ubuntu "$v"; [ "$OS_SUPPORT" = "tested" ] || { echo "$v => $OS_SUPPORT"; return 1; }; done
}

@test "Ubuntu 18.04 and 20.04 are best-effort with an EOL warning (not rejected)" {
    for v in 18.04 20.04; do
        fake_os ubuntu "$v"
        [ "$OS_SUPPORT" = "best-effort" ]
        [[ "$OS_REASON" == *"past standard support"* ]]
    done
}

@test "Debian 12 and 13 are 'tested'" {
    for v in 12 13; do fake_os debian "$v"; [ "$OS_SUPPORT" = "tested" ]; done
}

@test "unknown FUTURE Ubuntu/Debian is best-effort, not rejected" {
    fake_os ubuntu 28.04; [ "$OS_SUPPORT" = "best-effort" ]; [[ "$OS_REASON" == *"newer than the newest tested"* ]]
    fake_os ubuntu 26.10; [ "$OS_SUPPORT" = "best-effort" ]
    fake_os debian 14; [ "$OS_SUPPORT" = "best-effort" ]
}

@test "too-old / unsupported distros are rejected with a reason" {
    fake_os ubuntu 16.04; [ "$OS_SUPPORT" = "unsupported" ]; [[ "$OS_REASON" == *"older than 18.04"* ]]
    fake_os debian 11; [ "$OS_SUPPORT" = "unsupported" ]
    fake_os fedora 40; [ "$OS_SUPPORT" = "unsupported" ]; [[ "$OS_REASON" == *"not Ubuntu or Debian"* ]]
    fake_os centos 9; [ "$OS_SUPPORT" = "unsupported" ]
    fake_os alpine 3.20; [ "$OS_SUPPORT" = "unsupported" ]
    fake_os debian sid; [ "$OS_SUPPORT" = "unsupported" ]
}

@test "arch normalisation: amd64 / arm64, others rejected" {
    for m in x86_64 amd64 x64; do VRI_UNAME_M=$m arch_detect; [ "$ARCH" = "amd64" ]; done
    for m in aarch64 arm64 armv8l; do VRI_UNAME_M=$m arch_detect; [ "$ARCH" = "arm64" ]; done
    for m in armv7l i686 s390x riscv64; do VRI_UNAME_M=$m arch_detect; [[ "$ARCH" == unsupported:* ]]; done
}

@test "os_check_all dies on unsupported OS unless --allow-unsupported-os" {
    fake_os fedora 40
    run bash -c ". '$REPO/lib/common.sh'; . '$REPO/lib/validate.sh'; . '$REPO/lib/os.sh'; VRI_UNAME_M=x86_64 VRI_SKIP_SYSTEMD_CHECK=1 os_check_all"
    [ "$status" -eq 3 ]
    [[ "$output" == *"unsupported OS"* ]]
    run bash -c ". '$REPO/lib/common.sh'; . '$REPO/lib/validate.sh'; . '$REPO/lib/os.sh'; VRI_UNAME_M=x86_64 VRI_SKIP_SYSTEMD_CHECK=1 OPT_ALLOW_UNSUPPORTED_OS=1 os_check_all"
    [[ "$output" == *"UNSUPPORTED"* ]]
}

@test "os_check_all rejects unsupported architecture with the exact reason" {
    fake_os ubuntu 24.04
    run bash -c ". '$REPO/lib/common.sh'; . '$REPO/lib/validate.sh'; . '$REPO/lib/os.sh'; VRI_UNAME_M=armv7l VRI_SKIP_SYSTEMD_CHECK=1 os_check_all"
    [ "$status" -eq 3 ]
    [[ "$output" == *"unsupported CPU architecture 'armv7l'"* ]]
}

@test "os-release parsing does not execute its content" {
    printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="x $(touch %s/pwned) `touch %s/pwned2`"\n' "$T" "$T" >"$T/os-release"
    export VRI_OS_RELEASE_FILE="$T/os-release"
    os_detect
    [ ! -e "$T/pwned" ]
    [ ! -e "$T/pwned2" ]
}
