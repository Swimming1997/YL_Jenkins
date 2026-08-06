#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: paper-server-profile.sh <start|stop|status> <regression|release|deploy-dev|deploy-test>

Starts or stops one paper-server heavy profile with bounded Docker health,
Jenkins node, queue, executor, and cleanup checks. Only one heavy profile may
run at a time.
EOF
}

if [ "$#" -ne 2 ]; then
    usage >&2
    exit 64
fi

action=$1
profile=$2
case "$action" in
    start|stop|status) ;;
    *) usage >&2; exit 64 ;;
esac

case "$profile" in
    regression)
        agent=regression-agent
        dind=regression-docker
        ;;
    release)
        agent=release-agent
        dind=release-docker
        ;;
    deploy-dev)
        agent=deploy-dev-agent
        dind=deploy-dev-docker
        ;;
    deploy-test)
        agent=deploy-test-agent
        dind=deploy-test-docker
        ;;
    *) usage >&2; exit 64 ;;
esac
node=$agent

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
if [ "$repo_root" != /opt/jenkins-platform ]; then
    printf 'paper-server profile lifecycle must run from /opt/jenkins-platform.\n' >&2
    exit 64
fi

for command_name in docker curl python3 flock; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '%s is required.\n' "$command_name" >&2
        exit 69
    }
done

lock_path="${TMPDIR:-/tmp}/jenkins-platform-profile-lifecycle.lock"
exec 9>"$lock_path"
if ! flock -n 9; then
    printf 'PROFILE_LIFECYCLE_BLOCKED profile=%s action=%s reason=lifecycle_lock\n' "$profile" "$action" >&2
    exit 79
fi

case "${PAPER_SERVER_PROFILE_POLL_ATTEMPTS:-90}" in
    ''|*[!0-9]*) printf 'PAPER_SERVER_PROFILE_POLL_ATTEMPTS must be an integer from 1 to 300.\n' >&2; exit 64 ;;
esac
poll_attempts=${PAPER_SERVER_PROFILE_POLL_ATTEMPTS:-90}
[ "$poll_attempts" -ge 1 ] && [ "$poll_attempts" -le 300 ] || {
    printf 'PAPER_SERVER_PROFILE_POLL_ATTEMPTS must be an integer from 1 to 300.\n' >&2
    exit 64
}
case "${PAPER_SERVER_PROFILE_POLL_SECONDS:-2}" in
    ''|*[!0-9]*) printf 'PAPER_SERVER_PROFILE_POLL_SECONDS must be an integer from 0 to 10.\n' >&2; exit 64 ;;
esac
poll_seconds=${PAPER_SERVER_PROFILE_POLL_SECONDS:-2}
[ "$poll_seconds" -ge 0 ] && [ "$poll_seconds" -le 10 ] || {
    printf 'PAPER_SERVER_PROFILE_POLL_SECONDS must be an integer from 0 to 10.\n' >&2
    exit 64
}

compose() {
    docker compose -f "$repo_root/compose.yaml" -f "$repo_root/compose.paper-server.yaml" "$@"
}

service_id() {
    compose ps --quiet "$1"
}

service_running() {
    local id
    id=$(service_id "$1")
    [ -n "$id" ] && [ "$(docker inspect --format '{{.State.Running}}' "$id" 2>/dev/null || true)" = true ]
}

service_health() {
    local id
    id=$(service_id "$1")
    [ -n "$id" ] || return 1
    [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)" = healthy ]
}

heavy_services='regression-agent regression-docker release-agent release-docker deploy-dev-agent deploy-dev-docker deploy-test-agent deploy-test-docker'
other_running_services() {
    local service found=''
    for service in $heavy_services; do
        [ "$service" = "$agent" ] && continue
        [ "$service" = "$dind" ] && continue
        if service_running "$service"; then
            found="${found}${found:+,}$service"
        fi
    done
    printf '%s' "$found"
}

temp_root=''
admin_netrc=''
audit_netrc=''
cookie_file=''
json_file=''
rollback_start=false
started_here=0

remove_credentials() {
    if [ -n "$temp_root" ] && [ -d "$temp_root" ]; then
        rm -rf -- "$temp_root"
    fi
}

