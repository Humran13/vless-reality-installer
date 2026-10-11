#!/usr/bin/env bash
# BlueSoftKeys VLESS Reality Installer - bootstrap.
#
#   curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash -s -- --mode grpc
#   sudo bash install.sh --mode tcp        (from a checkout: uses the local files, downloads nothing)
#
# This script only fetches the project tree (verified against its SHA256SUMS), installs it to
# /opt/vless-reality-installer and hands over to `vless-reality install`, which does the real work.
# Everything after `install.sh` is passed through unchanged (except --ref REF, consumed here).
set -Eeuo pipefail

REPO="Humran13/vless-reality-installer"
REF="${VRI_REF:-main}"
HOME_DIR="${VRI_HOME:-/opt/vless-reality-installer}"
BIN_LINK="${VRI_BIN_LINK:-/usr/local/bin/vless-reality}"

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then R=$'\033[0;31m' G=$'\033[0;32m' B=$'\033[0;34m' Z=$'\033[0m'; else R="" G="" B="" Z=""; fi
info() { printf '%s\n' "${B}[*]${Z} $*" >&2; }
ok() { printf '%s\n' "${G}[+]${Z} $*" >&2; }
fail() {
    printf '%s\n' "${R}[x]${Z} $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
BlueSoftKeys VLESS Reality Installer

  curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash
  curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash -s -- [options]

Options (passed to `vless-reality install`):
  --mode tcp|grpc|xhttp   --port PORT   --server-address ADDR   --reality-target HOST:PORT   --sni HOST
  --client-name NAME   --grpc-service-name NAME   --xhttp-path PATH   --allow-unsupported-os
  --non-interactive   --verbose   --help   --version
Bootstrap-only: --ref REF (install a specific git tag/branch of this project; default: main)
Full documentation: https://github.com/Humran13/vless-reality-installer
EOF
}

# ---- argument scan: handle --help / --version / --ref locally, pass the rest through ----
args=()
while (($#)); do
    case "$1" in
        --ref)
            [[ -n "${2:-}" ]] || fail "--ref needs a value"
            REF="$2"
            shift 2
            ;;
        --ref=*)
            REF="${1#--ref=}"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || fail "invalid --ref"

# ---- run from a local checkout when possible ----
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ -n "$script_dir" && -f "$script_dir/lib/common.sh" && -x "$script_dir/bin/vless-reality" ]]; then
    info "Using the local checkout at $script_dir"
    exec "$script_dir/bin/vless-reality" install ${args[@]+"${args[@]}"}
fi

((EUID == 0)) || fail "please run as root:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sudo bash"
[[ "$(uname -s)" == "Linux" ]] || fail "Linux only"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/vri-bootstrap.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# The bootstrap cannot source lib/common.sh until curl/tar are available, so it
# has a small standalone copy of the same inactivity-watchdog mechanism.
bootstrap_watchdog_run() {
    local timeout="${VRI_INACTIVITY_TIMEOUT:-300}" interval fifo heartbeat timed_out pid watcher rc=0 now last
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=300
    interval=$((timeout / 5)); ((interval < 1)) && interval=1; ((interval > 10)) && interval=10
    fifo="$tmp/bootstrap-fifo.$$" heartbeat="$tmp/bootstrap-heartbeat.$$" timed_out="$tmp/bootstrap-timeout.$$"
    mkfifo -m 600 "$fifo" || return 1
    : >"$heartbeat"
    if command -v setsid >/dev/null 2>&1; then setsid "$@" </dev/null >"$fifo" 2>&1 & else "$@" </dev/null >"$fifo" 2>&1 & fi
    pid=$!
    (
        while kill -0 "$pid" 2>/dev/null; do
            sleep "$interval"
            kill -0 "$pid" 2>/dev/null || exit 0
            now="$(date +%s)"; last="$(stat -c %Y "$heartbeat" 2>/dev/null || printf '%s' "$now")"
            if ((now - last >= timeout)); then
                : >"$timed_out"
                printf '[x] bootstrap command produced no output for %s seconds; stopping it\n' "$timeout" >&2
                if command -v setsid >/dev/null 2>&1; then kill -TERM -- "-$pid" 2>/dev/null || true; else kill -TERM "$pid" 2>/dev/null || true; fi
                sleep 2
                if command -v setsid >/dev/null 2>&1; then kill -KILL -- "-$pid" 2>/dev/null || true; else kill -KILL "$pid" 2>/dev/null || true; fi
                exit 0
            fi
        done
    ) &
    watcher=$!
    while IFS= read -r line || [[ -n "$line" ]]; do touch "$heartbeat"; printf '%s\n' "$line"; done <"$fifo"
    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
    [[ -e "$timed_out" ]] && rc=124
    rm -f "$fifo" "$heartbeat" "$timed_out"
    return "$rc"
}

