#!/usr/bin/env bash
set -euo pipefail

sha=''
slot=''
timeout_minutes=430
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sha) sha=${2:-}; shift 2 ;;
        --slot) slot=${2:-}; shift 2 ;;
        --timeout-minutes) timeout_minutes=${2:-}; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
    esac
done
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { printf 'A full lowercase SHA is required.\n' >&2; exit 64; }
[[ $slot =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:00:00Z$ ]] || { printf 'An even UTC validation slot is required.\n' >&2; exit 64; }
[ $((10#${slot:11:2} % 2)) -eq 0 ] || { printf 'Validation slot must use an even UTC hour.\n' >&2; exit 64; }
[[ $timeout_minutes =~ ^[0-9]+$ ]] && [ "$timeout_minutes" -gt 0 ] || { printf 'Timeout must be a positive number of minutes.\n' >&2; exit 64; }

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
base='http://127.0.0.1:8080'
job="$base/job/XHSMedium/job/Regression/job/scheduled"
auth=$(mktemp)
cookie=$(mktemp)
scan=$(mktemp -d)
cleanup() { rm -f -- "$auth" "$cookie"; rm -rf -- "$scan"; }
trap cleanup EXIT
trap 'exit 130' INT TERM
{ printf 'machine 127.0.0.1 login admin password '; tr -d '\r\n' <"$repo_root/.secrets/jenkins_admin_password"; printf '\n'; } >"$auth"
chmod 0600 "$auth"

config=$(curl --netrc-file "$auth" -fsS "$job/config.xml")
if printf '%s' "$config" | grep -q 'TimerTrigger'; then
    printf 'paper-server regression Job unexpectedly contains a timer trigger.\n' >&2
    exit 65
fi
next=$(curl -g --netrc-file "$auth" -fsS "$job/api/json?tree=nextBuildNumber" | sed -n 's/.*"nextBuildNumber":\([0-9][0-9]*\).*/\1/p')
[ -n "$next" ] || { printf 'Could not resolve the next build number.\n' >&2; exit 69; }
crumb=$(curl --netrc-file "$auth" --cookie-jar "$cookie" --cookie "$cookie" -fsS "$base/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
curl --netrc-file "$auth" --cookie-jar "$cookie" --cookie "$cookie" -fsS -X POST -H "$crumb" \
    --data-urlencode 'BRANCH=dev' \
    --data-urlencode "GIT_SHA=$sha" \
    --data-urlencode "VALIDATION_SLOT_UTC=$slot" \
    --data-urlencode 'VALIDATION_TIMEOUT_MINUTES=0' \
    "$job/buildWithParameters" >/dev/null
printf 'INFO: triggered paper-server regression build %s for %s.\n' "$next" "$sha"

deadline=$((SECONDS + timeout_minutes * 60))
result=''
while [ "$SECONDS" -lt "$deadline" ]; do
    json=$(curl -g --netrc-file "$auth" -fsS "$job/$next/api/json?tree=building,result,duration" 2>/dev/null || true)
    if [ -n "$json" ] && printf '%s' "$json" | grep -q '"building":false'; then
        result=$(printf '%s' "$json" | sed -n 's/.*"result":"\([A-Z]*\)".*/\1/p')
        duration=$(printf '%s' "$json" | sed -n 's/.*"duration":\([0-9][0-9]*\).*/\1/p')
        break
    fi
    sleep 15
done
[ "$result" = 'SUCCESS' ] || { printf 'Regression build %s did not complete successfully; result=%s.\n' "$next" "${result:-timeout}" >&2; exit 1; }

console="$scan/console.txt"
curl --netrc-file "$auth" -fsS "$job/$next/consoleText" -o "$console"
grep -q 'Running on regression-agent' "$console"
grep -q 'P4_SCHEDULED_REGRESSION_OK' "$console"
identity=$(grep -Eo 'P4_SCHEDULED_REGRESSION_OK runId=scheduled-[0-9]{8}-[0-9]{6}-[0-9a-f]{8} sha=[0-9a-f]{40}' "$console" | tail -n1)
run_id=$(printf '%s' "$identity" | sed -n 's/.*runId=\([^ ]*\) sha=.*/\1/p')
tested_sha=$(printf '%s' "$identity" | sed -n 's/.* sha=\([0-9a-f]*\)$/\1/p')
[ "$tested_sha" = "$sha" ] || { printf 'Completion marker SHA does not match.\n' >&2; exit 65; }

curl --netrc-file "$auth" -fsS "$job/$next/artifact/offline-dependency-cache.log" -o "$scan/offline-dependency-cache.log"
curl --netrc-file "$auth" -fsS "$job/$next/artifact/artifacts/test-runs/$run_id/summary.json" -o "$scan/summary.json"
grep -q "OFFLINE_DEPENDENCY_CACHE role=runner sha=$sha" "$scan/offline-dependency-cache.log"
grep -q "OFFLINE_DEPENDENCY_CACHE role=backend,frontend sha=$sha" "$scan/offline-dependency-cache.log"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"PASSED"' "$scan/summary.json"
grep -Eq '"succeeded"[[:space:]]*:[[:space:]]*true' "$scan/summary.json"

controller=$(docker compose -f "$repo_root/compose.yaml" -f "$repo_root/compose.paper-server.yaml" ps --quiet controller)
archive_path="/var/jenkins_home/jobs/XHSMedium/jobs/Regression/jobs/scheduled/builds/$next/archive"
docker cp "$controller:$archive_path/." "$scan/artifacts"
token=$(tr -d '\r\n' <"$repo_root/.secrets/xhsmedium_scm_token")
[ -n "$token" ] || { printf 'SCM token is empty.\n' >&2; exit 66; }
if grep -rFq -- "$token" "$scan"; then
    printf 'SCM token was found in console or artifacts.\n' >&2
    exit 65
fi

project="xhsmedium-test-$run_id"
regression_docker=$(docker compose -f "$repo_root/compose.yaml" -f "$repo_root/compose.paper-server.yaml" ps --quiet regression-docker)
regression_agent=$(docker compose -f "$repo_root/compose.yaml" -f "$repo_root/compose.paper-server.yaml" ps --quiet regression-agent)
[ -n "$regression_docker" ] && [ -n "$regression_agent" ]
stage_count=$(docker exec -i "$regression_agent" node -e '
const fs = require("fs");
const summary = JSON.parse(fs.readFileSync(0, "utf8"));
const coverage = summary.coverage || {};
if (summary.status !== "PASSED" || summary.testedSha !== process.argv[1] || summary.executor !== "docker") process.exit(2);
if (!Array.isArray(summary.stages) || summary.stages.some((stage) => stage.status !== "PASSED")) process.exit(3);
if (coverage.covered !== 2 || coverage.partial !== 0 || coverage.blocked !== 0 || summary.firstFailure !== null) process.exit(4);
if (!summary.cleanup || !summary.cleanup.attempted || !summary.cleanup.succeeded) process.exit(5);
process.stdout.write(String(summary.stages.length));
' "$sha" <"$scan/summary.json")
[ "$stage_count" = 11 ] || { printf 'Expected 11 passing regression stages; found %s.\n' "$stage_count" >&2; exit 65; }
[ -z "$(docker exec "$regression_docker" docker ps -aq --filter "label=com.docker.compose.project=$project")" ]
[ -z "$(docker exec "$regression_docker" docker volume ls -q --filter "label=com.docker.compose.project=$project")" ]
[ -z "$(docker exec "$regression_docker" docker network ls -q --filter "label=com.docker.compose.project=$project")" ]
[ -z "$(docker exec "$regression_agent" sh -lc 'find /home/jenkins/agent -mindepth 1 -maxdepth 8 -path "*/workspace/XHSMedium/Regression/scheduled/*" -print -quit')" ]
[ -z "$(docker exec "$regression_agent" sh -lc 'find /tmp -maxdepth 1 -name "jenkins-XHSMedium-Regression-scheduled-*-npm-cache" -print -quit')" ]
[ -z "$(docker exec "$regression_agent" sh -lc 'find /tmp -maxdepth 1 -name "npm-ci-network-retry.*" -print -quit')" ]
printf 'P4_PAPER_SERVER_EVIDENCE: build=%s runId=%s sha=%s duration_ms=%s token_leak=NO cleanup=OK\n' "$next" "$run_id" "$sha" "$duration"
