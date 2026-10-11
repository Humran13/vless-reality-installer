#!/usr/bin/env bash
# shellcheck shell=bash
# installer.sh - the `install` flow: fresh VPS -> official stable 3X-UI -> managed VLESS+REALITY inbound -> first client.
# Idempotent: a second run never creates duplicate inbounds/clients/rules/keys and never resets panel credentials.

PANEL_MARKER_NAME=".panel-installed-by-wrapper"

installer_panel_marker() { printf '%s/%s' "$VRI_STATE_DIR" "$PANEL_MARKER_NAME"; }

# ---------- input resolution ----------

install_choose_port() {
    local p owners
    if [[ -n "${OPT_PORT:-}" ]]; then
        valid_port "$OPT_PORT" || die "invalid --port '$OPT_PORT' (must be 1-65535)" "$VRI_EX_USAGE"
        p="$((10#$OPT_PORT))"
        if net_port_in_use "$p"; then
            owners="$(net_port_listeners "$p")"
            die "TCP port $p is already in use by ${owners:-another process}. I will not stop it; choose another --port." "$VRI_EX_ENV"
        fi
        PORT="$p"
        return 0
    fi
    p=443
    while :; do
        if ! net_port_in_use "$p"; then
            PORT="$p"
            return 0
        fi
        owners="$(net_port_listeners "$p")"
        log_warn "TCP port $p is already in use by ${owners:-another process} (I will not stop it)."
        if ((!VRI_INTERACTIVE)); then
            die "port $p is occupied; re-run with --port <free port> (e.g. --port 8443)" "$VRI_EX_ENV"
        fi
        vri_ask p "Enter another port for the VLESS inbound" "8443"
        valid_port "$p" || {
            log_err "invalid port"
            p=443
            continue
        }
        p="$((10#$p))"
    done
}

install_choose_address() {
    if [[ -n "${OPT_SERVER_ADDRESS:-}" ]]; then
        valid_server_address "$OPT_SERVER_ADDRESS" || die "invalid --server-address '$OPT_SERVER_ADDRESS' (IPv4 or hostname)" "$VRI_EX_USAGE"
        SERVER_ADDR="$OPT_SERVER_ADDRESS"
        return 0
    fi
    local ip
    if ip="$(net_detect_public_ip)"; then
        SERVER_ADDR="$ip"
        log_info "Detected public address: $SERVER_ADDR (override with --server-address)"
        return 0
    fi
    ((VRI_INTERACTIVE)) || die "could not detect this server's public IP; pass --server-address" "$VRI_EX_ENV"
    vri_ask SERVER_ADDR "Public IPv4 address or domain of this server" ""
    valid_server_address "$SERVER_ADDR" || die "invalid server address" "$VRI_EX_USAGE"
}

# ---------- panel ----------

