#!/usr/bin/env bash
# shellcheck shell=bash
# uninstall.sh - three clearly separated levels. Only level 3 touches upstream 3X-UI.
#   1  remove BlueSoftKeys-managed VLESS REALITY configuration only (our inbound, clients, token, firewall rule, state)
#   2  level 1 + remove the wrapper itself (/opt/vless-reality-installer, management command)
#   3  level 2 + remove 3X-UI via its official uninstaller
# Unrelated inbounds/clients are never deleted by levels 1-2. Backups are kept.

_uninstall_level1() {
    local email n_removed=0 tmp
    log_step "Removing the managed VLESS REALITY configuration"
    if state_exists; then
        state_load
        if api_session_init_quiet; then
            local bk
            bk="$(backup_create pre-uninstall)" && log_ok "Backup saved: $bk"
            # our clients first (only those attached to OUR inbound), then the inbound itself
            tmp="$(vri_mktemp ulist)"
            if panel_clients_list; then
                jq -r --argjson id "$INBOUND_ID" '.obj[] | select((.inboundIds // []) == [$id]) | .email' "$API_OUT" >"$tmp"
                # orphans (no inbound left) that WE created: recorded in state or tagged by us
                jq -r --slurpfile st "$(state_file)" '($st[0].clients // [] | map(.email)) as $ours
                    | .obj[] | select((.inboundIds // []) == [] and ((.comment // "") == "BlueSoftKeys" or (.email as $e | $ours | index($e) != null))) | .email' "$API_OUT" >>"$tmp"
                while IFS= read -r email; do
                    [[ -n "$email" ]] || continue
                    if panel_client_del "$email"; then n_removed=$((n_removed + 1)); else log_warn "could not remove client $email: $API_MSG"; fi
                done <"$tmp"
            fi
            if panel_inbound_get "$INBOUND_ID" && [[ "$(api_obj '.obj.remark // ""')" == "$(mode_remark "$MODE")" ]]; then
                if panel_inbound_del "$INBOUND_ID"; then
                    log_ok "Removed inbound $INBOUND_ID and $n_removed client(s)"
                else
                    log_warn "could not delete inbound $INBOUND_ID: $API_MSG"
                fi
            else
                log_info "managed inbound is already gone from the panel"
            fi
            # our token(s) last: after this the stored token no longer works
            api_delete_all_own_tokens
        else
            log_warn "panel API unavailable ($API_MSG): the inbound could not be removed automatically; remove it in the panel (remark starts with $INBOUND_REMARK_PREFIX)"
        fi
        fw_close_ours
    else
        log_info "no wrapper state found; nothing to remove at this level"
    fi
    rm -f "$VRI_STATE_DIR/state.json" "$VRI_STATE_DIR/api-token" "$VRI_STATE_DIR/.state."* 2>/dev/null || true
}

_uninstall_level2() {
    log_step "Removing the wrapper"
    if [[ "$(readlink "$VRI_BIN_LINK" 2>/dev/null || true)" == "$VRI_HOME/bin/vless-reality" ]]; then
        rm -f "$VRI_BIN_LINK"
        log_ok "Removed $VRI_BIN_LINK"
    fi
    rm -f "$VRI_STATE_DIR/.panel-installed-by-wrapper"
    rmdir "$VRI_STATE_DIR" 2>/dev/null || true
    if [[ -d "$VRI_HOME" ]]; then
        rm -rf -- "$VRI_HOME"
        log_ok "Removed $VRI_HOME"
    fi
    log_info "Backups were kept in $VRI_BACKUP_DIR (delete them yourself when no longer needed)."
}

_uninstall_level3() {
    log_step "Removing 3X-UI (official uninstaller)"
    if ! upstream_installed; then
        log_info "3X-UI is not installed"
        return 0
    fi
    upstream_uninstall || die "the official 3X-UI uninstaller failed" "$VRI_EX_UPSTREAM"
    upstream_installed && die "3X-UI is still present after uninstall" "$VRI_EX_UPSTREAM"
    log_ok "3X-UI removed"
}

# uninstall_run  (uses OPT_UNINSTALL_LEVEL, VRI_ASSUME_YES)
uninstall_run() {
    vri_require_root
    vri_tmp_init
    vri_lock
    local level="${OPT_UNINSTALL_LEVEL:-}"
    if [[ -z "$level" ]]; then
        ((VRI_INTERACTIVE)) || die "choose what to remove with --level 1|2|3 (non-interactive)" "$VRI_EX_USAGE"
        cat >&2 <<'EOF'
What do you want to remove?

  1. Remove BlueSoftKeys-managed VLESS REALITY configuration only
  2. Remove wrapper + managed configuration
  3. Remove wrapper + managed configuration + 3X-UI (ALL panel data, including unrelated inbounds/clients)
EOF
        vri_ask level "Choose [1-3]" ""
    fi
    [[ "$level" =~ ^[123]$ ]] || die "invalid level '$level' (use 1, 2 or 3)" "$VRI_EX_USAGE"

    state_exists && state_load
    case "$level" in
        1) vri_confirm "Remove the managed inbound, its clients and our firewall rule? (a backup is taken first)" n || die "cancelled" "$VRI_EX_GENERAL" ;;
        2) vri_confirm "Remove the managed configuration AND the wrapper itself? (a backup is taken first)" n || die "cancelled" "$VRI_EX_GENERAL" ;;
        3)
            if [[ "$PANEL_BY_US" != "true" ]]; then
                log_warn "3X-UI was NOT installed by this tool; removing it deletes every inbound and client in it."
            fi
            vri_confirm_typed "This removes 3X-UI completely, including ALL its inbounds, clients and settings (a database backup is taken first)." "REMOVE-3XUI" || die "cancelled" "$VRI_EX_GENERAL"
            ;;
    esac

    # level 3 needs a DB backup even when we have no state to speak of
    if [[ "$level" == "3" ]] && ! state_exists && upstream_installed; then
        if api_session_init_quiet; then
            local bk
            bk="$(backup_create pre-uninstall)" && log_ok "Backup saved: $bk"
        else
            log_warn "could not back up the panel database ($API_MSG)"
        fi
    fi

    _uninstall_level1
    [[ "$level" == "1" ]] && {
        log_ok "Done. The wrapper is still installed; run 'sudo vless-reality install' to set up again."
        return 0
    }
    if [[ "$level" == "3" ]]; then
        _uninstall_level3
    fi
    _uninstall_level2
    log_ok "Done."
}
