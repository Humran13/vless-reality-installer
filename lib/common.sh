#!/usr/bin/env bash
# shellcheck shell=bash
# common.sh - constants, logging, prompts, temp files, locking.
# Sourced by bin/vless-reality (which sets `set -Eeuo pipefail`). Compatible with bash >= 4.4 (Ubuntu 18.04).

VRI_LIB_DIR="${VRI_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
VRI_ROOT_DIR="${VRI_ROOT_DIR:-$(dirname "$VRI_LIB_DIR")}"
VRI_VERSION="$(tr -d '[:space:]' <"$VRI_ROOT_DIR/VERSION" 2>/dev/null || true)"
VRI_VERSION="${VRI_VERSION:-unknown}"

VRI_PRODUCT="BlueSoftKeys VLESS Reality Installer"
VRI_REPO="${VRI_REPO:-Humran13/vless-reality-installer}"
VRI_HOME="${VRI_HOME:-/opt/vless-reality-installer}"
VRI_STATE_DIR="${VRI_STATE_DIR:-/etc/vless-reality-installer}"
VRI_BACKUP_DIR="${VRI_BACKUP_DIR:-/var/backups/vless-reality-installer}"
VRI_LOG_DIR="${VRI_LOG_DIR:-/var/log/vless-reality-installer}"
VRI_BIN_LINK="${VRI_BIN_LINK:-/usr/local/bin/vless-reality}"
VRI_LOCK_FILE="${VRI_LOCK_FILE:-/run/lock/vless-reality-installer.lock}"

# Exit codes
VRI_EX_GENERAL=1 VRI_EX_USAGE=2 VRI_EX_ENV=3 VRI_EX_UPSTREAM=4 VRI_EX_API=5 VRI_EX_STATE=6