install_ensure_panel() {
    local tag
    state_dir_init
    if upstream_installation_complete; then
        log_info "Existing 3X-UI detected ($(upstream_version || echo unknown)). It will not be reinstalled, reset or modified."
        [[ -e "$(installer_panel_marker)" ]] && PANEL_BY_US="true"
        if ! upstream_service_active; then
            log_info "x-ui service is not running; starting it"
            systemctl start "$UPSTREAM_SERVICE" || die "could not start the x-ui service (see: journalctl -u x-ui)" "$VRI_EX_UPSTREAM"
        fi
        api_configure || die "cannot determine the panel URL" "$VRI_EX_API"
        if ! api_acquire_token; then
            die "cannot authenticate to the existing 3X-UI panel. I will NOT reset credentials or regenerate tokens.
  Create an API token in the panel (Settings -> API Tokens), then re-run:
    sudo VRI_XUI_API_TOKEN='<token>' vless-reality install ..." "$VRI_EX_API"
        fi
    else
        if upstream_installed || upstream_service_exists; then
            log_warn "The 3X-UI installation is incomplete (binary or systemd unit missing); running the official installer to repair it."
        fi
        if [[ -n "${OPT_PANEL_VERSION:-}" ]]; then
            valid_stable_tag "$OPT_PANEL_VERSION" || die "--panel-version must be a stable tag like v3.8.5 (dev builds are never installed)" "$VRI_EX_USAGE"
            tag="$OPT_PANEL_VERSION"
        else
            tag="$(upstream_latest_stable)" || die "could not determine the latest stable 3X-UI release (GitHub unreachable or rate limited); try again later" "$VRI_EX_UPSTREAM"
        fi
        log_step "Installing official 3X-UI $tag"
        [[ "$tag" == "$TESTED_UPSTREAM" ]] || log_warn "3X-UI $tag differs from the version this wrapper was validated with ($TESTED_UPSTREAM); an API contract check follows"
        : >"$(installer_panel_marker)"
        chmod 600 "$(installer_panel_marker)"
        PANEL_BY_US="true"
        upstream_install "$tag" || die "the official 3X-UI installer failed; see the output above. Nothing else was changed." "$VRI_EX_UPSTREAM"
        api_configure || die "cannot determine the panel URL after installation" "$VRI_EX_API"
        upstream_result_load || die "3X-UI installed, but ${UPSTREAM_RESULT_FILE} is missing or malformed, so I cannot obtain its API token safely.
  I will not regenerate tokens or reset credentials. Create an API token in the panel (Settings -> API Tokens) and re-run with VRI_XUI_API_TOKEN=..." "$VRI_EX_UPSTREAM"
        api_set_token "$XUI_API_TOKEN"
        API_TOKEN_SOURCE="result"
        api_wait_ready 90 || die "3X-UI is installed but its API did not become ready: $API_MSG (see: systemctl status x-ui)" "$VRI_EX_UPSTREAM"
        log_ok "3X-UI $(upstream_version || echo "$tag") is running (Xray $(upstream_xray_version || echo '?'))"
    fi
    api_check_contract || die "incompatible 3X-UI API; aborting before making any change" "$VRI_EX_UPSTREAM"
    api_ensure_own_token
}

# ---------- inbound ----------

# Find our managed inbound in the panel by its remark prefix. Prints the JSON object of the first match.
install_find_our_inbound() {
    panel_inbounds_list || die "cannot list inbounds: $API_MSG" "$VRI_EX_API"
    jq -c --arg p "$INBOUND_REMARK_PREFIX" \
        '.obj // [] | map(select((.remark // "") | startswith($p))) | .[0] // empty' "$API_OUT"
}

