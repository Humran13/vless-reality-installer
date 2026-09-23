# Testing and support evidence

## Automated suites

`tests/run-unit.sh` runs the Bats suite in the disposable `bsk-dev` Docker image. The current suite has 134 cases
covering API authentication/errors/contracts, inbound and client lifecycle, mode JSON and link parsing, idempotency,
repair, backup/restore, update failures, uninstall scoping, OS detection, shell syntax, ShellCheck, manifest integrity,
unsafe shell patterns, permissions and secret/path scanning.

The real integration harness builds a fresh systemd container from the named distribution image, installs the official
stable 3X-UI release, and runs an Xray client against the generated server configuration. Each full lifecycle contains
96 assertions: install, live traffic, rerun/idempotency, foreign-resource preservation, client enable/disable/remove,
backup/restore, service and inbound repair, tamper repair, secret leakage, all uninstall levels, reinstall and traffic
with the original link after repair. The update harness adds 31 checks for stable-channel update, rollback guards,
state/key preservation, post-update traffic and verified wrapper self-update.

Run locally (Docker required):

```bash
bash tests/run-unit.sh
bash tests/integration/run.sh ubuntu:24.04 tcp
bash tests/integration/run.sh ubuntu:24.04 grpc
bash tests/integration/run.sh ubuntu:24.04 xhttp
bash tests/integration/run.sh ubuntu:24.04 tcp --script update.sh
```

## Recorded matrix

| Image | Architecture | Modes exercised | Result / classification |
|---|---|---|---|
| Ubuntu 18.04 | amd64 | TCP, gRPC, XHTTP | Live traffic passed; best effort because standard support ended |
| Ubuntu 20.04 | amd64 | TCP | Full lifecycle passed; best effort because standard support ended |
| Ubuntu 22.04 | amd64 | TCP | Full lifecycle passed |
| Ubuntu 24.04 | amd64 | TCP, gRPC, XHTTP; update | Fresh full lifecycle 96/96 for every mode; update 31/31 |
| Ubuntu 24.04 | arm64 | TCP | Full lifecycle passed under Docker platform emulation |
| Ubuntu 26.04 | amd64 | TCP, XHTTP | Live traffic/lifecycle exercised; TCP full lifecycle passed |
| Debian 12 | amd64 | TCP | Full lifecycle passed |
| Debian 13 | amd64 | TCP, gRPC | Full lifecycle passed |

The dated working-tree logs under `tests/results/` are development evidence and are excluded from releases and Git.
Some older logs retain isolated cleanup assertion failures that were rerun successfully on Ubuntu 24.04; support claims
above distinguish those from fresh green runs.

## What containers do and do not prove

Privileged systemd containers validate the real upstream installer, services, listening sockets, API, Xray-generated
configuration and local client/server data transfer without touching the development host's firewall or routing. They do
not reproduce a cloud security group, provider NAT, public DNS, cross-network filtering or every kernel/firewall variant.
Production deployment still needs one disposable VPS smoke test from an external client/network.

GitHub Actions intentionally runs the deterministic Bats/ShellCheck suite on Ubuntu 22.04 and 24.04. The network-heavy,
privileged real-upstream matrix remains a release test because it depends on Docker systemd privileges and live upstream
availability.