VRI_VERBOSE="${VRI_VERBOSE:-0}"
VRI_INTERACTIVE=0
VRI_IN_FD=0
VRI_ASSUME_YES=0
VRI_TMP=""
VRI_SECRETS=()

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[0;31m' C_GRN=$'\033[0;32m' C_YEL=$'\033[0;33m' C_BLU=$'\033[0;34m' C_BOLD=$'\033[1m' C_OFF=$'\033[0m'
else
    C_RED="" C_GRN="" C_YEL="" C_BLU="" C_BOLD="" C_OFF=""
fi

# ---------- secrets & logging ----------

# Register a value that must never appear in logs/output produced by log_*.
vri_secret_add() {
    local s="${1:-}"
    ((${#s} >= 6)) || return 0
    VRI_SECRETS+=("$s")
}

vri_redact() {
    local msg="$1" s
    for s in "${VRI_SECRETS[@]}"; do
        msg="${msg//"$s"/<redacted>}"
    done
    printf '%s' "$msg"
}

_vri_logfile_write() {
    local line
    line="$(vri_redact "$1")"
    [[ -n "${VRI_LOG_DIR:-}" ]] || return 0
    if [[ ! -d "$VRI_LOG_DIR" ]]; then
        (umask 077 && mkdir -p "$VRI_LOG_DIR") 2>/dev/null || return 0
    fi
    (umask 077 && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$VRI_LOG_DIR/vri.log") 2>/dev/null || true
}

log_info() { printf '%s\n' "${C_BLU}[*]${C_OFF} $(vri_redact "$*")" >&2; _vri_logfile_write "INFO $*"; }
log_ok() { printf '%s\n' "${C_GRN}[+]${C_OFF} $(vri_redact "$*")" >&2; _vri_logfile_write "OK   $*"; }
log_warn() { printf '%s\n' "${C_YEL}[!]${C_OFF} $(vri_redact "$*")" >&2; _vri_logfile_write "WARN $*"; }
log_err() { printf '%s\n' "${C_RED}[x]${C_OFF} $(vri_redact "$*")" >&2; _vri_logfile_write "ERROR $*"; }
log_debug() {
    [[ "$VRI_VERBOSE" == "1" ]] || return 0
    printf '%s\n' "[debug] $(vri_redact "$*")" >&2
    _vri_logfile_write "DEBUG $*"
}
log_step() { printf '\n%s\n' "${C_BOLD}==> $(vri_redact "$*")${C_OFF}" >&2; _vri_logfile_write "STEP $*"; }

die() {
    local msg="$1" code="${2:-$VRI_EX_GENERAL}"
    log_err "$msg"
    exit "$code"
}

# ---------- temp files ----------

vri_tmp_init() {
    [[ -n "$VRI_TMP" && -d "$VRI_TMP" ]] && return 0
    VRI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vri.XXXXXXXX")" || die "cannot create temporary directory" "$VRI_EX_ENV"
    chmod 700 "$VRI_TMP"
}

vri_tmp_cleanup() {
    if [[ -n "$VRI_TMP" && -d "$VRI_TMP" && "$VRI_TMP" == */vri.* ]]; then
        rm -rf -- "$VRI_TMP"
    fi
    VRI_TMP=""
}

# Create a private temp file inside VRI_TMP and print its path.
vri_mktemp() {
    vri_tmp_init
    mktemp "$VRI_TMP/${1:-f}.XXXXXX"
}

# ---------- locking ----------

vri_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    local dir
    dir="$(dirname "$VRI_LOCK_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
    exec 9>"$VRI_LOCK_FILE" || return 0
    flock -n 9 || die "another vless-reality process is already running (lock: $VRI_LOCK_FILE)" "$VRI_EX_STATE"
}

# ---------- interactivity ----------

# Decide whether we can prompt. Under `curl | bash`, stdin is a pipe: fall back to /dev/tty when usable.
vri_detect_interactive() {
    if [[ "${VRI_FORCE_NONINTERACTIVE:-0}" == "1" ]]; then
        VRI_INTERACTIVE=0
        return 0
    fi
    if [[ -t 0 ]]; then
        VRI_INTERACTIVE=1
        VRI_IN_FD=0
    elif [[ -c /dev/tty && ( -t 1 || -t 2 ) ]]; then
        exec 3</dev/tty
        VRI_INTERACTIVE=1
        VRI_IN_FD=3
    else
        VRI_INTERACTIVE=0
    fi
}

# vri_ask VAR "Question" "default"  -> sets VAR (default returned when non-interactive or empty answer)
vri_ask() {
    local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
    if ((VRI_INTERACTIVE)); then
        if [[ -n "$__def" ]]; then
            printf '%s [%s]: ' "$__prompt" "$__def" >&2
        else
            printf '%s: ' "$__prompt" >&2
        fi
        IFS= read -r -u "$VRI_IN_FD" __ans || __ans=""
    fi
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# vri_confirm "Question" [default y|n]  -> 0 for yes
vri_confirm() {
    local q="$1" def="${2:-n}" ans=""
    if ((VRI_ASSUME_YES)); then return 0; fi
    if ((!VRI_INTERACTIVE)); then
        [[ "$def" == "y" ]]
        return
    fi
    local hint="y/N"
    [[ "$def" == "y" ]] && hint="Y/n"
    printf '%s [%s]: ' "$q" "$hint" >&2
    IFS= read -r -u "$VRI_IN_FD" ans || ans=""
    ans="${ans:-$def}"
    [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]]
}

# vri_confirm_typed "Question" "WORD" -> requires typing WORD exactly (never satisfied by --yes alone in non-interactive
# unless VRI_ASSUME_YES was given explicitly).
vri_confirm_typed() {
    local q="$1" word="$2" ans=""
    if ((VRI_ASSUME_YES)); then return 0; fi
    ((VRI_INTERACTIVE)) || return 1
    printf '%s\nType %s to continue: ' "$q" "$word" >&2
    IFS= read -r -u "$VRI_IN_FD" ans || ans=""
    [[ "$ans" == "$word" ]]
}

# ---------- misc helpers ----------

vri_require_root() {
    [[ "${VRI_SKIP_ROOT_CHECK:-0}" == "1" ]] && return 0
    ((EUID == 0)) || die "this command must be run as root (try: sudo vless-reality ...)" "$VRI_EX_ENV"
}

vri_have() { command -v "$1" >/dev/null 2>&1; }

# curl with sane timeouts/retries. Works with curl >= 7.58 (Ubuntu 18.04): no --retry-all-errors / --fail-with-body.
vri_curl() {
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time "${VRI_CURL_MAX_TIME:-180}" "$@"
}

# Atomically write stdin to a file with the given mode (default 600).
vri_write_atomic() {
    local dest="$1" mode="${2:-600}" tmp
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 1
    if cat >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

vri_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
vri_now_stamp() { date -u +%Y%m%d-%H%M%S; }

# Percent-decode (no eval, no printf %b on user data beyond hex escapes).
vri_urldecode() {
    local s="${1//+/ }" out=""
    while [[ "$s" =~ ^([^%]*)%([0-9A-Fa-f]{2})(.*)$ ]]; do
        # shellcheck disable=SC2059
        out+="${BASH_REMATCH[1]}$(printf "\\x${BASH_REMATCH[2]}")"
        s="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${s}"
}

vri_random_alnum() { # length
    local n="${1:-12}" out=""
    while ((${#out} < n)); do
        # tr gets SIGPIPE once head has enough bytes; that is expected, hence `|| true` under pipefail.
        out+="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$n" || true)"
    done
    printf '%s' "${out:0:n}"
}

vri_random_hex() { # bytes
    local n="${1:-8}"
    if vri_have openssl; then
        openssl rand -hex "$n"
    else
        LC_ALL=C od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n'
    fi
}
