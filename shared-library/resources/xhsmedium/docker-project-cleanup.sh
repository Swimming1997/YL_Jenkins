#!/usr/bin/env bash
set -euo pipefail

real_docker=/usr/local/bin/docker
project=${1:-}
if [[ ! $project =~ ^xhsmedium-test-scheduled-[a-z0-9_-]+$ ]]; then
    printf 'Refusing unsafe cleanup project: %s\n' "$project" >&2
    exit 61
fi

stable_empty=0
for _attempt in $(seq 1 20); do
    mapfile -t containers < <("$real_docker" ps --all --quiet --filter "label=com.docker.compose.project=$project")
    if (( ${#containers[@]} )); then
        "$real_docker" rm --force "${containers[@]}" >/dev/null 2>&1 || true
    fi

    mapfile -t volumes < <("$real_docker" volume ls --quiet --filter "label=com.docker.compose.project=$project")
    if (( ${#volumes[@]} )); then
        "$real_docker" volume rm "${volumes[@]}" >/dev/null 2>&1 || true
    fi

    mapfile -t networks < <("$real_docker" network ls --quiet --filter "label=com.docker.compose.project=$project")
    if (( ${#networks[@]} )); then
        "$real_docker" network rm "${networks[@]}" >/dev/null 2>&1 || true
    fi

    mapfile -t containers < <("$real_docker" ps --all --quiet --filter "label=com.docker.compose.project=$project")
    mapfile -t volumes < <("$real_docker" volume ls --quiet --filter "label=com.docker.compose.project=$project")
    mapfile -t networks < <("$real_docker" network ls --quiet --filter "label=com.docker.compose.project=$project")
    if (( ! ${#containers[@]} && ! ${#volumes[@]} && ! ${#networks[@]} )); then
        stable_empty=$((stable_empty + 1))
        if (( stable_empty >= 3 )); then
            printf 'P4_EXACT_PROJECT_CLEANUP_OK project=%s\n' "$project"
            exit 0
        fi
    else
        stable_empty=0
    fi
    sleep 1
done

printf 'Exact project cleanup did not converge: project=%s containers=%s volumes=%s networks=%s\n' \
    "$project" "${#containers[@]}" "${#volumes[@]}" "${#networks[@]}" >&2
exit 62
