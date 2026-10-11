# BlueSoftKeys VLESS Reality Installer

An independent installer and management layer for the official
[MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) panel. It provisions one managed VLESS + REALITY inbound, creates
clients through the panel API, and leaves unrelated 3X-UI resources alone.

## Install

Run on a fresh supported VPS as a sudo-capable user:

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash
```

Non-interactive examples:

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash -s -- --mode tcp --non-interactive
curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash -s -- --mode grpc --non-interactive
curl -fsSL https://raw.githubusercontent.com/Humran13/vless-reality-installer/main/install.sh | sudo bash -s -- --mode xhttp --non-interactive
```

The bootstrap downloads the repository archive, verifies `bin/`, `lib/`, and `VERSION` against `SHA256SUMS`, installs
the wrapper under `/opt/vless-reality-installer`, then invokes the management CLI. The wrapper pins or discovers only
stable `vX.Y.Z` 3X-UI releases; it never selects `dev-latest`.

Package installation and the official 3X-UI installer run unattended with streaming output. Ubuntu `needrestart`
prompts, including **Pending kernel upgrade**, are answered automatically; the installer never reboots the VPS. If a
newer kernel was installed, the final output recommends a manual reboot. No full OS upgrade is required or performed.

## Supported modes

| Mode | Transport | Flow | Validation |
|---|---|---|---|
| TCP / Raw + REALITY | `tcp` | `xtls-rprx-vision` | Real Xray client/server traffic |
| gRPC + REALITY | `grpc` | none | Real Xray client/server traffic |
| XHTTP + REALITY | `xhttp`, mode `auto` | none | Real Xray client/server traffic |

WebSocket, HTTPUpgrade and mKCP are not offered as REALITY modes because current stable 3X-UI does not treat them as
valid REALITY combinations.

## Platforms

- Fully lifecycle-tested: Ubuntu 22.04, 24.04 and 26.04; Debian 12 and 13.
- Best effort: Ubuntu 18.04 and 20.04. Both are past standard support; use Ubuntu Pro/ESM or upgrade the OS.
- CPU architectures: `amd64`/`x86_64` and `arm64`/`aarch64` (Ubuntu 24.04 arm64 was lifecycle-tested).
- Required environment: apt-based Ubuntu/Debian with systemd as PID 1 and outbound HTTPS access.

Evidence and exact per-image coverage are in [docs/testing.md](docs/testing.md). Other systems are rejected unless
`--allow-unsupported-os` is explicitly supplied.

## Management

```text
vless-reality menu
vless-reality status
vless-reality info [NAME]
vless-reality clients
vless-reality add-client [NAME] [--expire-days N] [--quota-gb N]
vless-reality remove-client NAME
vless-reality enable-client NAME
vless-reality disable-client NAME
vless-reality qr [NAME]
vless-reality logs
vless-reality diagnostics
vless-reality backup
vless-reality restore FILE
vless-reality update
vless-reality update --self
vless-reality repair
vless-reality uninstall --level 1|2|3
vless-reality version
vless-reality help
```

Updates take a backup first and use only the latest stable upstream release. Repair is scoped to the inbound, clients,
API token, firewall rule, and state owned by this wrapper. Uninstall levels are conservative:

1. Remove the managed VPN configuration and wrapper state, retaining the wrapper and 3X-UI.
2. Also remove the wrapper, retaining 3X-UI and backups.
3. Also invoke the official 3X-UI uninstaller after typed confirmation; backups remain.

## Security notes

- 3X-UI is downloaded from its official stable tag; its installer verifies the release archive checksum.
- The wrapper uses Bearer-authenticated panel APIs on localhost and never edits the SQLite database directly.
- API tokens, state and backups use restrictive permissions. REALITY private keys remain server-side and are redacted
  from command output and wrapper logs.
- The installer adds a single inbound rule only when UFW is already active. It never enables, resets or flushes a
  firewall. You must separately allow the inbound port in your cloud firewall/security group.
- 3X-UI's panel is HTTP by default. Do not expose its port publicly; use SSH tunnelling or configure panel TLS.
- Review scripts before piping them to a shell if that is part of your security policy.

## Backups and limitations

Backups contain the official panel database export plus wrapper state and may contain credentials. Store them securely.
Restore validates archive structure before importing it through the supported panel API.

The automated connection tests run client and server on the same disposable host. They prove Xray accepts the generated
config and that TCP, gRPC and XHTTP REALITY traffic works, but they cannot prove a particular VPS provider, national
network or cloud firewall permits the traffic. Public DNS, routing and provider filtering remain deployment-specific.

See [docs/architecture.md](docs/architecture.md), [docs/testing.md](docs/testing.md), and [NOTICE.md](NOTICE.md) for
design details, test evidence and upstream attribution. This project is MIT-licensed; 3X-UI and Xray retain their own
GPL-3.0 and MPL-2.0 licences respectively.
