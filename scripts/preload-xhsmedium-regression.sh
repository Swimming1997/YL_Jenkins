#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: preload-xhsmedium-regression.sh --sha <40-char SHA> [--pull-inputs] [--import-existing] [--verify-only]

Fetches an exact XHSMedium commit with the read-only SCM Secret, builds its
dependency stages in host Docker, and imports the labeled images into the
isolated regression DIND. No project runtime is installed on the host.
EOF
}

sha=''
pull_inputs=false
import_existing=false
verify_only=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sha)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            sha=$2
            shift 2
            ;;
        --pull-inputs)
            pull_inputs=true
            shift
            ;;
        --import-existing)
            import_existing=true
            shift
            ;;
        --verify-only)
            verify_only=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

case "$sha" in
    *[!0-9a-f]*|'') printf 'Sha must be a full lowercase 40-character commit SHA.\n' >&2; exit 64 ;;
esac
[ "${#sha}" -eq 40 ] || { printf 'Sha must be a full lowercase 40-character commit SHA.\n' >&2; exit 64; }

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
short_sha=${sha:0:8}
cache_prefix="xhsmedium-deps-$short_sha"
compose=(docker compose -f "$repo_root/compose.yaml" -f "$repo_root/compose.paper-server.yaml")
dind_id=$("${compose[@]}" ps --quiet regression-docker)
[ -n "$dind_id" ] || { printf 'regression-docker is not running.\n' >&2; exit 69; }

temp_root=''
dind_archive="/certs/client/xhsmedium-p4-preload-$short_sha.tar"
node_alias="xhsmedium-p4-input-node:$short_sha"
runner_alias="xhsmedium-p4-input-runner:$short_sha"
cleanup() {
    docker exec "$dind_id" rm -f -- "$dind_archive" >/dev/null 2>&1 || true
    docker image rm "$node_alias" "$runner_alias" >/dev/null 2>&1 || true
    if [ -n "$temp_root" ] && [ -d "$temp_root" ]; then
        rm -rf -- "$temp_root"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

input_refs=(
    'docker.m.daocloud.io/library/mysql:8.4'
    'docker.m.daocloud.io/library/node:20-bookworm-slim'
    'mcr.microsoft.com/playwright:v1.59.1-noble'
    'mcr.microsoft.com/playwright:v1.60.0-noble'
)
input_ids=(
    'sha256:8dbcf531a03aade657e181b9cf2f1d1803ce621a1d55610cb44cb531ab7d7db6'
    'sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0'
    'sha256:b0ab6f3cb99aa7803adbc14d9027ec1785fc6e433b97e134e0f8fe61683b6b53'
    'sha256:9bd26ad900bb5e0f4dee75839e957a89ae89c2b7ab1e76050e559790e946b948'
)

verify_host_input() {
    local reference=$1 expected=$2 actual=''
    actual=$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null || true)
    if [ "$actual" != "$expected" ] && [ "$pull_inputs" = true ]; then
        docker pull "$reference"
        actual=$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null || true)
    fi
    [ "$actual" = "$expected" ] || {
        printf 'Pinned preload input is missing or has changed: %s\n' "$reference" >&2
        return 1
    }
    printf 'PASS: pinned host input verified: %s\n' "$reference"
}

verify_host_cache() {
    local role=$1 image="$cache_prefix-$1:latest" actual_sha='' actual_role=''
    actual_sha=$(docker image inspect --format '{{index .Config.Labels "xhsmedium.preload.sha"}}' "$image" 2>/dev/null || true)
    actual_role=$(docker image inspect --format '{{index .Config.Labels "xhsmedium.preload.role"}}' "$image" 2>/dev/null || true)
    [ "$actual_sha" = "$sha" ] && [ "$actual_role" = "$role" ] || {
        printf 'Host cache identity verification failed for %s.\n' "$image" >&2
        return 1
    }
    printf 'PASS: existing host cache verified: %s\n' "$image"
}

