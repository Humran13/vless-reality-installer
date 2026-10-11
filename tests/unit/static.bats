#!/usr/bin/env bats
# Static checks: syntax, ShellCheck, CRLF, permissions, sourced files, unsafe patterns, secrets, dev-latest.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    cd "$REPO"
    FILES=(install.sh bin/vless-reality lib/*.sh tools/*.sh tests/integration/*.sh)
    LIBS=(install.sh bin/vless-reality lib/*.sh)
}

@test "bash -n syntax check passes for every script" {
    for f in "${FILES[@]}"; do bash -n "$f" || { echo "syntax error: $f"; return 1; }; done
}

@test "ShellCheck passes (warning level and above) for every script" {
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    run shellcheck -x -S warning "${FILES[@]}"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "no CRLF line endings anywhere in tracked source" {
    run grep -rlI $'\r' --include='*.sh' --include='*.bats' --include='*.bash' --include='*.md' --include='*.yml' --include='*.py' --include='VERSION' --include='SHA256SUMS' . --exclude-dir=.git --exclude-dir=results
    [ -z "$output" ] || { echo "CRLF in: $output"; return 1; }
    [ -z "$(head -c 200 bin/vless-reality | grep -a $'\r')" ]
}

@test "entry points have a bash shebang and are executable" {
    for f in install.sh bin/vless-reality tools/gen-sums.sh tests/integration/*.sh; do
        head -n1 "$f" | grep -q '^#!/usr/bin/env bash' || { echo "bad shebang: $f"; return 1; }
        [ -x "$f" ] || { echo "not executable: $f"; return 1; }
    done
}

@test "every module sourced by bin/vless-reality exists" {
    mods="$(sed -n 's/^for _m in \(.*\); do/\1/p' bin/vless-reality)"
    [ -n "$mods" ]
    for m in $mods; do [ -f "lib/$m.sh" ] || { echo "missing lib/$m.sh"; return 1; }; done
    for m in mode_tcp mode_grpc mode_xhttp; do [ -f "lib/$m.sh" ]; grep -q "$m.sh" lib/modes.sh; done
}

@test "no library file is left unreferenced" {
    for f in lib/*.sh; do
        b="$(basename "$f" .sh)"
        grep -q "\b$b\b" bin/vless-reality lib/modes.sh || { echo "unreferenced: $f"; return 1; }
    done
}

@test "SHA256SUMS is current (run tools/gen-sums.sh after editing bin/ lib/ VERSION)" {
    run sha256sum -c --quiet SHA256SUMS
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # GNU sha256sum may prefix filenames with either a space (text mode) or
    # '*' (binary mode).  The marker is not part of the filename.
    listed="$(awk '{name=$2; sub(/^\*/, "", name); print name}' SHA256SUMS | sort)"
    actual="$( (find bin lib -type f; echo VERSION) | sort)"
    [ "$listed" = "$actual" ] || { diff <(echo "$listed") <(echo "$actual"); return 1; }
}