finish() {
    local original_status=$? cleanup_status=0
    trap - EXIT INT TERM
    if [ "$rollback_start" = true ] && [ "$started_here" -eq 1 ]; then
        compose stop "$agent" "$dind" >/dev/null 2>&1 || cleanup_status=$?
        if service_running "$agent" || service_running "$dind"; then
            cleanup_status=70
        fi
        if [ "$cleanup_status" -eq 0 ]; then
            printf 'PROFILE_LIFECYCLE_CLEANUP profile=%s action=start containers=0 residue=0 status=OK\n' "$profile" >&2
        else
            printf 'PROFILE_LIFECYCLE_CLEANUP profile=%s action=start residue=unknown status=FAILED\n' "$profile" >&2
        fi
    fi
    remove_credentials
    if [ "$cleanup_status" -ne 0 ]; then
        exit 70
    fi
    exit "$original_status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_credentials() {
    local role=$1 secret_file netrc_file
    case "$role" in
        admin)
            secret_file="$repo_root/.secrets/jenkins_admin_password"
            netrc_file=$admin_netrc
            ;;
        audit)
            secret_file="$repo_root/.secrets/jenkins_audit_password"
            netrc_file=$audit_netrc
            ;;
        *) return 64 ;;
    esac
    [ -s "$secret_file" ] || {
        printf 'Missing required Jenkins %s Secret.\n' "$role" >&2
        return 66
    }
    if [ ! -s "$netrc_file" ]; then
        {
            printf 'machine 127.0.0.1 login %s password ' "$role"
            tr -d '\r\n' <"$secret_file"
            printf '\n'
        } >"$netrc_file"
        chmod 0600 "$netrc_file"
    fi
}

ensure_temp_root() {
    if [ -z "$temp_root" ]; then
        umask 077
        temp_root=$(mktemp -d "${TMPDIR:-/tmp}/jenkins-profile-lifecycle.XXXXXX")
        admin_netrc="$temp_root/admin.netrc"
        audit_netrc="$temp_root/audit.netrc"
        cookie_file="$temp_root/cookie"
        json_file="$temp_root/response.json"
    fi
}

jenkins_base=http://127.0.0.1:8080
node_state() {
    ensure_temp_root
    prepare_credentials admin || return $?
    curl --netrc-file "$admin_netrc" --fail --silent --show-error \
        "$jenkins_base/computer/$node/api/json?tree=offline" -o "$json_file" || return $?
    python3 -c 'import json,sys; value=json.load(open(sys.argv[1])).get("offline"); assert isinstance(value,bool); print("offline" if value else "online")' "$json_file"
}

launch_node() {
    local crumb
    ensure_temp_root
    prepare_credentials admin || return $?
    crumb=$(curl --netrc-file "$admin_netrc" --cookie-jar "$cookie_file" --cookie "$cookie_file" \
        --fail --silent --show-error \
        "$jenkins_base/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)") || return $?
    curl --netrc-file "$admin_netrc" --cookie-jar "$cookie_file" --cookie "$cookie_file" \
        --fail --silent --show-error --request POST --header "$crumb" \
        "$jenkins_base/computer/$node/launchSlaveAgent" >/dev/null
}

wait_for_services_healthy() {
    local attempt
    for attempt in $(seq 1 "$poll_attempts"); do
        if service_health "$agent" && service_health "$dind"; then
            return 0
        fi
        sleep "$poll_seconds"
    done
    return 1
}

wait_for_node_state() {
    local expected=$1 attempt current
    for attempt in $(seq 1 "$poll_attempts"); do
        current=$(node_state) || return $?
        if [ "$current" = "$expected" ]; then
            return 0
        fi
        sleep "$poll_seconds"
    done
    return 1
}

jenkins_activity_counts() {
    ensure_temp_root
    prepare_credentials audit || return $?
    curl --netrc-file "$audit_netrc" --globoff --fail --silent --show-error \
        "$jenkins_base/queue/api/json?tree=items[id]" -o "$temp_root/queue.json" || return $?
    curl --netrc-file "$audit_netrc" --globoff --fail --silent --show-error \
        "$jenkins_base/computer/api/json?tree=computer[executors[currentExecutable[url]],oneOffExecutors[currentExecutable[url]]]" \
        -o "$temp_root/executors.json" || return $?
    python3 -c 'import json,sys; q=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); items=q.get("items"); computers=c.get("computer"); assert isinstance(items,list) and isinstance(computers,list) and computers; active=sum(1 for n in computers for e in n.get("executors",[])+n.get("oneOffExecutors",[]) if e.get("currentExecutable")); print(len(items), active)' \
        "$temp_root/queue.json" "$temp_root/executors.json"
}