if [ "$verify_only" = false ]; then
    for index in "${!input_refs[@]}"; do
        verify_host_input "${input_refs[$index]}" "${input_ids[$index]}"
    done

    temp_root=$(mktemp -d "$repo_root/.secrets/p4-preload-$short_sha.XXXXXX")
    image_archive="$temp_root/images.tar"
    if [ "$import_existing" = false ]; then
        token_file="$repo_root/.secrets/xhsmedium_scm_token"
        [ -s "$token_file" ] || { printf 'Missing required read-only SCM Secret.\n' >&2; exit 66; }
        source_root="$temp_root/source"
        snapshot="$temp_root/snapshot"
        askpass="$temp_root/git-askpass.sh"
        mkdir -p "$source_root" "$snapshot"
        cat >"$askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "$SCM_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
        chmod 0700 "$askpass"
        SCM_TOKEN=$(tr -d '\r\n' <"$token_file")
        export SCM_TOKEN
        GIT_ASKPASS="$askpass" GIT_ASKPASS_REQUIRE=force git -C "$source_root" init --quiet
        GIT_ASKPASS="$askpass" GIT_ASKPASS_REQUIRE=force git -C "$source_root" remote add origin https://github.com/MuFannnn/xhsmedium.git
        GIT_ASKPASS="$askpass" GIT_ASKPASS_REQUIRE=force git -C "$source_root" fetch --quiet --depth=1 origin "$sha"
        unset SCM_TOKEN
        [ "$(git -C "$source_root" rev-parse FETCH_HEAD)" = "$sha" ] || { printf 'Fetched commit does not match requested SHA.\n' >&2; exit 65; }
        git -C "$source_root" archive "$sha" | tar -x -C "$snapshot"

        docker tag 'docker.m.daocloud.io/library/node:20-bookworm-slim' "$node_alias"
        docker tag 'mcr.microsoft.com/playwright:v1.60.0-noble' "$runner_alias"
        docker build --network host --target dependencies \
            --build-arg "BACKEND_DEPENDENCY_CACHE_IMAGE=$node_alias" \
            --label "xhsmedium.preload.sha=$sha" --label 'xhsmedium.preload.role=backend' \
            --tag "$cache_prefix-backend:latest" --file "$snapshot/deploy/docker/backend.Dockerfile" "$snapshot"
        docker build --network host --target dependencies \
            --build-arg "FRONTEND_DEPENDENCY_CACHE_IMAGE=$node_alias" \
            --label "xhsmedium.preload.sha=$sha" --label 'xhsmedium.preload.role=frontend' \
            --tag "$cache_prefix-frontend:latest" --file "$snapshot/deploy/docker/frontend.Dockerfile" "$snapshot"
        docker build --network host --target dependencies \
            --build-arg "RUNNER_DEPENDENCY_CACHE_IMAGE=$runner_alias" \
            --label "xhsmedium.preload.sha=$sha" --label 'xhsmedium.preload.role=runner' \
            --tag "$cache_prefix-runner:latest" --file "$snapshot/automation/docker/runner.Dockerfile" "$snapshot"
    else
        for role in backend frontend runner; do
            verify_host_cache "$role"
        done
    fi

    docker save --output "$image_archive" \
        'docker.m.daocloud.io/library/mysql:8.4' \
        'docker.m.daocloud.io/library/node:20-bookworm-slim' \
        'mcr.microsoft.com/playwright:v1.59.1-noble' \
        "$cache_prefix-backend:latest" \
        "$cache_prefix-frontend:latest" \
        "$cache_prefix-runner:latest"
    docker cp "$image_archive" "$dind_id:$dind_archive"
    docker exec "$dind_id" docker load --input "$dind_archive"
fi

for role in backend frontend runner; do
    image="$cache_prefix-$role:latest"
    actual_sha=$(docker exec "$dind_id" docker image inspect --format '{{index .Config.Labels "xhsmedium.preload.sha"}}' "$image")
    actual_role=$(docker exec "$dind_id" docker image inspect --format '{{index .Config.Labels "xhsmedium.preload.role"}}' "$image")
    [ "$actual_sha" = "$sha" ] && [ "$actual_role" = "$role" ] || {
        printf 'DIND cache identity verification failed for %s.\n' "$image" >&2
        exit 65
    }
    printf 'PASS: %s is loaded for %s.\n' "$image" "$sha"
done

for image in 'docker.m.daocloud.io/library/mysql:8.4' 'docker.m.daocloud.io/library/node:20-bookworm-slim' 'mcr.microsoft.com/playwright:v1.59.1-noble'; do
    docker exec "$dind_id" docker image inspect "$image" >/dev/null
    printf 'PASS: runtime image is loaded: %s\n' "$image"
done
printf 'P4_PRELOAD_EVIDENCE: sha=%s prefix=%s\n' "$sha" "$cache_prefix"
