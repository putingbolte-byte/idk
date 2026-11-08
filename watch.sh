#!/usr/bin/env bash
# watch.sh — poll the bench files and push whenever one changes.
#
# no inotify in this container, so this is a hash poll. cheap: six md5s every
# few seconds. sync.sh no-ops when nothing actually differs.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL="${1:-5}"

SOURCES=(
    /root/recon2.lua
    /root/gun.lua
    /root/mobtest.lua
    /root/hit.lua
    /root/wp.lua
    /root/firetest.lua
    /root/fisch.lua
)

fingerprint() {
    local out=""
    for f in "${SOURCES[@]}"; do
        if [ -f "$f" ]; then
            out+="$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"
        else
            out+="-"
        fi
    done
    echo "$out"
}

echo "[watch] $(date '+%H:%M:%S') polling every ${INTERVAL}s" >&2
last="$(fingerprint)"

while true; do
    sleep "$INTERVAL"
    now="$(fingerprint)"
    if [ "$now" != "$last" ]; then
        last="$now"
        out="$(bash "$HERE/sync.sh" 2>&1)"
        if [ -n "$out" ]; then
            echo "[watch] $(date '+%H:%M:%S') $out" >&2
        fi
    fi
done
