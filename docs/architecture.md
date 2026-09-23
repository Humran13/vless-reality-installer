# Architecture

## Boundaries

This repository is a wrapper around official 3X-UI, not a fork. `install.sh` verifies and installs the wrapper tree;
`bin/vless-reality` loads the modules under `lib/`; `lib/upstream.sh` invokes official stable 3X-UI install/update
scripts; and `lib/api.sh` manages inbounds and clients through the panel's Bearer-token API. No module writes directly
to the panel database.

Runtime data is deliberately separate from program files:

| Path | Purpose |
|---|---|
| `/opt/vless-reality-installer` | Verified wrapper code |
| `/usr/local/bin/vless-reality` | Management-command symlink |
| `/var/lib/vless-reality-installer` | Mode, managed resource IDs, clients and private API token |
| `/var/backups/vless-reality-installer` | Mode-0600 backup archives |
| `/var/log/vless-reality-installer/vri.log` | Redacted wrapper operations |
| `/usr/local/x-ui`, `/etc/x-ui` | Upstream-owned 3X-UI program and data |

## Install flow

1. Validate CLI input, OS, CPU architecture, systemd and required tools.
2. Discover or validate a stable `vX.Y.Z` 3X-UI release.
3. Fetch the official tagged installer and require its checksum-verification logic before executing it unattended.
4. Parse upstream's root-owned mode-0600 `install-result.env` only after rejecting unsafe shell constructs; never call
   the token-regenerating CLI operation.
5. Validate the panel API contract and REALITY target, generate X25519 keys through Xray's panel endpoint, and build a
   mode-specific inbound.
6. Create the first client, validate the authoritative panel-generated share link, open one rule only if UFW is already
   active, and atomically persist ownership state.

Re-running the installer adopts or reuses the managed inbound and client. It preserves UUIDs, keys, short IDs,
credentials, tokens and firewall state; switching modes requires uninstalling the managed configuration first.

## Mode isolation

The registry in `lib/modes.sh` dispatches to `mode_tcp.sh`, `mode_grpc.sh`, or `mode_xhttp.sh`. Shared REALITY fields
are built once, while each module owns transport settings, flow requirements and share-link validation. TCP uses Vision;
gRPC and XHTTP deliberately use no flow. The private key appears only in server stream settings; share links must contain
the matching public key and must not contain the private key.

## Lifecycle and recovery

- Client updates send a complete client object so enable/disable does not erase flow or other fields.
- Backup downloads a consistent database snapshot through `/server/getDb`; restore imports through `/server/importDB`.
- Panel update takes a backup, uses the official stable updater, validates service/API/inbound/client state, and restores
  the snapshot on failure where possible.
- Repair compares the live managed resources with state, starts a stopped service, recreates a missing inbound/client,
  or restores altered mode settings while preserving recorded keys and UUIDs.
- Uninstall deletes resources by their recorded identities, removes only a recorded wrapper-created UFW rule, and never
  removes unrelated inbounds or clients. Removing upstream 3X-UI requires level 3 and typed confirmation.

## Security model

Inputs are allow-listed before reaching commands or JSON, JSON is constructed with `jq`, temporary directories are
private, and state is written atomically. Secrets are registered with the output redactor and are passed to curl through
a private process-substitution config rather than command-line headers. Downloaded wrapper code is checked against the
repository manifest; downloaded upstream scripts are restricted to official tagged URLs and reviewed invariants.

The bootstrap's trust root is the public GitHub repository: `SHA256SUMS` protects against partial or mixed downloads,
not against a compromised repository owner. Administrators needing a stronger trust model should pin a reviewed tag and
verify it independently.
