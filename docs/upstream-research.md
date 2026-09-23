# Upstream research (3X-UI)

Researched against the official `MHSanaei/3x-ui` repository (tag source + release metadata) and **verified
empirically** by running the real release in a disposable Ubuntu 24.04 systemd container.
Do not re-research these facts; re-verify only when `TESTED_UPSTREAM` in `lib/upstream.sh` is bumped.

## Versions

| Item | Value (at time of writing) |
|---|---|
| Latest stable (GitHub "latest" release) | **v3.8.5** (published 2026-09-16) |
| Rolling dev build | `dev-latest` (pre-release, force-moved tag) — **never used** |
| Bundled Xray | **26.9.9** (`Xray 26.9.9 ... go1.27.1`) |
| Licence | GPL-3.0 (we do not copy or modify upstream code; we call its installer + HTTP API) |
| Release assets | `x-ui-linux-{386,amd64,arm64,armv5,armv6,armv7,s390x}.tar.gz` + `.sha256` sidecars |
| Binaries | Static musl builds (`CGO_ENABLED=1`, Bootlin musl, `-extldflags -static`) → no glibc dependency |

Stable discovery: `https://github.com/MHSanaei/3x-ui/releases/latest` redirects to `/releases/tag/<tag>`
(what upstream's own installer uses; not subject to the 60 req/h API limit). API fallback:
`api.github.com/repos/MHSanaei/3x-ui/releases/latest` (`prerelease:false`).

## Installation (official, unattended)

* `install.sh` (fetch from the **tag**, not `main`): `bash install.sh v3.8.5` pins the release
  (numeric floor `v2.3.5`; `dev`/`dev-latest` are accepted aliases — we never pass them).
* Non-interactive when `XUI_NONINTERACTIVE=1` **or** stdin is not a TTY. Every prompt has an env-var/default.
* Env vars we use: `XUI_NONINTERACTIVE=1`, `XUI_ENABLE_FAIL2BAN=false` (do not change unrelated system
  config), `XUI_SSL_MODE` (default `none` → panel is HTTP-only, upstream default).
* Env vars we do **not** set (so upstream randomises them): `XUI_USERNAME`, `XUI_PASSWORD`, `XUI_PANEL_PORT`,
  `XUI_WEB_BASE_PATH`. Random: 10-char user/pass, 18-char base path, panel port 1024–62000.
* `install_base` runs `apt-get update && apt-get install cron curl tar tzdata socat ca-certificates openssl`
  (apt-based: `ubuntu|debian|armbian`).
* Checksum: release tarball is verified against `<asset>.sha256` (mismatch/HTTP≠200/≠404 aborts). Preserved
  because we run upstream's own installer.
* Result file `/etc/x-ui/install-result.env` (0600, `printf %q`, source-able):
  `XUI_USERNAME XUI_PASSWORD XUI_PANEL_PORT XUI_WEB_BASE_PATH XUI_ACCESS_URL XUI_API_TOKEN XUI_DB_TYPE`.
  Written **only** on a fresh install with default credentials (not on re-runs / existing installs).
* Layout: `/usr/local/x-ui/{x-ui,x-ui.sh,bin/xray-linux-<arch>,...}` (≈260 MB), `/etc/x-ui/x-ui.db` (SQLite, WAL),
  `/usr/bin/x-ui` (CLI wrapper), unit `/etc/systemd/system/x-ui.service` (service name **`x-ui`**),
  logs via `journalctl -u x-ui` and `/var/log/x-ui/`.
* Supported OS in upstream installer: ubuntu/debian/armbian (apt), fedora/rhel family (dnf), arch, alpine, etc.
  No OS minimum is enforced by upstream. Architectures: amd64, arm64, armv7/6/5, 386, s390x.

## CLI (`/usr/local/x-ui/x-ui`)

* `x-ui setting -show` → `port:`, `webBasePath:`, `hasDefaultCredential:` (no secrets).
* `x-ui setting -getCert` → `cert:` / `key:` (flags must precede positionals).
* ⚠️ **`x-ui setting -getApiToken` REGENERATES the token** and invalidates the previous one
  (only hashes are stored). We never call it on an existing install.
* `x-ui -v` → version. `x-ui update` → interactive wrapper around `update.sh`.
* Update: `XUI_UPDATE_TAG=<tag> bash update.sh` (fetch `update.sh` from the same tag). Default (no tag)
  = latest stable; `dev-latest` only via explicit tag. `update.sh` deletes the old program dir *before*
  extracting (non-atomic) → we snapshot before updating. It preserves `/etc/x-ui`.
* Uninstall: `x-ui uninstall` (interactive y/n; stops/disables unit, removes `/etc/x-ui`, `/usr/local/x-ui`).

## HTTP API

* Base: `http(s)://<host>:<panelPort>/<webBasePath>/panel/api/...`. Spec served at `/panel/api/openapi.json`.
* Auth: **`Authorization: Bearer <token>`** (admin-scope token) or session cookie. Bad token → `401`;
  no auth → `404`. Bearer-authenticated mutations bypass CSRF.
* Tokens: `GET /setting/apiTokens`, `POST /setting/apiTokens/create {name,scope?,expiresAt?}` (plaintext returned once),
  `POST /setting/apiTokens/delete/:id {expectedScope}`. We mint our own admin token (`bluesoftkeys-vless-reality`).
* Envelope: `{"success":bool,"msg":str,"obj":...}` (HTTP 200 even for logical errors, e.g. port in use).
* Helpers: `GET /server/getNewX25519Cert` → `{privateKey,publicKey}` (Xray's own keygen);
  `GET /server/getNewUUID`; `POST /server/scanRealityTarget` (form `target=host:port&sni=`) → `feasible, tls13, h2,
  x25519, certValid, serverNames[]`; `GET /server/status` (`obj.xray.state`); `GET /server/getConfigJson`;
  `GET /server/getDb` (SQLite download = official backup); `POST /server/importDB` (multipart `db`, restarts panel);
  `POST /server/restartXrayService`.
* Inbounds: `GET /inbounds/list`, `/inbounds/get/:id`, `POST /inbounds/add`, `/inbounds/update/:id`, `/inbounds/del/:id`.
  Body: full inbound; `settings/streamSettings/sniffing` as nested objects. `tag` is server-generated
  (`in-<port>-tcp`); duplicate port → `success:false "port N (tcp) already used by inbound ..."`.
  `shareAddrStrategy:"custom"` + `shareAddr:"<host>"` makes generated links use our public address.
* Clients (v3 model — clients are separate records attached to inbounds):
  `POST /clients/add {"client":{...},"inboundIds":[id]}` (server fills `id`/UUID, `subId`),
  `GET /clients/list`, `/clients/get/:email` (returns `uuid`, integer `id`), `POST /clients/del/:email`,
  `GET /clients/links/:email` → share URIs (authoritative), `POST /clients/update/:email`.
  * ⚠️ **Update is a full replace**: a partial body (e.g. `{"email","enable":false}`) **wipes `flow`**.
    Send the whole client with `uuid` mapped to `id` (string). Verified: enable/disable then preserves flow.
  * Duplicate email → `success:false "email already in use"`.
  * `totalGB` is **bytes** despite the name; `expiryTime` is unix **ms**, `0` = none.
* Flow gating (server side, `inboundCanEnableTlsFlow`): Vision allowed only for `tcp`+(`tls`|`reality`), or
  `xhttp` when VLESS encryption (vlessenc) is enabled. Otherwise the panel strips/ignores flow.

## VLESS + REALITY schema

Inbound: `protocol:"vless"`, `settings:{clients:[],decryption:"none",encryption:"none",fallbacks:[]}`,
`streamSettings:{network,security:"reality",realitySettings:{...},<network>Settings}`.

`realitySettings`: `show:false, xver:0, target:"host:443" (alias dest), serverNames:[..], privateKey, minClientVer:"",
maxClientVer:"", maxTimediff:0, shortIds:[..], mldsa65Seed:"",
settings:{publicKey, fingerprint:"chrome", serverName:"", spiderX:"/", mldsa65Verify:""}`.

* Keys: X25519 from panel/Xray (`getNewX25519Cert`). Private key stays server-side; link carries `pbk` only.
* `shortIds`: even-length hex, ≤16 chars (we use 16 hex chars = 8 random bytes).
* Target requirement (Xray docs + panel scanner): TLS 1.3, h2, X25519, valid cert; `serverNames` must be covered by
  the target's certificate SANs.
* REALITY-eligible networks in stable (`REALITY_NETWORKS` in panel frontend): `tcp`, `grpc`, `xhttp`, and legacy
  `http` (h2). WebSocket / HTTPUpgrade / mKCP are **not** eligible. Legacy `http` has **no** stream schema and **no**
  share-link support in the panel (`applyShareNetworkParams` handles tcp/kcp/ws/grpc/httpupgrade/xhttp) → **not offered**.

### Per-mode behaviour (verified with real traffic through Xray 26.9.9)

| Mode | `network` | extra stream settings | Flow | Share-link params (from panel) |
|---|---|---|---|---|
| tcp | `tcp` | `tcpSettings:{header:{type:none}}` | `xtls-rprx-vision` | `type=tcp&flow=xtls-rprx-vision&security=reality&pbk&sid&sni&fp&spx&encryption=none` |
| grpc | `grpc` | `grpcSettings:{serviceName,authority:"",multiMode:false}` | **none** (Vision unsupported) | `type=grpc&serviceName=..&authority=` + reality params, no `flow` |
| xhttp | `xhttp` | `xhttpSettings:{path,host:"",mode:"auto"}` | **none** (Vision needs vlessenc) | `type=xhttp&path=..&host=&mode=auto&extra={"mode":"auto"}` + reality params, no `flow` |

XHTTP: we deliberately do **not** enable VLESS encryption (vlessenc); without it the panel and Xray require an
empty flow. Advanced XHTTP knobs (xmux, padding, session placement) stay at upstream defaults.

## Service / health

* `systemctl is-active x-ui`; Xray state via `GET /server/status` → `obj.xray.state == "running"`.
* Listening sockets: `ss -ltn`. Inbound listens on `*:<port>` (Xray).

## Gotchas discovered

1. `getApiToken` regenerates (see above).
2. Client update wipes omitted fields (see above).
3. `getDb` returns a consistent SQLite snapshot (magic `SQLite format 3`); raw file copy of a running WAL DB is not safe.
4. Panel is HTTP-only by default with a random port + base path (upstream default; we do not change it or open its port).
5. Generated links use the request host unless `shareAddr` is set → we set it.
