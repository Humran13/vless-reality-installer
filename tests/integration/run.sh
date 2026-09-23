#!/usr/bin/env bash
# Host-side driver: boots a disposable systemd container ("fresh VPS") of BASE image, syncs this checkout into it and runs
# lifecycle.sh for MODE against the real official 3X-UI. Nothing on the host is modified.
#   tests/integration/run.sh ubuntu:24.04 tcp [--platform linux/arm64] [--keep] [--script lifecycle.sh]
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
BASE="${1:?base image, e.g. ubuntu:24.04}"
MODE="${2:?mode tcp|grpc|xhttp}"
shift 2
PLATFORM="" KEEP=0 SCRIPT=lifecycle.sh
while (($#)); do
    case "$1" in
        --platform) PLATFORM="$2"; shift ;;
        --keep) KEEP=1 ;;
        --script) SCRIPT="$2"; shift ;;
        *) echo "unknown arg $1" >&2; exit 2 ;;
    esac
    shift
done
tag="$(echo "$BASE" | tr ':/' '--')${PLATFORM:+-$(basename "$PLATFORM")}"
img="vri-fresh:$tag"
name="vri-it-$tag-$MODE-$$"
mkdir -p tests/results
log="tests/results/$tag-$MODE.log"
plat=()
[[ -n "$PLATFORM" ]] && plat=(--platform "$PLATFORM")

docker image inspect "$img" >/dev/null 2>&1 || docker build -q "${plat[@]}" -t "$img" --build-arg "BASE=$BASE" -f tests/docker/Dockerfile.systemd tests/docker >/dev/null
docker run -d --name "$name" "${plat[@]}" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock "$img" >/dev/null
cleanup() { ((KEEP)) || docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for _ in $(seq 1 40); do
    st="$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)"
    [[ "$st" == running || "$st" == degraded ]] && break
    sleep 1
done
bash tools/gen-sums.sh >/dev/null
# A real VPS has no /.dockerenv; upstream's x-ui.sh switches to its Docker-image layout (/app) when it exists.
docker exec "$name" rm -f /.dockerenv
docker exec "$name" mkdir -p /src
tar -cf - --exclude=.git --exclude=tests/results . | docker exec -i "$name" tar -xf - -C /src
rc=0
docker exec "$name" bash "/src/tests/integration/$SCRIPT" "$MODE" /src 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
echo "== $BASE $MODE ($SCRIPT): exit $rc (log: $log)"
exit "$rc"