# Rebuild state from an existing managed inbound (state lost, or install interrupted before the state was written).
adopt_inbound() { # inbound-json
    local inb="$1" net m
    net="$(jq -r '(.streamSettings | if type == "string" then fromjson else . end).network' <<<"$inb")"
    MODE=""
    for m in "${VRI_MODES[@]}"; do
        [[ "$(mode_call "$m" network)" == "$net" ]] && MODE="$m"
    done
    [[ -n "$MODE" ]] || die "found inbound '$(jq -r .remark <<<"$inb")' with unsupported network '$net'; not adopting it" "$VRI_EX_STATE"
    local sf
    sf="$(vri_mktemp adopt)"
    jq -c '.streamSettings | if type == "string" then fromjson else . end' <<<"$inb" >"$sf"
    INBOUND_ID="$(jq -r '.id' <<<"$inb")"
    INBOUND_TAG="$(jq -r '.tag' <<<"$inb")"
    PORT="$(jq -r '.port' <<<"$inb")"
    SERVER_ADDR="$(jq -r 'if (.shareAddr // "") != "" then .shareAddr else "" end' <<<"$inb")"
    [[ -n "$SERVER_ADDR" ]] || install_choose_address
    R_TARGET="$(jq -r '.realitySettings.target // .realitySettings.dest // ""' "$sf")"
    R_SNI="$(jq -r '.realitySettings.serverNames[0] // ""' "$sf")"
    R_PRIV="$(jq -r '.realitySettings.privateKey // ""' "$sf")"
    R_PUB="$(jq -r '.realitySettings.settings.publicKey // ""' "$sf")"
    R_SID="$(jq -r '.realitySettings.shortIds[0] // ""' "$sf")"
    R_FINGERPRINT="$(jq -r '.realitySettings.settings.fingerprint // "chrome"' "$sf")"
    MODE_OPTS_JSON="$(mode_call "$MODE" extract_opts "$sf")"
    vri_secret_add "$R_PRIV"
    if ! { valid_reality_key "$R_PRIV" && valid_reality_key "$R_PUB" && valid_shortid "$R_SID"; }; then
        die "the existing inbound has incomplete REALITY settings; not adopting it. Remove it in the panel or run: sudo vless-reality uninstall" "$VRI_EX_STATE"
    fi
    state_create || die "cannot write state" "$VRI_EX_STATE"
    # restore client records
    local row
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        state_client_upsert "$(jq -r '.email' <<<"$row")" "$(jq -r '.uuid' <<<"$row")" "$(jq -r '.flow // ""' <<<"$row")" "$(jq -r '.enable' <<<"$row")" || true
    done < <(panel_clients_list && jq -c --argjson id "$INBOUND_ID" '.obj[] | select((.inboundIds // []) | index($id) != null)' "$API_OUT")
    log_ok "Adopted the existing BlueSoftKeys inbound (id $INBOUND_ID, mode $MODE, port $PORT); state rebuilt"
}

install_create_inbound() {
    local body
    reality_choose_target
    reality_generate_keys
    reality_generate_shortid
    body="$(vri_mktemp inbound)"
    inbound_build_json >"$body"
    panel_inbound_add "$body" || die "the panel refused to create the inbound: $API_MSG" "$VRI_EX_API"
    INBOUND_ID="$(api_obj '.obj.id // empty')"
    INBOUND_TAG="$(api_obj '.obj.tag // empty')"
    [[ "$INBOUND_ID" =~ ^[0-9]+$ ]] || die "the panel did not return an inbound id" "$VRI_EX_API"
    state_create || die "cannot write state" "$VRI_EX_STATE"
    log_ok "Inbound created (id $INBOUND_ID, tag $INBOUND_TAG, port $PORT)"
}

# Wait until Xray listens on our port; restart Xray once via the official API if needed.
install_wait_listening() {
    local i restarted=0
    for ((i = 0; i < 40; i++)); do
        net_port_listening "$PORT" && return 0
        if ((i == 12 && !restarted)); then
            restarted=1
            log_info "Xray is not listening yet; asking the panel to restart it"
            panel_restart_xray || log_warn "restart request failed: $API_MSG"
        fi
        sleep 1
    done
    return 1
}

# ---------- main ----------

# Validate every user-supplied option BEFORE anything on the system is touched.
install_validate_options() {
    if [[ -n "${OPT_PORT:-}" ]]; then valid_port "$OPT_PORT" || die "invalid --port '$OPT_PORT' (must be 1-65535)" "$VRI_EX_USAGE"; fi
    if [[ -n "${OPT_SERVER_ADDRESS:-}" ]]; then valid_server_address "$OPT_SERVER_ADDRESS" || die "invalid --server-address '$OPT_SERVER_ADDRESS' (IPv4 or hostname)" "$VRI_EX_USAGE"; fi
    if [[ -n "${OPT_CLIENT_NAME:-}" ]]; then valid_client_name "$OPT_CLIENT_NAME" || die "invalid --client-name '$OPT_CLIENT_NAME'" "$VRI_EX_USAGE"; fi
    if [[ -n "${OPT_REALITY_TARGET:-}" ]]; then valid_target "$OPT_REALITY_TARGET" || die "invalid --reality-target '$OPT_REALITY_TARGET' (expected HOST:PORT)" "$VRI_EX_USAGE"; fi
    if [[ -n "${OPT_SNI:-}" ]]; then valid_sni "$OPT_SNI" || die "invalid --sni '$OPT_SNI'" "$VRI_EX_USAGE"; fi
    if [[ -n "${OPT_PANEL_VERSION:-}" ]]; then valid_stable_tag "$OPT_PANEL_VERSION" || die "--panel-version must be a stable tag like v3.8.5 (dev builds are never installed)" "$VRI_EX_USAGE"; fi
    if [[ -n "${OPT_GRPC_SERVICE_NAME:-}" && "${OPT_MODE:-}" == "grpc" ]]; then
        valid_grpc_service "$OPT_GRPC_SERVICE_NAME" || die "invalid --grpc-service-name '$OPT_GRPC_SERVICE_NAME'" "$VRI_EX_USAGE"
    fi
    if [[ -n "${OPT_XHTTP_PATH:-}" && "${OPT_MODE:-}" == "xhttp" ]]; then
        valid_xhttp_path "$OPT_XHTTP_PATH" || die "invalid --xhttp-path '$OPT_XHTTP_PATH'" "$VRI_EX_USAGE"
    fi
    return 0
}

