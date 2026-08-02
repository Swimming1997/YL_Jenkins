#!/usr/bin/env bash
set -euo pipefail

real_docker=/usr/local/bin/docker
expected_project=${XHSMEDIUM_DOCKER_PROJECT:?XHSMEDIUM_DOCKER_PROJECT is required}
cache_prefix=${XHSMEDIUM_DEPENDENCY_CACHE_PREFIX:?XHSMEDIUM_DEPENDENCY_CACHE_PREFIX is required}
resolved_sha=${RESOLVED_SHA:?RESOLVED_SHA is required}
compose_override=${XHSMEDIUM_COMPOSE_OVERRIDE_PATH:?XHSMEDIUM_COMPOSE_OVERRIDE_PATH is required}
args=("$@")

if [[ ! -f $compose_override ]]; then
    printf 'Compose compatibility override is missing: %s\n' "$compose_override" >&2
    exit 41
fi

if [[ ${args[0]:-} != compose ]]; then
    exec "$real_docker" "${args[@]}"
fi

action_index=-1
for index in "${!args[@]}"; do
    case "${args[$index]}" in
        build|up|run|logs|down|ps|config)
            action_index=$index
            break
            ;;
    esac
done

if (( action_index < 0 )); then
    exec "$real_docker" "${args[@]}"
fi

project=''
for ((index = 0; index < action_index; index++)); do
    if [[ ${args[$index]} == --project-name && $((index + 1)) -lt $action_index ]]; then
        project=${args[$((index + 1))]}
    fi
done
if [[ $project != "$expected_project" ]]; then
    printf 'Refusing unexpected Compose project: %s\n' "$project" >&2
    exit 42
fi

verify_cache_image() {
    local role=$1
    local image="${cache_prefix}-${role}:latest"
    local actual_sha actual_role
    actual_sha=$("$real_docker" image inspect --format '{{index .Config.Labels "xhsmedium.preload.sha"}}' "$image")
    actual_role=$("$real_docker" image inspect --format '{{index .Config.Labels "xhsmedium.preload.role"}}' "$image")
    if [[ $actual_sha != "$resolved_sha" || $actual_role != "$role" ]]; then
        printf 'Offline cache identity mismatch for %s\n' "$image" >&2
        exit 43
    fi
}

prefix=("${args[@]:0:$action_index}" -f "$compose_override")
action=${args[$action_index]}
tail=("${args[@]:$((action_index + 1))}")

if [[ $action == build ]]; then
    if [[ ${tail[*]} != runner ]]; then
        printf 'Unexpected explicit Compose build request: %s\n' "${tail[*]}" >&2
        exit 44
    fi
    verify_cache_image runner
    printf 'OFFLINE_DEPENDENCY_CACHE role=runner sha=%s\n' "$resolved_sha"
    exec "$real_docker" "${prefix[@]}" build \
        --build-arg NPM_OFFLINE=true \
        --build-arg "RUNNER_DEPENDENCY_CACHE_IMAGE=${cache_prefix}-runner:latest" \
        runner
fi

if [[ $action == up ]]; then
    requires_build=false
    filtered=()
    for value in "${tail[@]}"; do
        if [[ $value == --build ]]; then
            requires_build=true
        else
            filtered+=("$value")
        fi
    done
    if [[ $requires_build == true ]]; then
        if [[ ${tail[*]} != *'backend frontend' ]]; then
            printf 'Unexpected Compose up --build request: %s\n' "${tail[*]}" >&2
            exit 45
        fi
        verify_cache_image backend
        verify_cache_image frontend
        printf 'OFFLINE_DEPENDENCY_CACHE role=backend,frontend sha=%s\n' "$resolved_sha"
        "$real_docker" "${prefix[@]}" build \
            --build-arg NPM_OFFLINE=true \
            --build-arg "BACKEND_DEPENDENCY_CACHE_IMAGE=${cache_prefix}-backend:latest" \
            --build-arg "FRONTEND_DEPENDENCY_CACHE_IMAGE=${cache_prefix}-frontend:latest" \
            backend frontend
        exec "$real_docker" "${prefix[@]}" up "${filtered[@]}"
    fi
fi

exec "$real_docker" "${prefix[@]}" "$action" "${tail[@]}"
