#!/usr/bin/env bats
# Upstream handling: stable discovery, dev-latest exclusion, download failures, install-result parsing, token safety.

setup() {
    load helpers
    vri_test_env
    start_mock
    load_libs
}
teardown() { stop_mock; }

@test "stable release discovery follows the /releases/latest redirect" {
    mock_ctl '{"latest_tag":"v3.9.1"}'
    run upstream_latest_stable
    [ "$status" -eq 0 ]
    [ "$output" = "v3.9.1" ]
}

@test "dev-latest is never returned as the stable release" {
    mock_ctl '{"latest_tag":"dev-latest"}'
    run upstream_latest_stable
    [ "$status" -ne 0 ]
    [[ "$output" != *dev-latest* ]]
}

@test "pre-release style tags are rejected" {
    mock_ctl '{"latest_tag":"v3.9.0-rc1"}'
    run upstream_latest_stable
    [ "$status" -ne 0 ]
}

@test "release discovery fails cleanly when GitHub is unreachable" {
    export VRI_UPSTREAM_WEB="http://127.0.0.1:9/web" VRI_UPSTREAM_API="http://127.0.0.1:9/api"
    load_libs
    run upstream_latest_stable
    [ "$status" -ne 0 ]
}

@test "installing a non-stable ref is refused before any download" {
    for ref in dev-latest dev main v3.8; do
        run upstream_install "$ref"
        [ "$status" -ne 0 ]
        [[ "$output" == *"non-stable"* ]]
    done
}

@test "upstream_fetch_script: download failure (404) is reported" {
    run upstream_fetch_script install.sh v9.9.9
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to download"* ]]
}

@test "upstream_fetch_script refuses a script that no longer verifies checksums" {
    mkdir -p "$T/upstream/v3.8.5"
    printf '#!/bin/bash\n# MHSanaei/3x-ui\necho installing without any verification\n' >"$T/upstream/v3.8.5/install.sh"
    run upstream_fetch_script install.sh v3.8.5
    [ "$status" -ne 0 ]
    [[ "$output" == *"no longer verifies release checksums"* ]]
}

@test "upstream_fetch_script refuses non-bash / foreign content" {
    mkdir -p "$T/upstream/v3.8.5"
    printf 'PK\x03\x04binary' >"$T/upstream/v3.8.5/install.sh"
    run upstream_fetch_script install.sh v3.8.5
    [ "$status" -ne 0 ]
    printf '#!/bin/bash\necho hi # sha256\n' >"$T/upstream/v3.8.5/install.sh"
    run upstream_fetch_script install.sh v3.8.5
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not reference MHSanaei/3x-ui"* ]]
}

@test "upstream_install: runs unattended, sets no credentials, never echoes credentials" {
    prepare_uninstalled_panel
    run upstream_install v3.8.5
    [ "$status" -eq 0 ]
    [[ "$output" != *"hunter2-secret-pass"* ]]
    [[ "$output" != *"admin-secret-user"* ]]
    [[ "$output" != *"leaked-token-value"* ]]
    [ -f "$XUI_MAIN_FOLDER/.installed" ]
}

@test "upstream_install failure: filtered output, no credential leak, non-zero" {
    prepare_uninstalled_panel
    export FAKE_INSTALL_FAIL=1
    run upstream_install v3.8.5
    [ "$status" -ne 0 ]
    [[ "$output" != *"hunter2-secret-pass"* ]]
    [[ "$output" != *"leaked-token-value"* ]]
    [[ "$output" == *"upstream script failed"* ]]
}

write_result() { # content
    printf '%s' "$1" >"$VRI_XUI_ETC/install-result.env"
    chmod "${2:-600}" "$VRI_XUI_ETC/install-result.env"
}

@test "install-result.env: valid file is parsed" {
    write_result $'XUI_USERNAME=u\nXUI_PASSWORD=p\nXUI_PANEL_PORT=9821\nXUI_WEB_BASE_PATH=abcDEF123456\nXUI_API_TOKEN=tok_0123456789abcdef0123\nXUI_DB_TYPE=sqlite\n'
    upstream_result_load
    [ "$XUI_PANEL_PORT" = "9821" ]
    [ "$XUI_WEB_BASE_PATH" = "abcDEF123456" ]
    [ "$XUI_API_TOKEN" = "tok_0123456789abcdef0123" ]
}

