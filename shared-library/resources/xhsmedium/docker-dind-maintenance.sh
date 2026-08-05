#!/usr/bin/env bash
set -euo pipefail

target=${1:-}
mode=${2:-}
current_sha=${3:-}
previous_sha=${4:-}
confirmation=${5:-}
real_docker=${6:-/usr/local/bin/docker}
cache_limit_bytes=${DIND_CACHE_LIMIT_BYTES:-4294967296}

case "$target" in
    regression|release|deploy-dev|deploy-test) ;;
    *) printf 'Refusing unsafe DIND maintenance target: %s\n' "$target" >&2; exit 64 ;;
esac
case "$mode" in
    AUDIT|APPLY) ;;
    *) printf 'Maintenance mode must be AUDIT or APPLY.\n' >&2; exit 65 ;;
esac
if [[ $mode == APPLY && $confirmation != APPLY_DEDICATED_DIND_MAINTENANCE ]]; then
    printf 'APPLY requires the exact maintenance confirmation.\n' >&2
    exit 66
fi
if [[ ! -x $real_docker ]]; then
    printf 'Docker client is not executable: %s\n' "$real_docker" >&2
    exit 67
fi
if [[ ! $cache_limit_bytes =~ ^[1-9][0-9]*$ ]]; then
    printf 'DIND cache limit must be a positive byte count.\n' >&2
    exit 68
fi

if [[ $target == regression ]]; then
    [[ $current_sha =~ ^[0-9a-f]{40}$ ]] || {
        printf 'Regression maintenance requires the current validated full SHA.\n' >&2
        exit 69
    }
    if [[ -n $previous_sha && ! $previous_sha =~ ^[0-9a-f]{40}$ ]]; then
        printf 'Previous validated SHA must be blank or a full lowercase SHA.\n' >&2
        exit 69
    fi
    if [[ -n $previous_sha && $previous_sha == "$current_sha" ]]; then
        printf 'Current and previous validated SHAs must differ.\n' >&2
        exit 69
    fi
elif [[ -n $current_sha || -n $previous_sha ]]; then
    printf 'SHA cache retention applies only to the Regression DIND.\n' >&2
    exit 69
fi

size_to_bytes() {
    local value=${1%% *}
    if [[ ! $value =~ ^([0-9]+([.][0-9]+)?)(B|kB|MB|GB|TB)$ ]]; then
        return 1
    fi
    local number=${BASH_REMATCH[1]}
    local unit=${BASH_REMATCH[3]}
    local multiplier=1
    case "$unit" in
        B) multiplier=1 ;;
        kB) multiplier=1000 ;;
        MB) multiplier=1000000 ;;
        GB) multiplier=1000000000 ;;
        TB) multiplier=1000000000000 ;;
    esac
    awk -v number="$number" -v multiplier="$multiplier" 'BEGIN { printf "%.0f", number * multiplier }'
}

read_cache_stats() {
    local system_df cache_line cache_size cache_reclaimable
    system_df=$("$real_docker" system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}')
    cache_line=$(printf '%s\n' "$system_df" | awk -F '\t' '$1 == "Build Cache" { print; exit }')
    [[ -n $cache_line ]] || {
        printf 'Docker system df did not report Build Cache.\n' >&2
        return 1
    }
    IFS=$'\t' read -r _ cache_size cache_reclaimable <<<"$cache_line"
    cache_bytes=$(size_to_bytes "$cache_size")
    reclaimable_bytes=$(size_to_bytes "$cache_reclaimable")
}

before_disk_available_bytes=$(df -B1 --output=avail / | tail -n 1 | tr -d ' ')
[[ $before_disk_available_bytes =~ ^[0-9]+$ ]] || {
    printf 'Could not measure Agent filesystem available bytes.\n' >&2
    exit 70
}

running_containers=$("$real_docker" ps --quiet)
running_container_count=$(printf '%s\n' "$running_containers" | awk 'NF { count++ } END { print count+0 }')
if [[ $mode == APPLY && -n $running_containers ]]; then
    printf 'Refusing maintenance while target DIND has running containers.\n' >&2
    exit 71
fi

