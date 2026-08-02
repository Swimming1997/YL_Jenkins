#!/usr/bin/env bash
set -euo pipefail

runner_uid=${XHSMEDIUM_RUNNER_UID:?XHSMEDIUM_RUNNER_UID is required}
runner_gid=${XHSMEDIUM_RUNNER_GID:?XHSMEDIUM_RUNNER_GID is required}
if [[ $runner_uid == *[!0-9]* || $runner_gid == *[!0-9]* || $runner_uid == 0 || $runner_gid == 0 ]]; then
    printf 'Invalid non-root runner identity: %s:%s\n' "$runner_uid" "$runner_gid" >&2
    exit 51
fi

for dependency_dir in \
    /workspace/backend/node_modules \
    /workspace/frontend/node_modules \
    /workspace/automation/node_modules; do
    if ! mountpoint -q "$dependency_dir"; then
        printf 'Runner dependency path is not an isolated volume: %s\n' "$dependency_dir" >&2
        exit 52
    fi
    marker="$dependency_dir/.xhsmedium-owner-${runner_uid}-${runner_gid}"
    if [[ ! -f $marker || $(stat -c '%u:%g' "$dependency_dir") != "$runner_uid:$runner_gid" ]]; then
        chown -R "$runner_uid:$runner_gid" "$dependency_dir"
        install -m 0600 -o "$runner_uid" -g "$runner_gid" /dev/null "$marker"
    fi
done

exec setpriv --reuid="$runner_uid" --regid="$runner_gid" --clear-groups -- "$@"