@test "install-result.env: %q-quoted values (as written by upstream) are handled" {
    write_result "$(printf 'XUI_USERNAME=%q\nXUI_PASSWORD=%q\nXUI_PANEL_PORT=%q\nXUI_WEB_BASE_PATH=%q\nXUI_API_TOKEN=%q\n' 'u s' 'p a$s"s' 9821 abcDEF123456 tok_0123456789abcdef0123)"
    upstream_result_load
    [ "$XUI_PASSWORD" = 'p a$s"s' ]
}

@test "install-result.env: missing file" {
    rm -f "$VRI_XUI_ETC/install-result.env"
    run upstream_result_load
    [ "$status" -ne 0 ]
}

@test "install-result.env: malformed content is rejected without executing it" {
    write_result $'XUI_PANEL_PORT=$(touch '"$T"$'/pwned)\nthis is not shell ((\n'
    run upstream_result_load
    [ "$status" -ne 0 ]
    [ ! -e "$T/pwned" ]
}

@test "install-result.env: invalid fields are rejected (port / base path / token)" {
    write_result $'XUI_PANEL_PORT=99999\nXUI_WEB_BASE_PATH=abcDEF123456\nXUI_API_TOKEN=tok_0123456789abcdef0123\n'
    run upstream_result_load; [ "$status" -ne 0 ]
    write_result $'XUI_PANEL_PORT=9821\nXUI_WEB_BASE_PATH=a/b\nXUI_API_TOKEN=tok_0123456789abcdef0123\n'
    run upstream_result_load; [ "$status" -ne 0 ]
    write_result $'XUI_PANEL_PORT=9821\nXUI_WEB_BASE_PATH=abcDEF123456\nXUI_API_TOKEN=\n'
    run upstream_result_load; [ "$status" -ne 0 ]
}

@test "install-result.env: group/world-readable file is refused" {
    write_result $'XUI_PANEL_PORT=9821\nXUI_WEB_BASE_PATH=abcDEF123456\nXUI_API_TOKEN=tok_0123456789abcdef0123\n' 644
    run upstream_result_load
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe permissions"* ]]
}

@test "token acquisition: env > own file > install-result; the CLI 'getApiToken' is NEVER called" {
    api_configure
    # own token file is valid
    printf '%s\n' "$MOCK_TOKEN" >"$VRI_STATE_DIR.tok" && mkdir -p "$VRI_STATE_DIR" && mv "$VRI_STATE_DIR.tok" "$VRI_STATE_DIR/api-token"
    api_acquire_token
    [ "$API_TOKEN_SOURCE" = "file" ]
    # invalid env token falls through to the file
    VRI_XUI_API_TOKEN=wrong-token-value-123456 api_acquire_token
    [ "$API_TOKEN_SOURCE" = "file" ]
    # nothing works -> failure, still no getApiToken
    rm -f "$VRI_STATE_DIR/api-token" "$VRI_XUI_ETC/install-result.env"
    VRI_XUI_API_TOKEN= run api_acquire_token
    [ "$status" -ne 0 ]
    [ ! -e "$MOCK_DIR/getApiToken.called" ]
}

@test "panel settings come from the read-only CLI (no secrets)" {
    unset VRI_PANEL_URL
    upstream_panel_settings
    [ "$PANEL_PORT" = "$MOCK_PORT" ]
    [ "$PANEL_BASE_PATH" = "$MOCK_BASE" ]
    [ ! -e "$MOCK_DIR/getApiToken.called" ]
}

@test "service failure: repair cannot start x-ui -> clear error" {
    touch "$MOCK_DIR/svc_inactive" "$MOCK_DIR/svc_start_fails"
    printf '{}' >/dev/null
    run repair_ensure_service
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot start x-ui"* ]]
}