target_running_count() {
    local count=0
    service_running "$agent" && count=$((count + 1))
    service_running "$dind" && count=$((count + 1))
    printf '%s' "$count"
}

case "$action" in
    start)
        others=$(other_running_services)
        if [ -n "$others" ]; then
            printf 'PROFILE_LIFECYCLE_BLOCKED profile=%s action=start reason=other_heavy_profile services=%s\n' "$profile" "$others" >&2
            exit 79
        fi
        running=$(target_running_count)
        if [ "$running" -eq 1 ]; then
            printf 'PROFILE_LIFECYCLE_INVALID profile=%s action=start reason=partial_profile_state\n' "$profile" >&2
            exit 70
        fi
        if [ "$running" -eq 0 ]; then
            rollback_start=true
            started_here=1
            compose --profile "$profile" up --detach "$dind" "$agent"
        fi
        wait_for_services_healthy || {
            printf 'PROFILE_LIFECYCLE_TIMEOUT profile=%s action=start reason=container_health\n' "$profile" >&2
            exit 70
        }
        current_node_state=$(node_state)
        if [ "$current_node_state" = offline ]; then
            launch_node
        fi
        wait_for_node_state online || {
            printf 'PROFILE_LIFECYCLE_TIMEOUT profile=%s action=start reason=jenkins_node_online\n' "$profile" >&2
            exit 70
        }
        others=$(other_running_services)
        [ -z "$others" ] || {
            printf 'PROFILE_LIFECYCLE_INVALID profile=%s action=start reason=other_profile_started services=%s\n' "$profile" "$others" >&2
            exit 70
        }
        rollback_start=false
        printf 'PROFILE_LIFECYCLE_EVIDENCE profile=%s action=start containers=2 node=online started=%s residue=0 status=OK\n' "$profile" "$started_here"
        ;;
    stop)
        counts=$(jenkins_activity_counts)
        read -r queued active <<<"$counts"
        if [ "$queued" -ne 0 ]; then
            printf 'PROFILE_LIFECYCLE_BLOCKED profile=%s action=stop reason=jenkins_queue count=%s\n' "$profile" "$queued" >&2
            exit 79
        fi
        if [ "$active" -ne 0 ]; then
            printf 'PROFILE_LIFECYCLE_BLOCKED profile=%s action=stop reason=active_executor count=%s\n' "$profile" "$active" >&2
            exit 79
        fi
        compose stop "$agent" "$dind"
        if service_running "$agent" || service_running "$dind"; then
            printf 'PROFILE_LIFECYCLE_INVALID profile=%s action=stop reason=container_still_running\n' "$profile" >&2
            exit 70
        fi
        wait_for_node_state offline || {
            printf 'PROFILE_LIFECYCLE_TIMEOUT profile=%s action=stop reason=jenkins_node_offline\n' "$profile" >&2
            exit 70
        }
        printf 'PROFILE_LIFECYCLE_EVIDENCE profile=%s action=stop containers=0 node=offline residue=0 status=OK\n' "$profile"
        ;;
    status)
        running=$(target_running_count)
        node_state=$(node_state)
        others=$(other_running_services)
        other_count=0
        [ -z "$others" ] || other_count=$(printf '%s' "$others" | awk -F, '{print NF}')
        if { [ "$running" -eq 0 ] && [ "$node_state" = offline ]; } || \
            { [ "$running" -eq 2 ] && [ "$node_state" = online ]; }; then
            printf 'PROFILE_LIFECYCLE_EVIDENCE profile=%s action=status containers=%s node=%s other_containers=%s residue=0 status=OK\n' \
                "$profile" "$running" "$node_state" "$other_count"
        else
            printf 'PROFILE_LIFECYCLE_EVIDENCE profile=%s action=status containers=%s node=%s other_containers=%s residue=unknown status=INVALID\n' \
                "$profile" "$running" "$node_state" "$other_count" >&2
            exit 70
        fi
        ;;
esac
