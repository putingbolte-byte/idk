#!/usr/bin/env bash
# sync.sh — mirror the bench deliverables in /root into this repo and push.
#
# called by the watcher, or by hand. no-op when nothing changed, so it is safe
# to run on a timer. exits non-zero only on a real push failure.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="main"
LOCK="/tmp/idk-sync.lock"

exec 9>"$LOCK"
if ! flock -n 9; then
    # another sync is mid-flight; the next tick will pick up whatever changed
    exit 0
fi

# src:dst — recon2.lua is shipped as recon.lua so the load path stays put
MAP=(
    "/root/recon2.lua:recon.lua"
    "/root/gun.lua:gun.lua"
    "/root/mobtest.lua:mobtest.lua"
    "/root/hit.lua:hit.lua"
    "/root/wp.lua:wp.lua"
    "/root/firetest.lua:firetest.lua"
    "/root/deadshift.lua:deadshift.lua"
)

changed=()
for pair in "${MAP[@]}"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    [ -f "$src" ] || continue

    # never publish a file that does not parse
    if command -v luac >/dev/null 2>&1; then
        if ! luac -p "$src" >/dev/null 2>&1; then
            echo "skip $dst — syntax error in $src" >&2
            continue
        fi
    fi

    if ! cmp -s "$src" "$REPO/$dst"; then
        cp "$src" "$REPO/$dst"
        changed+=("$dst")
    fi
done

if [ ${#changed[@]} -eq 0 ]; then
    exit 0
fi

cd "$REPO" || exit 1
git add -- "${changed[@]}" || exit 1

stamp="$(date '+%Y-%m-%d %H:%M:%S')"
msg="sync: ${changed[*]} ($stamp)"
git -c user.name="putingbolte-byte" -c user.email="putingbolte@gmail.com" \
    commit -q -m "$msg" || { echo "commit failed" >&2; exit 1; }

for attempt in 1 2 3; do
    if git push -q origin "$BRANCH" 2>/tmp/idk-push.err; then
        echo "$msg"
        exit 0
    fi
    # someone else moved main — rebase and retry
    git pull -q --rebase origin "$BRANCH" >/dev/null 2>&1
    sleep $((attempt * 2))
done

echo "push failed: $(cat /tmp/idk-push.err 2>/dev/null)" >&2
exit 1
