#!/usr/bin/env bash
set -euo pipefail

project=${1:-}
real_docker=${2:-/usr/local/bin/docker}
measurement_image='docker.m.daocloud.io/library/node:20-bookworm-slim'

if [[ ! $project =~ ^xhsmedium-test-scheduled-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$ ]]; then
    printf 'Refusing unsafe run image cleanup project: %s\n' "$project" >&2
    exit 64
fi
if [[ ! -x $real_docker ]]; then
    printf 'Docker client is not executable: %s\n' "$real_docker" >&2
    exit 65
fi

measure_available_bytes() {
    local available=''
    available=$("$real_docker" run --rm --network none --read-only --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --mount type=bind,source=/var/lib/docker,target=/docker-root,readonly \
        --entrypoint sh "$measurement_image" -lc \
        'df -B1 --output=avail /docker-root | tail -n 1 | tr -d " "')
    [[ $available =~ ^[0-9]+$ ]] || {
        printf 'Could not measure dedicated DIND available bytes.\n' >&2
        return 1
    }
    printf '%s' "$available"
}

expected_images=(
    "$project-backend:latest"
    "$project-frontend:latest"
    "$project-runner:latest"
)
image_list=$("$real_docker" image ls --format '{{.Repository}}:{{.Tag}}')
mapfile -t project_images < <(
    printf '%s\n' "$image_list" | awk -v prefix="$project-" 'index($0, prefix) == 1 { print }'
)

for image in "${project_images[@]}"; do
    allowed=false
    for expected in "${expected_images[@]}"; do
        if [[ $image == "$expected" ]]; then
            allowed=true
            break
        fi
    done
    if [[ $allowed != true ]]; then
        printf 'Refusing unexpected run image: %s\n' "$image" >&2
        exit 66
    fi
done

before_bytes=$(measure_available_bytes)
removed_images=0
removed_logical_bytes=0
for image in "${expected_images[@]}"; do
    if [[ " ${project_images[*]} " == *" $image "* ]]; then
        image_size=$("$real_docker" image inspect --format '{{.Size}}' "$image")
        [[ $image_size =~ ^[0-9]+$ ]] || {
            printf 'Invalid image size for %s.\n' "$image" >&2
            exit 67
        }
        "$real_docker" image rm "$image" >/dev/null
        removed_images=$((removed_images + 1))
        removed_logical_bytes=$((removed_logical_bytes + image_size))
    fi
done

image_list=$("$real_docker" image ls --format '{{.Repository}}:{{.Tag}}')
mapfile -t residue < <(
    printf '%s\n' "$image_list" | awk -v prefix="$project-" 'index($0, prefix) == 1 { print }'
)
if (( ${#residue[@]} )); then
    printf 'Run image cleanup left residue: project=%s images=%s\n' "$project" "${residue[*]}" >&2
    exit 68
fi

after_bytes=$(measure_available_bytes)
reclaimed_bytes=0
if (( after_bytes > before_bytes )); then
    reclaimed_bytes=$((after_bytes - before_bytes))
fi
printf 'RESIDUE_CLEANUP_EVIDENCE scope=%s removed_images=%s removed_logical_bytes=%s reclaimed_bytes=%s disk_available_bytes=%s residue=0 status=OK\n' \
    "$project" "$removed_images" "$removed_logical_bytes" "$reclaimed_bytes" "$after_bytes"