image_list=$("$real_docker" image ls --format '{{.Repository}}:{{.Tag}}')
mapfile -t all_images < <(printf '%s\n' "$image_list" | awk 'NF')
candidate_images=()
protected_images=()
current_short=${current_sha:0:8}
previous_short=${previous_sha:0:8}

for image in "${all_images[@]}"; do
    if [[ $target == regression && $image == xhsmedium-deps-* ]]; then
        if [[ ! $image =~ ^xhsmedium-deps-([0-9a-f]{8})-(backend|frontend|runner):latest$ ]]; then
            printf 'Refusing malformed Regression dependency cache image: %s\n' "$image" >&2
            exit 72
        fi
        image_short=${BASH_REMATCH[1]}
        if [[ $image_short != "$current_short" && ( -z $previous_short || $image_short != "$previous_short" ) ]]; then
            candidate_images+=("$image")
            continue
        fi
    fi
    protected_images+=("$image")
done

read_cache_stats
before_cache_bytes=$cache_bytes
before_reclaimable_bytes=$reclaimable_bytes
for image in "${candidate_images[@]}"; do
    printf 'DIND_MAINTENANCE_CANDIDATE target=%s image=%s\n' "$target" "$image"
done

removed_images=0
removed_logical_bytes=0
if [[ $mode == APPLY ]]; then
    for image in "${candidate_images[@]}"; do
        image_size=$("$real_docker" image inspect --format '{{.Size}}' "$image")
        [[ $image_size =~ ^[0-9]+$ ]] || {
            printf 'Invalid image size for %s.\n' "$image" >&2
            exit 73
        }
        "$real_docker" image rm "$image" >/dev/null
        removed_images=$((removed_images + 1))
        removed_logical_bytes=$((removed_logical_bytes + image_size))
    done
    if (( before_cache_bytes > cache_limit_bytes )); then
        "$real_docker" builder prune --all --force --max-used-space "${cache_limit_bytes}B" >/dev/null
    fi
fi

after_image_list=$("$real_docker" image ls --format '{{.Repository}}:{{.Tag}}')
for image in "${protected_images[@]}"; do
    if ! grep -Fqx -- "$image" <<<"$after_image_list"; then
        printf 'Maintenance removed a protected image: %s\n' "$image" >&2
        exit 74
    fi
done
if [[ $mode == APPLY ]]; then
    for image in "${candidate_images[@]}"; do
        if grep -Fqx -- "$image" <<<"$after_image_list"; then
            printf 'Maintenance left an expired dependency cache: %s\n' "$image" >&2
            exit 75
        fi
    done
fi

read_cache_stats
after_cache_bytes=$cache_bytes
after_reclaimable_bytes=$reclaimable_bytes
if [[ $mode == APPLY && $after_cache_bytes -gt $cache_limit_bytes ]]; then
    printf 'Dedicated DIND BuildKit cache remains above limit: bytes=%s limit=%s\n' "$after_cache_bytes" "$cache_limit_bytes" >&2
    exit 76
fi

disk_available_bytes=$(df -B1 --output=avail / | tail -n 1 | tr -d ' ')
cache_reclaimed_bytes=0
if (( before_cache_bytes > after_cache_bytes )); then
    cache_reclaimed_bytes=$((before_cache_bytes - after_cache_bytes))
fi
reclaimed_bytes=0
if (( disk_available_bytes > before_disk_available_bytes )); then
    reclaimed_bytes=$((disk_available_bytes - before_disk_available_bytes))
fi
printf 'DIND_MAINTENANCE_EVIDENCE target=%s mode=%s running_containers=%s candidate_images=%s removed_images=%s removed_logical_bytes=%s cache_before_bytes=%s cache_after_bytes=%s cache_reclaimable_before_bytes=%s cache_reclaimable_after_bytes=%s cache_reclaimed_bytes=%s reclaimed_bytes=%s disk_available_bytes=%s protected_images=%s residue=0 status=OK\n' \
    "$target" "$mode" "$running_container_count" "${#candidate_images[@]}" "$removed_images" "$removed_logical_bytes" \
    "$before_cache_bytes" "$after_cache_bytes" "$before_reclaimable_bytes" "$after_reclaimable_bytes" \
    "$cache_reclaimed_bytes" "$reclaimed_bytes" "$disk_available_bytes" "${#protected_images[@]}"