need_pkgs=()
command -v curl >/dev/null 2>&1 || need_pkgs+=(curl)
command -v tar >/dev/null 2>&1 || need_pkgs+=(tar)
command -v sha256sum >/dev/null 2>&1 || need_pkgs+=(coreutils)
[[ -d /etc/ssl/certs ]] || need_pkgs+=(ca-certificates)
if ((${#need_pkgs[@]})); then
    command -v apt-get >/dev/null 2>&1 || fail "missing tools (${need_pkgs[*]}) and apt-get is unavailable"
    info "Installing prerequisites: ${need_pkgs[*]}"
    apt_config="$tmp/apt-unattended.conf"
    (umask 077 && printf '%s\n' \
        'APT::Get::Assume-Yes "true";' \
        'Dpkg::Options {' \
        '  "--force-confdef";' \
        '  "--force-confold";' \
        '};' >"$apt_config") || fail "could not create temporary apt configuration"
    chmod 600 "$apt_config"
    unattended_env=(env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true DEBIAN_PRIORITY=critical
        NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1 APT_CONFIG="$apt_config")
    bootstrap_watchdog_run "${unattended_env[@]}" apt-get update -q || info "apt-get update reported problems; trying package installation"
    bootstrap_watchdog_run "${unattended_env[@]}" apt-get install -y -q --no-install-recommends "${need_pkgs[@]}" || fail "could not install ${need_pkgs[*]}"
fi

# ---- download ----
info "Downloading $REPO@$REF ..."
url="https://codeload.github.com/$REPO/tar.gz/$REF"
if [[ "${VRI_TEST_MODE:-0}" == "1" && -n "${VRI_SELF_TARBALL_URL:-}" ]]; then
    url="$VRI_SELF_TARBALL_URL" # test-suite only
fi
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$tmp/src.tgz" ||
    fail "download failed ($url). Check the ref '$REF' and your network."
mkdir "$tmp/src"
tar -xzf "$tmp/src.tgz" -C "$tmp/src" --strip-components=1 --no-same-owner || fail "downloaded archive is corrupt"

# ---- verify ----
[[ -f "$tmp/src/VERSION" && -x "$tmp/src/bin/vless-reality" && -d "$tmp/src/lib" ]] || fail "downloaded archive is not a complete project tree"
[[ -f "$tmp/src/SHA256SUMS" ]] || fail "SHA256SUMS missing in the downloaded tree"
(cd "$tmp/src" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || fail "checksum verification failed; refusing to install"
for f in "$tmp/src/bin/vless-reality" "$tmp/src"/lib/*.sh; do
    bash -n "$f" || fail "syntax check failed: $f"
done
ver="$(tr -d '[:space:]' <"$tmp/src/VERSION")"
ok "Downloaded and verified wrapper $ver"

# ---- install atomically ----
stage="$HOME_DIR.new.$$"
old="$HOME_DIR.old.$$"
mkdir -p "$(dirname "$HOME_DIR")"
rm -rf "$stage"
mkdir -p "$stage"
cp -a "$tmp/src/bin" "$tmp/src/lib" "$tmp/src/VERSION" "$tmp/src/SHA256SUMS" "$stage/"
for extra in LICENSE NOTICE.md README.md; do
    [[ -f "$tmp/src/$extra" ]] && cp -a "$tmp/src/$extra" "$stage/"
done
chmod -R go-w "$stage"
if [[ -e "$HOME_DIR" ]]; then mv "$HOME_DIR" "$old"; fi
if ! mv "$stage" "$HOME_DIR"; then
    [[ -e "$old" ]] && mv "$old" "$HOME_DIR"
    fail "could not install into $HOME_DIR"
fi
rm -rf "$old"
ln -sfn "$HOME_DIR/bin/vless-reality" "$BIN_LINK"

# ---- hand over (stdin: keep a real terminal; under `curl | bash` reattach /dev/tty when possible) ----
info "Starting the installer..."
if [[ -t 0 ]]; then
    exec "$HOME_DIR/bin/vless-reality" install ${args[@]+"${args[@]}"}
elif [[ -c /dev/tty && ( -t 1 || -t 2 ) ]]; then
    exec "$HOME_DIR/bin/vless-reality" install ${args[@]+"${args[@]}"} </dev/tty
else
    exec "$HOME_DIR/bin/vless-reality" install ${args[@]+"${args[@]}"} </dev/null
fi
