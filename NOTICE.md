# Notice and attribution

**BlueSoftKeys VLESS Reality Installer** is an independent automation, provisioning and management layer. It is
**not** a fork, rebrand or redistribution of any of the projects below, and it is not affiliated with or endorsed by
their authors. All credit for the engines it drives belongs to them.

## MHSanaei/3x-ui

- Project: <https://github.com/MHSanaei/3x-ui> — the web panel that this tool installs and manages.
- Licence: GPL-3.0.
- How we use it: at run time we download and execute **the official, unmodified** `install.sh` / `update.sh` from a
  stable release tag of that repository, which in turn downloads the official release archive (verified against the
  release's published `.sha256` by upstream's own scripts). We then talk to the panel only through its documented HTTP
  API (Bearer token, localhost). We do not copy, embed, patch or link any 3X-UI source code, and we never modify its
  database directly.
- All panel names, logos and UI remain 3X-UI's. The `x-ui` command and the panel are theirs.

## XTLS/Xray-core

- Project: <https://github.com/XTLS/Xray-core> — the proxy core (VLESS, XTLS Vision, REALITY, XHTTP, gRPC transports)
  bundled and managed by 3X-UI. REALITY key generation is performed by that bundled Xray through the panel's API; this
  project implements no cryptography.
- Licence: MPL-2.0.

## Other tools used at run time (from the OS package repositories)

`curl`, `jq`, `openssl`, `iproute2`, `util-linux`, `tar`, `coreutils`, and optionally `qrencode` and `ufw`.

## Testing tools (development only)

ShellCheck, Bats, Docker, Python 3 (mock server). None are shipped or required on a server.

## This project

Licensed under the MIT License (see `LICENSE`). Because it only invokes the above projects as separate programs
(command line and HTTP), the GPL/MPL terms of those projects do not extend to this repository's own code; their terms
continue to apply to the software you install from them.