@test "no eval anywhere in the shipped scripts" {
    run grep -nE '(^|[^a-zA-Z_])eval[[:space:]]' "${LIBS[@]}"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "no 'curl | bash' / 'wget | sh' in executable implementation code" {
    # Remove comments, quoted strings and heredoc bodies before scanning. This
    # keeps required usage/help examples while still catching a real pipeline,
    # including commands whose URL or arguments happen to be quoted.
    executable_shell_text() {
        awk '
        function code_only(line,    out,i,c,n,sq,dq,esc) {
            out=""; sq=0; dq=0; esc=0
            for (i=1; i<=length(line); i++) {
                c=substr(line,i,1)
                if (esc) { esc=0; if (!sq && !dq) out=out " "; continue }
                if (c=="\\" && !sq) { esc=1; if (!dq) out=out " "; continue }
                if (!dq && c=="\047") { sq=!sq; out=out " "; continue }
                if (!sq && c=="\"") { dq=!dq; out=out " "; continue }
                if (!sq && !dq && c=="#") break
                if (!sq && !dq) out=out c
                else out=out " "
            }
            return out
        }
        {
            if (heredoc != "") {
                end=$0
                if (strip_tabs) sub(/^\t+/, "", end)
                if (end == heredoc) { heredoc=""; strip_tabs=0 }
                next
            }
            raw=$0
            print FILENAME ":" FNR ":" code_only(raw)
            if (match(raw, /<<-?[[:space:]]*[\047\"][A-Za-z_][A-Za-z0-9_]*[\047\"]|<<-?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)) {
                token=substr(raw, RSTART, RLENGTH)
                strip_tabs=(token ~ /^<<-/)
                sub(/^<<-?[[:space:]]*/, "", token)
                gsub(/[\047\"]/, "", token)
                heredoc=token
            }
        }' "$@"
    }

    run bash -c 'source /dev/stdin' <<<"$(declare -f executable_shell_text)"$'\n''executable_shell_text install.sh bin/vless-reality lib/*.sh | grep -E '\''(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'\'''
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }

    # Prove the scanner itself rejects executable pipelines rather than merely
    # passing because this checkout contains none.
    probe="$(mktemp)"
    printf '%s\n' 'curl "https://example.invalid/payload" | bash' >"$probe"
    run executable_shell_text "$probe"
    rm -f "$probe"
    [[ "$output" =~ (curl|wget).*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh ]]
}

@test "TLS verification is never disabled" {
    run grep -nE 'curl[^#]*( -k( |$)|--insecure)|wget[^#]*--no-check-certificate|CURL_CA_BUNDLE=' "${LIBS[@]}"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "unattended install protection remains wired into package and upstream paths" {
    grep -q 'vri_run_unattended_logged apt-get update' lib/os.sh
    grep -q 'vri_run_unattended_logged apt-get install' lib/os.sh
    grep -q 'vri_unattended_run' lib/upstream.sh
    grep -Eq 'vri_unattended_run.*\|.*_upstream_filter.*\|.*tee' lib/upstream.sh
    grep -q 'NEEDRESTART_MODE=a' lib/common.sh install.sh
    grep -q 'APT_CONFIG=' lib/common.sh install.sh
    grep -q '</dev/null' install.sh
    ! grep -RInE 'apt(-get)?[[:space:]]+(full-upgrade|upgrade)|awk[[:space:]]+-W[[:space:]]*interactive' install.sh bin lib
    ! grep -RInE '^[[:space:]]*(sudo[[:space:]]+)?(shutdown|reboot|systemctl[[:space:]]+reboot)([[:space:]]|$)' install.sh bin lib
}

@test "no destructive firewall commands" {
    run grep -nE 'ufw[[:space:]]+(disable|reset|reload|default)|iptables[[:space:]]+-F|iptables[[:space:]]+--flush|nft[[:space:]]+flush|firewall-cmd[[:space:]]+--reload' "${LIBS[@]}"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "no direct SQLite access / database hacking" {
    run grep -nE 'sqlite3|\.db[^-a-z]|x-ui\.db' "${LIBS[@]}"
    # x-ui.db is only referenced for the stopped-service rollback file swap in update.sh / backup.sh
    [ -z "$(printf '%s\n' "$output" | grep -vE 'lib/(update|backup)\.sh' | grep -v '^$')" ] || { echo "$output"; return 1; }
    ! grep -nE 'sqlite3 ' "${LIBS[@]}"
}

@test "dev-latest is only ever referenced as something we refuse" {
    run grep -n 'dev-latest' "${LIBS[@]}"
    while IFS= read -r line; do
        [[ "$line" =~ (never|refus|reject|dev-latest\ is\ never|non-stable|dev\ builds|not\ installed|Never) ]] || { echo "suspicious dev-latest reference: $line"; return 1; }
    done <<<"$output"
}

@test "upstream is fetched only from the official MHSanaei/3x-ui repository" {
    run grep -noE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' lib/upstream.sh install.sh lib/update.sh
    for u in $(printf '%s\n' "$output" | awk -F: '{print $NF}' | sort -u); do
        [[ "$u" == github.com/MHSanaei/3x-ui || "$u" == github.com/Humran13/vless-reality-installer ]] || { echo "unexpected repo: $u"; return 1; }
    done
    grep -q 'UPSTREAM_REPO="MHSanaei/3x-ui"' lib/upstream.sh
}

@test "no secrets, private keys, tokens or personal paths in the repository" {
    run grep -rInE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gho_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}' . --exclude-dir=.git --exclude-dir=results --exclude=static.bats
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
    run grep -rIn 'C:\\Users\|/Users/Humran\|Documents/APPS' . --exclude-dir=.git --exclude-dir=results --exclude=static.bats
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "no leftover debug code / TODO / FIXME in shipped scripts" {
    run grep -nE 'set -x|TODO|FIXME|(^|[^X])XXX([^X]|$)|echo "DEBUG' "${LIBS[@]}"
    [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test ".gitignore blocks secrets and runtime state" {
    for pat in '*.env' '*.key' 'api-token' 'state.json' '*.db'; do grep -qxF "$pat" .gitignore || { echo "missing $pat"; return 1; }; done
}

@test "state/secret files are created with restrictive permissions (umask/chmod present)" {
    grep -q 'chmod 600' lib/state.sh
    grep -q 'chmod 700' lib/state.sh
    grep -q 'umask 077' lib/backup.sh lib/api.sh
}

@test "NOTICE.md credits upstream projects; LICENSE present; README shows the one-line installer" {
    grep -q 'MHSanaei/3x-ui' NOTICE.md
    grep -q 'XTLS/Xray-core' NOTICE.md
    [ -s LICENSE ]
    grep -qF 'curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash' README.md
}