installer_run() {
    local recover_existing=0
    output_banner
    vri_require_root
    vri_tmp_init
    vri_lock
    # cheap, side-effect-free validation first: nothing on the system is touched for a bad command line
    if [[ -n "${OPT_MODE:-}" ]]; then valid_mode "$OPT_MODE" || die "invalid --mode '$OPT_MODE' (valid: ${VRI_MODES[*]})" "$VRI_EX_USAGE"; fi
    install_validate_options
    log_step "Checking the system"
    os_check_all
    os_install_deps

    if state_exists && ! state_is_complete; then
        die "$(state_file) exists but is not a complete ${VRI_PRODUCT} state file. It will not be treated as an installed setup or overwritten; move it aside after inspecting it, then re-run." "$VRI_EX_STATE"
    fi

    if state_is_complete; then
        state_load
        if ! upstream_installation_complete; then
            recover_existing=1
            log_warn "A VLESS Reality project state exists, but 3X-UI or x-ui.service is missing; continuing through the installation path to repair it."
        else
            log_info "A BlueSoftKeys setup already exists on this server; verifying it instead of installing again."
            if [[ -n "${OPT_MODE:-}" && "$OPT_MODE" != "$MODE" ]]; then
                die "this server is already configured for mode '$MODE'. To switch modes run 'sudo vless-reality uninstall' (option 1) first, then install again." "$VRI_EX_STATE"
            fi
            repair_session_init
            install_management_command
            repair_run quiet
            if [[ "$(state_get '(.clients // []) | length')" == "0" ]]; then
                log_info "No client recorded (an earlier run was interrupted?); creating the first client"
                client_create "${OPT_CLIENT_NAME:-$DEFAULT_CLIENT_NAME}"
            fi
            output_info
            return 0
        fi
    fi

    # ----- decide inputs (before touching the system) -----
    if ((recover_existing)); then
        if [[ -n "${OPT_MODE:-}" && "$OPT_MODE" != "$MODE" ]]; then
            die "the recoverable project state is configured for mode '$MODE', not '$OPT_MODE'. Re-run without changing the mode." "$VRI_EX_STATE"
        fi
        log_info "Recovering mode: $(mode_call "$MODE" label)"
        mode_call "$MODE" validate || die "saved project state has invalid mode options; refusing unsafe automatic recovery" "$VRI_EX_STATE"
    elif [[ -z "${OPT_MODE:-}" ]]; then
        ((VRI_INTERACTIVE)) || die "no mode was specified and no interactive terminal is available; pass --mode tcp|grpc|xhttp" "$VRI_EX_USAGE"
        modes_choose
    fi
    if ((!recover_existing)); then
        valid_mode "$OPT_MODE" || die "invalid --mode '$OPT_MODE' (valid: ${VRI_MODES[*]})" "$VRI_EX_USAGE"
        MODE="$OPT_MODE"
        log_info "Mode: $(mode_call "$MODE" label)"
        mode_call "$MODE" defaults
        ((VRI_INTERACTIVE)) && mode_call "$MODE" prompt
        mode_call "$MODE" validate || die "invalid mode options" "$VRI_EX_USAGE"
        install_validate_options
    fi

    # ----- panel first: we may find an interrupted install to adopt -----
    log_step "3X-UI panel"
    local existing
    # port/address are only needed for a new inbound; but the panel must exist to know whether one already does
    install_ensure_panel
    if ((recover_existing)); then
        log_step "Repairing the incomplete VLESS Reality installation"
        repair_run quiet
    else
        existing="$(install_find_our_inbound)"
    fi
    if ((!recover_existing)) && [[ -n "$existing" ]]; then
        log_step "Found an existing BlueSoftKeys inbound"
        local existing_net want_net
        existing_net="$(jq -r '(.streamSettings | if type == "string" then fromjson else . end).network' <<<"$existing")"
        want_net="$(mode_call "$MODE" network)"
        if [[ "$existing_net" != "$want_net" && -n "${OPT_MODE:-}" ]]; then
            die "a BlueSoftKeys inbound with network '$existing_net' exists but you asked for '$MODE'. Use 'sudo vless-reality uninstall' (option 1) first." "$VRI_EX_STATE"
        fi
        adopt_inbound "$existing"
    elif ((!recover_existing)); then
        log_step "Preparing the VLESS REALITY inbound"
        install_choose_address
        install_choose_port
        install_create_inbound
    fi

    # ----- first client -----
    log_step "Creating the first client"
    local cname="${OPT_CLIENT_NAME:-$DEFAULT_CLIENT_NAME}"
    if [[ "$(state_get '(.clients // []) | length')" == "0" ]]; then
        client_create "$cname"
    fi

    log_step "Firewall"
    fw_open_port "$PORT"

    log_step "Verifying"
    install_wait_listening || die "Xray is not listening on TCP $PORT. Check: sudo vless-reality diagnostics" "$VRI_EX_STATE"
    log_ok "Xray is listening on TCP $PORT"
    panel_wait_xray_running 30 || die "Xray is in state '$XRAY_STATE' instead of 'running'. Check: sudo vless-reality diagnostics" "$VRI_EX_STATE"
    local first
    first="$(state_get '(.clients // [])[0].email')"
    client_link "$first" >/dev/null || die "the generated share link does not match the configuration (see warnings above)" "$VRI_EX_STATE"
    log_ok "Share link verified"

    install_management_command
    state_touch || true

    printf '\n%s\n' "${C_GRN}Installation complete.${C_OFF}" >&2
    output_connection_details
    output_client_block "$first"
    output_panel_hint
    printf '\nManage everything with: sudo vless-reality menu   (or: vless-reality help)\n'
    fw_reminder
    os_warn_reboot_if_kernel_changed
}

fw_reminder() {
    printf '\nIf your VPS provider has a cloud/network firewall, make sure TCP %s is allowed there.\n' "$PORT"
}

# Install /usr/local/bin/vless-reality -> installed code. When running from the installed copy this is a no-op.
install_management_command() {
    local target="$VRI_HOME/bin/vless-reality"
    if [[ "$VRI_ROOT_DIR" != "$VRI_HOME" && -x "$VRI_ROOT_DIR/bin/vless-reality" && ! -e "$target" ]]; then
        # running from a checkout (e.g. tests): copy the tree so the command keeps working after the checkout is gone
        selfupdate_install_tree "$VRI_ROOT_DIR" || log_warn "could not install the wrapper into $VRI_HOME"
    fi
    if [[ -x "$target" ]]; then
        if ln -sfn "$target" "$VRI_BIN_LINK"; then
            log_ok "Management command installed: $VRI_BIN_LINK"
        else
            log_warn "could not create $VRI_BIN_LINK"
        fi
    fi
}
